package main

import (
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
