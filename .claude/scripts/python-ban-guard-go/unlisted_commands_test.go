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
