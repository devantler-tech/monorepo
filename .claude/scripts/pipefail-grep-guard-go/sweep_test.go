package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// 1. The behavioural proof that the class is real on this host: a writer piped into `grep -q`
// reports FAILURE on a successful match, and the pipe-free form does not. The last write is
// synchronized after the reader has closed its pipe, because a finite payload can fit in a
// kernel buffer before grep runs, so neither size nor repetition proves SIGPIPE (monorepo#4663).
// `command grep` keeps a harness shim out of the measurement.
const behaviourProbe = `
set +e
tmp=$1
printf 'NEEDLE\nTAIL\n' >"$tmp/payload"
mkfifo "$tmp/reader-closed"
exec 3<>"$tmp/reader-closed"
{
  printf 'NEEDLE\n'
  IFS= read -r -t 5 signal <&3 || exit 92
  [[ "$signal" == closed ]] || exit 93
  LC_ALL=C printf 'TAIL\n'
} 2>"$tmp/writer-error" | (
  command grep -q NEEDLE
  consumer_rc=$?
  exec 0<&-
  printf 'closed\n' >&3
  exit "$consumer_rc"
)
status=("$?" "${PIPESTATUS[@]}")
command grep -q NEEDLE <"$tmp/payload" >/dev/null 2>&1
here_rc=$?
exec 3>&-
broken=no
command grep -F 'Broken pipe' "$tmp/writer-error" >/dev/null && broken=yes
printf '%s:%s:%s %s %s\n' "${status[0]}" "${status[1]}" "${status[2]}" "$here_rc" "$broken"
`

func TestBehaviour(t *testing.T) {
	out, err := exec.Command("bash", "-o", "pipefail", "-c", behaviourProbe, "probe", t.TempDir()).Output()
	if err != nil {
		t.Fatalf("the probe did not run: %v", err)
	}
	fields := strings.Fields(string(out))
	if len(fields) != 3 {
		t.Fatalf("unexpected probe output %q", out)
	}
	status, hereRC, broken := fields[0], fields[1], fields[2]
	if !strings.HasSuffix(status, ":0") {
		t.Errorf("behaviour: the needle IS present (so any failure is spurious, not a real no-match): %s", status)
	}
	// An inherited ignored SIGPIPE makes Bash report EPIPE as status 1 instead of signal status
	// 141. Only accept that alternative together with the closed-pipe error.
	if !(status == "141:141:0" || (status == "1:1:0" && broken == "yes")) {
		t.Errorf("behaviour: piping a writer into 'grep -q' reports FAILURE on a successful match: %s", status)
	}
	if hereRC != "0" {
		t.Errorf("behaviour: the pipe-free form the guard asks for never reports that failure: rc=%s", hereRC)
	}
}

// 2j. Shebang classification runs only in the repository-wide sweep, so each case is a throwaway
// git repository holding the offending line under one shebang, plus a benign `*.sh` so the target
// set is never empty (an empty one fails closed with exit 2).
func mkrepo(t *testing.T, shebang string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "tool"), []byte(shebang+"\nproducer | grep -q MATCH\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "noop.sh"), []byte("#!/usr/bin/env bash\ntrue\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"init", "-q"},
		{"add", "tool", "noop.sh"},
		{"-c", "user.email=guard-test@example.invalid", "-c", "user.name=guard test", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	return dir
}

func TestShebangSweep(t *testing.T) {
	for _, c := range []struct {
		name, shebang string
		want          int
	}{
		{"a version-suffixed shebang is swept, not silently skipped", "#!/usr/bin/ksh93", 1},
		{"an env-dispatched shebang resolves to the shell in its argument", "#!/usr/bin/env bash", 1},
		{"an env -S shebang resolves to the shell after the option", "#!/usr/bin/env -S bash", 1},
		{"an env -S shebang with an attached value is swept", "#!/usr/bin/env -Sbash -x", 1},
		{"an env --split-string= shebang is swept", "#!/usr/bin/env --split-string=bash -x", 1},
		{"an env option consuming a separate value still reaches the shell", "#!/usr/bin/env -u FOO bash", 1},
		{"an env -S assignment with a quoted space still reaches the shell", "#!/usr/bin/env -S LABEL='a b' bash", 1},
		{"the same holds for a double-quoted assignment value", `#!/usr/bin/env -S LABEL="a b" bash`, 1},
		{"a quoted-assignment -S shebang naming a non-shell is not swept", "#!/usr/bin/env -S LABEL='a b' ruby", 0},
		{"an env -S shebang naming a non-shell is not swept", "#!/usr/bin/env -S ruby", 0},
		{"a non-shell interpreter is not swept", "#!/usr/bin/perl", 0},
		{"a CRLF shebang still names its shell", "#!/bin/bash\r", 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Chdir(mkrepo(t, c.shebang))
			if rc, out := guard(); rc != c.want {
				t.Fatalf("rc=%d, want %d\n%s", rc, c.want, out)
			}
		})
	}
}

