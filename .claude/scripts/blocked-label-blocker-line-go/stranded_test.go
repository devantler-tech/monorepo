package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// A parked dependency pull request is owned work, never a terminal state
// (devantler-tech/agent-plugins#699). Every open Dependabot pull request of the
// portfolio once sat parked for weeks, nine of them on one issue nobody was
// working, while the digest called each one finished. These tests pin the
// STRANDED verdict that keeps such a park in the run's work.

const (
	strandedLine = "**Blocker:** owner/repo#7 | upstream | last-verified 2026-09-01: open"
	decidedLine  = "**Blocker:** owner/repo#7 | upstream | last-verified 2026-09-01: open; tried: pinning the v1 SDK, still conflicts; next: patch the vendored v2 client; re-check 2026-09-05"
)

// datedRecord is a record comment created at the given time; an empty time
// leaves created_at out.
func datedRecord(t *testing.T, line, created string) string {
	t.Helper()
	fields := map[string]any{"user": map[string]string{"login": "devantler"}, "body": recordHead + line}
	if created != "" {
		fields["created_at"] = created
	}
	raw, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// botPull is an --input parked pull request by author, whose record is the
// given comment, with extra fields placed before the body.
func botPull(author, extra, record string) string {
	return `[{"repo":"p","number":5,"pull_request":{},"labels":[{"name":"blocked"}],"user":{"login":"` + author + `"},` + extra + `"body":"bump","comments":[` + record + `]}]`
}

// The tests take 2026-09-01 as today, so a record created on 2026-08-17 is 15 days old.
func TestParkedDigestStrandsALongParkedDependencyPullRequestWithoutARoute(t *testing.T) {
	for _, tc := range []struct {
		name, author, line, created string
		extra                       []string
		want                        string
	}{
		{"a new park", "dependabot[bot]", strandedLine, "2026-09-01T09:00:00Z", nil, "PARKED     p#5  "},
		{"exactly at the bound", "dependabot[bot]", strandedLine, "2026-08-18T23:59:59Z", nil, "PARKED     p#5  "},
		{"one day past the bound", "dependabot[bot]", strandedLine, "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  age=15d  owner/repo#7\n"},
		{"renovate past the bound", "renovate[bot]", strandedLine, "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  age=15d  "},
		{"a current route record", "dependabot[bot]", decidedLine, "2026-08-17T00:00:00Z", nil, "PARKED     p#5  "},
		{"a re-check due today", "dependabot[bot]", strings.Replace(decidedLine, "2026-09-05", "2026-09-01", 1), "2026-08-17T00:00:00Z", nil, "PARKED     p#5  "},
		{"a lapsed re-check", "dependabot[bot]", strings.Replace(decidedLine, "2026-09-05", "2026-08-31", 1), "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=ROUTE-LAPSED  age=15d  "},
		{"a re-check at the bound ahead", "dependabot[bot]", strings.Replace(decidedLine, "2026-09-05", "2026-09-15", 1), "2026-08-17T00:00:00Z", nil, "PARKED     p#5  "},
		{"a re-check past the bound ahead", "dependabot[bot]", strings.Replace(decidedLine, "2026-09-05", "2026-09-16", 1), "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  "},
		{"a re-check that is no date", "dependabot[bot]", strings.Replace(decidedLine, "2026-09-05", "2026-02-30", 1), "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  "},
		{"a record without what was tried", "dependabot[bot]", strings.Replace(decidedLine, "tried: pinning the v1 SDK, still conflicts; ", "", 1), "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  "},
		{"a record without the next route", "dependabot[bot]", strings.Replace(decidedLine, "next: patch the vendored v2 client; ", "", 1), "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  "},
		{"two re-check dates", "dependabot[bot]", decidedLine + "; re-check 2026-09-06", "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  "},
		{"a route written into the blocker, not the result", "dependabot[bot]", "**Blocker:** owner/repo#7 tried: x; next: y; re-check 2026-09-05 | upstream | last-verified 2026-09-01: open", "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  "},
		// No bound hands the work to the maintainer: a park of any age stays the
		// agent's, held only by a current route record (maintainer, 2026-11-13).
		{"a current route record long past the bound", "dependabot[bot]", decidedLine, "2026-06-01T00:00:00Z", nil, "PARKED     p#5  "},
		{"an outcome wait without a route", "dependabot[bot]", "**Blocker:** the next v2 release being published | outcome | last-verified 2026-09-01: not yet; re-check 2026-09-05", "2026-08-17T00:00:00Z", nil, "STRANDED   p#5  reason=NO-ROUTE  "},
		{"an outcome wait with a route", "dependabot[bot]", "**Blocker:** the next v2 release being published | outcome | last-verified 2026-09-01: not yet; tried: the v2 beta, fails CI; next: backport the fix; re-check 2026-09-05", "2026-08-17T00:00:00Z", nil, "PARKED     p#5  [outcome]"},
		// A maintainer ask is a question of direction, never a handoff, so it
		// does not pause the work.
		{"a maintainer ask without a route", "dependabot[bot]", "**Blocker:** approve the upgrade | authority | last-verified 2026-09-01: waiting | asked digest o/monorepo#40 2026-08-30", "2026-08-17T00:00:00Z", []string{`"ask_state":"open",`}, "STRANDED   p#5  reason=NO-ROUTE  "},
		{"a maintainer ask while routes continue", "dependabot[bot]", "**Blocker:** approve the upgrade | authority | last-verified 2026-09-01: waiting; tried: the v2 shim; next: fork the client; re-check 2026-09-05 | asked digest o/monorepo#40 2026-08-30", "2026-08-17T00:00:00Z", []string{`"ask_state":"open",`}, "PARKED     p#5  [authority]"},
		{"a new maintainer ask", "dependabot[bot]", "**Blocker:** approve the upgrade | authority | last-verified 2026-09-01: waiting | asked digest o/monorepo#40 2026-08-30", "2026-08-25T00:00:00Z", []string{`"ask_state":"open",`}, "PARKED     p#5  [authority]"},
		{"a wider bound", "dependabot[bot]", strandedLine, "2026-08-17T00:00:00Z", []string{"--stranded-max-age-days", "20"}, "PARKED     p#5  "},
		{"a narrower bound", "dependabot[bot]", strandedLine, "2026-08-25T00:00:00Z", []string{"--stranded-max-age-days", "3"}, "STRANDED   p#5  reason=NO-ROUTE  age=7d  "},
		// Only the exact identities are dependency pull requests: anyone else's
		// park is judged as before, whatever its age.
		{"the maintainer's pull request", "devantler", strandedLine, "2026-06-01T00:00:00Z", nil, "PARKED     p#5  "},
		{"a lookalike author", "dependabot[bot]-fork", strandedLine, "2026-06-01T00:00:00Z", nil, "PARKED     p#5  "},
		{"another spelling", "Dependabot[bot]", strandedLine, "2026-06-01T00:00:00Z", nil, "PARKED     p#5  "},
		{"the app name without its suffix", "dependabot", strandedLine, "2026-06-01T00:00:00Z", nil, "PARKED     p#5  "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			extra, args := "", []string{"--parked-digest"}
			for _, e := range tc.extra {
				if strings.HasPrefix(e, `"`) {
					extra += e
				} else {
					args = append(args, e)
				}
			}
			code, out := runInput(t, botPull(tc.author, extra, datedRecord(t, tc.line, tc.created)), args...)
			stranded := strings.HasPrefix(tc.want, "STRANDED")
			if !strings.Contains(out, tc.want) || (code == 1) != stranded || (code == 0) == stranded {
				t.Fatalf("code=%d, want %q; out:\n%s", code, tc.want, out)
			}
			counts := "CHECKED labelled=1 parked=1 actionable=0\n"
			if stranded {
				counts = "CHECKED labelled=1 parked=0 actionable=1\n"
			}
			if !strings.Contains(out, counts) {
				t.Fatalf("missing %q; out:\n%s", counts, out)
			}
		})
	}
}

