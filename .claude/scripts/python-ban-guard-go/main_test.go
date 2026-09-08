package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// python-ban-guard: allow-file — these inert inputs exercise command classification.

// TestKnownShellExecutionBoundaries catches known executable operands without
// treating unknown command words or inert arguments as Python invocations.
func TestKnownShellExecutionBoundaries(t *testing.T) {
	tests := []struct {
		name, source string
		wantHit      bool
	}{
		{"shell positional zero", `bash -c '"$0" --version' python3`, true},
		{"shell positional one", `sh -c '"$1" --version' ignored python3`, true},
		{"shell positional ten", `bash -c '"${10}" --version' ignored a b c d e f g h i python3`, true},
		{"shell positional unknown does not shift", `sh -c '"$1" --version' "$name" python3`, true},
		{"shell positional arguments remain data", `sh -c 'echo "$0" "$1"' python3 python3`, false},
		{"shell positional command remains unknown", `sh -c '"$0" --version' "$tool" python3`, false},
		{"shell positional replacement", `sh -c 'set -- echo; "$1" python3' ignored python3`, false},
		{"shell positional shift", `sh -c 'shift; "$1" python3' ignored python3 echo`, false},
		{"shell function has separate parameters", `sh -c 'f() { "$1" python3; }; f echo' ignored python3`, false},
		{"shell function inherits zero", `sh -c 'f() { "$0" --version; }; f' python3`, true},
		{"bash function inherits zero", `bash -c 'f() { "$0" --version; }; f' python3`, true},
		{"dash function inherits zero", `dash -c 'f() { "$0" --version; }; f' python3`, true},
		{"zsh function zero is not inherited", `zsh -c 'f() { "$0" --version; }; f' python3`, false},
		{"zsh top level zero is inherited", `zsh -c '"$0" --version' python3`, true},
		{"ksh function zero remains unknown", `ksh -c 'f() { "$0" --version; }; f' python3`, false},
		{"ksh keyword function zero remains unknown", `ksh -c 'function f { "$0" --version; }; f' python3`, false},
		{"shell unquoted parameter may vanish", `sh -c '"$1" --version' $name python3 echo`, false},
		{"shell known empty parameter disappears", `name=; sh -c '"$1" --version' $name python3 echo`, false},
		{"shell quoted at can change argument count", `sh -c '"$1" --version' "$@" python3 echo`, false},
		{"shell quoted array can change argument count", `sh -c '"$1" --version' "${ARGS[@]}" python3 echo`, false},
		{"shell quoted set invalidates parameters", `sh -c '"set" -- echo; "$1" python3' ignored python3`, false},
		{"shell command set invalidates parameters", `sh -c 'command set -- echo; "$1" python3' ignored python3`, false},
		{"shell wrapped quoted set invalidates parameters", `sh -c '"command" -p "set" -- echo; "$1" python3' ignored python3`, false},
		{"shell literal bound set invalidates parameters", `sh -c 's=set; "$s" -- echo; "$1" python3' ignored python3`, false},
		{"shell positional bound set invalidates parameters", `sh -c '"$1" -- echo; "$2" python3' ignored set python3`, false},
		{"shell command literal bound set invalidates parameters", `sh -c 's=set; command "$s" -- echo; "$1" python3' ignored python3`, false},
		{"shell repeated command set invalidates parameters", `sh -c 'command command set -- echo; "$1" python3' ignored python3`, false},
		{"shell mutation preserves earlier parameters", `sh -c '"$1" --version; set -- echo' ignored python3`, true},
		{"shell data bound command keeps parameters", `sh -c 's=echo; "$s" set; "$1" --version' ignored python3`, true},
		{"shell zero survives set", `sh -c 'set -- echo; "$0" --version' python3`, true},
		{"env opaque chdir", `env -C "$WORKDIR" python3 --version`, true},
		{"env opaque long chdir", `env --chdir "$WORKDIR" python3 --version`, true},
		{"env opaque unset", `env -u "$NAME" python3 --version`, true},
		{"env opaque argv zero", `env --argv0 "$NAME" python3 --version`, true},
		{"env opaque operand remains data", `env -C "$WORKDIR" echo python3`, false},
		{"env unquoted operand may vanish", `env -C $WORKDIR python3 echo safe`, false},
		{"env unquoted unset operand may vanish", `env -u $NAME python3 echo safe`, false},
		{"env known empty unset operand disappears", `NAME=; env -u $NAME python3 echo safe`, false},
		{"env literal operand remains data", `env -C python3 echo safe`, false},
		{"env unknown split string stays unknown", `env -S "$PROGRAM" python3`, false},
		{"env split quoted operand remains one word", `env -S '-u "${NAME}" python3 --version'`, true},
		{"watch command", `watch python3 --version`, true},
		{"watch option operand", `watch -n "$INTERVAL" python3 --version`, true},
		{"watch long options", `watch --interval=1 --differences=permanent -- python3`, true},
		{"watch shell string", `watch 'echo safe; python3 --version'`, true},
		{"watch exec mode", `watch -x python3 --version`, true},
		{"watch exec data", `watch -x echo 'safe; python3 --version'`, false},
		{"watch optional short operand", `watch -dx 'echo safe; python3'`, true},
		{"watch command argument data", `watch echo python3`, false},
		{"watch help", `watch --help python3`, false},
		{"watch short help", `watch -h python3`, false},
		{"watch version", `watch --version python3`, false},
		{"watch short version", `watch -v python3`, false},
		{"watch operand data", `watch -n python3 echo safe`, false},
		{"tilde basename", `~/bin/python3 --version`, true},
		{"named home basename", `~someone/bin/python3 --version`, true},
		{"wrapped tilde basename", `env ~/bin/python3 --version`, true},
		{"tilde command remains unknown", `~/bin/"$TOOL" python3`, false},
		{"tilde directory only", `~python3`, false},
		{"tilde argument remains data", `echo ~/bin/python3`, false},
		{"trap handler", `trap 'python3 --version' EXIT`, true},
		{"trap delimiter", `trap -- 'python3 --version' EXIT`, true},
		{"trap nested handler", `trap 'sh -c "python3 --version"' EXIT`, true},
		{"trap handler data", `trap 'echo python3' EXIT`, false},
		{"trap print", `trap -p 'python3 --version' EXIT`, false},
		{"trap list", `trap -l 'python3 --version' EXIT`, false},
		{"trap reset", `trap - EXIT`, false},
		{"trap ignore", `trap '' EXIT`, false},
		{"trap missing signal", `trap 'python3 --version'`, false},
		{"trap unknown handler", `trap "$HANDLER" EXIT`, false},
		{"unknown wrapper stays unchanged", `custom-wrapper python3 --version`, false},
		{"unknown command stays unchanged", `"$TOOL" python3 --version`, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: "check.sh", seen: make(map[string]bool)}
			if err := s.source(test.source, 1, 0, false); err != nil {
				t.Fatal(err)
			}
			if got := len(s.hits) > 0; got != test.wantHit {
				t.Errorf("findings=%v; want hit=%v", s.hits, test.wantHit)
			}
		})
	}
}

