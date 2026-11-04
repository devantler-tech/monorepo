package main

import (
	"encoding/json"
	"errors"
	"strings"
)

// The Bash implementation turned every commit into a jq `@tsv` row and split it back with
// `IFS=$'\t' read -r`. Both halves are reproduced exactly, so a row with an empty or unusual
// field reads the same way it always did.

var errNotScalar = errors.New("value cannot be tsv-formatted")

// tsvField is one jq `@tsv` cell: null is empty, strings are escaped, numbers and booleans print
// as JSON, and arrays or objects are an error.
func tsvField(value any) (string, error) {
	switch typed := value.(type) {
	case nil:
		return "", nil
	case string:
		return strings.NewReplacer(`\`, `\\`, "\t", `\t`, "\n", `\n`, "\r", `\r`).Replace(typed), nil
	case bool:
		if typed {
			return "true", nil
		}
		return "false", nil
	case json.Number:
		return typed.String(), nil
	default:
		return "", errNotScalar
	}
}

// toString is jq's `tostring`: a string is itself, anything else is its JSON text.
func toString(value any) string {
	if s, isString := value.(string); isString {
		return s
	}
	if value == nil {
		return "null"
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return string(encoded)
}

// truthy is jq's notion of a value that `//` keeps: anything but null and false.
func truthy(value any) bool {
	if value == nil {
		return false
	}
	if b, isBool := value.(bool); isBool {
		return b
	}
	return true
}

// readFields is `IFS=$'\t' read -r v1 … vn` on one line. A tab is IFS whitespace, so runs of
// tabs are one separator and leading or trailing tabs are dropped; the last variable takes the
// rest of the line, minus trailing tabs.
func readFields(line string, n int) []string {
	fields := make([]string, n)
	rest := strings.TrimLeft(line, "\t")
	for i := 0; i < n; i++ {
		if i == n-1 {
			fields[i] = strings.TrimRight(rest, "\t")
			break
		}
		cut := strings.IndexByte(rest, '\t')
		if cut < 0 {
			fields[i] = rest
			rest = ""
			continue
		}
		fields[i] = rest[:cut]
		rest = strings.TrimLeft(rest[cut:], "\t")
	}
	return fields
}

// lines splits text the way `while read … done <<<"$text"` visits it: one entry per line,
// with no entry for the final newline.
func lines(text string) []string {
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

// countNonEmpty is `grep -c .`.
func countNonEmpty(text string) int {
	n := 0
	for _, line := range strings.Split(text, "\n") {
		if line != "" {
			n++
		}
	}
	return n
}