// The park date is what every age verdict rests on: a record whose date cannot
// be read would make an old park look new, so the digest is UNKNOWN instead.
func TestParkedDigestIsUnknownWhenADependencyParkCannotBeDated(t *testing.T) {
	for name, created := range map[string]string{
		"no created_at":           "",
		"an unreadable timestamp": "yesterday",
		"a date only":             "2026-08-01",
		"a time after today":      "2026-09-02T00:00:00Z",
	} {
		t.Run(name, func(t *testing.T) {
			code, out := runInput(t, botPull("dependabot[bot]", "", datedRecord(t, strandedLine, created)), "--parked-digest")
			if code != 2 || !strings.Contains(out, "UNKNOWN") || strings.Contains(out, "CHECKED") || strings.Contains(out, "PARKED") {
				t.Fatalf("code=%d out:\n%s", code, out)
			}
		})
	}
	t.Run("the maintainer's park is not dated", func(t *testing.T) {
		if code, out := runInput(t, botPull("devantler", "", datedRecord(t, strandedLine, "")), "--parked-digest"); code != 0 || !strings.Contains(out, "PARKED     p#5  ") {
			t.Fatalf("code=%d out:\n%s", code, out)
		}
	})
}

// An in-portfolio blocker is finishing work: one that nobody holds keeps the
// dependency pull request in the run's work, at any age.
func TestParkedDigestStrandsADependencyPullRequestWhoseBlockerNobodyHolds(t *testing.T) {
	record := datedRecord(t, strandedLine, "2026-09-01T00:00:00Z")
	for _, tc := range []struct {
		name, author, extra string
		code                int
		want                string
	}{
		{"an unclaimed blocker", "renovate[bot]", `"blocker_state":"open","blocker_claim":"unclaimed",`, 1, "STRANDED   p#5  reason=UNCLAIMED  age=0d  owner/repo#7\n"},
		{"a held blocker", "renovate[bot]", `"blocker_state":"open","blocker_claim":"held",`, 0, "PARKED     p#5  [upstream, blocker open]"},
		{"a closed blocker stays BLOCKER-CLOSED", "renovate[bot]", `"blocker_state":"closed","blocker_claim":"unclaimed",`, 1, "ACTIONABLE p#5  record=BLOCKER-CLOSED"},
		{"a blocker whose state was not read", "renovate[bot]", ``, 0, "PARKED     p#5  [upstream, blocker state not read]"},
		{"no claim on an open blocker", "renovate[bot]", `"blocker_state":"open",`, 2, "blocker_claim -- UNKNOWN"},
		{"an unreadable claim", "renovate[bot]", `"blocker_state":"open","blocker_claim":"maybe",`, 2, "blocker_claim -- UNKNOWN"},
		{"the maintainer's pull request needs no claim", "devantler", `"blocker_state":"open",`, 0, "PARKED     p#5  [upstream, blocker open]"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, out := runInput(t, botPull(tc.author, tc.extra, record), "--parked-digest")
			if code != tc.code || !strings.Contains(out, tc.want) || (code == 2) == strings.Contains(out, "CHECKED") {
				t.Fatalf("code=%d, want %d and %q; out:\n%s", code, tc.code, tc.want, out)
			}
		})
	}
}

