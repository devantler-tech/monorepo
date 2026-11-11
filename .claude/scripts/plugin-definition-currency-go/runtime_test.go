package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeCodex puts a `codex` that runs body first on PATH, so the query below reaches it and no
// host runtime is ever asked about the fixture (monorepo#4932).
func fakeCodex(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte("#!/bin/sh\n"+body), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return dir
}

// codexFixture is a Codex home with one cached copy of the plugin, and a check that resolves it.
func codexFixture(t *testing.T, bound string) (*check, string) {
	t.Helper()
	home := t.TempDir()
	install := filepath.Join(home, "plugins", "cache", "devantler-plugins", "agentic-engineering", "9.9.9")
	if err := os.MkdirAll(install, 0o700); err != nil {
		t.Fatal(err)
	}
	c := &check{runtimeTimeout: bound, o: options{
		runtime: "codex", codexHome: home,
		pluginID: "agentic-engineering@devantler-plugins", pluginName: "agentic-engineering",
	}}
	return c, install
}

// waitGone fails the test unless pid exits within a few seconds; signal 0 fails with ESRCH once
// the process is gone.
func waitGone(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			_ = syscall.Kill(pid, syscall.SIGKILL)
			t.Fatalf("descendant %d outlived the bound", pid)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func readPID(t *testing.T, file string) int {
	t.Helper()
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("the descendant never started, so the test proves nothing: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 {
		t.Fatalf("unreadable descendant PID %q", raw)
	}
	return pid
}

// A runtime that never answers, ignores TERM and leaves a descendant holding its output open ends
// as UNKNOWN at the deadline, names the deadline, and leaves no process behind.
func TestCodexStateQueryThatHangsIsUnknownAtTheDeadline(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "descendant.pid")
	fakeCodex(t, "trap '' TERM\nsh -c 'echo $$ >\""+pidFile+"\"; trap \"\" TERM; exec sleep 60' &\nsleep 60\n")
	c, _ := codexFixture(t, "1")
	start := time.Now()
	err := c.resolveInstalled()
	elapsed := time.Since(start)
	var u *unknown
	if !errors.As(err, &u) {
		t.Fatalf("a hanging runtime query must be UNKNOWN, got %v", err)
	}
	if !strings.Contains(u.msg, "did not answer within 1s") {
		t.Fatalf("the UNKNOWN does not name the deadline: %q", u.msg)
	}
	if c.o.installed != "" {
		t.Fatalf("a hanging runtime query still resolved an install: %s", c.o.installed)
	}
	if elapsed > 1*time.Second+killGrace+5*time.Second {
		t.Fatalf("the deadline did not hold: %v", elapsed)
	}
	waitGone(t, readPID(t, pidFile))
}

// Negative control: a runtime that answers at once is unaffected by the deadline and resolves its
// one cached copy.
func TestCodexStateQueryThatAnswersStillResolves(t *testing.T) {
	fakeCodex(t, "printf '{\"installed\":[{\"pluginId\":\"agentic-engineering@devantler-plugins\",\"enabled\":true}],\"available\":[]}\\n'\n")
	c, install := codexFixture(t, "1")
	if err := c.resolveInstalled(); err != nil {
		t.Fatalf("a runtime that answers at once must resolve, got %v", err)
	}
	if c.o.installed != install {
		t.Fatalf("resolved %q, want %q", c.o.installed, install)
	}
}

// A runtime that exits non-zero is still a failed query, and malformed output still UNKNOWN,
// under the bound.
func TestCodexStateQueryFailuresStayUnknown(t *testing.T) {
	for _, tc := range []struct{ name, body, want string }{
		{"a failed query", "echo 'failed to load configuration' >&2\nexit 1\n", "runtime state query failed"},
		{"malformed output", "echo '{not json'\n", "malformed JSON"},
		{"no output", "exit 0\n", "returned no data"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fakeCodex(t, tc.body)
			c, _ := codexFixture(t, "5")
			var u *unknown
			if err := c.resolveInstalled(); !errors.As(err, &u) || !strings.Contains(u.msg, tc.want) {
				t.Fatalf("got %v, want UNKNOWN naming %q", err, tc.want)
			}
		})
	}
}

// A stop request that reaches the check while a bounded call runs ends the call and its
// descendants at once and is reported as a failure, never a clean result.
func TestBoundedCallEndsItsGroupWhenTheCheckIsStopped(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "descendant.pid")
	script := filepath.Join(dir, "slow")
	body := "#!/bin/sh\ntrap '' TERM\nsh -c 'echo $$ >\"" + pidFile + "\"; trap \"\" TERM; exec sleep 60' &\nsleep 60\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := bounded(30, nil, script)
		done <- err
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(pidFile); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the bounded command never started its descendant")
		}
		time.Sleep(20 * time.Millisecond)
	}
	pid := readPID(t, pidFile)
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, errStopped) {
			t.Fatalf("a stopped call must report errStopped, got %v", err)
		}
	case <-time.After(killGrace + 5*time.Second):
		t.Fatal("a stop request did not end the bounded call")
	}
	waitGone(t, pid)
}

// The runtime deadline is validated like the remote one: a value that is not a whole number of
// seconds is UNKNOWN, never an unbounded query.
func TestRuntimeDeadlineMustBeWholeSeconds(t *testing.T) {
	for _, v := range []string{"soon", "0", "1000", "-1", "1.5"} {
		t.Run(v, func(t *testing.T) {
			t.Setenv("PLUGIN_CURRENCY_RUNTIME_TIMEOUT_SECS", v)
			var stdout, stderr strings.Builder
			code := run([]string{"--runtime", "codex", "--gitlink", strings.Repeat("a", 40)}, &stdout, &stderr)
			if code != 2 || !strings.Contains(stderr.String(), "PLUGIN_CURRENCY_RUNTIME_TIMEOUT_SECS must be a whole number of seconds from 1 to 999") {
				t.Fatalf("exit %d, stderr %q", code, stderr.String())
			}
		})
	}
}
