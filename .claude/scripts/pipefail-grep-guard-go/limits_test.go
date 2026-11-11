package main

import (
	"strings"
	"testing"
)

// The residual the Bash implementation documented as knowingly unfixed: a `#` inside a QUOTED
// string read as a comment introducer, so executable text could carry the line-level escape
// hatch. A parser knows that text is a string, so the pipeline after it is still reported.
var quotedHashFlag = []lineCase{
	{"a quoted '#' ahead of the marker is a string, not a comment that exempts the line",
		[]string{`marker="# pipefail-grep-guard: allow"; producer | grep -q MATCH`}},
	{"a single-quoted '#' ahead of the marker does not exempt the line either",
		[]string{`echo '# pipefail-grep-guard: allow'; producer | grep -q MATCH`}},
	{"a quoted '#' after the pipeline does not exempt it",
		[]string{`producer | grep -q MATCH "# pipefail-grep-guard: allow"`}},
	{"a heredoc payload line spelling the marker does not exempt the pipeline that feeds it",
		[]string{`producer | grep -q MATCH <<EOF`, `# pipefail-grep-guard: allow`, `EOF`}},
}

// Their control: the same marker in a REAL comment on that line still exempts it, so the cases
// above fail only because the text is quoted, not because the hatch stopped working.
var quotedHashClean = []lineCase{
	{"control: the marker in a real comment after quoted text still exempts the line",
		[]string{`marker="# x"; producer | grep -q MATCH # pipefail-grep-guard: allow — fixture`}},
}

// TestQuotedHashResidualClosed pins the closed quoted-# residual and its control.
func TestQuotedHashResidualClosed(t *testing.T) {
	expect(t, quotedHashFlag, 1)
	expect(t, quotedHashClean, 0)
}

// Where the escape hatch must sit. It always required a `#` at line start or after whitespace,
// and it covers the pipeline it ends, not a neighbouring line.
var hatchFlag = []lineCase{
	{"a marker attached to an operator is not the escape hatch",
		[]string{`producer | grep -q MATCH;# pipefail-grep-guard: allow`}},
	{"a marker on the line above the pipeline does not exempt it",
		[]string{`# pipefail-grep-guard: allow`, `producer | grep -q MATCH`}},
	{"a marker after the pipe but before the grep's line does not exempt it",
		[]string{`producer | # pipefail-grep-guard: allow`, `  grep -q MATCH`}},
	{"a marker on the grep's line does not exempt a pipeline that continues past it",
		[]string{`producer | grep -q MATCH | # pipefail-grep-guard: allow`, `  sort`}},
}

// The whole-file directive is a comment line that BEGINS with it; a trailing comment spelling it
// on a code line is not that line.
var hatchFileFlag = []lineCase{
	{"a trailing comment spelling allow-file does not exempt the file",
		[]string{`x=1 # pipefail-grep-guard: allow-file — trailing, not a directive line`, `producer | grep -q MATCH`}},
}

