package main

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// python-ban-guard: allow-file — inert devcontainer fixtures verify lifecycle command boundaries.

// TestDevcontainerLifecycleCommands follows executed lifecycle values while leaving metadata alone.
func TestDevcontainerLifecycleCommands(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name, path, source, want string
		handled                  bool
	}{
		{
			name: "string lifecycle command", path: ".devcontainer.json",
			source:  "{\n  \"postCreateCommand\": \"python3 --version\"\n}\n",
			handled: true, want: ":2: Python invocation",
		},
		{
			name: "array lifecycle command", path: ".devcontainer.json",
			source:  "{\n  \"onCreateCommand\": [\"python3\", \"--version\"]\n}\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "object lifecycle command", path: ".devcontainer.json",
			source:  "{\n  \"postStartCommand\": {\n    \"deps\": \"python3 --version\"\n  }\n}\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "nested devcontainer directory", path: ".devcontainer/devcontainer.json",
			source:  "{\n  \"initializeCommand\": \"python3 --version\"\n}\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "non lifecycle key stays data", path: ".devcontainer.json",
			source:  "{\n  \"name\": \"python3 --version\"\n}\n",
			handled: true,
		},
		{
			name: "lifecycle argument stays data", path: ".devcontainer.json",
			source:  "{\n  \"postCreateCommand\": [\"echo\", \"python3\"]\n}\n",
			handled: true,
		},
		{
			name: "comment bearing jsonc is handled", path: ".devcontainer.json",
			source:  "{\n  // a comment makes this JSONC\n  \"postCreateCommand\": \"echo safe\"\n}\n",
			handled: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			s := scanner{path: test.path, seen: make(map[string]bool)}
			handled, err := s.file(test.source)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if handled != test.handled {
				t.Fatalf("handled=%v; want %v", handled, test.handled)
			}
			got := strings.Join(s.hits, "\n")
			if test.want == "" && got != "" {
				t.Errorf("data reported as executable: %s", got)
			}
			if test.want != "" && !strings.Contains(got, test.want) {
				t.Errorf("findings %q do not contain %q", got, test.want)
			}
		})
	}
}

// TestDevcontainerJSONC scans standard commented configurations without moving diagnostics.
func TestDevcontainerJSONC(t *testing.T) {
	for _, test := range []struct {
		name, source string
		lines        []int
	}{
		{"line comment", "{\n// ordinary comment\n\"postCreateCommand\": \"python3 --version\"\n}", []int{3}},
		{"block comment before value", "{\n\"postCreateCommand\": /* unicode æ\ncomment */\n\"python3 --version\"\n}", []int{4}},
		{"parallel comments retain distinct lines", "{\n\"postCreateCommand\": {\n// first\n\"a\": \"python3 --version\",\n/* second */\n\"b\": [\"python3\", /* argument */ \"--version\"]\n}\n}", []int{4, 6}},
		{"trailing commas with comments", "{\n\"postCreateCommand\": [\"python3\", \"--version\", /* trailing */], // trailing\n}", []int{2}},
		{"commented command is data", "{\n// \"postCreateCommand\": \"python3 --version\"\n\"name\": \"safe\"\n}", nil},
		{"block commented command is data", "{/* \"postCreateCommand\": \"python3 --version\", */\"name\": \"safe\"}", nil},
		{"comment delimiters in strings", "{\"postCreateCommand\": [\"echo\", \"https://example.test/*safe*/\", \"\\\"//safe\"], // comment\n}", nil},
		{"CRLF comment", "{\r\n// comment\r\n\"postCreateCommand\": \"python3 --version\"\r\n}", []int{3}},
		{"EOF comment", "{\"postCreateCommand\": \"python3 --version\"}// trailing comment", []int{1}},
		{"comma and delimiters inside command", "{\"postCreateCommand\": \"echo ',}' '/*' '//'; python3 --version\",}", []int{1}},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: ".devcontainer.json", seen: make(map[string]bool)}
			handled, err := s.file(test.source)
			if err != nil || !handled {
				t.Fatalf("scan: handled=%v error=%v", handled, err)
			}
			if len(s.hits) != len(test.lines) {
				t.Fatalf("findings=%v; expected lines %v", s.hits, test.lines)
			}
			for i, line := range test.lines {
				want := fmt.Sprintf(".devcontainer.json:%d: Python invocation", line)
				if !strings.HasPrefix(s.hits[i], want) {
					t.Errorf("finding=%q; want prefix %q", s.hits[i], want)
				}
			}
		})
	}
}

// TestDevcontainerCommandLocations preserves separate identical commands and value offsets.
func TestDevcontainerCommandLocations(t *testing.T) {
	for _, test := range []struct {
		name, source string
		want         []string
	}{
		{
			name:   "identical parallel strings in source order",
			source: "{\n  \"postCreateCommand\": {\n    \"z\": \"python3 --version\",\n    \"a\": \"python3 --version\"\n  }\n}",
			want:   []string{".devcontainer.json:3: Python invocation `python3 --version`", ".devcontainer.json:4: Python invocation `python3 --version`"},
		},
		{
			name:   "identical parallel argv arrays",
			source: "{\n  \"postCreateCommand\": {\n    \"z\": [\"python3\", \"--version\"],\n    \"a\": [\"python3\", \"--version\"]\n  }\n}",
			want:   []string{".devcontainer.json:3: Python invocation `python3 --version`", ".devcontainer.json:4: Python invocation `python3 --version`"},
		},
		{
			name:   "parallel object and command start below their keys",
			source: "{\n  \"postCreateCommand\":\n  {\n    \"z\":\n      \"python3 --version\",\n    \"a\":\n      \"python3 --version\"\n  }\n}",
			want:   []string{".devcontainer.json:5: Python invocation `python3 --version`", ".devcontainer.json:7: Python invocation `python3 --version`"},
		},
		{
			name:   "overridden parallel member stays data",
			source: "{\n  \"postCreateCommand\": {\n    \"x\": \"python3 --version\",\n    \"x\": \"echo safe\"\n  }\n}",
		},
		{
			name:   "string starts below lifecycle key",
			source: "{\n  \"postCreateCommand\":\n    \"python3 --version\"\n}",
			want:   []string{".devcontainer.json:3: Python invocation `python3 --version`"},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: ".devcontainer.json", seen: make(map[string]bool)}
			handled, err := s.file(test.source)
			if err != nil || !handled {
				t.Fatalf("devcontainer scan: handled=%v, error=%v", handled, err)
			}
			if !slices.Equal(s.hits, test.want) {
				t.Errorf("findings=%v; want %v", s.hits, test.want)
			}
		})
	}
}
