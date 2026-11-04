package main

import (
	"strings"
	"testing"
)

// python-ban-guard: allow-file — the fixtures below are inert scanner inputs.

// TestUnlistedWrappersAreReported covers monorepo#3271: a wrapper the walker has no rule for
// must not hide the interpreter it runs. Each case runs Python through such a wrapper.
func TestUnlistedWrappersAreReported(t *testing.T) {
	tests := []struct{ name, source string }{
		{"flock", "flock /tmp/x python3 build.py"},
		{"runuser", "runuser -u nobody -- python3 build.py"},
		{"parallel", "parallel python3 ::: a b"},
		{"chrt", "chrt -f 10 python3 x.py"},
		{"taskset", "taskset -c 0 python3 x.py"},
		{"unbuffer", "unbuffer python3 x.py"},
		{"pip through a wrapper", "flock /tmp/x pip3 install requests"},
		{"pytest through a wrapper", "chronic pytest -q"},
		{"absolute interpreter path", "flock /tmp/x /usr/bin/python3 x.py"},
		{"script command string", "script -q -c 'python3 x.py' /dev/null"},
		{"script long command option", "script --command='python3 x.py' /dev/null"},
		{"su command string", "su -c 'python3 x.py' nobody"},
		{"runuser command string", "runuser -u nobody -c 'python3 x.py'"},
		{"unlisted wrapper inside sh -c", `sh -c 'flock /tmp/x python3 x.py'`},
		{"unlisted wrapper after a listed one", "timeout 5 flock /tmp/x python3 x.py"},
		{"unlisted wrapper in a pipeline", "printf x | flock /tmp/x python3 x.py"},
		{"unlisted wrapper then a nested shell", `flock /tmp/x sh -c 'python3 x.py'`},
		{"unlisted wrapper then eval", `chrt -f 10 eval 'python3 x.py'`},
		{"unlisted wrapper then env -S", `flock /tmp/x env -S 'python3 x.py'`},
		{"unlisted wrapper then a listed wrapper", "taskset -c 0 timeout 5 python3 x.py"},
		{"unlisted wrapper then another unlisted one", "chrt -f 10 flock /tmp/x python3 x.py"},
		{"flock command string", `flock -c 'python3 x.py' /tmp/x`},
		{"flock long command string", `flock --command 'python3 x.py' /tmp/x`},
		{"entr shell string", `entr -s 'python3 x.py'`},
		{"parallel command template", `parallel 'python3 {}' ::: a`},
		{"parallel after an option", `parallel -j4 'python3 {}' ::: a`},
		{"script bundled command option", `script -qc 'python3 x.py' /dev/null`},
		{"script bundled flags before the command option", `script -qfc "python3 x.py" /dev/null`},
		{"su bundled login and command", `su -lc 'python3 x.py' nobody`},
		{"su attached command string", `su -c'python3 x.py' nobody`},
		{"builtin exec", "builtin exec python3 x.py"},
		{"builtin eval", `builtin eval 'python3 x.py'`},
		{"mise exec", "mise exec -- python3 x.py"},
		{"mise x", "mise x python@3.12 -- python x.py"},
		{"asdf exec", "asdf exec python3 x.py"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := scanner{path: "check.sh", seen: map[string]bool{}}
			if err := s.source(tt.source, 1, 0, false); err != nil {
				t.Fatalf("scan error: %v", err)
			}
			if len(s.hits) == 0 {
				t.Fatalf("unlisted wrapper read clean but runs Python: %s", tt.source)
			}
		})
	}
}

// TestUnlistedCommandSurfacesStayClean is the command-surface negative control for
// monorepo#3271, the counterpart of TestResolvedBuildSurfacesStayClean: resolved commands with no
// Python, and commands that only treat an interpreter name as data, stay clean, so the rule cannot
// pass by reporting everything.
func TestUnlistedCommandSurfacesStayClean(t *testing.T) {
	tests := []struct{ name, source string }{
		{"unlisted wrapper running something else", "flock /tmp/x make build"},
		{"unlisted command with no interpreter", "custom-wrapper --flag value"},
		{"interpreter as part of a longer word", "flock /tmp/x python3-config --help"},
		{"interpreter inside a longer operand", "cp python3.tar.gz /tmp/"},
		{"echo", "echo python3"},
		{"printf", "printf '%s\\n' python3"},
		{"builtin", "builtin python3"},
		{"type", "type python3"},
		{"which", "which python3"},
		{"hash", "hash python3"},
		{"command lookup", "command -v python3"},
		{"test", `test -x python3`},
		{"grep", "grep -c python3 requirements.txt"},
		{"pgrep", "pgrep python3"},
		{"pkill", "pkill python3"},
		{"apt-get install", "apt-get install -y python3"},
		{"apk add", "apk add --no-cache python3"},
		{"brew install", "brew install python3"},
		{"script without a command string", "script -q /dev/null"},
		{"su without a command string", "su nobody"},
		{"dynamic command word stays unresolved", `"$TOOL" python3 --version`},
		{"literal double dash in command position", "timeout 5 -- python3"},
		{"option word in command position", "command -- -v python3"},
		{"number in command position", "xargs --max-lines 1 python3"},
		{"all-capitals word in command position", "CMD python3 app.py"},
		{"data command under an unlisted wrapper", "chrt -f 10 grep python3 f"},
		{"directory operand", "flock /tmp/x ls python/"},
		{"directory named like an interpreter", "chrt -f 10 cp -r src/ py/"},
		{"cd into a directory", "cd python"},
		{"git path", "git rm -r python/"},
		{"remove an installed interpreter", "rm -f /usr/local/bin/pip"},
		{"read into a variable", "read -r py"},
		{"mise install", "mise install python@3.12"},
		{"asdf plugin", "asdf plugin add python"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := scanner{path: "check.sh", seen: map[string]bool{}}
			if err := s.source(tt.source, 1, 0, false); err != nil {
				t.Fatalf("scan error: %v", err)
			}
			if len(s.hits) != 0 {
				t.Fatalf("clean command surface reported: %s", strings.Join(s.hits, "\n"))
			}
		})
	}
}

// TestShellStringOperandIsReportedOnce pins that an operand the -c branch already scanned is not
// reported a second time by the operand scan.
func TestShellStringOperandIsReportedOnce(t *testing.T) {
	s := scanner{path: "check.sh", seen: map[string]bool{}}
	if err := s.source("script -c python3 /dev/null", 1, 0, false); err != nil {
		t.Fatalf("scan error: %v", err)
	}
	if len(s.hits) != 1 {
		t.Fatalf("want exactly one finding, got %d: %s", len(s.hits), strings.Join(s.hits, "\n"))
	}
}
