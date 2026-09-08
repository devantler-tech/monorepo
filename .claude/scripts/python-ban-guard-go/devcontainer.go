package main

import (
	"encoding/json"
	"path/filepath"
	"slices"
	"strings"
)

// devcontainerLifecycle names the Dev Container properties whose values are executed during
// container setup or attachment, so Python selected there runs exactly as it would from a script.
// https://containers.dev/implementors/json_reference/#lifecycle-scripts
var devcontainerLifecycle = map[string]bool{
	"initializeCommand":    true,
	"onCreateCommand":      true,
	"updateContentCommand": true,
	"postCreateCommand":    true,
	"postStartCommand":     true,
	"postAttachCommand":    true,
}

// devcontainerSourcePath identifies the two standard Dev Container configuration locations.
func devcontainerSourcePath(path string) bool {
	slash := filepath.ToSlash(path)
	base := filepath.Base(slash)
	if base == ".devcontainer.json" {
		return true
	}

	return base == "devcontainer.json" &&
		(strings.HasPrefix(slash, ".devcontainer/") || strings.Contains(slash, "/.devcontainer/"))
}

// devcontainerCommands scans each lifecycle value while retaining its original line number.
//
// A lifecycle value is a string (shell source), an argv array, or an object whose values are
// themselves strings or argv arrays. Anything the standard JSON decoder cannot read — a
// comment-bearing JSONC file being the common case — is reported unhandled so the caller's
// existing fallback still sees the file, rather than erroring on a legitimate configuration.
func (s *scanner) devcontainerCommands(src string) (bool, error) {
	if !json.Valid([]byte(src)) {
		return false, nil
	}

	decoder := json.NewDecoder(strings.NewReader(src))
	if open, err := decoder.Token(); err != nil || open != json.Delim('{') {
		return false, nil
	}

	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return false, err
		}

		name, _ := key.(string)
		start := int(decoder.InputOffset())

		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return false, err
		}

		if !devcontainerLifecycle[name] {
			continue
		}

		if err := s.devcontainerValue(src, value, start, true); err != nil {
			return false, err
		}
	}

	return true, nil
}

// devcontainerValue scans one lifecycle value. Object forms name parallel commands, so their
// members are scanned as commands too; nesting beyond that is not part of the specification.
func (s *scanner) devcontainerValue(
	src string, value json.RawMessage, start int, allowObject bool,
) error {
	trimmed := strings.TrimSpace(string(value))
	line := 1 + strings.Count(src[:start], "\n") +
		strings.Count(string(value)[:len(value)-len(strings.TrimLeft(string(value), " \t\r\n"))], "\n")

	switch {
	case strings.HasPrefix(trimmed, `"`):
		var program string
		if err := json.Unmarshal(value, &program); err != nil {
			return err
		}

		return s.source(program, line, 0, false)
	case strings.HasPrefix(trimmed, "["):
		var args []string
		if err := json.Unmarshal(value, &args); err != nil {
			// A non-string element cannot statically name an executable; leave it as data.
			return nil //nolint:nilerr // a malformed argv is data, not a scanning failure
		}

		known := make([]bool, len(args))
		for i := range known {
			known[i] = true
		}

		_, err := s.argv(args, known, line, 0)

		return err
	case strings.HasPrefix(trimmed, "{") && allowObject:
		return s.devcontainerObject(src, value, start)
	}

	return nil
}

// devcontainerObject scans each member of a parallel-command object in a deterministic order.
func (s *scanner) devcontainerObject(src string, value json.RawMessage, start int) error {
	var members map[string]json.RawMessage
	if err := json.Unmarshal(value, &members); err != nil {
		return err
	}

	names := make([]string, 0, len(members))
	for name := range members {
		names = append(names, name)
	}

	slices.Sort(names)

	for _, name := range names {
		offset := strings.Index(src[start:], string(members[name]))
		if offset < 0 {
			offset = 0
		}

		if err := s.devcontainerValue(src, members[name], start+offset, false); err != nil {
			return err
		}
	}

	return nil
}
