package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// A zero search is confirmed without the archived:false qualifier before it is
// believed (#4435): a zero followed by open items is UNKNOWN, and a zero the
// unqualified read agrees with, or finds only in archived repositories, stays
// clean. (An org with no issue at all is UNKNOWN for its own reason, #3822.)
func TestZeroSearchIsConfirmed(t *testing.T) {
	pull := forgeParkedPull(t, "platform")
	active := `{"archived":false}`
	for _, tc := range []struct {
		name, first, confirm, repo string
		confirmErr                 error
		parked                     bool
		code                       int
		want                       string
	}{
		{"pull zero then items", searchPage(), searchPage(pull), active, nil, true, 2, "search answered zero, then 1"},
		{"pull zero then failure", searchPage(), "", "", errors.New("down"), true, 2, "confirming a zero search"},
		{"pull zero then malformed", searchPage(), "not JSON", "", nil, true, 2, "unreadable search page"},
		{"pull zero then incomplete", searchPage(), `{"total_count":0,"incomplete_results":true,"items":[]}`, "", nil, true, 2, "incomplete_results"},
		{"pull zero confirmed", searchPage(), searchPage(), "", nil, true, 0, "CHECKED labelled=0 parked=0 actionable=0"},
		{"issue zero then items", searchPage(), searchPage(forgeIssue), active, nil, false, 2, "search answered zero, then 1"},
		{"pull zero then only archived items", searchPage(), searchPage(pull), `{"archived":true}`, nil, true, 0, "CHECKED labelled=0 parked=0 actionable=0"},
		{"issue zero then only archived items", searchPage(), searchPage(forgeIssue), `{"archived":true}`, nil, false, 2, "read no open Security issue"},
		{"pull zero then unreadable repository", searchPage(), searchPage(pull), `{}`, nil, true, 2, "unreadable repository"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			original := forgeRead
			t.Cleanup(func() { forgeRead = original })
			target := pullEndpoint("o")
			if !tc.parked {
				target = searchEndpoint("o")
			}
			if unqualified(target) == target {
				t.Fatalf("endpoint %q carries no archived:false qualifier to drop", target)
			}
			reads := make(map[string]int)
			forgeRead = func(endpoint string) ([]byte, error) {
				reads[endpoint]++
				switch endpoint {
				case target:
					return []byte(tc.first), nil
				case unqualified(target):
					return []byte(tc.confirm), tc.confirmErr
				case "repos/o/platform":
					return []byte(tc.repo), nil
				case searchEndpoint("o"), pullEndpoint("o"):
					return []byte(searchPage(forgeIssue)), nil
				default:
					return nil, errors.New("unexpected read: " + endpoint)
				}
			}
			args := []string{"--org", "o", "--today", "2026-09-01"}
			if tc.parked {
				args = append(args, "--parked-digest")
			}
			var out, stderr bytes.Buffer
			code := run(args, strings.NewReader(""), &out, &stderr)
			got := out.String() + stderr.String()
			if code != tc.code || !strings.Contains(got, tc.want) {
				t.Fatalf("code=%d, want %d containing %q; out:\n%s", code, tc.code, tc.want, got)
			}
			if code == 2 && strings.Contains(got, "CHECKED") {
				t.Fatalf("UNKNOWN still printed a digest; out:\n%s", got)
			}
			if reads[target] != 1 || reads[unqualified(target)] != 1 {
				t.Fatalf("want one qualified and one unqualified read; reads=%v", reads)
			}
		})
	}
}
