package main

import (
	"strings"
	"testing"
)

// python-ban-guard: allow-file — inert workflow fixtures distinguish commands from data.

// TestWorkflowSchemaPositions rejects only commands in executable workflow fields.
func TestWorkflowSchemaPositions(t *testing.T) {
	tests := []struct {
		name, source, want string
	}{
		{"workflow env run is data", "env: {run: 'python3 --version'}\n", ""},
		{"workflow env shell is data", "env: {shell: python3}\n", ""},
		{"job env is data", "jobs:\n  test:\n    env: {run: 'python3 --version', shell: python3}\n", ""},
		{"step env is data", "jobs:\n  test:\n    steps:\n      - env: {run: 'python3 --version', shell: python3}\n        run: echo safe\n", ""},
		{"action inputs are data", "jobs:\n  test:\n    steps:\n      - uses: example/action@v1\n        with: {run: 'python3 --version', shell: python3}\n", ""},
		{"dispatch input names are data", "on:\n  workflow_dispatch:\n    inputs:\n      run: {description: python3, default: 'python3 --version'}\n      shell: {description: python3, default: python3}\n", ""},
		{"reusable workflow inputs are data", "jobs:\n  test:\n    uses: ./workflow.yml\n    with: {run: 'python3 --version', shell: python3}\n", ""},
		{"metadata run is data", "metadata: {run: 'python3 --version', shell: python3}\n", ""},
		{"top level steps are not workflow steps", "steps:\n  - run: python3 --version\n", ""},
		{"nested fake steps are data", "jobs:\n  test:\n    env:\n      steps:\n        - run: python3 --version\n", ""},
		{"workflow working directory is data", "defaults:\n  run:\n    working-directory: python3\n", ""},
		{"real step run", "jobs:\n  test:\n    steps:\n      - run: python3 --version\n", ":4: Python invocation"},
		{"real step shell", "jobs:\n  test:\n    steps:\n      - run: echo safe\n        shell: python3 {0}\n", ":5: Python invocation"},
		{"workflow default shell", "defaults:\n  run:\n    shell: python3\n", ":3: Python invocation"},
		{"job default shell", "jobs:\n  test:\n    defaults:\n      run:\n        shell: python3\n", ":5: Python invocation"},
		{"block command location", "jobs:\n  test:\n    steps:\n      - run: |\n          echo safe\n          python3 --version\n", ":6: Python invocation"},
		{"aliased command keeps anchor location", "env:\n  TEXT: &command python3 --version\njobs:\n  test:\n    steps:\n      - run: *command\n", ":2: Python invocation"},
		{"aliased jobs retain schema position", "metadata: &jobs\n  test:\n    steps:\n      - run: python3 --version\njobs: *jobs\n", ":4: Python invocation"},
		{"data alias stays data", "env:\n  TEXT: &command python3 --version\nmetadata:\n  run: *command\n", ""},
		{"expression preserves following command", "jobs:\n  test:\n    steps:\n      - run: echo ${{ inputs.message }}; python3 --version\n", ":4: Python invocation"},
		{"comment marker still exempts file", "# python-ban-guard: allow-file — documented workflow fixture\njobs:\n  test:\n    steps:\n      - run: python3 --version\n", ""},
		{"bare comment marker still reports", "# python-ban-guard: allow-file\nenv: {run: python3}\n", "bare"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: ".github/workflows/test.yml", seen: make(map[string]bool)}
			handled, err := s.file(test.source)
			if err != nil || !handled {
				t.Fatalf("workflow scan: handled=%v, err=%v", handled, err)
			}
			if test.want == "" {
				if len(s.hits) != 0 {
					t.Errorf("workflow data reported as a command: %v", s.hits)
				}
			} else if len(s.hits) != 1 || !strings.Contains(s.hits[0], test.want) {
				t.Errorf("findings=%v; want one finding containing %q", s.hits, test.want)
			}
		})
	}
}

// TestWorkflowSchemaErrors keeps malformed commands and cyclic aliases fail-closed.
func TestWorkflowSchemaErrors(t *testing.T) {
	for _, test := range []struct{ name, source, want string }{
		{"data alias cycle", "metadata: &loop\n  child: *loop\n", "cyclic YAML alias"},
		{"command alias cycle", "jobs: &loop\n  test: *loop\n", "cyclic YAML alias"},
		{"malformed actual command", "jobs:\n  test:\n    steps:\n      - run: echo 'unfinished\n", "cannot parse shell commands"},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: ".github/workflows/test.yml", seen: make(map[string]bool)}
			_, err := s.file(test.source)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Errorf("error=%v; want %q", err, test.want)
			}
		})
	}
}
