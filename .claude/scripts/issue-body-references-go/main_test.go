package main

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestBodyMentions(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		want       bool
	}{
		{"bare", "Delivered #42", true},
		{"bracketed bare", "Delivered [#42]", true},
		{"unresolved reference", "Delivered [#42][not-defined]", true},
		{"local URL", "https://github.com/o/r/issues/42", true},
		{"sentence punctuation", "https://github.com/o/r/issues/42!", true},
		{"parentheses", "(https://github.com/o/r/issues/42).", true},
		{"local Markdown", "[#42](https://github.com/O/R/issues/42)", true},
		{"local HTML", `<a href="https://github.com/o/r/issues/42">issue</a>`, true},
		{"empty link", `<a href="">#42</a>`, false},
		{"named anchor", `<a name="point">#42</a>`, true},
		{"duplicate destination", `<a href="" href="https://github.com/o/r/issues/42">#42</a>`, false},
		{"foreign Markdown", "[#42](https://github.com/other/r/issues/42)", false},
		{"foreign HTML", `<a href="https://redirect.github.com/other/r/pull/42"><code>#42</code></a>`, false},
		{"reference link", "[#42][upstream]\n\n[upstream]: https://github.com/other/r/issues/42", false},
		{"shortcut link", "[#42]\n\n[#42]: https://github.com/other/r/issues/42", false},
		{"mixed", "[#42](https://github.com/other/r/issues/42); fixes #42 here", true},
		{"longer number", "Tracks #420 and https://github.com/o/r/issues/420", false},
		{"foreign qualified", "other/r#42", false},
		{"nested URL", "https://other.example/?next=https://github.com/o/r/issues/42", false},
		{"route suffix", "https://github.com/o/r/issues/42legacy", false},
		{"file suffix", "https://github.com/o/r/issues/42.md", false},
		{"foreign code URL", "`https://other.example/?text=#42`", false},
		{"GFM www URL", "www.example.com/?next=#42", false},
		{"literal www URL", "`www.example.com/?next=#42`", false},
		{"GFM email", "a+#42@example.com", false},
		{"empty", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := bodyMentions(tc.body, "o/r", 42)
			if err != nil || got != tc.want {
				t.Fatalf("got %v, %v; want %v", got, err, tc.want)
			}
		})
	}
}

func TestSearchObservation(t *testing.T) {
	const valid = `{"total_count":1,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":7,"state":"closed","body":"Fixes #42","pull_request":{"merged_at":"2026-01-01T00:00:00Z"}}]}`
	var output bytes.Buffer
	if err := run([]string{"o/r", "42"}, strings.NewReader(valid), &output); err != nil {
		t.Fatal(err)
	}
	if want := "[{\"k\":\"o/r#7\",\"s\":\"MERGED\",\"c\":false}]\n"; output.String() != want {
		t.Fatalf("got %q; want %q", output.String(), want)
	}
	for _, tc := range []struct{ name, data string }{
		{"truncated JSON", valid[:len(valid)-1]},
		{"multiple payloads", valid + valid},
		{"short page", strings.Replace(valid, `"total_count":1`, `"total_count":2`, 1)},
		{"incomplete search", strings.Replace(valid, `"incomplete_results":false`, `"incomplete_results":true`, 1)},
		{"nontext body", strings.Replace(valid, `"body":"Fixes #42"`, `"body":false`, 1)},
		{"foreign result", strings.Replace(valid, "repos/o/r", "repos/other/r", 1)},
		{"contradictory state", strings.Replace(valid, `"state":"closed"`, `"state":"open"`, 1)},
		{"invalid merge", strings.Replace(valid, "2026-01-01T00:00:00Z", "unknown", 1)},
		{"missing merge field", strings.Replace(valid, `"pull_request":{"merged_at":"2026-01-01T00:00:00Z"}`, `"other":{}`, 1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := run([]string{"o/r", "42"}, strings.NewReader(tc.data), &out); err == nil || out.Len() != 0 {
				t.Fatalf("err=%v output=%q", err, out.String())
			}
		})
	}
	for _, reader := range []io.Reader{
		io.MultiReader(strings.NewReader(valid), failedRead{}),
		strings.NewReader(strings.Repeat(" ", (16<<20)+1)),
	} {
		var out bytes.Buffer
		if err := run([]string{"o/r", "42"}, reader, &out); err == nil || out.Len() != 0 {
			t.Fatalf("failed/oversized read: err=%v output=%q", err, out.String())
		}
	}
}

type failedRead struct{}

func (failedRead) Read([]byte) (int, error) { return 0, errors.New("late read failure") }