var hatchClean = []lineCase{
	{"a marker on the last line of a continued pipeline exempts it",
		[]string{`producer \`, `  | grep -q MATCH # pipefail-grep-guard: allow — fixture`}},
}

// TestEscapeHatchPlacement pins where the line and file escape hatches must sit.
func TestEscapeHatchPlacement(t *testing.T) {
	expect(t, hatchFlag, 1)
	expect(t, hatchFileFlag, 1)
	expect(t, hatchClean, 0)
}

// Gaps recorded on monorepo#2797 and in the old header, each needing parsing the line layer could
// not do. Each keeps a control.
var gapFlag = []lineCase{
	{"a |& pipe ending the line still continues into the grep",
		[]string{`producer |&`, `  grep -q MATCH`}},
	{"a heredoc opener continued onto the next line: the pipe after the continuation is code",
		[]string{`cat <<PAYLOAD \`, `  | grep -q MATCH`, `payload`, `PAYLOAD`}},
	{"an empty heredoc delimiter ends at the first blank line, and code after it is scanned",
		[]string{`cat <<''`, `payload`, ``, `producer | grep -q MATCH`}},
	{"env -S builds the command from its value, and that command is grep",
		[]string{`producer | env -S 'grep -q MATCH'`}},
	{"an attached env -S value is split too",
		[]string{`producer | env --split-string='LC_ALL=C grep -q MATCH'`}},
	{"an unquoted heredoc body runs its command substitutions",
		[]string{`cat <<EOF`, `$(producer | grep -q MATCH)`, `EOF`}},
	{"a pipeline inside a process substitution still runs",
		[]string{`while read -r x; do :; done < <(producer | grep -q MATCH)`}},
	{"--files is an abbreviation of --files-with-matches",
		[]string{`producer | grep --files MATCH`}},
	{"an early exit spelled with an expansion after it is still that option",
		[]string{`producer | grep -q"$extra" MATCH`}},
	{"a max count only the running shell knows is reported",
		[]string{`producer | grep -m "$n" MATCH`}},
	{"an ANSI-C hex escape spelling the option is still that option",
		[]string{`producer | grep $'\x2d'q MATCH`}},
	{"an ANSI-C octal escape spelling the option is still that option",
		[]string{`producer | grep $'\055q' MATCH`}},
	{"an ANSI-C escape spelling the command name is still grep",
		[]string{`producer | $'\x67rep' -q MATCH`}},
}

var gapClean = []lineCase{
	{"a payload line of a continued heredoc opener is data",
		[]string{`cat <<PAYLOAD \`, `  > /dev/null`, `producer | grep -q MATCH`, `PAYLOAD`}},
	{"an empty heredoc delimiter's body is data",
		[]string{`cat <<''`, `producer | grep -q MATCH`, ``}},
	{"command -v only inspects grep; it never runs it",
		[]string{`printf x | command -v grep -q`}},
	{"env -S naming a command that is not grep is not grep",
		[]string{`producer | env -S 'sort -m'`}},
	{"a quoted heredoc body is data even when it spells a substitution",
		[]string{`cat <<'EOF'`, `$(producer | grep -q MATCH)`, `EOF`}},
	{"--file is the exact --file option, not an abbreviation of --files-with-matches",
		[]string{`producer | grep --file patterns.txt`}},
	{"a command word only the running shell knows is not claimed to be grep",
		[]string{`producer | "$GREP" -q MATCH`}},
}

// TestRecordedGaps covers the gaps recorded on monorepo#2797, each with a control.
func TestRecordedGaps(t *testing.T) {
	expect(t, gapFlag, 1)
	expect(t, gapClean, 0)
}

// A file the parser cannot read is reported, never passed. Two shapes reach it: a real syntax
// error, and the one former KNOWN LIMIT whose exit status does not move. Bash dequotes the
// delimiter `<<"E\"OF"` to E"OF; mvdan.cc/sh rejects that spelling, so the file is reported as
// unparsable (exit 1, as before) instead of passing — fail-closed, and named in the output.
func TestUnparsableFilesAreReported(t *testing.T) {
	for _, c := range []lineCase{
		{"an unparsable delimiter masks nothing rather than guessing", []string{`cat <<E"OF`, `producer | grep -q MATCH`, `EOF`}},
		{"KNOWN LIMIT: an escaped quote inside a delimiter word is not dequoted", []string{`cat <<"E\"OF"`, `producer | grep -q MATCH`, `E"OF`}},
		{"a syntax error is reported even in a file carrying the allow-file directive", []string{`# pipefail-grep-guard: allow-file — x`, `if then fi (`}},
	} {
		t.Run(c.name, func(t *testing.T) {
			rc, out := guard(mkscript(t, "fixture.sh", c.lines...))
			if rc != 1 || !strings.Contains(out, "cannot be parsed as shell") || !strings.Contains(out, "could not be parsed") {
				t.Fatalf("rc=%d\n%s", rc, out)
			}
		})
	}
}
