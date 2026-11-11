package main

import (
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// grepNames are the command names that run grep.
var grepNames = map[string]bool{"grep": true, "egrep": true, "fgrep": true}

// earlyExit reports the option that makes a pipeline stage's grep stop at its first match, if
// the stage runs grep at all.
func earlyExit(src string, call *syntax.CallExpr) (string, bool) {
	args := argvWords(src, call.Args)
	i, args := grepIndex(args)
	if i < 0 {
		return "", false
	}
	return earlyExitFlag(args[i+1:])
}

// grepIndex finds grep behind the spellings that still run it: `command` and `env` (with their
// own options, value-taking env options and NAME=value operands) and an absolute path. The
// leading NAME=value prefixes of a simple command are separate assignments in the syntax tree,
// so a quoted, mixed, escaped or substituted value can no longer hide the command word.
//
// It returns the index of grep in the (possibly rewritten) argv, or -1. The argv is rewritten
// only for `env -S STRING`, whose command line lives inside the option VALUE: that string is
// split as a shell line and stands in for the option.
//
// Deliberately NOT a wrapper: `xargs` consumes the producer's whole stream and hands grep file
// names, so nothing is SIGPIPEd; and `command -v`/`-V` only describe grep without running it.
func grepIndex(args []word) (int, []word) {
	wrapper := ""
	for i := 0; i < len(args); {
		w := args[i]
		v := w.val
		switch {
		case w.lit && (v == "command" || v == "env"):
			wrapper = v
			i++
		case w.lit && wrapper == "env" && (v == "-S" || v == "--split-string"):
			if i+1 < len(args) && args[i+1].lit {
				if split, ok := splitString(args[i+1].val); ok {
					args = append(append(append([]word{}, args[:i]...), split...), args[i+2:]...)
					continue
				}
			}
			i += 2
		case w.lit && wrapper == "env" && (strings.HasPrefix(v, "--split-string=") || (strings.HasPrefix(v, "-S") && len(v) > 2)):
			value := strings.TrimPrefix(v, "--split-string=")
			if value == v {
				value = v[2:]
			}
			if split, ok := splitString(value); ok {
				args = append(append(append([]word{}, args[:i]...), split...), args[i+1:]...)
				continue
			}
			i++
		case w.lit && (v == "-u" || v == "-C" || v == "-S" || v == "--unset" || v == "--chdir" || v == "--split-string"):
			i += 2
		case strings.HasPrefix(v, "-"):
			if wrapper == "command" && !strings.HasPrefix(v, "--") && strings.ContainsAny(v, "vV") {
				return -1, args // `command -v grep` inspects grep; it never runs it
			}
			i++
		case isAssignmentWord(v):
			i++
		default:
			if w.lit && grepNames[basename(v)] {
				return i, args
			}
			return -1, args
		}
	}
	return -1, args
}

// splitString splits an `env -S` value the way the shell splits a command line, without
// expanding anything. A value it cannot parse leaves the option as an opaque word.
func splitString(s string) ([]word, bool) {
	f, err := syntax.NewParser(syntax.Variant(syntax.LangBash)).Parse(strings.NewReader(s), "")
	if err != nil || len(f.Stmts) == 0 {
		return nil, false
	}
	call, ok := f.Stmts[0].Cmd.(*syntax.CallExpr)
	if !ok {
		return nil, false
	}
	var out []word
	for _, a := range call.Assigns {
		out = append(out, word{val: a.Name.Value + "=" + unknown, show: a.Name.Value + "="})
	}
	return append(out, argvWords(s, call.Args)...), true
}

// earlyExitFlag decides, from everything after `grep`, whether grep was asked to stop at its
// first match: -q/--quiet/--silent, -l/--files-with-matches and a finite -m/--max-count do, while
// -c, -L and a plain grep read their input to the end.
//
// The walk does NOT stop at the first operand: GNU grep permutes later options to the front
// unless POSIXLY_CORRECT is set, so `grep PATTERN -q` IS an early exit on the Linux runner. Only
// `--` ends option parsing. Cluster letters are case-sensitive: `-L` reads to the end, `-l` does
// not. A value-taking letter swallows the rest of its cluster or the next word, so `-eq` is -e
// with the pattern `q`.
//
// `-m` is the one early exit a LATER option can undo: grep keeps the last count and a negative
// one is infinity. So the max-count verdict is settled when the words run out.
func earlyExitFlag(args []word) (string, bool) {
	pending := ""
	wantCount, skipNext := false, false
	for _, w := range args {
		tok := w.val
		if wantCount {
			wantCount = false
			if maxCountIsFinite(tok) {
				pending = "-m " + w.show
			} else {
				pending = ""
			}
			continue
		}
		if skipNext {
			skipNext = false
			continue
		}
		switch {
		case tok == "--":
			return settle(pending)
		case tok == "--quiet" || tok == "--silent" || tok == "--files-with-matches":
			return w.show, true
		case strings.HasPrefix(tok, "--max-count="):
			pending = finiteOr(strings.TrimPrefix(tok, "--max-count="), w.show)
		case tok == "--max-count":
			wantCount = true
		case strings.HasPrefix(tok, "--"):
			if flag, ok := longOption(w, &pending, &wantCount, &skipNext); ok {
				return flag, true
			}
		case strings.HasPrefix(tok, "-"):
			letters := tok[1:]
		cluster:
			for i := 0; i < len(letters); i++ {
				switch letters[i] {
				case 'q', 'l':
					return w.show, true
				case 'm':
					// -m takes a value: the rest of the cluster, else the next word.
					if rest := letters[i+1:]; rest == "" {
						wantCount = true
					} else {
						pending = finiteOr(rest, w.show)
					}
					break cluster
				case 'e', 'f', 'A', 'B', 'C', 'D', 'd':
					if i+1 >= len(letters) {
						skipNext = true
					}
					break cluster
				}
			}
		}
	}
	return settle(pending)
}

// valueLongOptions are grep's long options whose value is the FOLLOWING word.
var valueLongOptions = []string{
	"--regexp", "--file", "--after-context", "--before-context", "--context",
	"--binary-files", "--devices", "--directories", "--label", "--include",
	"--exclude", "--exclude-dir", "--exclude-from", "--group-separator",
}

// longOption handles a long option other than the exact early-exit and max-count spellings. GNU
// accepts any unambiguous ABBREVIATION, so `--quie` is `--quiet`; an exact name wins over an
// abbreviation, so `--file` is --file and not a short `--files-with-matches`. Over-reading an
// ambiguous abbreviation is safe: grep itself rejects it, so the pipeline does not run.
func longOption(w word, pending *string, wantCount, skipNext *bool) (string, bool) {
	tok := w.val
	name, value, hasValue := strings.Cut(tok, "=")
	for _, exact := range valueLongOptions {
		if name == exact {
			*skipNext = !hasValue
			return "", false
		}
	}
	for _, opt := range []string{"--quiet", "--silent", "--files-with-matches"} {
		if strings.HasPrefix(opt, tok) {
			return w.show, true
		}
	}
	if strings.HasPrefix("--max-count", name) {
		if hasValue {
			*pending = finiteOr(value, w.show)
		} else {
			*wantCount = true
		}
		return "", false
	}
	if !hasValue {
		for _, opt := range valueLongOptions {
			if strings.HasPrefix(opt, tok) {
				*skipNext = true
				break
			}
		}
	}
	return "", false
}

// finiteOr returns show when count can stop grep mid-stream, and "" when it cannot.
func finiteOr(count, show string) string {
	if maxCountIsFinite(count) {
		return show
	}
	return ""
}

// settle reports the max-count verdict once the command has ended.
func settle(pending string) (string, bool) {
	return pending, pending != ""
}

// maxCountIsFinite is true for a count that can stop grep mid-stream. A NEGATIVE count is
// infinity and ZERO selects nothing, so neither races; a missing value makes grep fail. Zero is
// decided by value, never by a leading `0` (`-m01` is one). Anything that is not a bare decimal,
// including a value only the running shell knows, is reported.
func maxCountIsFinite(v string) bool {
	switch {
	case strings.HasPrefix(v, "-"), v == "":
		return false
	case strings.Trim(v, "0123456789") != "":
		return true
	}
	return strings.TrimLeft(v, "0") != ""
}