// TestShellParameterMutationScopes distinguishes local execution environments
// from mutations that change the current shell's positional parameters.
func TestShellParameterMutationScopes(t *testing.T) {
	tests := []struct {
		name, source string
		wantHit      bool
	}{
		{"uncalled function keeps outer parameters", `sh -c 'f() { set -- echo; }; "$1" --version' ignored python3`, true},
		{"called function restores outer parameters", `sh -c 'f() { set -- echo; }; f; "$1" --version' ignored python3`, true},
		{"function shift keeps outer parameters", `sh -c 'f() { shift; }; "$1" --version' ignored python3 echo`, true},
		{"function builtin set keeps outer parameters", `bash -c 'f() { builtin set -- echo; }; f; "$1" --version' ignored python3`, true},
		{"brace group changes outer parameters", `sh -c '{ set -- echo; }; "$1" python3' ignored python3`, false},
		{"subshell keeps outer parameters", `sh -c '(set -- echo); "$1" --version' ignored python3`, true},
		{"subshell inherits earlier parameters", `sh -c '("$1" --version; set -- echo)' ignored python3`, true},
		{"subshell mutates its own parameters", `sh -c '(set -- echo; "$1" python3)' ignored python3`, false},
		{"subshell inherits outer mutation", `sh -c 'set -- echo; ("$1" python3)' ignored python3`, false},
		{"nested subshell keeps enclosing parameters", `sh -c '( (set -- echo); "$1" --version)' ignored python3`, true},
		{"command substitution keeps outer parameters", `sh -c 'v=$(set -- echo); "$1" --version' ignored python3`, true},
		{"command substitution inherits earlier parameters", `sh -c 'v=$("$1" --version; set -- echo)' ignored python3`, true},
		{"command substitution mutates its own parameters", `sh -c 'v=$(set -- echo; "$1" python3)' ignored python3`, false},
		{"mutator arguments precede mutation", `sh -c 'set -- "$("$1" --version)"' ignored python3`, true},
		{"process substitution keeps outer parameters", `bash -c 'cat <(set -- echo); "$1" --version' ignored python3`, true},
		{"background command keeps outer parameters", `sh -c 'set -- echo & "$1" --version' ignored python3`, true},
		{"nonfinal pipeline keeps outer parameters", `sh -c 'set -- echo | cat; "$1" --version' ignored python3`, true},
		{"middle pipeline keeps outer parameters", `sh -c 'cat | { set -- echo; } | cat; "$1" --version' ignored python3`, true},
		{"pipeline component mutates its own parameters", `sh -c '{ set -- echo; "$1" python3; } | cat' ignored python3`, false},
		{"builtin set changes parameters", `bash -c 'builtin set -- echo; "$1" python3' ignored python3`, false},
		{"builtin shift changes parameters", `bash -c 'builtin shift; "$1" python3' ignored python3 echo`, false},
		{"command builtin set changes parameters", `bash -c 'command builtin set -- echo; "$1" python3' ignored python3`, false},
		{"builtin command set changes parameters", `bash -c 'builtin command set -- echo; "$1" python3' ignored python3`, false},
		{"nested builtin command shift changes parameters", `bash -c 'command builtin command builtin shift; "$1" python3' ignored python3 echo`, false},
		{"builtin delimiter selects setter", `bash -c 'builtin -- set -- echo; "$1" python3' ignored python3`, false},
		{"builtin help does not set parameters", `bash -c 'builtin --help set -- echo; "$1" --version' ignored python3`, true},
		{"builtin command inspection does not set parameters", `bash -c 'builtin command -v set; "$1" --version' ignored python3`, true},
		{"builtin echo preserves parameters", `bash -c 'builtin echo set; "$1" --version' ignored python3`, true},
		{"builtin interpreter operand does not execute", `bash -c 'builtin python3 --version'`, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: "check.sh", seen: make(map[string]bool)}
			if err := s.source(test.source, 1, 0, false); err != nil {
				t.Fatal(err)
			}
			if got := len(s.hits) > 0; got != test.wantHit {
				t.Errorf("findings=%v; want hit=%v", s.hits, test.wantHit)
			}
		})
	}
}

