// Command pipefail-grep-guard rejects piping a writer into a grep that exits early.
//
// `grep -q` stops reading at its FIRST match and exits 0. The writer upstream is then killed by
// SIGPIPE (or its write returns EPIPE) and exits non-zero, and under `set -o pipefail` the
// pipeline reports the WRITER's failure — so a pipeline that MATCHED reports failure. Both
// polarities break, and the negated one fails OPEN: `if ! cmd | grep -q PAT` reads a match as a
// non-match. It is a race decided by how much is still unwritten after the match, so a short
// fixture can pass a hundred times and the same line still flip in production; do not try to
// prove or refute it with a length test. Under an agent harness, check `which grep` first: a
// shimmed grep does not reproduce the class.
//
// The flags that stop early are -q/--quiet/--silent, -l/--files-with-matches and a finite
// -m/--max-count; -c, -L and a plain grep read to the end. The fix the finding asks for is to feed
// grep without a pipe: a here-string from a variable, `out="$(cmd)"` then `<<<"$out"` for a
// command, or a file. `grep -q PAT < <(cmd)` also removes the pipe but DISCARDS the producer's
// exit status, so it fits only where that status is checked separately.
//
// This replaced a Bash implementation whose line-oriented regexes kept producing parsing gaps
// (monorepo#2797). Quoting, comments, heredocs, substitutions and command boundaries are decided
// by the mvdan.cc/sh parser, so that class of defect is no longer reachable here.
//
// KNOWN, DELIBERATE LIMITS. `producer | xargs grep -l …` carries the same hazard and is not
// detected (xargs would take the SIGPIPE); a grep that is not the stage's own command, such as
// `producer | { grep -q X; }`, is not detected either. Neither occurs in this repository.
package main

import (
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

//go:embed help.txt
var helpText string

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run is the whole command line: 0 clean, 1 at least one finding, 2 usage or unreadable input.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Fprint(stderr, helpText)
		return 2
	}
	die := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "pipefail-grep-guard: "+format+"\n", a...)
		return 2
	}
	targets := args
	if len(targets) == 0 {
		out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
		if err != nil {
			return die("not inside a git repository, and no paths were given")
		}
		repo := strings.TrimRight(string(out), "\n")
		if err := os.Chdir(repo); err != nil {
			return die("cannot enter %s", repo)
		}
		if targets, err = trackedShellScripts(); err != nil {
			return die("%v", err)
		}
		if len(targets) == 0 {
			return die("no tracked shell scripts found")
		}
	}

	findings, unparsed := 0, 0
	for _, path := range targets {
		found, lines, err := scanPath(path)
		if err != nil {
			return die("%v", err)
		}
		report(stdout, path, found, lines)
		for _, f := range found {
			if f.flag == "" {
				unparsed++
			} else {
				findings++
			}
		}
	}
	if findings+unparsed > 0 {
		if findings > 0 {
			fmt.Fprintf(stderr, "\npipefail-grep-guard: %d offending pipeline(s).\n", findings)
			fmt.Fprintln(stderr, "Each one reports FAILURE when it MATCHED. A negated one reports success and guards nothing.")
		}
		if unparsed > 0 {
			fmt.Fprintf(stderr, "\npipefail-grep-guard: %d file(s) could not be parsed, so they were not shown clean.\n", unparsed)
		}
		return 1
	}
	fmt.Fprintln(stdout, "pipefail-grep-guard: no writer piped into an early-exiting grep.")
	return 0
}

// report prints each finding with its fix. Two offenders on one line share a file:line and
// usually a flag, so each is numbered; a lone one is not.
func report(w io.Writer, path string, found []finding, lines []string) {
	perLine := map[int]int{}
	for _, f := range found {
		perLine[f.line]++
	}
	seen := map[int]int{}
	for _, f := range found {
		shown := ""
		if f.line-1 < len(lines) {
			shown = strings.TrimLeft(lines[f.line-1], " \t\n\v\f\r")
		}
		fmt.Fprintf(w, "%s:%d: %s\n", path, f.line, shown)
		if f.flag == "" {
			fmt.Fprintf(w, "    cannot be parsed as shell (%s), so it cannot be shown free of a writer piped into an early-exiting grep.\n", f.detail)
			fmt.Fprintln(w, "    fix: correct the syntax; if bash accepts this file, the parser gap is a guard defect to report, not a reason to skip the file.")
			continue
		}
		seen[f.line]++
		if n := perLine[f.line]; n > 1 {
			fmt.Fprintf(w, "    [%d of %d on this line] grep %s stops at the first match; the writer dies of SIGPIPE and pipefail reports THAT.\n", seen[f.line], n, f.flag)
		} else {
			fmt.Fprintf(w, "    grep %s stops at the first match; the writer dies of SIGPIPE and pipefail reports THAT.\n", f.flag)
		}
		fmt.Fprintf(w, "    fix: feed grep without a pipe — grep %s PAT <<<\"$var\", or out=\"$(cmd)\" then <<<\"$out\", or from a file.\n", f.flag)
		fmt.Fprintln(w, "    note: < <(cmd) removes the pipe too, but DISCARDS the producer status — check it separately.")
	}
}
