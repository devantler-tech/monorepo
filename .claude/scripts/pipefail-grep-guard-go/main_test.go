package main

// The cases below are the former shell suite (pipefail-grep-guard.test.sh), ported one for one
// and under the same names. Each "must flag" case has a control that differs in the one character
// that matters, so a control passing for the wrong reason shows up as its twin passing too.
//
// The former suite pinned ten KNOWN LIMITS at the Bash implementation's behaviour, saying the
// expectation should be inverted once a real parser replaced the layer. Nine are inverted here
// under their old names prefixed "inverted"; the escaped-delimiter one keeps its exit status for a
// different, stated reason (TestUnparsableFilesAreReported).

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// mkscript writes the lines as a bash script under errexit and pipefail and returns its path.
func mkscript(t *testing.T, name string, lines ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	body := "#!/usr/bin/env bash\nset -Eeuo pipefail\n" + strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// guard runs the command line as the entrypoint would, with stdout and stderr interleaved.
func guard(args ...string) (int, string) {
	var out bytes.Buffer
	rc := run(args, &out, &out)
	return rc, out.String()
}

type lineCase struct {
	name  string
	lines []string
}

func one(name, line string) lineCase { return lineCase{name, []string{line}} }

func expect(t *testing.T, cases []lineCase, want int) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rc, out := guard(mkscript(t, "fixture.sh", c.lines...))
			if rc != want {
				t.Fatalf("rc=%d, want %d\n%s", rc, want, out)
			}
		})
	}
}

