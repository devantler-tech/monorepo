package archive

import (
	"bytes"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/text"
)

var (
	ErrBytes    = errors.New("byte conservation")
	ErrLines    = errors.New("line conservation")
	ErrNonblank = errors.New("nonblank conservation")
	ErrMultiset = errors.New("verbatim multiset conservation")
	ErrControl  = errors.New("negative control did not prove multiset refusal")
)

var heading = regexp.MustCompile("^ {0,3}(#{1,6})(?:[ \\t]+|$)")
var fence = regexp.MustCompile("^ {0,3}(`{3,}|~{3,})(.*)$")
var rawHTML = regexp.MustCompile(`(?i)<(?:/?[a-z][a-z0-9-]*(?:[\t >]|$)|!|\?)`)
var setext = regexp.MustCompile(`^ {0,3}(?:=+|-+)[ \t]*$`)

// Split owns deeper headings and prose until an equal-or-shallower ATX heading.
// Offsets address the original bytes: neither line endings nor EOF are rebuilt.
func Split(source []byte, selector string) ([]byte, []byte, error) {
	if len(bytes.TrimSpace(source)) == 0 {
		return nil, nil, errors.New("empty source")
	}
	if selector == "" {
		return nil, nil, errors.New("empty selector")
	}
	selected, err := regexp.Compile(selector)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid selector: %w", err)
	}
	htmlSource, err := maskSameLineCode(source)
	if err != nil {
		return nil, nil, err
	}

	type boundary struct {
		offset, depth int
		selected      bool
	}
	var boundaries []boundary
	offset := 0
	marker := ""
	frontmatter := false
	previousParagraph := false
	for _, record := range bytes.SplitAfter(source, []byte("\n")) {
		line := strings.TrimSuffix(strings.TrimSuffix(string(record), "\n"), "\r")
		wasParagraph := previousParagraph
		previousParagraph = false
		if offset == 0 && line == "---" {
			frontmatter = true
			offset += len(record)
			continue
		}
		if frontmatter {
			if line == "---" {
				frontmatter = false
			}
			offset += len(record)
			continue
		}
		htmlLine := strings.TrimSuffix(strings.TrimSuffix(string(htmlSource[offset:offset+len(record)]), "\n"), "\r")
		f := fence.FindStringSubmatch(line)
		if marker != "" {
			if f != nil && f[1][0] == marker[0] && len(f[1]) >= len(marker) && strings.TrimSpace(f[2]) == "" {
				marker = ""
			}
		} else if f != nil && (f[1][0] != '`' || !strings.Contains(f[2], "`")) {
			marker = f[1]
		} else if strings.Contains(htmlLine, "<!--") || strings.Contains(htmlLine, "-->") {
			// Conserving bytes does not justify splitting an unmatched delimiter.
			return nil, nil, errors.New("HTML comments are unsupported outside fenced text")
		} else if rawHTML.MatchString(htmlLine) {
			return nil, nil, errors.New("raw HTML is unsupported outside fenced text")
		} else if wasParagraph && setext.MatchString(line) {
			return nil, nil, errors.New("setext headings are unsupported; use ATX headings")
		} else if h := heading.FindStringSubmatch(line); h != nil {
			boundaries = append(boundaries, boundary{offset, len(h[1]), selected.MatchString(line)})
		} else if strings.TrimSpace(line) != "" && !setext.MatchString(line) && !strings.HasPrefix(line, "    ") && !strings.HasPrefix(line, "\t") {
			previousParagraph = true
		}
		offset += len(record)
	}
	if frontmatter {
		return nil, nil, errors.New("unterminated frontmatter")
	}
	count, index := 0, 0
	for i, b := range boundaries {
		if b.selected {
			count++
			index = i
		}
	}
	if count != 1 {
		return nil, nil, fmt.Errorf("selector must match exactly one heading; matched %d", count)
	}
	start, end := boundaries[index].offset, len(source)
	for _, b := range boundaries[index+1:] {
		if b.depth <= boundaries[index].depth {
			end = b.offset
			break
		}
	}
	keep := append(bytes.Clone(source[:start]), source[end:]...)
	moved := bytes.Clone(source[start:end])
	if len(bytes.TrimSpace(keep)) == 0 {
		return nil, nil, errors.New("empty retained source")
	}
	if err := Verify(source, keep, moved); err != nil {
		return nil, nil, err
	}
	return keep, moved, nil
}

