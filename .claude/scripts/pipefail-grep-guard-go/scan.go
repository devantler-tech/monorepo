package main

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// The whole-file directive: a COMMENT LINE that BEGINS with it. A mention inside prose,
// backticks, a string or a heredoc body is not a comment, or not one that begins its line, so it
// exempts nothing — which is why the guard's own documentation cannot disable it.
var allowFileRe = regexp.MustCompile(`^[[:space:]]*pipefail-grep-guard:[[:space:]]*allow-file([[:space:]]|$)`)

// The line-level escape hatch: a comment carrying the marker on the pipeline's last line.
var allowLineRe = regexp.MustCompile(`pipefail-grep-guard:[[:space:]]*allow`)

// finding is one grep stage that stops at its first match while a writer feeds it.
type finding struct {
	line   int    // the line the pipeline STARTS on
	offset int    // where the grep stage starts, to order several on one line
	flag   string // the early-exit option as written, or "" for a file that cannot be parsed
	detail string // the parse error, when flag is ""
}

// scanPath reads one file and returns its findings. An unreadable or non-regular path is an
// error, never a silent pass: a tracked `*.sh` symlink to a character device is readable and
// endless, and reading it would hang a required job.
func scanPath(path string) ([]finding, []string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, nil, fmt.Errorf("cannot read %s", path)
	}
	if !info.Mode().IsRegular() {
		return nil, nil, fmt.Errorf("not a regular file: %s", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, fmt.Errorf("cannot read %s", path)
	}
	src := strings.ToValidUTF8(string(data), "�")
	return scanSource(src), strings.Split(src, "\n"), nil
}

// scanSource parses one script and returns every offending grep stage in source order.
//
// The parser decides what is code: quoting, comments, heredoc bodies, command and process
// substitutions (which run even inside double quotes and unquoted heredoc bodies), arithmetic
// and command boundaries. A heredoc body or a quoted string is data and is never matched; a `#`
// inside quotes opens no comment, so it can neither hide code nor carry an escape hatch.
//
// A file the parser cannot read is reported rather than passed: the guard cannot show it is
// free of the hazard, and a syntax error is something bash would reject too.
func scanSource(src string) []finding {
	f, err := syntax.NewParser(syntax.KeepComments(true), syntax.Variant(syntax.LangBash)).
		Parse(strings.NewReader(src), "")
	if err != nil {
		line := 1
		var perr syntax.ParseError
		var lerr syntax.LangError
		switch {
		case errors.As(err, &perr):
			line = int(perr.Pos.Line())
		case errors.As(err, &lerr):
			line = int(lerr.Pos.Line())
		}
		return []finding{{line: line, detail: err.Error()}}
	}

	allowLines := map[uint]bool{}
	exempt := false
	syntax.Walk(f, func(n syntax.Node) bool {
		c, ok := n.(*syntax.Comment)
		if !ok {
			return true
		}
		off := int(c.Hash.Offset())
		start := strings.LastIndexByte(src[:off], '\n') + 1
		before := src[start:off]
		if strings.TrimLeft(before, " \t\v\f\r") == "" && allowFileRe.MatchString(c.Text) {
			exempt = true
		}
		// The `#` must begin the line or follow whitespace, as the hatch always required.
		if (before == "" || isSpace(before[len(before)-1])) && allowLineRe.MatchString(c.Text) {
			allowLines[c.Hash.Line()] = true
		}
		return true
	})
	if exempt {
		return nil
	}

	var out []finding
	inner := map[*syntax.BinaryCmd]bool{}
	syntax.Walk(f, func(n syntax.Node) bool {
		b, ok := n.(*syntax.BinaryCmd)
		if !ok || !isPipe(b) || inner[b] {
			return true
		}
		stages := pipelineStages(b, inner)
		last := stages[len(stages)-1].End().Line()
		for _, st := range stages[1:] {
			call, ok := st.Cmd.(*syntax.CallExpr)
			if !ok {
				continue
			}
			flag, ok := earlyExit(src, call)
			if !ok {
				continue
			}
			// The escape hatch must sit on the line where the grep stage AND the pipeline end, so
			// a marker on some other line of a long pipeline cannot exempt this stage.
			if end := st.End().Line(); allowLines[end] && last == end {
				continue
			}
			out = append(out, finding{
				line:   int(stages[0].Pos().Line()),
				offset: int(st.Pos().Offset()),
				flag:   flag,
			})
		}
		return true
	})
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].line != out[j].line {
			return out[i].line < out[j].line
		}
		return out[i].offset < out[j].offset
	})
	return out
}

// isPipe reports whether a binary command is a `|` or `|&` pipe.
func isPipe(b *syntax.BinaryCmd) bool {
	return b.Op == syntax.Pipe || b.Op == syntax.PipeAll
}

// pipelineStages flattens a pipeline into its stages, in order, marking the nested pipe nodes so
// the walk does not report one pipeline once per operator.
func pipelineStages(b *syntax.BinaryCmd, inner map[*syntax.BinaryCmd]bool) []*syntax.Stmt {
	var stages []*syntax.Stmt
	var add func(*syntax.Stmt)
	add = func(st *syntax.Stmt) {
		if nb, ok := st.Cmd.(*syntax.BinaryCmd); ok && isPipe(nb) && !st.Negated && !st.Background &&
			!st.Coprocess && len(st.Redirs) == 0 {
			inner[nb] = true
			add(nb.X)
			add(nb.Y)
			return
		}
		stages = append(stages, st)
	}
	add(b.X)
	add(b.Y)
	return stages
}
