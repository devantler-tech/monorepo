package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
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
	// errOutputHeld marks a call whose output was still held open at the end of its bound.
	errOutputHeld = errors.New("the output was still held open at the deadline")
)

// descendants returns the process IDs below root in the process table, however deep, read from
// `ps` at the moment of the call. A process that left root's group with setsid is still root's
// descendant while its parent lives, so this reaches what a group signal cannot.
func descendants(root int) []int {
	raw, err := exec.Command("ps", "-A", "-o", "pid=", "-o", "ppid=").Output()
	if err != nil {
		return nil
	}
	children := map[int][]int{}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		if err1 == nil && err2 == nil && pid > 1 {
			children[ppid] = append(children[ppid], pid)
		}
	}
	var out []int
	queue := []int{root}
	seen := map[int]bool{root: true}
	for len(queue) > 0 {
		next := queue[0]
		queue = queue[1:]
		for _, child := range children[next] {
			if !seen[child] {
				seen[child] = true
				out = append(out, child)
				queue = append(queue, child)
			}
		}
	}
	return out
}

// bounded runs name with args and returns its standard output, and can never keep the check
// waiting past seconds plus killGrace: the command gets its own process group and the whole group
// is signalled when the bound passes, because a command can hand its work to a helper (ssh,
// git-remote-https, a runtime's own server) that outlives a signal aimed at the command alone.
// Each signal also goes to every descendant the process table shows at that moment, so a helper
// that moved to a session of its own while its parent still runs is ended too. env is added to the
// process's environment; standard error is discarded.
//
// The group is also ended when the check receives INT, TERM or HUP while the call runs: a group
// of its own does not get the terminal's or the caller's signal, so without this a stopped check
// would leave the call running. Either way the result is an error, never a clean read: it wraps
// errDeadline or errStopped, and the caller reports UNKNOWN.
//
// The output is read through a pipe this function owns, and only until the same deadline: a
// process the signals cannot reach (one already orphaned into a session of its own) can hold the
// pipe open, and the read then ends at the deadline as errOutputHeld, never as a clean read and
// never after a second full wait.
func bounded(seconds int, env []string, name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	cmd.Env = append(os.Environ(), env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	reader, writer, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	cmd.Stdout = writer
	bound := time.Duration(seconds) * time.Second
	// Listen before starting, so no stop request can fall between the start and the listener.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(stop)
	started := time.Now()
	if err := cmd.Start(); err != nil {
		writer.Close()
		return nil, err
	}
	// Only the command holds the write end now, so the read ends when everything that inherited
	// it has closed it.
	writer.Close()
	var out bytes.Buffer
	copied := make(chan struct{})
	go func() {
		_, _ = io.Copy(&out, reader)
		close(copied)
	}()
	pgid := cmd.Process.Pid
	var mu sync.Mutex
	tree := map[int]bool{}
	signalAll := func(sig syscall.Signal) {
		mu.Lock()
		defer mu.Unlock()
		for _, pid := range descendants(pgid) {
			tree[pid] = true
		}
		if syscall.Kill(-pgid, sig) != nil {
			_ = cmd.Process.Signal(sig)
		}
		// Every descendant seen at any signal so far, so one that was orphaned between TERM and
		// KILL is still reached. The window for a reused ID is the grace period at most.
		for pid := range tree {
			_ = syscall.Kill(pid, sig)
		}
	}
	var expired, stopped atomic.Bool
	var stoppedAt atomic.Int64
	term := time.AfterFunc(bound, func() {
		expired.Store(true)
		signalAll(syscall.SIGTERM)
	})
	// TERM only asks. KILL follows on its own clock, so a helper that ignores TERM cannot keep
	// this call waiting.
	kill := time.AfterFunc(bound+killGrace, func() { signalAll(syscall.SIGKILL) })
	finished, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case <-stop:
			stopped.Store(true)
			stoppedAt.Store(time.Now().UnixNano())
			signalAll(syscall.SIGTERM)
			kill.Reset(killGrace)
		case <-finished:
		}
	}()
	err = cmd.Wait()
	close(finished)
	// The watcher is done before the timers stop, so it cannot re-arm KILL after they have.
	<-watched
	// A stop request that came as the command finished is still a stop request.
	select {
	case <-stop:
		stopped.Store(true)
		stoppedAt.Store(time.Now().UnixNano())
	default:
	}
	term.Stop()
	kill.Stop()
	// KILL reaps whatever in the group, or in the tree seen at a signal, outlived the command.
	mu.Lock()
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
	for pid := range tree {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	mu.Unlock()
	// The read gets what is left of the original deadline and grace, or of the grace after a
	// stop, whichever ends first; never a fresh bound counted from the command's exit.
	deadline := started.Add(bound + killGrace)
	if at := stoppedAt.Load(); at != 0 {
		if afterStop := time.Unix(0, at).Add(killGrace); afterStop.Before(deadline) {
			deadline = afterStop
		}
	}
	// A read that has already finished wins over a deadline that has already passed.
	held := false
	select {
	case <-copied:
	default:
		select {
		case <-copied:
		case <-time.After(time.Until(deadline)):
			held = true
			_ = reader.Close() // ends the copy
			<-copied
		}
	}
	if held {
		err = errors.Join(errOutputHeld, err)
	}
	switch {
	case stopped.Load():
		return out.Bytes(), errors.Join(errStopped, err)
	case expired.Load():
		return out.Bytes(), errors.Join(errDeadline, err)
	}
	return out.Bytes(), err
}
