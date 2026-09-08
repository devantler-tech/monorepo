package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// python-ban-guard: allow-file — inert YAML fixtures verify command and literal argv boundaries.

// TestYAMLCommandOperands preserves decoded scalar boundaries while following executable operands.
func TestYAMLCommandOperands(t *testing.T) {
	tests := []struct {
		name, source, want string
	}{
		{"scalar command", "command: python3 --version\n", ":1: Python invocation"},
		{"scalar run", "run: pip3 --version\n", "Python invocation"},
		{"scalar shell", "shell: /usr/bin/python3\n", "Python invocation"},
		{"array command", "command: [python3, --version]\n", "Python invocation"},
		{"array run", "run: [python3, --version]\n", "Python invocation"},
		{"array shell", "shell: [python3, --version]\n", "Python invocation"},
		{"nested command", "spec:\n  containers:\n    - command: [python3, --version]\n", ":3: Python invocation"},
		{"block argv location", "command:\n  - python3\n  - --version\n", ":2: Python invocation"},
		{"block scalar location", "command: |\n  echo safe\n  python3 --version\n", ":3: Python invocation"},
		{"nested shell program", "command: [sh, -c, 'echo safe; python3 --version']\n", "Python invocation"},
		{"wrapper arguments", "command: [env, python3, --version]\n", "Python invocation"},
		{"array argument is data", "command: [echo, python3]\n", ""},
		{"array whitespace stays literal", "command: [\"python 3\", --version]\n", ""},
		{"array semicolon stays literal", "command: [\"python;3\", --version]\n", ""},
		{"array escaped apostrophe stays literal", "command: ['python''3', --version]\n", ""},
		{"array brackets stay literal", "command: ['python[3]', --version]\n", ""},
		{"array comma stays literal", "command: ['python,3', --version]\n", ""},
		{"array shell punctuation is data", "command: [echo, 'safe; python3 --version']\n", ""},
		{"quoted scalar executable whitespace", "command: '\"python 3\" --version'\n", ""},
		{"quoted scalar executable punctuation", "command: '\"python;3\" --version'\n", ""},
		{"scalar shell punctuation executes", "command: 'echo safe; python3 --version'\n", "Python invocation"},
		{"unicode escape decoded in argv", "command: [\"pyth\\u006fn3\", --version]\n", "Python invocation"},
		{"metadata values stay data", "description: python3\nannotation: [python3, --version]\nargs: [python3]\n", ""},
		{"metadata text does not introduce keys", "description: 'command: python3 --version'\n", ""},
		{"quoted marker stays data", "annotation: 'python-ban-guard: allow-file — search data'\ncommand: [python3]\n", "Python invocation"},
		{"real comment exempts", "# python-ban-guard: allow-file — documented command fixture\ncommand: [python3]\n", ""},
		{"bare comment marker reports", "# python-ban-guard: allow-file\ncommand: [echo, safe]\n", "bare"},
		{"scalar alias command", "value: &cmd python3 --version\ncommand: *cmd\n", ":1: Python invocation"},
		{"argv alias command", "value: &cmd [python3, --version]\ncommand: *cmd\n", ":1: Python invocation"},
		{"argv element alias", "value: &exe python3\ncommand: [*exe, --version]\n", ":1: Python invocation"},
		{"aliased metadata remains data", "value: &cmd [python3]\ndescription: *cmd\n", ""},
		{"mapping key alias", "name: &key command\n*key: [python3]\n", ":2: Python invocation"},
		{"later YAML document", "description: safe\n---\ncommand: [python3]\n", ":3: Python invocation"},
		{"empty document", "", ""},
		{"scalar command joins args", "command: sh\nargs: ['-c', 'python3 --version']\n", "Python invocation"},
		{"array command joins args", "command: [sh, -c]\nargs: ['python3 --version']\n", "Python invocation"},
		{"joined argv argument stays data", "command: echo\nargs: [python3]\n", ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: "deploy/pod.yaml", seen: make(map[string]bool)}
			if err := s.yamlCommands(test.source); err != nil {
				t.Fatal(err)
			}
			if test.want == "" {
				if len(s.hits) != 0 {
					t.Errorf("data reported as executable: %v", s.hits)
				}
			} else if len(s.hits) != 1 || !strings.Contains(s.hits[0], test.want) {
				t.Errorf("findings=%v; want one containing %q", s.hits, test.want)
			}
		})
	}
}

