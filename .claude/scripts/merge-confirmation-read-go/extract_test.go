package mergeconfirmation

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

func TestLegacyFormattingFixtures(t *testing.T) {
	// Each labelled Markdown form is a separate case, including its continuations.
	starts := regexp.MustCompile(`(?m)^[a-z-]+:`).FindAllStringIndex(badMarkdown, -1)
	if len(starts) != 11 {
		t.Fatalf("lost legacy bad forms: %d", len(starts))
	}
	for i, start := range starts {
		end := len(badMarkdown)
		if i+1 < len(starts) {
			end = starts[i+1][0]
		}
		input := badMarkdown[start[0]:end]
		name := strings.SplitN(input, ":", 2)[0]
		t.Run(name, func(t *testing.T) {
			lists, err := extract([]byte(input), false)
			if err != nil || len(badLists(lists)) != 1 {
				t.Fatalf("missed bad form: %q %v", lists, err)
			}
		})
	}
	var encoded struct {
		Prompts []string `json:"prompts"`
	}
	if err := json.Unmarshal([]byte(badJSON), &encoded); err != nil {
		t.Fatal(err)
	}
	for i, input := range encoded.Prompts {
		t.Run([]string{"unicode-space", "unicode-letter"}[i], func(t *testing.T) {
			data, _ := json.Marshal(input)
			lists, err := extract(data, true)
			if err != nil || len(badLists(lists)) != 1 {
				t.Fatalf("missed decoded form: %q %v", lists, err)
			}
		})
	}
	for _, tc := range []struct {
		name, text string
		json       bool
	}{
		{"valid-markdown", goodMarkdown, false}, {"valid-json", goodJSON, true},
		{"separate-scalars", `{"a":"CLI option --json","b":"merged is invalid"}`, true},
		{"same-line-comma", `"--json state, merged work"`, true},
		{"inline-boundary", "`--json comments`, merged work", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			lists, err := extract([]byte(tc.text), tc.json)
			if err != nil || len(badLists(lists)) != 0 {
				t.Fatalf("false finding: %q %v", lists, err)
			}
		})
	}
}

func TestExtractorRefusesMalformedJSON(t *testing.T) {
	for _, input := range []string{`{`, `{"a":"--json state,merged"`, `{} {`, `"unterminated`} {
		if _, err := extract([]byte(input), true); err == nil {
			t.Fatalf("accepted malformed JSON %q", input)
		}
	}
}

func TestJSONStreamMatchesJQGrammar(t *testing.T) {
	for _, input := range []string{"", "{} {}", `"CLI --json" "merged is invalid"`} {
		lists, err := extract([]byte(input), true)
		if err != nil || len(badLists(lists)) != 0 {
			t.Fatalf("valid jq stream refused: %q %v", lists, err)
		}
	}
}

func verifyFixtures(parse func([]byte, bool) ([]string, error)) error {
	for _, tc := range []struct {
		text string
		json bool
		bad  int
	}{
		{badMarkdown, false, 11}, {badJSON, true, 2}, {goodMarkdown, false, 0}, {goodJSON, true, 0},
	} {
		lists, err := parse([]byte(tc.text), tc.json)
		if err != nil {
			return err
		}
		if got := len(badLists(lists)); got != tc.bad {
			return fmt.Errorf("extractor self-test: caught %d/%d known-bad forms", got, tc.bad)
		}
	}
	return nil
}

func TestExtractorVacuityControl(t *testing.T) {
	if err := verifyFixtures(extract); err != nil {
		t.Fatal(err)
	}
	broken := func([]byte, bool) ([]string, error) { return nil, nil }
	if err := verifyFixtures(broken); err == nil || !strings.Contains(err.Error(), "known-bad") {
		t.Fatalf("a matcher that extracts nothing escaped the self-test: %v", err)
	}
}

func TestLegacyFieldListsOnEveryCurrentSurface(t *testing.T) {
	// Optional independent comparison uses the archived, unchanged Bash extractor, never
	// a reconstructed approximation. Normal CI always runs the fixtures and live audit.
	baseline := os.Getenv("MERGE_CONFIRMATION_LEGACY_EXTRACTOR")
	if baseline == "" {
		return
	}
	root := repositoryRoot()
	paths, err := discoverSurfaces(root)
	if err != nil {
		t.Fatal(err)
	}
	compared := 0
	for _, path := range paths {
		input, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		want, err := exec.Command("bash", baseline, path).CombinedOutput()
		if err != nil {
			t.Fatalf("legacy %s: %s %v", path, want, err)
		}
		got, err := extract(input, filepath.Ext(path) == ".json")
		if err != nil {
			t.Fatal(err)
		}
		var expected []string
		if len(want) != 0 {
			expected = strings.Split(strings.TrimSuffix(string(want), "\n"), "\n")
		}
		if !reflect.DeepEqual(got, expected) {
			t.Fatalf("%s: got %#v; legacy %#v", path, got, expected)
		}
		compared++
	}
	t.Logf("exact old/new field-list equality on all %d discovered surfaces", compared)
}
