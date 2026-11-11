package main

import (
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// unknown stands for the part of a word only the running shell could know (an expansion). It is
// a character no option name, digit or command name contains, so a test against a word with an
// unknown tail decides only on the literal prefix bash would also have seen.
const unknown = "\x00"

// word is one argv word after quote removal, decided statically.
type word struct {
	val  string // the value bash would pass; for a partial word, its literal prefix + unknown
	lit  bool   // the whole word is literal, so val is exactly what the command receives
	show string // the spelling a finding prints
}

// argvWords converts parsed words without expanding anything: no variable is read, no
// substitution runs and no pathname is globbed, so a pattern like `*.log` stays a literal and the
// verdict never depends on the caller's working directory.
func argvWords(src string, ws []*syntax.Word) []word {
	out := make([]word, 0, len(ws))
	for _, w := range ws {
		out = append(out, toWord(src, w))
	}
	return out
}

func toWord(src string, w *syntax.Word) word {
	var b strings.Builder
	lit := true
	for _, part := range w.Parts {
		v, ok := literalPart(part)
		if !ok {
			lit = false
			break
		}
		b.WriteString(v)
	}
	if lit {
		return word{val: b.String(), lit: true, show: b.String()}
	}
	show := src[w.Pos().Offset():w.End().Offset()]
	return word{val: b.String() + unknown, show: show}
}

// literalPart returns the quote-removed value of a word part that needs no expansion.
func literalPart(part syntax.WordPart) (string, bool) {
	switch p := part.(type) {
	case *syntax.Lit:
		return unescapeBare(p.Value), true
	case *syntax.SglQuoted:
		if p.Dollar {
			return unescapeANSIC(p.Value), true
		}
		return p.Value, true
	case *syntax.DblQuoted:
		var b strings.Builder
		for _, inner := range p.Parts {
			l, ok := inner.(*syntax.Lit)
			if !ok {
				return "", false
			}
			b.WriteString(unescapeDouble(l.Value))
		}
		return b.String(), true
	}
	return "", false
}

// unescapeBare removes an unquoted backslash and keeps the character it escapes; a backslash
// before a newline is a line continuation and disappears with it.
func unescapeBare(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
			if s[i] != '\n' {
				b.WriteByte(s[i])
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// unescapeDouble applies the escapes double quotes honour: a backslash is removed only before
// `$`, a backtick, `"`, `\` or a newline, and is literal before anything else.
func unescapeDouble(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) && strings.IndexByte("$`\"\\\n", s[i+1]) >= 0 {
			i++
			if s[i] != '\n' {
				b.WriteByte(s[i])
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// unescapeANSIC decodes the common `$'…'` escapes. An escape it does not know keeps its
// backslash, which can only make a word read as something no option or command name matches.
func unescapeANSIC(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	simple := map[byte]byte{'a': 7, 'b': 8, 'e': 27, 'E': 27, 'f': 12, 'n': 10, 'r': 13, 't': 9, 'v': 11, '\\': '\\', '\'': '\'', '"': '"', '?': '?'}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			if r, ok := simple[s[i+1]]; ok {
				b.WriteByte(r)
				i++
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// isAssignmentWord matches a NAME=value word on its literal prefix; the value may be anything.
func isAssignmentWord(v string) bool {
	eq := strings.IndexByte(v, '=')
	if eq <= 0 {
		return false
	}
	for i := 0; i < eq; i++ {
		c := v[i]
		if !(c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (i > 0 && c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}