// maskSameLineCode uses CommonMark parsing to distinguish code from autolinks,
// HTML and other inline syntax. The copy is only for conservative HTML checks;
// section selection and conservation always operate on the untouched source.
func maskSameLineCode(source []byte) ([]byte, error) {
	masked := bytes.Clone(source)
	document := goldmark.DefaultParser().Parse(text.NewReader(source))
	err := ast.Walk(document, func(node ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering || node.Kind() != ast.KindCodeSpan {
			return ast.WalkContinue, nil
		}
		// Goldmark retains one text segment per source line. Multiline code is
		// outside this archive grammar, so it never receives an HTML exemption.
		if node.ChildCount() != 1 {
			return ast.WalkSkipChildren, nil
		}
		content, ok := node.FirstChild().(*ast.Text)
		if !ok {
			return ast.WalkStop, errors.New("unproven inline code source segment")
		}
		start, stop := content.Segment.Start, content.Segment.Stop
		if start < 0 || stop < start || stop > len(source) {
			return ast.WalkStop, errors.New("invalid inline code source range")
		}
		// CommonMark may trim one padding space or newline at either end.
		// Include those adjacent bytes when establishing physical-line scope.
		left, right := max(0, start-1), min(len(source), stop+1)
		if bytes.ContainsAny(source[left:right], "\r\n") {
			return ast.WalkSkipChildren, nil
		}
		for i := start; i < stop; i++ {
			masked[i] = '*'
		}
		return ast.WalkSkipChildren, nil
	})
	if err != nil {
		return nil, fmt.Errorf("inspect inline code: %w", err)
	}
	return masked, nil
}

// records preserves the final unterminated line and every duplicate verbatim.
func records(data []byte) ([]string, int) {
	lines := bytes.SplitAfter(data, []byte("\n"))
	result := make([]string, 0, len(lines))
	nonblank := 0
	for _, line := range lines {
		if len(line) > 0 {
			result = append(result, string(line))
			if len(bytes.TrimSpace(line)) > 0 {
				nonblank++
			}
		}
	}
	return result, nonblank
}

func Check(source, keep, moved []byte) error {
	if len(source) != len(keep)+len(moved) {
		return ErrBytes
	}
	original, on := records(source)
	retained, rn := records(keep)
	archived, an := records(moved)
	if len(original) != len(retained)+len(archived) {
		return ErrLines
	}
	if on != rn+an {
		return ErrNonblank
	}
	combined := append(retained, archived...)
	sort.Strings(original)
	sort.Strings(combined)
	if !slices.Equal(original, combined) {
		return ErrMultiset
	}
	return nil
}

// Verify challenges the same validator used on real candidates. A transport,
// counting error or disabled check cannot masquerade as the expected refusal.
func Verify(source, keep, moved []byte) error {
	return verifyWith(Check, source, keep, moved)
}

func verifyWith(check func([]byte, []byte, []byte) error, source, keep, moved []byte) error {
	if err := check(source, keep, moved); err != nil {
		return err
	}
	bad := bytes.Clone(moved)
	for i, b := range bad {
		if !bytes.ContainsRune([]byte(" \t\r\n\v\f"), rune(b)) {
			bad[i] = '!'
			if b == '!' {
				bad[i] = '?'
			}
			if err := check(source, keep, bad); !errors.Is(err, ErrMultiset) {
				return fmt.Errorf("%w: %v", ErrControl, err)
			}
			return nil
		}
	}
	return errors.New("negative control needs a nonblank archived record")
}