// 2a. Must FLAG — each early-exit spelling.
var flagCases = []lineCase{
	one("printf into grep -q", `printf "%s" "$v" | grep -q NEEDLE`),
	one("grep -qF", `printf "%s" "$v" | grep -qF NEEDLE`),
	one("grep -Fq (letters the other way round)", `printf "%s" "$v" | grep -Fq NEEDLE`),
	one("grep -qE", `printf "%s" "$v" | grep -qE "NEE(DLE)"`),
	one("long option --quiet", `printf "%s" "$v" | grep --quiet NEEDLE`),
	one("long option --silent", `printf "%s" "$v" | grep --silent NEEDLE`),
	one("grep -l (also stops at the first match)", `find . -type f | xargs grep -l NEEDLE | grep -l NEEDLE`),
	one("grep -m1 (also stops at the first match)", `printf "%s" "$v" | grep -m1 NEEDLE`),
	one("grep --max-count=1", `printf "%s" "$v" | grep --max-count=1 NEEDLE`),
	one("egrep -q", `printf "%s" "$v" | egrep -q NEEDLE`),
	one("an env-var prefix before grep", `printf "%s" "$v" | LC_ALL=C grep -q NEEDLE`),
	one("a |& pipe carrying stderr too", `build_it |& grep -q NEEDLE`),
	one("a negated pipeline (the fail-OPEN direction)", `if ! printf "%s" "$v" | grep -q NEEDLE; then echo bad; fi`),
	one("the second pipeline on one line", `printf "%s" "$a" | grep -c NEEDLE && printf "%s" "$b" | grep -q NEEDLE`),
	// grep reached through a wrapper or an absolute path: the spellings that escape a harness shim.
	one("command grep (the spelling this guard's own docs recommend)", `printf "%s" "$v" | command grep -q NEEDLE`),
	one("env grep", `printf "%s" "$v" | env grep -q NEEDLE`),
	one("an absolute path to grep", `printf "%s" "$v" | /usr/bin/grep -q NEEDLE`),
	one("a wrapper AND an env-var prefix together", `printf "%s" "$v" | LC_ALL=C command grep -q NEEDLE`),
	// Options whose value is the FOLLOWING word must consume it, or a later flag is never seen.
	one("-e PATTERN before -q", `printf "%s" "$v" | grep -e PATTERN -q`),
	one("--regexp PATTERN before -q", `printf "%s" "$v" | grep --regexp PATTERN -q`),
	one("-f FILE before -q", `printf "%s" "$v" | grep -f patterns.txt -q`),
	one("a cluster ending in -e before -q", `printf "%s" "$v" | grep -ie PATTERN -q`),
	one("env with an option before grep", `printf "%s" "$v" | env -i grep -q NEEDLE`),
	one("command with an option before grep", `printf "%s" "$v" | command -p grep -q NEEDLE`),
	// GNU grep permutes options after operands to the front: an early exit on the Linux runner.
	one("an option AFTER the pattern operand (GNU permutes it)", `printf "%s" "$v" | grep PATTERN -q`),
	one("an option after the operand, clustered", `printf "%s" "$v" | grep PATTERN file -ql`),
	one("an infinite max-count overridden by a later finite one", `printf "%s" "$v" | grep -m-1 -m1 MATCH`),
	one("a finite max-count still fires when nothing overrides it", `printf "%s" "$v" | grep -m1 MATCH`),
	one("a leading zero does not make a finite count zero", `printf "%s" "$v" | grep -m01 MATCH`),
	one("a finite max-count before a shell separator", `printf "%s" "$v" | grep -m1 MATCH; true`),
	// 2f. Bash removes the quotes, so grep receives the ordinary option.
	one("a QUOTED early-exit option is still that option", `printf "%s" "$v" | grep "-q" NEEDLE`),
	one("a single-quoted early-exit option too", `printf "%s" "$v" | grep '-q' NEEDLE`),
	one("a quoted separator as the whole pattern does not end the command", `printf "%s" "$v" | grep ';' -q`),
	one("...but an early exit BEFORE that separator is still reported", `printf "%s" "$v" | grep -q MATCH; sort -m /dev/null`),
	one("a semicolon inside the pattern does not end the command", `printf "%s" "$v" | grep "a;b" -q`),
	one("...but a real early exit carrying a trailing comment still flags", `printf "%s" "$v" | grep -q MATCH # intentional`),
	one("a hash inside the pattern does not start a comment", `printf "%s" "$v" | grep "#p" -q`),
	one("a backslash-escaped early-exit option is still that option", `printf "%s" "$v" | grep \-q NEEDLE`),
	one("a pipeline inside a double-quoted command substitution still runs", `out="$({ printf "MATCH\n"; head -c 200000 /dev/zero; } | grep -q MATCH)"`),
	one("a $( inside double quotes is a substitution and does run", `printf "%s\n" "$(producer | grep -q MATCH)"`),
	one("a real pipeline carrying a trailing comment still flags", `printf "%s" "$v" | grep -q MATCH # intentional`),
	one("an EMPTY assignment prefix still reaches the grep", `producer | LC_ALL= grep -q MATCH`),
	one("an abbreviated --quiet is still --quiet", `producer | grep --quie MATCH`),
	one("an abbreviated --silent too", `producer | grep --sil MATCH`),
	one("an abbreviated --max-count with a finite value", `producer | grep --max-c=1 MATCH`),
	one("a real -q behind a consumed --regexp value is still found", `producer | grep --regexp PAT -q MATCH`),
	one("an attached --regexp= value consumes nothing extra", `producer | grep --regexp=PAT -q MATCH`),
	one("an assignment prefix proper still reaches the grep", `producer | WRAPPED=1 grep -q MATCH`),
	one("a hash inside a parameter expansion does not truncate the line", `x=${v:-|#foo}; producer | grep -q MATCH`),
}