// serveStranded answers the org reads for one parked pull request
// platform#900 by author, whose record names o/ksail#7, beside the other open
// pull requests given, and the blocker answer given. It returns the reads.
func serveStranded(t *testing.T, author, blocker string, others ...string) *[]string {
	t.Helper()
	pull := map[string]any{
		"repository_url": "https://api.github.com/repos/o/platform", "number": 900, "labels": []any{map[string]string{"name": "blocked"}},
		"pull_request": map[string]any{}, "body": "bump", "title": "bump", "comments": 99,
	}
	if author != "" {
		pull["user"] = map[string]string{"login": author}
	}
	raw, err := json.Marshal(pull)
	if err != nil {
		t.Fatal(err)
	}
	record := datedRecord(t, strings.Replace(strandedLine, "owner/repo#7", "o/ksail#7", 1), "2026-09-01T00:00:00Z")
	var reads []string
	original := forgeRead
	t.Cleanup(func() { forgeRead = original })
	forgeRead = func(endpoint string) ([]byte, error) {
		reads = append(reads, endpoint)
		switch endpoint {
		case pullEndpoint("o"):
			return []byte(searchPage(append([]string{string(raw)}, others...)...)), nil
		case "repos/o/platform/issues/900":
			return []byte(counted(1)), nil
		case "repos/o/platform/issues/900/comments?per_page=100":
			return []byte("[" + record + "]"), nil
		case "repos/o/ksail/issues/7":
			return []byte(blocker), nil
		}
		t.Errorf("unexpected read %q", endpoint)
		return nil, errors.New("unexpected read")
	}
	return &reads
}

