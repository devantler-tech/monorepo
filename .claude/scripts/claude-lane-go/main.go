// Command claude-lane answers two read-only questions about the Claude lane's scheduled runs, from the
// runtime's scheduled-tasks store and its session transcripts (monorepo#3592):
//
//	claude-lane liveness [flags]       did the newest dispatch of each task produce work?
//	claude-lane dispatch-rate [flags]  how many scheduled slots in a window actually dispatched?
//
// It is the implementation behind claude-lane-liveness.sh and claude-dispatch-rate.sh, which stay
// the entrypoints. The port keeps both scripts' contracts line for line: the same flags, the same
// output lines and the same exit codes (liveness: 0 producing, 1 NOT PRODUCING, 2 UNKNOWN;
// dispatch-rate: 0 measured, 2 UNKNOWN). liveness-help.txt and dispatch-rate-help.txt are the full
// usage and design notes, and `--help` prints them.
//
// The two commands share what the scripts each carried a copy of: store discovery, the anchored
// task-marker attribution of a transcript's first line, and the transcript enumeration. Local wall
// clock comes from the time package's zone database (the host TZ), never from offset arithmetic.
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, time.Local, time.Now().Unix()))
}

func run(args []string, stdout, stderr io.Writer, loc *time.Location, now int64) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "claude-lane: UNKNOWN -- expected a subcommand: liveness or dispatch-rate")
		return 2
	}
	env := environment{
		storePath:  os.Getenv("CLAUDE_SCHEDULE_STORE_PATH"),
		storeRoot:  os.Getenv("CLAUDE_SCHEDULE_STORE_ROOT"),
		projects:   os.Getenv("CLAUDE_PROJECTS_ROOT"),
		home:       os.Getenv("HOME"),
		loc:        loc,
		wallNow:    now,
		readHeader: readFirstLine,
		lookPath:   exec.LookPath,
	}
	switch args[0] {
	case "liveness":
		return liveness(args[1:], stdout, stderr, env)
	case "dispatch-rate":
		return dispatchRate(args[1:], stdout, stderr, env)
	default:
		fmt.Fprintf(stderr, "claude-lane: UNKNOWN -- unknown subcommand: %s\n", args[0])
		return 2
	}
}

// environment is everything a command reads from outside its arguments, so a test can pin it.
type environment struct {
	storePath, storeRoot, projects, home string
	loc                                  *time.Location
	wallNow                              int64
	// readHeader reads a transcript's first line. It is a seam only so a test can make one header
	// unreadable, which the shell suite did by shimming `head` on PATH.
	readHeader func(path string) (string, error)
	// lookPath finds a program on PATH; nil (in tests) means every program is present.
	lookPath func(name string) (string, error)
}

// hasJQ keeps the scripts' "no jq" UNKNOWN. This implementation parses JSON itself and never runs
// jq, but a host the Bash could not judge is not one the port starts judging silently; dropping
// the requirement is a separate, deliberate change.
func (e environment) hasJQ() bool {
	if e.lookPath == nil {
		return true
	}
	_, err := e.lookPath("jq")
	return err == nil
}

func (e environment) defaultStoreRoot() string {
	if e.storeRoot != "" {
		return e.storeRoot
	}
	return e.home + "/Library/Application Support/Claude/claude-code-sessions"
}

func (e environment) defaultProjects() string {
	if e.projects != "" {
		return e.projects
	}
	return e.home + "/.claude/projects"
}