// A sweep outside any repository, and one with nothing to scan, are usage errors, not clean.
func TestSweepFailsClosed(t *testing.T) {
	t.Chdir(t.TempDir())
	if rc, out := guard(); rc != 2 {
		t.Errorf("a sweep outside a repository exits 2: rc=%d\n%s", rc, out)
	}
	dir := t.TempDir()
	if out, err := exec.Command("git", "-C", dir, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	t.Chdir(dir)
	if rc, out := guard(); rc != 2 || !strings.Contains(out, "no tracked shell scripts found") {
		t.Errorf("a repository with no shell scripts exits 2: rc=%d\n%s", rc, out)
	}
}

// 2h. CI wiring. The sweep step is read as a parsed mapping, not a line window: a window from
// `name:` down misses an `if:` written above it, and a gated sweep reads green while checking
// nothing.
const sweepStep = "Reject writers piped into an early-exiting grep"

type workflow struct {
	Jobs map[string]struct {
		Steps []map[string]any `yaml:"steps"`
	} `yaml:"jobs"`
}

func stepsNamed(t *testing.T, path, name string) []map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the CI wiring could be inspected: %v", err)
	}
	var w workflow
	if err := yaml.Unmarshal(data, &w); err != nil {
		t.Fatalf("the CI wiring could be inspected: %v", err)
	}
	var out []map[string]any
	for _, j := range w.Jobs {
		for _, s := range j.Steps {
			if s["name"] == name {
				out = append(out, s)
			}
		}
	}
	return out
}

func TestCIWiring(t *testing.T) {
	ci := filepath.Join("..", "..", "..", ".github", "workflows", "ci.yaml")
	steps := stepsNamed(t, ci, sweepStep)
	if len(steps) != 1 {
		t.Fatalf("exactly one CI step runs the repository-wide sweep: %d", len(steps))
	}
	if steps[0]["run"] != "bash .claude/scripts/pipefail-grep-guard.sh" {
		t.Errorf("the repository-wide sweep runs in CI: %v", steps[0]["run"])
	}
	if _, gated := steps[0]["if"]; gated {
		t.Errorf("the repository-wide sweep is unconditional")
	}
	gatedFixture := filepath.Join(t.TempDir(), "gated-ci.yaml")
	if err := os.WriteFile(gatedFixture, []byte("jobs:\n  guard:\n    steps:\n"+
		"      - if: vars.ENFORCE_PIPEFAIL_GREP_GUARD == 'true'\n"+
		"        name: "+sweepStep+"\n"+
		"        run: bash .claude/scripts/pipefail-grep-guard.sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if g := stepsNamed(t, gatedFixture, sweepStep); len(g) != 1 || g[0]["if"] == nil {
		t.Errorf("a condition written above the step name is still detected")
	}
	data, _ := os.ReadFile(ci)
	if !strings.Contains(string(data), "go -C .claude/scripts/pipefail-grep-guard-go test ./...") {
		t.Errorf("the self-test runs in CI")
	}
}

// The entrypoint keeps the caller's path and exit codes: 0, 1 and 2 pass through, and a launcher
// failure is 2 — never 1, which a caller reads as a finding. It also runs under /bin/bash, which
// may be 3.2.
func TestLauncher(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the program through the shared launcher")
	}
	launcher, err := filepath.Abs(filepath.Join("..", "pipefail-grep-guard.sh"))
	if err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(t.TempDir(), "empty.sh")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, shell, path string
		want              int
	}{
		{"...also under /bin/bash, which may be 3.2", "/bin/bash", empty, 0},
		{"the entrypoint passes a finding through as 1", "bash", mkscript(t, "f.sh", `producer | grep -q MATCH`), 1},
		{"the entrypoint passes an unreadable path through as 2", "bash", filepath.Join(t.TempDir(), "missing.sh"), 2},
	} {
		t.Run(c.name, func(t *testing.T) {
			if _, err := os.Stat(c.shell); c.shell == "/bin/bash" && err != nil {
				t.Skip("no /bin/bash")
			}
			err := exec.Command(c.shell, launcher, c.path).Run()
			rc := 0
			if ee, ok := err.(*exec.ExitError); ok {
				rc = ee.ExitCode()
			} else if err != nil {
				t.Fatal(err)
			}
			if rc != c.want {
				t.Fatalf("rc=%d, want %d", rc, c.want)
			}
		})
	}
	// Source invariants of the launcher: every early exit before the program runs is 2, and no
	// index advances by post-increment (`((n++))` returns 1 at n=0 and errexit aborts on bash 5).
	src, err := os.ReadFile(launcher)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(src), "\n") {
		if strings.HasPrefix(line, "HERE=") || strings.HasPrefix(line, ". ") {
			if !strings.HasSuffix(line, "|| exit 2") {
				t.Errorf("a launcher setup line can fail as something other than 2: %s", line)
			}
		}
	}
	postIncrement := regexp.MustCompile(`(?m)^[[:space:]]*[^#[:space:]].*\(\([A-Za-z_][A-Za-z0-9_]*\+\+\)\)`)
	if postIncrement.Match(src) {
		t.Errorf("the guard advances indices by pre-increment, never post-increment")
	}
}
