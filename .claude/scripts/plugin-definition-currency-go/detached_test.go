package main

import (
	"errors"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// TestDetachedHelperProcess is not a test: run as a child with BOUNDED_DETACH_PIDFILE set, it is a
// helper that leaves its process group for a session of its own (as an ssh wrapper's helper can),
// records its PID, ignores TERM and keeps the inherited output open.
func TestDetachedHelperProcess(t *testing.T) {
	pidFile := os.Getenv("BOUNDED_DETACH_PIDFILE")
	if pidFile == "" {
		return
	}
	if _, err := syscall.Setsid(); err != nil {
		os.Exit(3)
	}
	signal.Ignore(syscall.SIGTERM)
	if os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0o600) != nil {
		os.Exit(4)
	}
	time.Sleep(60 * time.Second)
	os.Exit(0)
}

// detachedScript writes a command that ignores TERM and starts the detached helper, either as
// its own child (orphaned=false) or through a subshell that exits at once, so the helper is
// orphaned before any signal (orphaned=true).
func detachedScript(t *testing.T, orphaned bool) (script, pidFile string) {
	t.Helper()
	testBin, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	pidFile = filepath.Join(dir, "helper.pid")
	start := "'" + testBin + "' -test.run='^TestDetachedHelperProcess$' &"
	if orphaned {
		start = "( " + start + " )"
	}
	body := "#!/bin/sh\ntrap '' TERM\n" + start + "\nsleep 60\n"
	script = filepath.Join(dir, "detaching")
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BOUNDED_DETACH_PIDFILE", pidFile)
	return script, pidFile
}

// A helper that moved to a session of its own while its parent still runs is out of reach of the
// group signal, but not of the bound: it is ended with the group.
func TestBoundedEndsADescendantThatLeftTheGroup(t *testing.T) {
	script, pidFile := detachedScript(t, false)
	_, err := bounded(1, nil, script)
	if !errors.Is(err, errDeadline) {
		t.Fatalf("a call ended at the bound must report errDeadline, got %v", err)
	}
	waitGone(t, readPID(t, pidFile))
}

// The output wait is part of the bound, not a second one after the command exits: a process the
// signals cannot reach (orphaned into a session of its own before the deadline) holds the output
// open, and the call still returns by the deadline plus the grace period, as a failure.
func TestBoundedOutputWaitEndsWithTheDeadline(t *testing.T) {
	script, pidFile := detachedScript(t, true)
	start := time.Now()
	_, err := bounded(1, nil, script)
	elapsed := time.Since(start)
	pid := readPID(t, pidFile)
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
	if !errors.Is(err, errDeadline) || !errors.Is(err, errOutputHeld) {
		t.Fatalf("a held output at the bound must report errDeadline and errOutputHeld, got %v", err)
	}
	if limit := 1*time.Second + killGrace + 1500*time.Millisecond; elapsed > limit {
		t.Fatalf("the call took %v, past the deadline and grace (%v)", elapsed, limit)
	}
}
