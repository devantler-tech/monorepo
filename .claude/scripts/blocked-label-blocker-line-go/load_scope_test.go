package main

import (
	"errors"
	"strings"
	"testing"
)

// An unrelated backlog changing mid-pagination must not blind the PR-only
// report. Its own PR, comment and blocker reads must still be complete.
func TestParkedDigestDoesNotReadUnrelatedIssues(t *testing.T) {
	for _, tc := range []struct {
		name, issueReply string
		issueError       error
	}{
		{"failed issue search", "", errors.New("service unavailable")},
		{"changing issue total", searchPage(freshSecurityIssue) + searchPage(), nil},
		{"malformed issue search", "not JSON", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			original := forgeRead
			t.Cleanup(func() { forgeRead = original })
			reads := make(map[string]int)
			record := commentJSON(t, "devantler", recordHead+strings.Replace(goodLine, "owner/repo#7", "o/ksail#7", 1))
			forgeRead = func(endpoint string) ([]byte, error) {
				reads[endpoint]++
				switch endpoint {
				case searchEndpoint("o"):
					return []byte(tc.issueReply), tc.issueError
				case pullEndpoint("o"):
					return []byte(searchPage(forgeParkedPull(t, "platform"))), nil
				case "repos/o/platform/issues/900":
					return []byte(counted(1)), nil
				case "repos/o/platform/issues/900/comments?per_page=100":
					return []byte("[" + record + "]"), nil
				case "repos/o/ksail/issues/7":
					return []byte(`{"number":7,"state":"open"}`), nil
				default:
					return nil, errors.New("unexpected read: " + endpoint)
				}
			}
			code, out := runOrgDigest(t)
			if code != 0 || !strings.Contains(out, "CHECKED labelled=1 parked=1 actionable=0") {
				t.Fatalf("code=%d, want a complete parked digest; out:\n%s", code, out)
			}
			if reads[searchEndpoint("o")] != 0 {
				t.Fatalf("PR-only mode read unrelated issues: %v", reads)
			}
			for _, endpoint := range []string{pullEndpoint("o"), "repos/o/platform/issues/900", "repos/o/platform/issues/900/comments?per_page=100", "repos/o/ksail/issues/7"} {
				if reads[endpoint] != 1 {
					t.Fatalf("required read %q happened %d times; reads=%v", endpoint, reads[endpoint], reads)
				}
			}
		})
	}
}

func TestParkedDigestStillRejectsIncompletePullSearch(t *testing.T) {
	for _, tc := range []struct {
		name, reply, want string
		err               error
	}{
		{"failed", searchPage(), "forge read failed", errors.New("service unavailable")},
		{"malformed", "not JSON", "unreadable search page", nil},
		{"changing total", searchPage(forgeParkedPull(t, "platform")) + searchPage(), "search total_count changed", nil},
		{"incomplete", `{"total_count":0,"incomplete_results":true,"items":[]}`, "incomplete_results", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			original := forgeRead
			t.Cleanup(func() { forgeRead = original })
			forgeRead = func(endpoint string) ([]byte, error) {
				if endpoint == searchEndpoint("o") {
					return []byte(searchPage(freshSecurityIssue)), nil
				}
				if endpoint == pullEndpoint("o") {
					return []byte(tc.reply), tc.err
				}
				return nil, errors.New("unexpected read: " + endpoint)
			}
			code, out := runOrgDigest(t)
			if code != 2 || !strings.Contains(out, tc.want) || strings.Contains(out, "CHECKED") {
				t.Fatalf("code=%d, want UNKNOWN containing %q without a digest; out:\n%s", code, tc.want, out)
			}
		})
	}
}