// 2b. Must NOT flag.
var cleanCases = []lineCase{
	one("a here-string (the prescribed fix)", `grep -q NEEDLE <<<"$v"`),
	one("process substitution (the prescribed fix for a command)", `grep -q NEEDLE < <(printf "%s" "$v")`),
	one("reading a file (the prescribed fix for a file)", `grep -q NEEDLE "$file"`),
	one("a logical OR, not a pipe", `cached "$1" || grep -qF -- "$1" "$keepfile"`),
	one("a logical OR with spaces around it", `test -n "$v" || grep -q NEEDLE "$f"`),
	one("grep -c reads to the end", `printf "%s" "$v" | grep -c NEEDLE`),
	one("grep -L must read to the end to prove absence", `printf "%s" "$v" | grep -L NEEDLE`),
	one("a plain grep reads to the end", `printf "%s" "$v" | grep NEEDLE`),
	one("a pattern that merely contains -q", `printf "%s" "$v" | grep -F -- "-q is not a flag here"`),
	one("an arithmetic -eq after the pipeline", `if [ "$(printf "%s" "$v" | grep -Fc NEEDLE)" -eq 2 ]; then echo ok; fi`),
	one("a whole-line comment describing the bug", `# Here-string, not printf | grep -q: grep -q exits at the first match.`),
	one("an indented whole-line comment describing the bug", `    # was: printf "%s" "$out" | grep -q PAT`),
	one("-eq is -e with the pattern q, not an early exit", `printf "%s" "$v" | grep -eq PAT`),
	one("a wrapper in front of a grep that reads to the end", `printf "%s" "$v" | command grep -c NEEDLE`),
	one("a path-qualified name that merely ENDS in grep", `printf "%s" "$v" | /opt/bin/notgrep -q NEEDLE`),
	one("-m-1 is infinity, not an early exit", `printf "%s" "$v" | grep -m-1 PATTERN`),
	one("--max-count=-1 is infinity", `printf "%s" "$v" | grep --max-count=-1 PATTERN`),
	one("--max-count -1 as a separate word", `printf "%s" "$v" | grep --max-count -1 PATTERN`),
	one("a finite max-count overridden by a later infinite one", `printf "%s" "$v" | grep -m1 -m-1 MATCH`),
	one("an infinite max-count overridden in the long spelling", `printf "%s" "$v" | grep --max-count=1 --max-count=-1 MATCH`),
	one("a separate-word infinite override", `printf "%s" "$v" | grep -m 1 -m -1 MATCH`),
	one("a zero max-count cannot stop at a match", `printf "%s" "$v" | grep -m0 MATCH`),
	one("a zero max-count in the long spelling", `printf "%s" "$v" | grep --max-count=0 MATCH`),
	one("zero written with padding is still zero", `printf "%s" "$v" | grep -m00 MATCH`),
	one("a quoted -q consumed by -e is a pattern, not a flag", `printf "%s" "$v" | grep -e "-q" "$file"`),
	one("an attached semicolon ends the command before the next one's flags", `printf "%s" "$v" | grep MATCH; sort -m /dev/null`),
	one("an attached && does the same", `printf "%s" "$v" | grep MATCH&& sort -m /dev/null`),
	one("an attached pipe ends it too, like its ; twin", `printf "%s" "$v" | grep MATCH| sort -q x`),
	one("a trailing comment mentioning -q is not an option", `printf "%s" "$v" | grep MATCH # do not replace this with -q`),
	one("a quoted pipeline is text the script prints, not a pipeline it runs", `printf '%s\n' 'producer | grep -q MATCH'`),
	one("the same text as a plain quoted string is not a pipeline", `printf '%s\n' 'out=| grep -q MATCH'`),
	one("a $( inside single quotes is literal, not a substitution", `printf '%s\n' 'example: $(producer | grep -q MATCH)'`),
	one("pipeline-shaped prose in a trailing comment is not a pipeline", `printf 'ok\n' # producer | grep -q MATCH`),
	one("an abbreviated --max-count of -1 is still infinity", `producer | grep --max-c=-1 MATCH`),
	one("an unrelated long option is not an abbreviation of an early exit", `producer | grep --invert-match MATCH`),
	one("an abbreviated --regexp consumes the following word as its value", `producer | grep --reg -q MATCH`),
	one("a stream-consuming wrapper is not an assignment prefix", `producer | xargs grep -q MATCH`),
	one("a genuine trailing comment still ends the code", `x=1 # producer | grep -q MATCH`),
	one("'&& sort -m' is a separate command, not grep's early exit", `printf "MATCH\n" | grep MATCH && sort -m /dev/null`),
}

func TestFlags(t *testing.T) { expect(t, flagCases, 1) }

func TestClean(t *testing.T) { expect(t, cleanCases, 0) }

