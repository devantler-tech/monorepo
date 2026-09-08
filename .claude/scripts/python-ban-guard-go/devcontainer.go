package main

import (
	"encoding/json"
	"errors"
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
// themselves strings or argv arrays. JSONC comments and trailing commas become whitespace,
// preserving every byte offset and newline used to locate the executable values.
func (s *scanner) devcontainerCommands(src string) (bool, error) {
	jsonSource, err := devcontainerJSON(src)
	if err != nil {
		return false, err
	}
	if !json.Valid([]byte(jsonSource)) {
		return false, nil
	}

	decoder := json.NewDecoder(strings.NewReader(jsonSource))
	if open, err := decoder.Token(); err != nil || open != json.Delim('{') {
		return false, nil
	}

	type lifecycleCommand struct {
		value json.RawMessage
		start int
	}
	lifecycle := make(map[string]lifecycleCommand)

	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return false, err
		}

		name, _ := key.(string)

		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return false, err
		}
		start := int(decoder.InputOffset()) - len(value)

		if !devcontainerLifecycle[name] {
			continue
		}

		// Preserve JSON's last-value-wins behavior for duplicate member names, exactly as
		// devcontainerObject does. Scanning every occurrence would report a shadowed earlier
		// value as a command the resolver never runs.
		lifecycle[name] = lifecycleCommand{value: value, start: start}
	}

	commands := make([]lifecycleCommand, 0, len(lifecycle))
	for _, command := range lifecycle {
		commands = append(commands, command)
	}
	// Map iteration is unordered, so restore source order before scanning: findings are
	// reported by position and must not depend on Go's map ordering.
	slices.SortFunc(commands, func(a, b lifecycleCommand) int { return a.start - b.start })

	for _, command := range commands {
		if err := s.devcontainerValue(src, command.value, command.start, true); err != nil {
			return false, err
		}
	}

	return true, nil
}

// devcontainerJSON removes JSONC syntax without moving strings or their source locations.
func devcontainerJSON(src string) (string, error) {
	data := []byte(src)
	quoted := false
	for i := 0; i < len(data); i++ {
		if quoted {
			if data[i] == '\\' {
				i++
			} else if data[i] == '"' {
				quoted = false
			}
			continue
		}
		if data[i] == '"' {
			quoted = true
			continue
		}
		if data[i] != '/' || i+1 >= len(data) {
			continue
		}
		switch data[i+1] {
		case '/':
			for i < len(data) && data[i] != '\n' && data[i] != '\r' {
				data[i] = ' '
				i++
			}
		case '*':
			data[i], data[i+1] = ' ', ' '
			i += 2
			for i+1 < len(data) && !(data[i] == '*' && data[i+1] == '/') {
				if data[i] != '\n' && data[i] != '\r' {
					data[i] = ' '
				}
				i++
			}
			if i+1 >= len(data) {
				return "", errors.New("unterminated devcontainer JSONC comment")
			}
			data[i], data[i+1] = ' ', ' '
			i++
		}
	}
	quoted = false
	for i := 0; i < len(data); i++ {
		if quoted {
			if data[i] == '\\' {
				i++
			} else if data[i] == '"' {
				quoted = false
			}
			continue
		}
		if data[i] == '"' {
			quoted = true
			continue
		}
		if data[i] != ',' {
			continue
		}
		j := i + 1
		for j < len(data) && strings.ContainsRune(" \t\r\n", rune(data[j])) {
			j++
		}
		if j < len(data) && (data[j] == '}' || data[j] == ']') {
			data[i] = ' '
		}
	}
	return string(data), nil
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

// devcontainerObject keeps each parallel command's source offset, including identical values.
func (s *scanner) devcontainerObject(src string, value json.RawMessage, start int) error {
	decoder := json.NewDecoder(strings.NewReader(string(value)))
	if _, err := decoder.Token(); err != nil {
		return err
	}
	type command struct {
		value json.RawMessage
		start int
	}
	// Preserve JSON's existing last-value-wins behavior for duplicate member names.
	members := make(map[string]command)
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return err
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return err
		}
		name, _ := key.(string)
		members[name] = command{value: raw, start: start + int(decoder.InputOffset()) - len(raw)}
	}
	commands := make([]command, 0, len(members))
	for _, member := range members {
		commands = append(commands, member)
	}
	slices.SortFunc(commands, func(a, b command) int { return a.start - b.start })
	for _, member := range commands {
		if err := s.devcontainerValue(src, member.value, member.start, false); err != nil {
			return err
		}
	}

	return nil
}
