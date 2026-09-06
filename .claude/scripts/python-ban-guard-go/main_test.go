package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// python-ban-guard: allow-file — these inert inputs exercise command classification.

func TestExecutableSurfaceBoundaries(t *testing.T) {
	tests := []struct {
		name, path, source, want string
		handled, wantError       bool
	}{
		{
			name: "env split string flags precede the interpreter", path: "tools/check",
			source: "#!/usr/bin/env -S -i python3 -u\n", handled: true, want: "Python source file",
		},
		{
			name: "env split string assignment precedes the interpreter", path: "tools/check",
			source: "#!/usr/bin/env -S NAME=value python3 -u\n", handled: true, want: "Python source file",
		},
		{
			name: "ordinary env flags precede the interpreter", path: "tools/check",
			source: "#!/usr/bin/env -u UNUSED python3\n", handled: true, want: "Python source file",
		},
		{
			name: "shell heredoc retains commands beside unknown expansion", path: "tools/check.sh",
			source:  "bash <<SCRIPT\necho \"$HOME\"\npython3 --version\nSCRIPT\n",
			handled: true, want: "check.sh:3: Python invocation",
		},
		{
			name: "cat heredoc with unknown expansion remains data", path: "tools/check.sh",
			source:  "cat <<SCRIPT\necho \"$HOME\"\npython3 --version\nSCRIPT\n",
			handled: true,
		},
		{
			name: "stdin shell with positional arguments", path: "tools/check.sh",
			source:  "bash -s argument <<'SCRIPT'\npython3 --version\nSCRIPT\n",
			handled: true, want: "check.sh:2: Python invocation",
		},
		{
			name: "same value in package metadata has its own location", path: "package.json",
			source:  "{\n\"description\":\"python3 --version\",\n\"scripts\": {\n\"check\": \"python3 --version\"\n}\n}",
			handled: true, want: "package.json:4: Python invocation",
		},
		{
			name: "non workflow YAML keeps compatibility scan", path: "deploy/pod.yaml",
			source: "command:\n  - python3\n", handled: false,
		},
		{
			name: "unsupported marker data cannot exempt the fallback", path: "deploy/pod.yaml",
			source: "annotation: 'python-ban-guard: allow-file — data'\ncommand:\n  - python3\n", handled: false,
		},
		{
			name: "Dockerfile flags accept tab separators", path: "Dockerfile",
			source:  "FROM scratch\nRUN --mount=type=cache,target=/cache\tpython3\t--version\n",
			handled: true, want: "Dockerfile:2: Python invocation",
		},
		{
			name: "Dockerfile comment inside a continued instruction", path: "Dockerfile",
			source:  "FROM scratch\nRUN echo safe \\\n# comment\n&& python3 --version\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "Dockerfile comment cannot continue over the next command", path: "Dockerfile",
			source:  "FROM scratch\n# comment ending in a backslash\\\nRUN python3 --version\n",
			handled: true, want: "Dockerfile:3: Python invocation",
		},
		{
			name: "Dockerfile heredoc keeps compatibility scan", path: "Dockerfile",
			source: "FROM scratch\nRUN <<SCRIPT\npython3 --version\nSCRIPT\n", handled: false,
		},
		{
			name: "workflow command alias", path: ".github/workflows/test.yaml",
			source:  "command: &cmd python3 --version\nsteps:\n  - run: *cmd\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "workflow default shell", path: ".github/workflows/test.yaml",
			source:  "defaults:\n  run:\n    shell: python\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "malformed shell fails closed", path: "tools/check.sh",
			source: "echo 'unfinished", handled: true, wantError: true,
		},
		{
			name: "dynamic command word does not expose the following argument", path: "tools/check.sh",
			source: "$tool python3 --version\n", handled: true,
		},
		{
			name: "command lookup is data", path: "tools/check.sh",
			source: "command -v python3\n", handled: true,
		},
		{
			name: "nice wraps a command", path: "tools/check.sh",
			source: "nice python3 --version\n", handled: true, want: "Python invocation",
		},
		{
			name: "nice consumes its priority operand", path: "tools/check.sh",
			source: "nice -n 10 pip3 --version\n", handled: true, want: "Python invocation",
		},
		{
			name: "nice long priority operand", path: "Dockerfile",
			source: "FROM scratch\nRUN nice --adjustment 10 python3 --version\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "nice command arguments remain data", path: "tools/check.sh",
			source: "nice echo python3\nnice -n 10 echo python3\nnice --help python3\n",
			handled: true,
		},
		{
			name: "wrapper option operand", path: "tools/check.sh",
			source: "sudo -u nobody python3 --version\n", handled: true, want: "Python invocation",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: test.path, seen: make(map[string]bool)}
			handled, err := s.file(test.source)
			if handled != test.handled || (err != nil) != test.wantError {
				t.Fatalf("handled=%v error=%v; want handled=%v error=%v", handled, err, test.handled, test.wantError)
			}
			got := strings.Join(s.hits, "\n")
			if test.want == "" && got != "" {
				t.Errorf("unexpected finding: %s", got)
			}
			if test.want != "" && !strings.Contains(got, test.want) {
				t.Errorf("findings %q do not contain %q", got, test.want)
			}
		})
	}
}

func TestScanningNeverExecutesSubstitutions(t *testing.T) {
	target := filepath.Join(t.TempDir(), "must-not-exist")
	s := scanner{path: "tools/check.sh", seen: make(map[string]bool)}
	_, err := s.file("echo \"$(touch " + target + ")\"\necho <(touch " + target + ")\n")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("scanner executed fixture contents: %v", err)
	}
}
