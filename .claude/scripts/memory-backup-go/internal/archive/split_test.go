package archive

import (
	"errors"
	"strings"
	"testing"
)

func TestSplitPreservesSectionOwnershipAndBytes(t *testing.T) {
	for _, c := range []struct{ name, source, selector, keep, moved string }{
		{"nested prose", "# Store\nintro\n### t1\nfirst\n#### Addendum\nuntitled prose\n### t2\nsecond\n", "^### t1$", "# Store\nintro\n### t2\nsecond\n", "### t1\nfirst\n#### Addendum\nuntitled prose\n"},
		{"shallower boundary", "# Store\n### t1\nbody\n## Next\nkept\n", "^### t1$", "# Store\n## Next\nkept\n", "### t1\nbody\n"},
		{"CRLF and EOF", "# Store\r\n### t1\r\nsame\r\nsame", "^### t1$", "# Store\r\n", "### t1\r\nsame\r\nsame"},
		{"fenced headings", "# Store\n```md\n### t1\n```\n### t1\n~~~\n### t2\n~~~~\nbody\n### t2\nkept\n", "^### t1$", "# Store\n```md\n### t1\n```\n### t2\nkept\n", "### t1\n~~~\n### t2\n~~~~\nbody\n"},
		{"indentation", "# Store\n   ### t1\nchild\n### t2\nkept", "^   ### t1$", "# Store\n### t2\nkept", "   ### t1\nchild\n"},
		{"fenced comment is data", "# Store\n### t1\n```html\n<!--\n### fake\n-->\n```\n### Current\nkeep\n", "^### t1$", "# Store\n### Current\nkeep\n", "### t1\n```html\n<!--\n### fake\n-->\n```\n"},
		{"thematic breaks and fenced underlines", "# Store\n---\n### t1\nbody\n\n---\n```\nNext\n===\n```\n### Current\nkeep\n", "^### t1$", "# Store\n---\n### Current\nkeep\n", "### t1\nbody\n\n---\n```\nNext\n===\n```\n"},
		{"frontmatter headings", "---\n### t1\nkind: note\n---\n# Store\n### t1\nbody\n### t2\nkept\n", "^### t1$", "---\n### t1\nkind: note\n---\n# Store\n### t2\nkept\n", "### t1\nbody\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			keep, moved, err := Split([]byte(c.source), c.selector)
			if err != nil || string(keep) != c.keep || string(moved) != c.moved {
				t.Fatalf("wrong ownership: keep=%q moved=%q err=%v", keep, moved, err)
			}
			if err := Verify([]byte(c.source), keep, moved); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSplitRefusesUnprovenSelections(t *testing.T) {
	for _, c := range []struct{ source, selector, diagnostic string }{
		{"", "^#", "empty source"}, {"# Store\n", "", "empty selector"}, {"# Store\n", "[", "invalid selector"},
		{"# Store\n", "absent", "exactly one heading"}, {"# Store\n### t1\n### t1\n", "^### t1$", "exactly one heading"},
		{"### t1\nonly\n", "^### t1$", "empty retained"}, {" \n### t1\nonly\n", "^### t1$", "empty retained"},
		{"# Store\nnot a heading\n", "not a heading", "exactly one heading"},
		{"---\n# Store\n### t1\nbody\n", "^### t1$", "unterminated frontmatter"},
		{"# Store\n<!--\n### t1\n-->\n### Current\nkeep\n", "^### t1$", "HTML comments are unsupported"},
		{"# Store\n### t1\n<!-- hidden\n### Current\n-->\n", "^### t1$", "HTML comments are unsupported"},
		{"# Store\n### t1 <!-- hidden -->\nbody\n", "^### t1", "HTML comments are unsupported"},
		{"# Store\n<pre>\n### t1\nexample\n</pre>\n### Current\nkeep\n", "^### t1$", "raw HTML is unsupported"},
		{"# Store\n<SCRIPT>\n### t1\nexample\n</SCRIPT>\n### Current\nkeep\n", "^### t1$", "raw HTML is unsupported"},
		{"# Store\n### t1\nbody\nNext\n---\nkeep\n", "^### t1$", "setext headings are unsupported"},
		{"# Store\n### t1\nbody\nNext\n===\nkeep\n", "^### t1$", "setext headings are unsupported"},
	} {
		_, _, err := Split([]byte(c.source), c.selector)
		if err == nil || !strings.Contains(err.Error(), c.diagnostic) {
			t.Errorf("unsafe selection or wrong refusal: %v", err)
		}
	}
}

func TestConservationRejectsIndependentLossModes(t *testing.T) {
	for _, c := range []struct {
		name, source, keep, moved string
		want                      error
	}{
		{"bytes", "a\nb\n", "a\n", "bb\n", ErrBytes},
		{"lines", "aaa\nbbb\n", "a\na\n", "bbb\n", ErrLines},
		{"nonblank", "a \nb\n", "  \n", "b\n", ErrNonblank},
		{"verbatim", "a\nb\n", "a\n", "c\n", ErrMultiset},
		{"multiplicity", "a\na\nb\n", "a\n", "b\nb\n", ErrMultiset},
	} {
		t.Run(c.name, func(t *testing.T) {
			if err := Check([]byte(c.source), []byte(c.keep), []byte(c.moved)); !errors.Is(err, c.want) {
				t.Fatalf("wrong conservation refusal: got %v want %v", err, c.want)
			}
		})
	}
}

func TestVerifyChallengesItsOwnCheck(t *testing.T) {
	if err := Verify([]byte("# Store\n### Old\nsame\nsame"), []byte("# Store\n"), []byte("### Old\nsame\nsame")); err != nil {
		t.Fatal(err)
	}
	if err := Verify([]byte("# Store\n### Old\nsame\nsame"), []byte("# Store\n"), []byte("### Old\nsame\nlost")); !errors.Is(err, ErrMultiset) {
		t.Fatalf("changed bytes accepted: %v", err)
	}
}

func TestNegativeControlRequiresSpecificRefusal(t *testing.T) {
	for _, c := range []struct {
		name    string
		control error
		want    error
	}{
		{"disabled validator", nil, ErrControl},
		{"unrelated failure", ErrBytes, ErrControl},
		{"specific multiset refusal", ErrMultiset, nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			first := true
			check := func(_, _, _ []byte) error {
				if first {
					first = false
					return nil
				}
				return c.control
			}
			err := verifyWith(check, []byte("a\nb\n"), []byte("a\n"), []byte("b\n"))
			if !errors.Is(err, c.want) {
				t.Fatalf("negative control accepted an unproven validator: got %v want %v", err, c.want)
			}
		})
	}
}