// TestExecutableSurfaceBoundaries pairs executable syntax with nonexecuting data controls.
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
			name: "attached clustered env shebang", path: "tools/check",
			source: "#!/usr/bin/env -vSpython3 -u\n", handled: true, want: "Python source file",
		},
		{
			name: "env split separator in shebang", path: "tools/check",
			source: "#!/usr/bin/env -Spython3\\_--version\n", handled: true, want: "Python source file",
		},
		{
			name: "ordinary env flags precede the interpreter", path: "tools/check",
			source: "#!/usr/bin/env -u UNUSED python3\n", handled: true, want: "Python source file",
		},
		{
			name: "windows launcher shebang", path: "tools/check",
			source: "#!/usr/bin/env py\n", handled: true, want: "Python source file",
		},
		{
			name: "windows python executable shebang", path: "tools/check",
			source: "#!/usr/bin/env python.exe\n", handled: true, want: "Python source file",
		},
		{
			name: "windows versioned python executable shebang", path: "tools/check",
			source: "#!/usr/bin/env python3.exe\n", handled: true, want: "Python source file",
		},
		{
			name: "pip executable shebang is not a python source file", path: "tools/check",
			source: "#!/usr/bin/env pip3.exe\n", handled: true,
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
			name: "shell herestring is executable input", path: "tools/check.sh",
			source: "bash <<< 'python3 --version'\n", handled: true, want: "check.sh:1: Python invocation",
		},
		{
			name: "stdin shell arguments preserve herestring input", path: "tools/check.sh",
			source: "bash -s argument <<< 'python3 --version'\n", handled: true, want: "Python invocation",
		},
		{
			name: "explicit stdin herestring is executable input", path: "tools/check.sh",
			source: "bash 0<<< 'python3 --version'\n", handled: true, want: "Python invocation",
		},
		{
			name: "herestring used as data stays data", path: "tools/check.sh",
			source: "cat <<< 'python3 --version'\nbash <<< 'echo python3'\nbash -c 'echo safe' <<< 'python3 --version'\n", handled: true,
		},
		{
			name: "later stdin redirect replaces herestring", path: "tools/check.sh",
			source: "bash <<< 'python3 --version' </dev/null\n", handled: true,
		},
		{
			name: "non stdin herestring stays data", path: "tools/check.sh",
			source: "bash 3<<< 'python3 --version'\n", handled: true,
		},
		{
			name: "same value in package metadata has its own location", path: "package.json",
			source:  "{\n\"description\":\"python3 --version\",\n\"scripts\": {\n\"check\": \"python3 --version\"\n}\n}",
			handled: true, want: "package.json:4: Python invocation",
		},
		{
			name: "non workflow YAML parses command argv", path: "deploy/pod.yaml",
			source: "command:\n  - python3\n", handled: true, want: "Python invocation",
		},
		{
			name: "YAML marker data cannot exempt a command", path: "deploy/pod.yaml",
			source: "annotation: 'python-ban-guard: allow-file — data'\ncommand:\n  - python3\n", handled: true, want: "Python invocation",
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
			source:  "command: &cmd python3 --version\njobs:\n  check:\n    steps:\n      - run: *cmd\n",
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
			source:  "FROM scratch\nRUN nice --adjustment 10 python3 --version\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "nice command arguments remain data", path: "tools/check.sh",
			source:  "nice echo python3\nnice -n 10 echo python3\nnice --help python3\n",
			handled: true,
		},
		{
			name: "wrapper option operand", path: "tools/check.sh",
			source: "sudo -u nobody python3 --version\n", handled: true, want: "Python invocation",
		},
		{
			name: "clustered env option consumes its operand", path: "tools/check",
			source: "#!/usr/bin/env -S -iu HOME python3\n", handled: true, want: "Python source file",
		},
		{
			name: "dockerfile SHELL selects the interpreter", path: "Dockerfile",
			source: "SHELL [\"python3\", \"-c\"]\nRUN pass\n", handled: true, want: "Python invocation",
		},
		{
			name: "kubernetes args supply the shell operand", path: "deploy.yaml",
			source:  "spec:\n  containers:\n    - name: app\n      command: [\"sh\", \"-c\"]\n      args: [\"python3 --version\"]\n",
			handled: true, want: "Python invocation",
		},
		{
			name: "make shell function runs at read time", path: "Makefile",
			source: "VERSION := $(shell python3 --version)\n", handled: true, want: "Python invocation",
		},
		{
			name: "literal shell assignment used in command position", path: "tools/check.sh",
			source: "PYTHON=python3\n\"$PYTHON\" --version\n", handled: true, want: "Python invocation",
		},
		{
			name: "reassigned shell name stays unknown", path: "tools/check.sh",
			source:  "PYTHON=python3\nPYTHON=node\n\"$PYTHON\" --version\n",
			handled: true,
		},
		{
			name: "loop rebound shell name stays unknown", path: "tools/check.sh",
			source:  "PYTHON=python3\nfor PYTHON in node; do \"$PYTHON\" --version; done\n",
			handled: true,
		},
		{
			name: "go os/exec names the program", path: "tools/run.go",
			source: "package main\n\nimport (\n\t\"context\"\n\t\"os/exec\"\n)\n\nfunc run(ctx context.Context) error {\n\treturn exec.CommandContext(ctx, \"python3\", \"--version\").Run()\n}\n",
			want:   "Python invocation",
		},
		{
			name: "go os/exec with a non-python program", path: "tools/run.go",
			source: "package main\n\nimport \"os/exec\"\n\nfunc run() error {\n\treturn exec.Command(\"node\", \"--version\").Run()\n}\n",
		},
		{
			name: "go os/exec program from a variable stays unknown", path: "tools/run.go",
			source: "package main\n\nimport \"os/exec\"\n\nfunc run(program string) error {\n\treturn exec.Command(program, \"--version\").Run()\n}\n",
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

// TestVersionedPipCommands distinguishes executable names from lookalikes and data.
func TestVersionedPipCommands(t *testing.T) {
	for _, command := range []string{"pip2 --version", "/opt/venv/bin/pip2.7 install example", "pip3.12 --version", "/opt/venv/bin/pip3.13 install example"} {
		s := scanner{path: "check.sh", seen: make(map[string]bool)}
		if err := s.source(command, 1, 0, false); err != nil {
			t.Fatal(err)
		}
		if len(s.hits) != 1 {
			t.Errorf("command %q: want one finding, got %v", command, s.hits)
		}
	}
	for _, command := range []string{"pip-tools --version", "echo pip2 pip2.7 pip3.12", "pip2.7-helper --version", "pip3.12-helper --version"} {
		s := scanner{path: "check.sh", seen: make(map[string]bool)}
		if err := s.source(command, 1, 0, false); err != nil {
			t.Fatal(err)
		}
		if len(s.hits) != 0 {
			t.Errorf("command %q: unexpected findings %v", command, s.hits)
		}
	}
}

// TestEnvSplitStringBoundaries checks env splitting without applying shell evaluation.
func TestEnvSplitStringBoundaries(t *testing.T) {
	tests := []struct {
		name, path, source string
		wantHit            bool
	}{
		{"attached short", "check.sh", `env -S'python3 --version'`, true},
		{"attached long", "check.sh", `env --split-string='pip3 install example'`, true},
		{"short option cluster", "check.sh", `env -vS'python3 --version'`, true},
		{"Docker exec", "Dockerfile", "FROM scratch\nRUN [\"env\",\"-Spython3 --version\"]\n", true},
		{"split options", "check.sh", `env -S '-i python3 --version'`, true},
		{"split assignments", "check.sh", `env -S 'NAME=value python3 --version'`, true},
		{"quoted tail program", "check.sh", `env -S 'sh -c' 'python3 --version'`, true},
		{"quoted tail data", "check.sh", `env -S 'echo' 'safe; python3 --version'`, false},
		{"split punctuation is data", "check.sh", `env -S 'echo ; python3 --version'`, false},
		{"unknown tail stays unknown", "check.sh", `env -S 'sh -c' "$program" python3`, false},
		{"unset operand stays data", "check.sh", `env -u python3 -S 'echo safe'`, false},
		{"attached unset operand stays data", "check.sh", `env -uSpython3 echo safe`, false},
		{"assignment ends options", "check.sh", `env NAME=value -S 'echo; python3'`, false},
		{"separator ends options", "check.sh", `env -- -S 'echo; python3'`, false},
		{"env separator escape", "check.sh", `env -S 'python3\_--version'`, true},
		{"single quoted split interpreter", "check.sh", `env -S "'python3' --version"`, true},
		{"unknown split environment", "check.sh", `env -S 'sh -c ${PROGRAM}' python3`, false},
		{"split comment stops input", "check.sh", `env -S 'echo # python3'`, false},
		{"split stop escape", "check.sh", `env -S 'echo \c; python3'`, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: test.path, seen: make(map[string]bool)}
			handled, err := s.file(test.source)
			if err != nil || !handled {
				t.Fatalf("handled=%v error=%v", handled, err)
			}
			if gotHit := len(s.hits) > 0; gotHit != test.wantHit {
				t.Errorf("findings=%v; want hit=%v", s.hits, test.wantHit)
			}
		})
	}
}