// TestYAMLCommandErrors keeps malformed YAML, argv, commands and aliases fail-closed.
func TestYAMLCommandErrors(t *testing.T) {
	for _, test := range []struct{ name, source, want string }{
		{"malformed YAML", "command: [python3\n", "cannot parse YAML commands"},
		{"malformed later document", "command: echo safe\n---\ncommand: [python3\n", "cannot parse YAML commands"},
		{"metadata alias cycle", "metadata: &loop {again: *loop}\n", "cyclic YAML alias"},
		{"command alias cycle", "command: &loop [*loop]\n", "cyclic YAML alias"},
		{"nonscalar argv", "command: [echo, {data: value}]\n", "YAML command argv"},
		{"malformed scalar command", "command: echo 'unfinished\n", "cannot parse shell commands"},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: "deploy/pod.yaml", seen: make(map[string]bool)}
			if err := s.yamlCommands(test.source); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Errorf("error=%v; want %q", err, test.want)
			}
		})
	}
}

// TestYAMLCommandsNeverExecute ensures nested shell programs are parsed, never evaluated.
func TestYAMLCommandsNeverExecute(t *testing.T) {
	markerPath := filepath.Join(t.TempDir(), "executed")
	s := scanner{path: "deploy/pod.yaml", seen: make(map[string]bool)}
	program := "touch " + strconv.Quote(markerPath) + "; python3 --version"
	if err := s.yamlCommands("command: [sh, -c, " + strconv.Quote(program) + "]\n"); err != nil {
		t.Fatal(err)
	}
	if len(s.hits) != 1 {
		t.Fatalf("findings=%v; want Python invocation", s.hits)
	}
	if _, err := os.Stat(markerPath); !os.IsNotExist(err) {
		t.Fatalf("nested shell payload executed: stat error=%v", err)
	}
}

// TestNestedAliasesDoNotExplode pins the traversal cost of repeated YAML aliases.
// Decoding into raw nodes means yaml.v3 never expands aliases, so `visit` follows
// them itself. Without memoizing completed visits each level doubles the work, and
// a document this small becomes unscannable: measured before the fix, 26 levels
// took 72s and 24 levels took 19s from a 553-byte file. This test would not
// complete at 40 levels without that memoization.
func TestNestedAliasesDoNotExplode(t *testing.T) {
	const levels = 40
	var b strings.Builder
	b.WriteString("l0: &a0 [t, t, t, t]\n")
	for i := 1; i <= levels; i++ {
		fmt.Fprintf(&b, "l%d: &a%d [*a%d, *a%d]\n", i, i, i-1, i-1)
	}
	fmt.Fprintf(&b, "top: [*a%d, *a%d]\n", levels, levels)

	s := scanner{path: "deploy/pod.yaml", seen: map[string]bool{}}
	if err := s.yamlCommands(b.String()); err != nil {
		t.Fatalf("scan error: %v", err)
	}
	if len(s.hits) != 0 {
		t.Fatalf("hits = %v, want none", s.hits)
	}
}

// TestNestedAliasesStillReachCommands proves the memoization does not skip work
// that matters: an interpreter behind an alias is still reported.
func TestNestedAliasesStillReachCommands(t *testing.T) {
	s := scanner{path: "deploy/pod.yaml", seen: map[string]bool{}}
	if err := s.yamlCommands("exe: &e python3\ndup: [*e, *e]\ncommand: [*e, --version]\n"); err != nil {
		t.Fatalf("scan error: %v", err)
	}
	if len(s.hits) == 0 {
		t.Fatal("interpreter behind an alias was not reported")
	}
}
