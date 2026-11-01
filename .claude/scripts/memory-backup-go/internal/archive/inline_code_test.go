package archive

import (
	"os"
	"strings"
	"testing"
)

func TestSplitAcceptsSameLineInlineCodeAndConservesBytes(t *testing.T) {
	for _, c := range []struct{ name, line string }{
		{"placeholders", "`<pin>` and `<sha>`"},
		{"longer delimiters", "``<pin> ` <sha>``"},
		{"triple inline", "use ```<pre> <!-- -->``` here"},
		{"comment opening", "`<!--`"},
		{"comment closing", "`-->`"},
		{"separate spans", "before `<pre>` between `<!-- -->` after"},
		{"unmatched run before a span", "`` unmatched `<pre>`"},
		{"literal backslash inside", "`<pre>\\`"},
		{"escaped backslash before opening", "\\\\`<pre>`"},
		{"escaped first tick of longer run", "\\``<pre>`"},
		{"new paragraph resets unmatched code", "`before\n\nnew `<pin>`"},
		{"heading resets unmatched code", "`before\n#### Nested\n`<pin>`"},
		{"fence resets unmatched code", "`before\n```text\n<pre>\n```\n`<pin>`"},
		{"escaped prior opening", "\\`before\nclose`<pre>`after"},
		{"heading does not export unmatched ticks", "#### Nested `literal\n`<pin>`"},
		{"ASCII blank line resets ambiguity", "`before\n \t \nclose`<pre>`after"},
		{"URI autolink text inside code", "``<https://example.com/`><pre>``"},
		{"email autolink text inside code", "``<foo`@example.com><pre>``"},
		{"different inner run", "`<pre> `` <!-- -->`"},
	} {
		t.Run(c.name, func(t *testing.T) {
			movedWant := "### Old\r\n" + c.line + "\r\n"
			keepWant := "# Store\r\n### Current\r\nkeep"
			source := "# Store\r\n" + movedWant + "### Current\r\nkeep"
			keep, moved, err := Split([]byte(source), "^### Old$")
			if err != nil || string(keep) != keepWant || string(moved) != movedWant {
				t.Fatalf("wrong inline-code archive: keep=%q moved=%q err=%v", keep, moved, err)
			}
			if err := Verify([]byte(source), keep, moved); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSplitStillRefusesHTMLOutsideInlineCode(t *testing.T) {
	for _, c := range []struct{ name, line, diagnostic string }{
		{"bare tag", "<pre>", "raw HTML"},
		{"unclosed span", "`<pre>", "raw HTML"},
		{"unequal delimiters", "``<pre>`", "raw HTML"},
		{"tag after code", "`<pin>` <pre>", "raw HTML"},
		{"comment after code", "`<pin>` <!-- hidden -->", "HTML comments"},
		{"unclosed comment after code", "`<pin>` <!--", "HTML comments"},
		{"escaped opening", "\\`<pre>`", "raw HTML"},
		{"three escapes before opening", "\\\\\\`<pre>`", "raw HTML"},
		{"multiline span remains unsupported", "`<pre>\r\ntext`", "raw HTML"},
		{"literal backslash does not escape closing", "`ok\\`<pre>`", "raw HTML"},
		{"cross-line close before tag", "`before\nclose`<pre>`after", "raw HTML"},
		{"cross-line close before comment", "`before\nclose`<!-- hidden -->`after", "HTML comments"},
		{"cross-line long delimiter before tag", "``before\nclose``<pre>``after", "raw HTML"},
		{"cross-line close before comment delimiter", "`before\nclose`-->`after", "HTML comments"},
		{"NBSP does not end a paragraph", "`before\n\u00a0\nclose`<pre>`after", "raw HTML"},
		{"form feed does not end a paragraph", "`before\n\f\nclose`<pre>`after", "raw HTML"},
		{"vertical tab does not end a paragraph", "`before\n\u000b\nclose`<pre>`after", "raw HTML"},
		{"URI autolink tick before tag", "<https://example.com/`><pre>`", "raw HTML"},
		{"URI autolink tick before comment", "<https://example.com/`><!-- hidden -->`", "HTML comments"},
		{"email autolink tick before tag", "<foo`@example.com><pre>`", "raw HTML"},
		{"email autolink tick before comment", "<foo`@example.com><!-- hidden -->`", "HTML comments"},
		{"multiline trimmed final newline", "` <pre>\n`", "raw HTML"},
		{"multiline trimmed first newline", "`\n<pre> `", "raw HTML"},
		{"ticks in raw HTML attributes", "<pre data-x=\"`\">`", "raw HTML"},
	} {
		t.Run(c.name, func(t *testing.T) {
			source := "# Store\n### Old\n" + c.line + "\n### Current\nkeep\n"
			_, _, err := Split([]byte(source), "^### Old$")
			if err == nil || !strings.Contains(err.Error(), c.diagnostic) {
				t.Fatalf("unsafe structure or wrong refusal: %v", err)
			}
		})
	}
}

func TestArchiveInlinePlaceholdersThroughRealBackupAndRewrite(t *testing.T) {
	opt, _ := archiveFixture(t)
	original := []byte("# Store\r\n### Old\r\nUse `<pin>` and ``<sha> ` literal``.\r\n### Current\r\nkeep")
	if err := os.WriteFile(opt.Source, original, 0600); err != nil {
		t.Fatal(err)
	}
	result, err := Run(opt)
	if err != nil {
		t.Fatal(err)
	}
	assertBytes(t, opt.Source, []byte("# Store\r\n### Current\r\nkeep"))
	assertBytes(t, opt.Destination, []byte("### Old\r\nUse `<pin>` and ``<sha> ` literal``.\r\n"))
	assertBytes(t, result.Backup, original)
}