// 2c, 2f, 2g. Multi-line structure: continuations, comments, heredocs, strings and directives.
var multiLineFlag = []lineCase{
	{"a pipeline whose pipe ends the line and grep starts the next", []string{`printf "%s" "$v" |`, `  grep -q NEEDLE`}},
	{"a comment line between the pipe and the grep", []string{`printf "%s" "$v" |`, `  # explaining what the next line does`, `  grep -q NEEDLE`}},
	{"a trailing comment after the pipe does not end the pipeline", []string{`printf "%s" "$v" | # note`, `  grep -q NEEDLE`}},
	{"a trailing comment ending in a backslash still continues the pipe", []string{`printf "%s" "$v" | # rationale \`, `  grep -q NEEDLE`}},
	{"a file that only MENTIONS allow-file is still scanned", []string{`# The pipefail-grep-guard: allow-file directive is described here in prose.`, `MARKER="pipefail-grep-guard: allow-file"`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"negative control: the same line WITHOUT the marker still flags", []string{`printf "%s" "$v" | grep -q NEEDLE # ordinary comment, no marker`}},
	{"the marker in EXECUTABLE text does not suppress the finding", []string{`marker="pipefail-grep-guard: allow"; printf "%s" "$v" | grep -q NEEDLE`}},
	{"a '#' inside a parameter expansion is not a comment introducer", []string{`x="${v#pipefail-grep-guard: allow}"; printf "%s" "$x" | grep -q NEEDLE`}},
	{"a double-quoted assignment value with whitespace does not hide the grep", []string{`printf "%s" "$v" | LC_ALL="C UTF-8" grep -q NEEDLE`}},
	{"a single-quoted assignment value with whitespace does not hide the grep", []string{`printf '%s' "$v" | LC_ALL='C UTF-8' grep -q NEEDLE`}},
	{"a mixed quoted/unquoted assignment value does not hide the grep", []string{`printf "%s" "$v" | LC_ALL=C" UTF-8" grep -q NEEDLE`}},
	{"a command substitution in an assignment value does not hide the grep", []string{`printf '%s' "$v" | A=$(printf 'C UTF-8') grep -q NEEDLE`}},
	{"a backtick substitution in an assignment value does not hide the grep", []string{"printf \"%s\" \"$v\" | A=`printf \"C UTF-8\"` grep -q NEEDLE"}},
	{"a parameter expansion in an assignment value does not hide the grep", []string{`printf "%s" "$v" | A=${x-a b} grep -q NEEDLE`}},
	{"an arithmetic expansion with NO whitespace does not hide the grep", []string{`printf '%s' "$v" | A=$((1+2)) grep -q NEEDLE`}},
	{"an escaped double quote inside a quoted assignment value does not hide the grep", []string{`printf "%s" "$v" | A="x\" y" grep -q NEEDLE`}},
	{"an ANSI-C quoted assignment value does not hide the grep", []string{`printf '%s' "$v" | A=$'x\' y' grep -q NEEDLE`}},
	{"a literal backslash inside a single-quoted assignment value still reaches the grep", []string{`printf '%s' "$v" | B='x\" y' grep -q NEEDLE`}},
	{"an escaped space in an assignment value does not hide the grep", []string{`printf "%s" "$v" | LC_ALL=C\ UTF-8 grep -q NEEDLE`}},
	{"two assignment prefixes, the second quoted, still reach the grep", []string{`printf "%s" "$v" | A=1 B="x y" grep -q NEEDLE`}},
	{"a value-consuming wrapper option (env -u NAME) does not hide the grep", []string{`producer | env -u UNUSED grep -q MATCH`}},
	{"a whole-line comment ending in backslash does not swallow the next line", []string{`# ordinary comment \`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"nine comment lines between the pipe and the grep do not hide it", []string{`producer |`, `# c1`, `# c2`, `# c3`, `# c4`, `# c5`, `# c6`, `# c7`, `# c8`, `# c9`, `  grep -q MATCH`}},
	{"an allow-file directive inside a heredoc body does not exempt the file", []string{`cat <<EOF`, `# pipefail-grep-guard: allow-file — documentation only`, `EOF`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"an unterminated <<word is not a heredoc, so the code after it is still scanned", []string{`width=$(( total << bits ))`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"a quoted <<WORD is text, not a heredoc operator", []string{`EOF() { :; }`, `printf '%s\n' '<<EOF'`, `printf "%s" "$v" | grep -q NEEDLE`, `EOF`}},
	{"a <<WORD inside a comment is not a heredoc operator either", []string{`# see <<EOF for details`, `printf "%s" "$v" | grep -q NEEDLE`, `EOF`}},
	{"an escaped quote does not end a double-quoted run", []string{`printf "%s\n" "text\" <<EOF"`, `printf "%s" "$v" | grep -q NEEDLE`, `EOF`}},
	{"an allow-file line in the second payload does not exempt the file", []string{`cat <<FIRST <<SECOND`, `first payload`, `FIRST`, `# pipefail-grep-guard: allow-file — payload, not a directive`, `SECOND`, `printf "%s" "$v" | grep -q REAL`}},
	{"code after a closed heredoc is still scanned", []string{`cat <<DOC`, `just text`, `DOC`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"a punctuation heredoc delimiter still hides its payload from the directive", []string{`cat <<'---'`, `# pipefail-grep-guard: allow-file — payload, not a directive`, `---`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"a here-string opens no heredoc, so the code below it is still scanned", []string{`grep -q NEEDLE <<<"EOF"`, `printf "%s" "$v" | grep -q NEEDLE`, `EOF`}},
	{"an unquoted punctuation delimiter still hides its payload from the directive", []string{`cat <<+++`, `# pipefail-grep-guard: allow-file — payload, not a directive`, `+++`, `printf "%s" "$v" | grep -q REAL`}},
	{"a space-indented line does not terminate a plain heredoc", []string{`cat <<EOF`, `  EOF`, `# pipefail-grep-guard: allow-file — payload, not a directive`, `EOF`, `printf "%s" "$v" | grep -q REAL`}},
	{"positive control: <<- accepts a tab-indented terminator", []string{`cat <<-EOF`, `payload`, "\tEOF", `printf "%s" "$v" | grep -q REAL`}},
	{"a comment attached to the pipe does not stop the join", []string{`producer |# note`, `  grep -q MATCH`}},
	{"a comment opened straight after ';' is not a heredoc operator", []string{`:;# <<EOF`, `printf "%s" "$v" | grep -q NEEDLE`, `EOF`}},
	{"a comment opened straight after '&' is not a heredoc operator", []string{`:&# <<EOF`, `printf "%s" "$v" | grep -q NEEDLE`, `EOF`}},
	{"a comment opened straight after '|' is not a heredoc operator", []string{`:|# <<EOF`, `printf "%s" "$v" | grep -q NEEDLE`, `EOF`}},
	{"an unparsable delimiter masks nothing rather than guessing", []string{`cat <<E"OF`, `producer | grep -q MATCH`, `EOF`}},
	{"a delimiter with trailing whitespace does not terminate a heredoc", []string{`cat <<EOF`, `EOF `, `# pipefail-grep-guard: allow-file — payload, not a directive`, `EOF`, `printf "%s" "$v" | grep -q REAL`}},
	{"an allow-file marker inside a multi-line string is not a directive", []string{`doc="first line`, `# pipefail-grep-guard: allow-file — payload, not a directive`, `last line"`, `producer | grep -q MATCH`}},
	{"a line starting with a backslash does not abort the walk", []string{`\ls /tmp`, `printf "%s" "$v" | grep -q NEEDLE`}},
}

var multiLineClean = []lineCase{
	{"a comment above a grep with no preceding pipe stays clean", []string{`printf "%s" "$v" > /tmp/x`, `  # an unrelated comment`, `  grep -q NEEDLE /tmp/x`}},
	{"the real allow-file directive still exempts the whole file", []string{`# pipefail-grep-guard: allow-file — this fixture is about the offending form`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"a trailing '||' joined to a grep on the next line is still not a pipe", []string{`cached "$1" ||`, `  grep -q NEEDLE "$f"`}},
	{"the escape hatch suppresses a line that must keep the offending text", []string{`printf "%s" "$v" | grep -q NEEDLE # pipefail-grep-guard: allow — fixture text`}},
	{"positive control: a real allow-file comment still exempts a file with a heredoc", []string{`# pipefail-grep-guard: allow-file — this fixture is about the offending form`, `cat <<EOF`, `payload`, `EOF`, `printf "%s" "$v" | grep -q NEEDLE`}},
	{"a heredoc payload is data, not a pipeline that runs", []string{`cat <<DOC`, `producer | grep -q MATCH`, `DOC`}},
	{"a backslash inside single quotes is literal, so the quote still closes", []string{`cat 'text\' <<EOF`, `x | grep -q MATCH`, `EOF`}},
	{"positive control: an unquoted operator still hides its body", []string{`cat <<'EOF'`, `x | grep -q MATCH`, `EOF`}},
	{"the SECOND heredoc's payload is data too", []string{`cat <<FIRST <<SECOND`, `first payload`, `FIRST`, `producer | grep -q MATCH`, `SECOND`, `echo done`}},
	{"a heredoc opened on a joined continuation line still hides its body", []string{`producer |`, `  cat <<'DOC'`, `x | grep -q MATCH`, `DOC`, `echo done`}},
	{"the join does not pull a heredoc body into a live probe", []string{`cat <<'DOC' |`, `x | grep -q MATCH`, `DOC`, `echo done`}},
	{"positive control: a ${v#pat} expansion still leaves the heredoc detectable", []string{`x=${v#pat}`, `cat <<EOF`, `y | grep -q Z`, `EOF`}},
	{`the delimiter <<E"OF" names EOF after quote removal`, []string{`cat <<E"OF"`, `producer | grep -q MATCH`, `EOF`}},
	{`the delimiter <<E'OF' names EOF after quote removal`, []string{`cat <<E'OF'`, `producer | grep -q MATCH`, `EOF`}},
	{`the delimiter <<\EOF names EOF after quote removal`, []string{`cat <<\EOF`, `producer | grep -q MATCH`, `EOF`}},
	{"an allow-file marker after the string closes is still honoured", []string{`doc="first line`, `last line"`, `# pipefail-grep-guard: allow-file — a genuine directive`, `producer | grep -q MATCH`}},
	{"an apostrophe in a comment does not leak an open quote", []string{`x=1 # it does not open a quote`, `# pipefail-grep-guard: allow-file — still a directive`, `producer | grep -q MATCH`}},
}

func TestMultiLineFlags(t *testing.T) { expect(t, multiLineFlag, 1) }

func TestMultiLineClean(t *testing.T) { expect(t, multiLineClean, 0) }

// The former KNOWN LIMITS, under their old names with the expectation INVERTED. The Bash layer
// could not tell a delimiter from a character that looks like one, read arithmetic as code and
// masked quoted command words; a parser can. Each was pinned at the old behaviour so that a real
// parser replacing the layer would invert it, which is this.
var formerLimitsFlag = []lineCase{
	{"inverted — KNOWN LIMIT: a NESTED command substitution is not detected", []string{`printf '%s' "$v" | A=$(echo $(printf 'C UTF-8')) grep -q NEEDLE`}},
	{"inverted — KNOWN LIMIT: an UNNESTED substitution containing a quoted ')' is not detected either", []string{`printf '%s' "$v" | A=$(printf ') ') grep -q NEEDLE`}},
	{"inverted — KNOWN LIMIT: a quoted OPENING '(' inside a substitution is not detected either", []string{`printf '%s' "$v" | A=$(printf '(') grep -q NEEDLE`}},
	{"inverted — KNOWN LIMIT: an arithmetic expansion containing whitespace is not detected", []string{`printf '%s' "$v" | A=$((1 + 2)) grep -q NEEDLE`}},
	{"inverted — KNOWN LIMIT: a spaced arithmetic shift can look like a heredoc opener", []string{`width=$(( total << bits ))`, `producer | grep -q MATCH`, `bits`}},
	{"inverted — KNOWN LIMIT: a grouping ')' inside a substitution ends it early", []string{`out="$( (:) ; producer | grep -q MATCH )"`}},
	{"inverted — KNOWN LIMIT: a quoted command word is erased by masking", []string{`producer | "grep" -q MATCH`}},
	{"inverted — KNOWN LIMIT: a backtick substitution inside double quotes is masked as data", []string{"out=\"`producer | grep -q MATCH`\""}},
}

var formerLimitsClean = []lineCase{
	// The one former limit in the false-POSITIVE direction: `|` inside $(( )) is bitwise OR.
	{"inverted — KNOWN LIMIT: arithmetic bitwise-OR can read as a pipeline", []string{`value=$(( a | grep -q ))`}},
}

func TestFormerKnownLimits(t *testing.T) {
	expect(t, formerLimitsFlag, 1)
	expect(t, formerLimitsClean, 0)
}

// A pipeline continued with a trailing backslash: flagged once, at the line it starts on.
func TestContinuationReportedOnce(t *testing.T) {
	f := mkscript(t, "cont-backslash.sh", `if commands_in "$f" 2>/dev/null \`, `   | grep -qE "NEEDLE"; then echo hit; fi`)
	rc, out := guard(f)
	if rc != 1 {
		t.Fatalf("flags: a pipeline continued with a trailing backslash: rc=%d\n%s", rc, out)
	}
	if n := strings.Count(out, "stops at the first match"); n != 1 {
		t.Errorf("flags: that pipeline is reported ONCE, not once per line it spans: %d\n%s", n, out)
	}
	if !strings.Contains(out, ":3: ") {
		t.Errorf("flags: it is reported at the line the pipeline STARTS on\n%s", out)
	}
}

// 2d. Multiple findings, multiple files, and the exit contract.
func TestExitContract(t *testing.T) {
	f1 := mkscript(t, "multi-a.sh", `printf "%s" "$v" | grep -q A`, `printf "%s" "$v" | grep -q B`)
	f2 := mkscript(t, "multi-b.sh", `printf "%s" "$v" | grep -q C`)
	if _, out := guard(f1, f2); strings.Count(out, "stops at the first match") != 3 {
		t.Errorf("reports every offending line across every named file\n%s", out)
	}
	rc, out := guard(mkscript(t, "all-clean.sh", `grep -q NEEDLE <<<"$v"`, `echo done`))
	if rc != 0 {
		t.Errorf("a clean file exits 0 and says so: rc=%d", rc)
	}
	if !strings.Contains(out, "no writer piped into an early-exiting grep") {
		t.Errorf("the clean message names what was checked\n%s", out)
	}
	if rc, out := guard(filepath.Join(t.TempDir(), "does-not-exist.sh")); rc != 2 {
		t.Errorf("an unreadable path is a usage error (exit 2), not a silent pass: rc=%d\n%s", rc, out)
	}
	empty := filepath.Join(t.TempDir(), "empty.sh")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if rc, out := guard(empty); rc != 0 {
		t.Errorf("an empty file scans clean instead of aborting the sweep: rc=%d\n%s", rc, out)
	}
	if rc, out := guard("--help"); rc != 2 || !strings.Contains(out, "USAGE") {
		t.Errorf("--help prints the usage and exits 2: rc=%d\n%s", rc, out)
	}
	hang := filepath.Join(t.TempDir(), "hang.sh")
	if err := os.Symlink("/dev/zero", hang); err == nil {
		if rc, out := guard(hang); rc != 2 {
			t.Errorf("a non-regular tracked script is a controlled error, not a hang: rc=%d\n%s", rc, out)
		}
	}
}

// 2e. The finding must carry the fix, not just the complaint.
func TestMessage(t *testing.T) {
	_, out := guard(mkscript(t, "message.sh", `printf "%s" "$v" | grep -q NEEDLE`))
	for name, want := range map[string]string{
		"the finding names the offending flag":                              "grep -q stops at the first match",
		"the finding tells the reader what to write instead":                "fix: feed grep without a pipe",
		"the fix line offers the form that keeps the producer's status":     `out="$(cmd)" then <<<"$out"`,
		"the fix line warns that process substitution discards that status": "DISCARDS the producer status",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("%s\n%s", name, out)
		}
	}
	_, out = guard(mkscript(t, "lead-backslash.sh", `\ls /tmp`, `printf "%s" "$v" | grep -q NEEDLE`))
	if !strings.Contains(out, "grep -q NEEDLE") {
		t.Errorf("and the offending pipeline is still reported\n%s", out)
	}
}

// Both offenders on one line are reported and numbered; a lone one is not numbered.
func TestPairsOnOneLine(t *testing.T) {
	_, out := guard(mkscript(t, "two-on-one-line.sh", `printf A | grep -q A && printf B | grep -q B`))
	if n := strings.Count(out, "stops at the first match"); n != 2 {
		t.Errorf("both offenders on one logical line are reported, not just the first: %d\n%s", n, out)
	}
	if n := len(regexp.MustCompile(`\[[12] of 2 on this line\]`).FindAllString(out, -1)); n != 2 {
		t.Errorf("a pair on one line is numbered, so the two blocks are distinguishable\n%s", out)
	}
	_, out = guard(mkscript(t, "single-offender.sh", `printf "%s" "$v" | grep -q A`))
	if strings.Contains(out, "on this line") {
		t.Errorf("a single offender carries no of-N counter\n%s", out)
	}
}

// Splitting argv must not do pathname expansion, or the verdict depends on the caller's cwd: run
// from a directory holding a file whose NAME contains a separator.
func TestGlobNotExpanded(t *testing.T) {
	f := mkscript(t, "glob-in-argv.sh", `printf "%s" "$v" | grep *.txt -q`)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a;b.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	if rc, out := guard(f); rc != 1 {
		t.Errorf("a glob in grep's arguments is not expanded against the caller's cwd: rc=%d\n%s", rc, out)
	}
}
