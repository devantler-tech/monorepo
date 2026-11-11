package main

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

// killGrace is how long a TERM at a bound, or at a stop request, has before the whole process
// group is killed.
const killGrace = 2 * time.Second

var (
	// errDeadline marks a bounded call ended because its bound passed.
	errDeadline = errors.New("the deadline passed")
	// errStopped marks a bounded call ended because the check itself was asked to stop.
	errStopped = errors.New("the check was stopped")
)

// bounded runs name with args and returns its standard output, and can never keep the check
// waiting past seconds: the command gets its own process group and the whole group is signalled
// when the bound passes, because a command can hand its work to a helper (ssh, git-remote-https, a
// runtime's own server) that outlives a signal aimed at the command alone. env is added to the
// process's environment; standard error is discarded.
//
// The group is also ended when the check receives INT, TERM or HUP while the call runs: a group
// of its own does not get the terminal's or the caller's signal, so without this a stopped check
// would leave the call running. Either way the result is an error, never a clean read: it wraps
// errDeadline or errStopped, and the caller reports UNKNOWN.
func bounded(seconds int, env []string, name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	cmd.Env = append(os.Environ(), env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var out bytes.Buffer
	cmd.Stdout = &out
	bound := time.Duration(seconds) * time.Second
	// Wait also waits for the output pipe to close. A process outside the group can hold it open,
	// so the wait for it after the command exits is bounded too, and a pipe closed that way is a
	// failed read (exec.ErrWaitDelay), never a clean one.
	cmd.WaitDelay = bound + killGrace
	// Listen before starting, so no stop request can fall between the start and the listener.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(stop)
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	pgid := cmd.Process.Pid
	signalGroup := func(sig syscall.Signal) {
		if syscall.Kill(-pgid, sig) != nil {
			_ = cmd.Process.Signal(sig)
		}
	}
	var expired, stopped atomic.Bool
	term := time.AfterFunc(bound, func() {
		expired.Store(true)
		signalGroup(syscall.SIGTERM)
	})
	// TERM only asks. KILL follows on its own clock, so a helper that ignores TERM, or a
	// descendant holding the output open, cannot keep this call waiting.
	kill := time.AfterFunc(bound+killGrace, func() { signalGroup(syscall.SIGKILL) })
	finished, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case <-stop:
			stopped.Store(true)
			signalGroup(syscall.SIGTERM)
			kill.Reset(killGrace)
		case <-finished:
		}
	}()
	err := cmd.Wait()
	close(finished)
	// The watcher is done before the timers stop, so it cannot re-arm KILL after they have.
	<-watched
	// A stop request that came as the command finished is still a stop request.
	select {
	case <-stop:
		stopped.Store(true)
	default:
	}
	term.Stop()
	kill.Stop()
	// KILL reaps whatever in the group outlived the command.
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
	switch {
	case stopped.Load():
		return out.Bytes(), errors.Join(errStopped, err)
	case expired.Load():
		return out.Bytes(), errors.Join(errDeadline, err)
	}
	return out.Bytes(), err
}