// otherPull is another open pull request of the organization by author, with
// the given body.
func otherPull(author, repo, body string) string {
	return `{"repository_url":"https://api.github.com/repos/o/` + repo + `","number":50,"labels":[],"pull_request":{},"user":{"login":"` + author + `"},"title":"work","body":"` + body + `","comments":0}`
}

func TestParkedDigestReadsWhetherAnInPortfolioBlockerIsHeld(t *testing.T) {
	const unlabelled = `{"number":7,"state":"open","labels":[]}`
	for _, tc := range []struct {
		name, author, blocker string
		others                []string
		code                  int
		want                  string
	}{
		{"nobody holds it", "renovate[bot]", unlabelled, nil, 1, "STRANDED   platform#900  reason=UNCLAIMED  age=0d  o/ksail#7\n"},
		{"it is parked itself", "renovate[bot]", `{"number":7,"state":"open","labels":[{"name":"Blocked"}]}`, nil, 0, "PARKED     platform#900  [upstream, blocker open]"},
		{"an open pull request works on it", "renovate[bot]", unlabelled, []string{otherPull("devantler", "ksail", "Part of #7")}, 0, "PARKED     platform#900  "},
		{"an open pull request elsewhere names it", "renovate[bot]", unlabelled, []string{otherPull("devantler", "platform", "Fixes o/ksail#7")}, 0, "PARKED     platform#900  "},
		{"only a dependency pull request names it", "renovate[bot]", unlabelled, []string{otherPull("dependabot[bot]", "ksail", "Fixes #7")}, 1, "reason=UNCLAIMED"},
		{"only a number in prose names it", "renovate[bot]", unlabelled, []string{otherPull("devantler", "ksail", "we chose option #7")}, 1, "reason=UNCLAIMED"},
		{"an assignee does not hold it", "renovate[bot]", `{"number":7,"state":"open","labels":[],"assignees":[{"login":"devantler"}]}`, nil, 1, "reason=UNCLAIMED"},
		{"it is a pull request", "renovate[bot]", `{"number":7,"state":"open","pull_request":{}}`, nil, 0, "PARKED     platform#900  [upstream, blocker open]"},
		{"its labels cannot be read", "renovate[bot]", `{"number":7,"state":"open"}`, nil, 2, "carries no labels, so whether anyone holds it is unproven -- UNKNOWN"},
		{"its labels are not a list", "renovate[bot]", `{"number":7,"state":"open","labels":"blocked"}`, nil, 2, "carries no readable state -- UNKNOWN"},
		{"the maintainer's pull request reads no claim", "devantler", `{"number":7,"state":"open"}`, nil, 0, "PARKED     platform#900  [upstream, blocker open]"},
		{"a pull request with no author", "", `{"number":7,"state":"open","labels":[]}`, nil, 2, "carries no author"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reads := serveStranded(t, tc.author, tc.blocker, tc.others...)
			code, out := runOrgDigest(t)
			if code != tc.code || !strings.Contains(out, tc.want) || (code == 2) == strings.Contains(out, "CHECKED") {
				t.Fatalf("code=%d, want %d and %q; reads=%v out:\n%s", code, tc.code, tc.want, *reads, out)
			}
		})
	}
}

func TestStrandedBoundsAreNonNegativeIntegers(t *testing.T) {
	for _, value := range []string{"", "-1", "two", "1234567890"} {
		for _, flag := range []string{"--stranded-max-age-days"} {
			if code, out := runInput(t, "[]", "--parked-digest", flag, value); code != 2 || strings.Contains(out, "CHECKED") {
				t.Fatalf("%s %q: code=%d out:\n%s", flag, value, code, out)
			}
		}
	}
}

func TestHelpDescribesTheStrandedVerdict(t *testing.T) {
	for _, token := range []string{"STRANDED", "UNCLAIMED", "NO-ROUTE", "ROUTE-LAPSED", "--stranded-max-age-days", `"tried:"`, `"next:"`, `"re-check <YYYY-MM-DD>"`, "whatever its", "ACTIONABLE or STRANDED"} {
		if !strings.Contains(help, token) {
			t.Fatalf("--help does not state %q", token)
		}
	}
}