// TestTelemetryFixtureRemainsScanned separates fixture validation from the flag-gated production sweep.
func TestTelemetryFixtureRemainsScanned(t *testing.T) {
	const data = "#!/usr/bin/env bash\n" +
		"pattern='python-ban-guard: allow-file — quoted search data'\n" +
		"grep -F \"$pattern\" input.log\n" +
		"grep -E '(^|;)[[:space:]]*python3' input.log\n"
	for _, test := range []struct {
		name, suffix string
		wantHit      bool
	}{
		{name: "grep patterns remain data"},
		{name: "appended command cannot inherit an exemption", suffix: "\npython3 --version\n", wantHit: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: "agent-telemetry.sh", seen: make(map[string]bool)}
			handled, err := s.file(data + test.suffix)
			if err != nil || !handled {
				t.Fatalf("handled=%v error=%v", handled, err)
			}
			if gotHit := len(s.hits) > 0; gotHit != test.wantHit {
				t.Errorf("findings=%v; want hit=%v", s.hits, test.wantHit)
			}
		})
	}
}

// TestScanningNeverExecutesSubstitutions verifies that parsed substitutions cause no filesystem effects.
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

// TestDockerEnvPrefixQuotesValues pins the replay contract: a recorded ENV value is
// injected into shell source, so it must be single-quoted, and a name that is not a
// shell identifier must not be replayed as a command word.
func TestDockerEnvPrefixQuotesValues(t *testing.T) {
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"apostrophe is quoted", map[string]string{"DESC": "Devantler's"}, `DESC='Devantler'\''s'; `},
		{"plain value is quoted", map[string]string{"TOOL": "python3"}, "TOOL='python3'; "},
		{"non-identifier name is dropped", map[string]string{"-Dfoo": "bar", "OPTS": "x"}, "OPTS='x'; "},
		{"digit-leading name is dropped", map[string]string{"2BAD": "x"}, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := dockerEnvPrefix(tt.env); got != tt.want {
				t.Fatalf("dockerEnvPrefix = %q, want %q", got, tt.want)
			}
		})
	}
}
