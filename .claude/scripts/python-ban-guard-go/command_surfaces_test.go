package main

import "testing"

// python-ban-guard: allow-file — inert fixtures verify executable command boundaries.

// TestCommandSurfaceRegressions exercises the real file dispatcher without executing fixtures.
func TestCommandSurfaceRegressions(t *testing.T) {
	t.Setenv("EMPTY", "echo") // Classification must not consult the scanner host's environment.
	tests := []struct {
		name, source string
		wantHit      bool
	}{
		{"bash rcfile operand before command", `bash --rcfile python3 -c 'python3 --version'`, true},
		{"bash init file operand before command", `bash --init-file python3 -c 'python3 --version'`, true},
		{"bash unknown rcfile operand", `bash --rcfile "$CONFIG" -c 'python3 --version'`, true},
		{"bash option operand remains data", `bash --rcfile python3 -c 'echo safe'`, false},
		{"bash init file operand remains data", `bash --init-file python3 -c 'echo safe'`, false},
		{"bash script path stops option parsing", `bash script.sh --rcfile ignored -c 'python3 --version'`, false},
		{"env disappearing unset expansion", `env -u EMPTY -S '${EMPTY} python3 --version'`, true},
		{"env optional word before flags", `env -S '${EMPTY} -i python3 --version'`, true},
		{"env optional word after assignment", `env -S 'NAME=value ${EMPTY} python3 --version'`, true},
		{"env multiple optional words", `env -S '${EMPTY} ${OTHER} python3 --version'`, true},
		{"env optional word before wrapper", `env -S '${EMPTY} timeout 5 python3 --version'`, true},
		{"env optional word before data command", `env -u EMPTY -S '${EMPTY} echo python3 --version'`, false},
		{"env quoted expansion keeps word", `env -S '"${EMPTY}" python3 --version'`, false},
		{"env empty quote keeps expansion word", `env -S '${EMPTY}"" python3 --version'`, false},
		{"env expansion with literal prefix", `env -S 'prefix${EMPTY} python3 --version'`, false},
		{"env single quoted expansion is data", `env -S "'\${EMPTY}' python3 --version"`, false},
		{"env option operand stays unknown", `env -S '-u ${EMPTY} python3 --version'`, false},
		{"env shell operand stays unknown", `env -S 'sh -c ${PROGRAM}' python3`, false},
		{"env selected command keeps arguments as data", `env -S 'echo ${EMPTY} python3'`, false},
		{"find exec semicolon", `find . -exec python3 --version ';'`, true},
		{"find execdir semicolon", `find . -execdir /usr/bin/python3 --version ';'`, true},
		{"find ok semicolon", `find . -ok python3 --version ';'`, true},
		{"find okdir semicolon", `find . -okdir python3 --version ';'`, true},
		{"find batched exec", `find . -exec python3 '{}' +`, true},
		{"find batched execdir", `find . -execdir python3 '{}' +`, true},
		{"find wrapped command", `find . -exec timeout 5 python3 --version ';'`, true},
		{"find nested shell", `find . -exec bash --rcfile config -c 'python3 --version' ';'`, true},
		{"find later execution action", `find . -exec echo safe ';' -exec python3 --version ';'`, true},
		{"find data predicates", `find python3 -name python3 -printf 'python3 --version'`, false},
		{"find action name in predicate operand", `find . -name -exec -exec echo python3 ';'`, false},
		{"find formatted output operands", `find . -fprintf -exec python3`, false},
		{"find command arguments remain data", `find . -exec echo -exec python3 ';'`, false},
		{"find unknown command remains unknown", `find . -exec "$COMMAND" python3 ';'`, false},
		{"find plus argument is data", `find . -exec echo + python3 ';'`, false},
		{"find missing terminator cannot execute", `find . -exec python3 --version`, false},
		{"find help does not execute", `find --help -exec python3 ';'`, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: "tools/check.sh", seen: make(map[string]bool)}
			handled, err := s.file(test.source + "\n")
			if err != nil || !handled {
				t.Fatalf("handled=%v, err=%v", handled, err)
			}
			if got := len(s.hits) > 0; got != test.wantHit {
				t.Errorf("findings=%v; want hit=%v", s.hits, test.wantHit)
			}
		})
	}
}

// TestEnvOptionalShebangWords preserves interpreter detection and quoted data boundaries.
func TestEnvOptionalShebangWords(t *testing.T) {
	for _, test := range []struct {
		source string
		want   string
	}{
		{"#!/usr/bin/env -S ${EMPTY} python3\n", "python3"},
		{"#!/usr/bin/env -S -i ${EMPTY} python3\n", "python3"},
		{"#!/usr/bin/env -S -- ${EMPTY} python3\n", "python3"},
		{"#!/usr/bin/env -S ${EMPTY} echo python3\n", "echo"},
		{"#!/usr/bin/env -S \"${EMPTY}\" python3\n", ""},
		{"#!/usr/bin/env -S prefix${EMPTY} python3\n", ""},
	} {
		if got := shebang(test.source); got != test.want {
			t.Errorf("shebang(%q)=%q; want %q", test.source, got, test.want)
		}
	}
}