// A labelled pull request whose author is not named might be a dependency pull
// request, so it is UNKNOWN under --input as under --org, never PARKED.
func TestParkedDigestIsUnknownWhenAParkedPullRequestNamesNoAuthor(t *testing.T) {
	record := datedRecord(t, strandedLine, "2026-06-01T00:00:00Z")
	for name, user := range map[string]string{"no user": ``, "a null user": `"user":null,`, "an empty user": `"user":{},`, "an empty login": `"user":{"login":""},`} {
		t.Run(name, func(t *testing.T) {
			payload := `[{"repo":"p","number":5,"pull_request":{},"labels":[{"name":"blocked"}],` + user + `"body":"bump","comments":[` + record + `]}]`
			if code, out := runInput(t, payload, "--parked-digest"); code != 2 || !strings.Contains(out, "carries no author") || strings.Contains(out, "CHECKED") {
				t.Fatalf("code=%d out:\n%s", code, out)
			}
		})
	}
}

// The park date is the record comment's own: not an earlier comment's, nor a
// later one's, and taken in UTC whatever offset the forge reports.
func TestParkAgeIsTheRecordCommentsOwnUTCDate(t *testing.T) {
	other := func(created string) string {
		raw, err := json.Marshal(map[string]any{"user": map[string]string{"login": "dependabot[bot]"}, "body": "rebased", "created_at": created})
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	for _, tc := range []struct {
		name, comments, want string
	}{
		{"an older comment before the record", other("2026-06-01T00:00:00Z") + "," + datedRecord(t, strandedLine, "2026-08-30T00:00:00Z"), "PARKED     p#5  "},
		{"a newer comment after the record", datedRecord(t, strandedLine, "2026-08-01T00:00:00Z") + "," + other("2026-08-31T00:00:00Z"), "STRANDED   p#5  reason=NO-ROUTE  age=31d  "},
		// 01:00 at +02:00 on 2026-08-18 is 23:00 UTC on 2026-08-17: 15 days, not 14.
		{"an offset that crosses midnight", datedRecord(t, strandedLine, "2026-08-18T01:00:00+02:00"), "STRANDED   p#5  reason=NO-ROUTE  age=15d  "},
		{"a year the calendar has no day for", datedRecord(t, strandedLine, "0000-01-01T00:00:00Z"), "unusable created_at -- UNKNOWN"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := `[{"repo":"p","number":5,"pull_request":{},"labels":[{"name":"blocked"}],"user":{"login":"dependabot[bot]"},"body":"bump","comments":[` + tc.comments + `]}]`
			if _, out := runInput(t, payload, "--parked-digest"); !strings.Contains(out, tc.want) {
				t.Fatalf("want %q; out:\n%s", tc.want, out)
			}
		})
	}
}

// A closed blocker outranks an unclaimed one named before it: the park no
// longer holds at all, so the pull request is driven, not merely stranded.
func TestParkedDigestReadsEveryBlockerBeforeStranding(t *testing.T) {
	record := datedRecord(t, "**Blocker:** o/ksail#7 and o/ksail#8 | upstream | last-verified 2026-09-01: open", "2026-09-01T00:00:00Z")
	pull := `{"repository_url":"https://api.github.com/repos/o/platform","number":900,"labels":[{"name":"blocked"}],"pull_request":{},"user":{"login":"renovate[bot]"},"title":"bump","body":"bump","comments":99}`
	original := forgeRead
	t.Cleanup(func() { forgeRead = original })
	forgeRead = func(endpoint string) ([]byte, error) {
		switch endpoint {
		case pullEndpoint("o"):
			return []byte(searchPage(pull)), nil
		case "repos/o/platform/issues/900":
			return []byte(counted(1)), nil
		case "repos/o/platform/issues/900/comments?per_page=100":
			return []byte("[" + record + "]"), nil
		case "repos/o/ksail/issues/7":
			return []byte(`{"number":7,"state":"open","labels":[]}`), nil
		case "repos/o/ksail/issues/8":
			return []byte(`{"number":8,"state":"closed","labels":[]}`), nil
		}
		t.Errorf("unexpected read %q", endpoint)
		return nil, errors.New("unexpected read")
	}
	if code, out := runOrgDigest(t); code != 1 || !strings.Contains(out, "ACTIONABLE platform#900  record=BLOCKER-CLOSED") || strings.Contains(out, "STRANDED") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}
