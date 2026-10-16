package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func TestExposure(t *testing.T) {
	for _, tc := range []struct {
		name, source string
		want         bool
	}{
		{"canonical", "set -euo pipefail\ntrap cleanup EXIT\n", true},
		{"long option and numeric signal", "set -o errexit\ntrap 'rm -f x' 0\n", true},
		{"separate flags", "set -u -e\ntrap cleanup INT EXIT\n", true},
		{"trap option", "set -e\ntrap -- cleanup EXIT\n", true},
		{"quoted command", "'set' -e\ntrap cleanup EXIT\n", true},
		{"builtin command", "builtin set -Ee\nbuiltin trap cleanup EXIT\n", true},
		{"nested live command", "f() { set -e; trap cleanup EXIT; }\n", true},
		{"no errexit", "set -u\ntrap 'rm -f x' EXIT\n", false},
		{"disabled errexit", "set +e\ntrap cleanup EXIT\n", false},
		{"positional flags", "set -- -e\ntrap cleanup EXIT\n", false},
		{"other signal", "set -e\ntrap cleanup INT\n", false},
		{"removed trap", "set -e\ntrap - EXIT\n", false},
		{"trap inspection", "set -e\ntrap -p EXIT\n", false},
		{"empty trap", "set -e\ntrap '' EXIT\n", false},
		{"comment", "# set -e\n# trap cleanup EXIT\n", false},
		{"quoted prose", "printf '%s' 'set -e; trap cleanup EXIT'\n", false},
		{"embedded fixture", "cat <<'EOF'\nset -e\ntrap cleanup EXIT\nEOF\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := exposed([]byte(tc.source))
			if err != nil || got != tc.want {
				t.Fatalf("exposed = %v, %v; want %v", got, err, tc.want)
			}
		})
	}
	if _, err := exposed([]byte("if then")); err == nil {
		t.Fatal("invalid shell must not become clean evidence")
	}
}

func TestCoverage(t *testing.T) {
	const path = ".claude/scripts/new-helper.sh"
	files := fstest.MapFS{path: {Data: []byte("set -euo pipefail\ntrap cleanup EXIT\n")}}
	findings, err := auditPaths(files, []string{path}, nil, nil)
	if err != nil || len(findings) != 1 || !strings.Contains(findings[0], path) {
		t.Fatalf("unlisted planted helper: %v, %v", findings, err)
	}
	for _, covered := range []bool{true, false} {
		injected, exceptions := map[string]string{}, map[string]string{}
		if covered {
			injected[path] = "injected"
		} else {
			exceptions[path] = "Trap is installed only after a separate checkout transaction."
		}
		findings, err = auditPaths(files, []string{path}, injected, exceptions)
		if err != nil || len(findings) != 0 {
			t.Fatalf("reviewed coverage: %v, %v", findings, err)
		}
	}
	files[path] = &fstest.MapFile{Data: []byte("set -u\ntrap cleanup EXIT\n")}
	if findings, err = auditPaths(files, []string{path}, nil, nil); err != nil || len(findings) != 0 {
		t.Fatalf("no-errexit control: %v, %v", findings, err)
	}
	files[path] = &fstest.MapFile{Data: []byte("if then")}
	if _, err = auditPaths(files, []string{path}, nil, nil); err == nil {
		t.Fatal("a parse failure must be UNKNOWN")
	}
	if _, err = auditPaths(fstest.MapFS{}, []string{path}, nil, nil); err == nil {
		t.Fatal("a missing tracked file must be UNKNOWN")
	}
	if _, err = auditPaths(files, nil, nil, nil); err == nil {
		t.Fatal("an empty enumeration proves nothing")
	}
}

func TestCommand(t *testing.T) {
	root := t.TempDir()
	write := func(name, body string) {
		t.Helper()
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		if data, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git: %v: %s", err, data)
		}
	}
	git("init", "-q")
	write("covered", "")
	write("exceptions", "")
	args := []string{"--root", root, "--covered", filepath.Join(root, "covered"), "--exceptions", filepath.Join(root, "exceptions")}
	check := func(want int, fragment string) {
		t.Helper()
		var out, err bytes.Buffer
		got := run(args, &out, &err)
		if got != want || !strings.Contains(out.String()+err.String(), fragment) {
			t.Fatalf("exit=%d stdout=%q stderr=%q; want %d and %q", got, out.String(), err.String(), want, fragment)
		}
		if want != 0 && strings.Contains(out.String(), "OK") {
			t.Fatal("partial/failed census reported clean")
		}
	}
	check(2, "nothing checked")
	const path = ".claude/scripts/planted.sh"
	write(path, "set -euo pipefail\ntrap cleanup EXIT\n")
	git("add", "--", path)
	check(1, path)
	write("covered", "planted.sh|\n")
	check(0, "1 tracked shell scripts checked")
	write("covered", "")
	write("exceptions", "planted.sh|Needs transaction-specific fixtures.\n")
	check(0, "1 tracked shell scripts checked")
	write("exceptions", "planted.sh|\n")
	check(2, "exception needs a reason")
	write("exceptions", "")
	write(path, "set -u\ntrap cleanup EXIT\n")
	check(0, "1 tracked shell scripts checked")
	write(path, "if then")
	check(2, "cannot parse shell")
	if err := os.Remove(filepath.Join(root, path)); err != nil {
		t.Fatal(err)
	}
	check(2, path)
	write(path, "set -u\n")
	// An inherited index must not hide the requested checkout's uncovered script.
	write(path, "set -e\ntrap cleanup EXIT\n")
	write(".claude/scripts/safe.sh", "set -u\n")
	git("add", "--", path, ".claude/scripts/safe.sh")
	index := filepath.Join(t.TempDir(), "index")
	for _, argv := range [][]string{{"read-tree", "--empty"}, {"add", "--", ".claude/scripts/safe.sh"}} {
		cmd := exec.Command("git", append([]string{"-C", root}, argv...)...)
		cmd.Env = append(os.Environ(), "GIT_INDEX_FILE="+index)
		if data, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("fixture index: %v: %s", err, data)
		}
	}
	t.Setenv("GIT_INDEX_FILE", index)
	check(1, path)
	// A failed git read can emit a perfectly plausible partial index first.
	stub := filepath.Join(t.TempDir(), "git")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nprintf '100644 0000000000000000000000000000000000000000 0\\t.claude/scripts/planted.sh\\0'\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", filepath.Dir(stub)+string(os.PathListSeparator)+os.Getenv("PATH"))
	check(2, "tracked-file enumeration failed")
}
