package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// shells are the interpreter names, after a version suffix is stripped, whose scripts are in scope.
var shells = map[string]bool{
	"sh": true, "bash": true, "dash": true, "ksh": true, "mksh": true, "pdksh": true,
	"ash": true, "zsh": true, "yash": true, "busybox": true,
}

// trackedShellScripts lists every tracked shell script in the current repository: `*.sh` by
// name, plus any regular file whose shebang resolves to a shell. Git quotes a path outside its
// safe character set (`"t\303\251st.sh"`), so the list is read NUL-delimited; a quoted path
// would match neither test and the sweep would skip it while still reporting the tree clean.
func trackedShellScripts() ([]string, error) {
	out, err := exec.Command("git", "ls-files", "-z").Output()
	if err != nil {
		return nil, fmt.Errorf("cannot list tracked files: %v", err)
	}
	var targets []string
	for _, f := range strings.Split(string(out), "\x00") {
		if f == "" {
			continue
		}
		// A `*.sh` path is in scope whatever it is: a non-regular one is then a controlled
		// error at scan time rather than a silent omission here.
		if strings.HasSuffix(f, ".sh") {
			targets = append(targets, f)
			continue
		}
		shell, err := isShellScript(f)
		if err != nil {
			return nil, err
		}
		if shell {
			targets = append(targets, f)
		}
	}
	return targets, nil
}

// isShellScript reports whether a tracked file's shebang names a shell. The executable bit alone
// would sweep in every compiled helper, so the interpreter is resolved instead. A directory (a
// submodule gitlink) or another non-regular entry is not a script; a tracked path that cannot be
// stat'ed or read is an error, never a silent omission that leaves its pipelines unscanned.
func isShellScript(path string) (bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		return false, fmt.Errorf("cannot read %s", path)
	}
	if !info.Mode().IsRegular() {
		return false, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return false, fmt.Errorf("cannot read %s", path)
	}
	defer f.Close()
	buf := make([]byte, 4096)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		return false, fmt.Errorf("cannot read %s", path)
	}
	first := buf[:n]
	if i := bytes.IndexByte(first, '\n'); i >= 0 {
		first = first[:i]
	}
	return shebangIsShell(strings.TrimSuffix(string(first), "\r")), nil
}

// shebangIsShell resolves the interpreter a first line names rather than asking whether it ends
// in `sh`: a suffix test misses `#!/usr/bin/ksh93` and `#!/usr/bin/bash5` and admits
// `shellcheck`. `#!/usr/bin/env …` puts the shell in env's OPERAND, behind env's own options.
func shebangIsShell(first string) bool {
	if !strings.HasPrefix(first, "#!") {
		return false
	}
	shebang := trimLeftSpace(first[2:])
	interp := shebang
	if i := strings.IndexFunc(shebang, isSpaceRune); i >= 0 {
		interp = shebang[:i]
	}
	base := basename(interp)
	if base == "env" || (len(base) > 3 && strings.HasPrefix(base, "env") && strings.ContainsRune("0123456789.", rune(base[3]))) {
		base = basename(envOperand(shebang))
	}
	// Strip a version suffix: ksh93 -> ksh, bash5 -> bash, sh5.2 -> sh.
	base = strings.TrimRight(base, "0123456789.")
	return shells[base]
}

// envOperand resolves the command `env` would execute, given a shebang with `#!` removed. env's
// options come first; value-taking ones consume their value; `-S`/`--split-string` introduces a
// command line whose FIRST word is the command, attached or separate; `--` ends option parsing.
// It returns "" when no operand remains, which resolves to no shell.
func envOperand(rest string) string {
	rest = trimLeftSpace(rest)
	if i := strings.IndexFunc(rest, isSpaceRune); i >= 0 {
		rest = rest[i:] // drop env's own path
	} else {
		rest = ""
	}
	options := true
loop:
	for {
		rest = trimLeftSpace(rest)
		if rest == "" {
			break
		}
		tok := envNextToken(rest)
		if !options {
			// After `--` env still consumes NAME=value operands before the command.
			if !isEnvAssignment(tok) {
				break
			}
			rest = rest[len(tok):]
			continue
		}
		switch {
		case tok == "--":
			rest = rest[2:]
			options = false
		case tok == "-S" || tok == "--split-string":
			rest = splitStringSeparators(rest[len(tok):])
		case strings.HasPrefix(tok, "--split-string="):
			rest = splitStringSeparators(rest[len("--split-string="):])
		case strings.HasPrefix(tok, "-S"):
			rest = splitStringSeparators(rest[2:])
		case strings.HasPrefix(tok, "--unset=") || strings.HasPrefix(tok, "--chdir="):
			rest = rest[len(tok):]
		case tok == "-u" || tok == "-C" || tok == "--unset" || tok == "--chdir":
			// Consume the option AND the separate word carrying its value, which can be quoted.
			rest = trimLeftSpace(rest[len(tok):])
			rest = rest[len(envNextToken(rest)):]
		case strings.HasPrefix(tok, "-"):
			rest = rest[len(tok):]
		case isEnvAssignment(tok):
			rest = rest[len(tok):]
		default:
			break loop
		}
	}
	return envDequote(envNextToken(trimLeftSpace(rest)))
}

// splitStringSeparators applies env -S's own separator escape: outside quotes `\_` separates
// arguments exactly as a space does, so `bash\_-e` is the command `bash` with `-e`.
func splitStringSeparators(s string) string {
	var b strings.Builder
	var q byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case q != 0:
			if c == q {
				q = 0
			}
		case c == '\'' || c == '"':
			q = c
		case c == '\\' && i+1 < len(s):
			if s[i+1] == '_' {
				b.WriteByte(' ')
			} else {
				b.WriteString(s[i : i+2])
			}
			i++
			continue
		}
		b.WriteByte(c)
	}
	return b.String()
}

// envNextToken returns the next whitespace-delimited token exactly as written, honouring single
// and double quotes so `LABEL='a b'` stays one token, as env -S splits it. An unterminated quote
// consumes the remainder.
func envNextToken(s string) string {
	var q byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		if q != 0 {
			if c == q {
				q = 0
			}
			continue
		}
		if isSpace(c) {
			return s[:i]
		}
		if c == '\'' || c == '"' {
			q = c
		}
	}
	return s
}

// envDequote strips ONE balanced layer of quotes, so `env -S 'bash' -x` resolves to `bash`.
func envDequote(w string) string {
	if len(w) >= 2 && (w[0] == '\'' || w[0] == '"') && w[len(w)-1] == w[0] {
		return w[1 : len(w)-1]
	}
	return w
}

// isEnvAssignment matches env's NAME=value operand form: a leading letter or underscore and an
// `=` somewhere after it, as the shell glob `[A-Za-z_]*=*` does.
func isEnvAssignment(tok string) bool {
	if tok == "" {
		return false
	}
	c := tok[0]
	if !(c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
		return false
	}
	return strings.Contains(tok[1:], "=")
}

// basename returns the last slash-separated element of a path.
func basename(p string) string {
	return p[strings.LastIndexByte(p, '/')+1:]
}

// isSpace matches the POSIX [[:space:]] class in ASCII.
func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

// isSpaceRune is isSpace for a rune.
func isSpaceRune(r rune) bool { return r < 0x80 && isSpace(byte(r)) }

// trimLeftSpace drops leading [[:space:]] characters.
func trimLeftSpace(s string) string {
	return strings.TrimLeftFunc(s, isSpaceRune)
}
