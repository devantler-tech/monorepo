package main

import (
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
			name: "comment bearing jsonc defers to the fallback", path: ".devcontainer.json",
			source:  "{\n  // a comment makes this JSONC\n  \"postCreateCommand\": \"echo safe\"\n}\n",
			handled: false,
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
