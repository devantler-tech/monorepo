package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// digestPull is one --input pull request in repo p with the given number,
// labels fragment and comments.
func digestPull(number, labels string, comments ...string) string {
	return `{"repo":"p","number":` + number + `,"pull_request":{},` + labels + `"body":"**Blocker:** body/only#1","comments":[` + strings.Join(comments, ",") + `]}`
}

const blockedLabel = `"labels":[{"name":"blocked"}],`

func TestParkedDigestReportsAConformingRecordAsParkedWithItsBlocker(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+goodLine)
	code, out := runInput(t, "["+digestPull("5", blockedLabel, record)+"]", "--parked-digest")
	if code != 0 {
		t.Fatalf("code=%d, want 0; out:\n%s", code, out)
	}
	for _, want := range []string{"PARKED     p#5  [upstream, blocker state not read]  owner/repo#7\n", "CHECKED labelled=1 parked=1 actionable=0\n"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q; out:\n%s", want, out)
		}
	}
	if strings.Contains(out, "body/only") || strings.Contains(out, "CONFORMS") {
		t.Fatalf("the digest carries more than its own rows; out:\n%s", out)
	}
}

// The label alone never parks a pull request for the survey: without one valid
// record it stays work to do, and the row says which verdict kept it there.
func TestParkedDigestKeepsALabelWithoutAValidRecordActionable(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+goodLine)
	for _, tc := range []struct {
		name     string
		comments []string
		extra    []string
		verdict  string
	}{
		{"no record", nil, nil, "MISSING"},
		{"a record from another author", []string{commentJSON(t, "someone", recordHead+goodLine)}, nil, "MISSING"},
		{"a record without the disclosure line", []string{commentJSON(t, "devantler", recordMarker+"\n"+goodLine)}, nil, "MISSING"},
		{"two records", []string{record, record}, nil, "DUPLICATE"},
		{"a malformed record", []string{commentJSON(t, "devantler", recordHead+"**Blocker:** owner/repo#7")}, nil, "MALFORMED"},
		{"a record nobody re-verified", []string{record}, []string{"--today", "2026-09-09", "--verify-max-age-days", "7"}, "STALE"},
		{"an authority blocker nobody was asked about", []string{commentJSON(t, "devantler", recordHead+"**Blocker:** approve the upgrade | authority | last-verified 2026-09-01: waiting")}, nil, "NO-ASK"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, out := runInput(t, "["+digestPull("5", blockedLabel, tc.comments...)+"]", append([]string{"--parked-digest"}, tc.extra...)...)
			if code != 1 {
				t.Fatalf("code=%d, want 1; out:\n%s", code, out)
			}
			for _, want := range []string{"ACTIONABLE p#5  record=" + tc.verdict + "\n", "CHECKED labelled=1 parked=0 actionable=1\n"} {
				if !strings.Contains(out, want) {
					t.Fatalf("missing %q; out:\n%s", want, out)
				}
			}
			if strings.Contains(out, "PARKED") {
				t.Fatalf("a pull request without a valid record was reported parked; out:\n%s", out)
			}
		})
	}
}

func TestParkedDigestNeverReportsAnUnlabelledPullRequest(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+goodLine)
	for name, labels := range map[string]string{"an empty label set": `"labels":[],`, "another label": `"labels":[{"name":"dependencies"}],`} {
		t.Run(name, func(t *testing.T) {
			code, out := runInput(t, "["+digestPull("5", labels, record)+"]", "--parked-digest")
			if code != 0 || out != "CHECKED labelled=0 parked=0 actionable=0\n" {
				t.Fatalf("code=%d out:\n%s", code, out)
			}
		})
	}
}

func TestParkedDigestReportsAnAuthorityBlockerThatWasAsked(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+"**Blocker:** approve the upgrade | authority | last-verified 2026-09-01: waiting | asked slack 2026-08-30")
	code, out := runInput(t, "["+digestPull("5", blockedLabel, record)+"]", "--parked-digest")
	if code != 0 || !strings.Contains(out, "PARKED     p#5  [authority]  approve the upgrade\n") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// One pull request's missing record must not hide another's valid park, and
// the closing line must account for every labelled pull request read.
func TestParkedDigestReportsEachPullRequestOnItsOwn(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+goodLine)
	payload := "[" + digestPull("5", blockedLabel, record) + "," + digestPull("6", blockedLabel) + "," + digestPull("7", `"labels":[],`) + "]"
	code, out := runInput(t, payload, "--parked-digest")
	if code != 1 {
		t.Fatalf("code=%d, want 1; out:\n%s", code, out)
	}
	for _, want := range []string{"PARKED     p#5  [upstream, blocker state not read]  owner/repo#7\n", "ACTIONABLE p#6  record=MISSING\n", "CHECKED labelled=2 parked=1 actionable=1\n"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q; out:\n%s", want, out)
		}
	}
	if strings.Contains(out, "p#7") {
		t.Fatalf("an unlabelled pull request was reported; out:\n%s", out)
	}
}

// The digest answers one question, about pull requests. An issue finding
// belongs to the verdict report and must neither appear nor change the answer.
func TestParkedDigestIsNotChangedByIssueFindings(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+goodLine)
	issues := `{"repo":"p","number":1,"labels":[],"type":null,"body":"` + goodLine + `"},{"repo":"p","number":2,"labels":[{"name":"blocked"}],"body":"no record"}`
	payload := "[" + issues + "," + digestPull("5", blockedLabel, record) + "]"
	// CONTROL: the same payload has findings in the verdict report.
	if code, out := runInput(t, payload); code != 1 || !strings.Contains(out, "UNLABELLED p#1") || !strings.Contains(out, "MISSING    p#2") {
		t.Fatalf("control: code=%d out:\n%s", code, out)
	}
	code, out := runInput(t, payload, "--parked-digest")
	if code != 0 || out != "PARKED     p#5  [upstream, blocker state not read]  owner/repo#7\nCHECKED labelled=1 parked=1 actionable=0\n" {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// The blocker is printed for an operator, so it is bounded like every other
// reported record field.
func TestParkedDigestBoundsTheBlockerItPrints(t *testing.T) {
	long := "owner/repo#7 " + strings.Repeat("x", 300)
	record := commentJSON(t, "devantler", recordHead+"**Blocker:** "+long+" | upstream | last-verified 2026-09-01: open")
	code, out := runInput(t, "["+digestPull("5", blockedLabel, record)+"]", "--parked-digest")
	if code != 0 {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	row := strings.SplitN(out, "\n", 2)[0]
	if !strings.HasPrefix(row, "PARKED     p#5  [upstream, blocker state not read]  owner/repo#7 xxx") || len([]rune(row)) > 165 {
		t.Fatalf("row is not bounded: %d runes: %q", len([]rune(row)), row)
	}
}

func TestParkedDigestRefusesToBeCombinedWithAnotherReport(t *testing.T) {
	for _, other := range []string{"--ask-digest", "--quiet"} {
		if code, out := runInput(t, "[]", "--parked-digest", other); code != 2 || !strings.Contains(out, "--parked-digest") {
			t.Fatalf("%s: code=%d out:\n%s", other, code, out)
		}
	}
}

// An unreadable payload is UNKNOWN in every mode: the digest must not turn a
// read that failed into "nothing is parked".
func TestParkedDigestIsUnknownWhenTheInputCannotBeRead(t *testing.T) {
	for name, payload := range map[string]string{
		"not JSON":                            "{",
		"a labelled pull without comments":    `[{"repo":"p","number":5,"pull_request":{},"labels":[{"name":"blocked"}],"body":"x"}]`,
		"a pull request with no labels array": `[{"repo":"p","number":5,"pull_request":{},"body":"x","comments":[]}]`,
		"a pull request without its number":   `[{"repo":"p","pull_request":{},"labels":[{"name":"blocked"}],"body":"x","comments":[]}]`,
	} {
		t.Run(name, func(t *testing.T) {
			if code, out := runInput(t, payload, "--parked-digest"); code != 2 || strings.Contains(out, "CHECKED") {
				t.Fatalf("code=%d out:\n%s", code, out)
			}
		})
	}
}

func TestHelpDescribesTheParkedDigest(t *testing.T) {
	for _, want := range []string{"--parked-digest", "PARKED", "ACTIONABLE", "CHECKED"} {
		if !strings.Contains(help, want) {
			t.Fatalf("help does not mention %q", want)
		}
	}
}

// A park outlives its blocker unless something reads the blocker. An --input
// record states the blocker's state, and a closed one is work again.
func TestParkedDigestDoesNotHonourAParkWhoseBlockerClosed(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+goodLine)
	pull := func(state string) string {
		return "[" + digestPull("5", blockedLabel+state, record) + "]"
	}
	if code, out := runInput(t, pull(`"blocker_state":"closed",`), "--parked-digest"); code != 1 || out != "ACTIONABLE p#5  record=BLOCKER-CLOSED  owner/repo#7\nCHECKED labelled=1 parked=0 actionable=1\n" {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	// CONTROL: the same record with its blocker still open stays parked.
	if code, out := runInput(t, pull(`"blocker_state":"open",`), "--parked-digest"); code != 0 || out != "PARKED     p#5  [upstream, blocker open]  owner/repo#7\nCHECKED labelled=1 parked=1 actionable=0\n" {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	// A state that is neither is not a state: UNKNOWN, never parked.
	for _, state := range []string{`"blocker_state":"merged",`, `"blocker_state":"OPEN",`} {
		if code, out := runInput(t, pull(state), "--parked-digest"); code != 2 || strings.Contains(out, "PARKED") || strings.Contains(out, "CHECKED") {
			t.Fatalf("%s: code=%d out:\n%s", state, code, out)
		}
	}
}

// An authority blocker waits on a decision. Whatever object it names closing
// does not make that decision, so its park is not read through the object.
func TestParkedDigestDoesNotReadAnAuthorityBlockersState(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+"**Blocker:** owner/repo#7 | authority | last-verified 2026-09-01: waiting | asked slack 2026-08-30")
	code, out := runInput(t, "["+digestPull("5", blockedLabel+`"blocker_state":"closed",`, record)+"]", "--parked-digest")
	if code != 0 || !strings.Contains(out, "PARKED     p#5  [authority]  owner/repo#7\n") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// serveDigest answers the org reads for platform#900 carrying one record with
// the given blocker, and the blocker reads listed in states. It returns the
// blocker endpoints that were read.
func serveDigest(t *testing.T, blocker string, states map[string]string, failing string) *[]string {
	t.Helper()
	record := commentJSON(t, "devantler", recordHead+"**Blocker:** "+blocker+" | upstream | last-verified 2026-09-01: open")
	var read []string
	original := forgeRead
	t.Cleanup(func() { forgeRead = original })
	forgeRead = func(endpoint string) ([]byte, error) {
		switch endpoint {
		case searchEndpoint("o"):
			return []byte(searchPage()), nil
		case pullEndpoint("o"):
			return []byte(searchPage(forgeParkedPull(t, "platform"))), nil
		case "repos/o/platform/issues/900":
			return []byte(counted(1)), nil
		case "repos/o/platform/issues/900/comments?per_page=100":
			return []byte("[" + record + "]"), nil
		}
		answer, known := states[endpoint]
		if !known {
			t.Errorf("unexpected read %q", endpoint)
			return nil, errors.New("unexpected read")
		}
		read = append(read, endpoint)
		if endpoint == failing {
			return []byte(answer), errors.New("exit status 1")
		}
		return []byte(answer), nil
	}
	return &read
}

func runOrgDigest(t *testing.T) (int, string) {
	t.Helper()
	var out, stderr bytes.Buffer
	code := run([]string{"--org", "o", "--today", "2026-09-01", "--parked-digest"}, strings.NewReader(""), &out, &stderr)
	return code, out.String() + stderr.String()
}

func TestParkedDigestReadsTheBlockerOfThisOrganizationFromTheForge(t *testing.T) {
	for _, tc := range []struct {
		name, blocker, endpoint, answer string
		code                            int
		want                            string
	}{
		{"an open blocker in another repository", "o/ksail#7", "repos/o/ksail/issues/7", `{"number":7,"state":"open"}`, 0, "PARKED     platform#900  [upstream, blocker open]  o/ksail#7\n"},
		{"a closed blocker in another repository", "o/ksail#7", "repos/o/ksail/issues/7", `{"number":7,"state":"closed"}`, 1, "ACTIONABLE platform#900  record=BLOCKER-CLOSED  o/ksail#7\n"},
		{"the organization spelled in another case", "O/ksail#7", "repos/o/ksail/issues/7", `{"number":7,"state":"closed"}`, 1, "record=BLOCKER-CLOSED"},
		{"a bare reference is in the pull request's own repository", "#7", "repos/o/platform/issues/7", `{"number":7,"state":"closed"}`, 1, "ACTIONABLE platform#900  record=BLOCKER-CLOSED  #7\n"},
		{"a reference with closing punctuation", "o/ksail#7.", "repos/o/ksail/issues/7", `{"number":7,"state":"closed"}`, 1, "record=BLOCKER-CLOSED"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			read := serveDigest(t, tc.blocker, map[string]string{tc.endpoint: tc.answer}, "")
			code, out := runOrgDigest(t)
			if code != tc.code || !strings.Contains(out, tc.want) || len(*read) != 1 {
				t.Fatalf("code=%d, want %d and %q; reads=%v out:\n%s", code, tc.code, tc.want, *read, out)
			}
		})
	}
}

// Another owner's repository is outside what a sweep may query, and prose
// names nothing to query. Neither is read, and neither is called open.
func TestParkedDigestNeverReadsABlockerItMayNotOrCannotName(t *testing.T) {
	for name, blocker := range map[string]string{
		"another owner":                 "other/repo#7",
		"a name that only starts alike": "o-fork/ksail#7",
		"a repository with no number":   "o/ksail",
	} {
		t.Run(name, func(t *testing.T) {
			read := serveDigest(t, blocker, nil, "")
			code, out := runOrgDigest(t)
			if code != 0 || len(*read) != 0 || !strings.Contains(out, "PARKED     platform#900  [upstream, blocker state not read]  ") || strings.Contains(out, "blocker open") {
				t.Fatalf("code=%d reads=%v out:\n%s", code, *read, out)
			}
		})
	}
}

// Each of these would read as an open blocker to a check that ignored it.
func TestParkedDigestIsUnknownWhenTheBlockerReadIsNotAnAnswer(t *testing.T) {
	const endpoint = "repos/o/ksail/issues/7"
	for _, tc := range []struct{ name, answer, failing, want string }{
		{"the read fails after printing an open blocker", `{"number":7,"state":"open"}`, endpoint, "forge read failed -- UNKNOWN"},
		{"the answer is another object", `{"number":8,"state":"open"}`, "", "carries no readable state"},
		{"the answer has no state", `{"number":7}`, "", "carries no readable state"},
		{"the state is neither open nor closed", `{"number":7,"state":"merged"}`, "", "carries no readable state"},
		{"the answer is an error body", `{"message":"Not Found"}`, "", "carries no readable state"},
		{"the answer is empty", ``, "", "carries no readable state"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			serveDigest(t, "o/ksail#7", map[string]string{endpoint: tc.answer}, tc.failing)
			if code, out := runOrgDigest(t); code != 2 || !strings.Contains(out, tc.want) || strings.Contains(out, "PARKED") || strings.Contains(out, "CHECKED") {
				t.Fatalf("code=%d, want 2 and %q; out:\n%s", code, tc.want, out)
			}
		})
	}
}

// The verdict report judges the record, not the blocker, and reads nothing
// more for it: only the digest spends a read per blocker.
func TestVerdictReportDoesNotReadBlockerStates(t *testing.T) {
	read := serveDigest(t, "o/ksail#7", map[string]string{"repos/o/ksail/issues/7": `{"number":7,"state":"closed"}`}, "")
	if code, out := runOrg(t); code != 0 || len(*read) != 0 {
		t.Fatalf("code=%d reads=%v out:\n%s", code, *read, out)
	}
}

// classify accepts a blocker that holds a reference anywhere in its text. Each
// of these names a closed blocker in a spelling that is not a bare reference,
// and each would stay parked if only a bare reference were read.
func TestParkedDigestFindsAClosedBlockerInsideALongerBlockerText(t *testing.T) {
	const closed = `{"number":7,"state":"closed"}`
	for name, tc := range map[string]struct{ blocker, endpoint string }{
		"the repository shorthand":      {"ksail#7", "repos/o/ksail/issues/7"},
		"a reference followed by a URL": {"o/ksail#7 https://github.com/o/ksail/issues/7", "repos/o/ksail/issues/7"},
		"a reference followed by prose": {"o/ksail#7 (fix pending release)", "repos/o/ksail/issues/7"},
		"a reference and other marks":   {"o/ksail#7!", "repos/o/ksail/issues/7"},
		"prose before a bare reference": {"see #7", "repos/o/platform/issues/7"},
	} {
		t.Run(name, func(t *testing.T) {
			read := serveDigest(t, tc.blocker, map[string]string{tc.endpoint: closed}, "")
			code, out := runOrgDigest(t)
			if code != 1 || len(*read) != 1 || !strings.Contains(out, "ACTIONABLE platform#900  record=BLOCKER-CLOSED  ") {
				t.Fatalf("code=%d reads=%v out:\n%s", code, *read, out)
			}
		})
	}
}

// Every blocker a record names is read. One open blocker beside a closed one
// does not keep the park, in either order.
func TestParkedDigestReadsEveryBlockerARecordNames(t *testing.T) {
	states := func(first, second string) map[string]string {
		return map[string]string{"repos/o/ksail/issues/7": `{"number":7,"state":"` + first + `"}`, "repos/o/ksail/issues/8": `{"number":8,"state":"` + second + `"}`}
	}
	for name, tc := range map[string]struct {
		first, second string
		code          int
		want          string
	}{
		"the second is closed": {"open", "closed", 1, "record=BLOCKER-CLOSED"},
		"the first is closed":  {"closed", "open", 1, "record=BLOCKER-CLOSED"},
		// CONTROL: both open stays parked, after two reads.
		"both are open": {"open", "open", 0, "PARKED     platform#900  [upstream, blocker open]  "},
	} {
		t.Run(name, func(t *testing.T) {
			read := serveDigest(t, "o/ksail#7 and the fix in o/ksail#8", states(tc.first, tc.second), "")
			code, out := runOrgDigest(t)
			if code != tc.code || !strings.Contains(out, tc.want) || (tc.code == 0 && len(*read) != 2) {
				t.Fatalf("code=%d reads=%v out:\n%s", code, *read, out)
			}
		})
	}
}

// A record that waits on the pull request it parks waits for ever, and one
// whose reference has no usable number names nothing. Neither is a park.
func TestParkedDigestRefusesABlockerThatCannotClear(t *testing.T) {
	for name, tc := range map[string]struct{ blocker, reason string }{
		"the pull request itself, bare":      {"#900", "BLOCKER-SELF"},
		"the pull request itself, in full":   {"o/platform#900", "BLOCKER-SELF"},
		"the pull request in another case":   {"o/Platform#900", "BLOCKER-SELF"},
		"a reference numbered zero":          {"#0", "BLOCKER-UNREADABLE"},
		"a number no pull request can carry": {"o/ksail#99999999999999999999", "BLOCKER-UNREADABLE"},
	} {
		t.Run(name, func(t *testing.T) {
			read := serveDigest(t, tc.blocker, nil, "")
			code, out := runOrgDigest(t)
			if code != 1 || len(*read) != 0 || !strings.Contains(out, "ACTIONABLE platform#900  record="+tc.reason+"  ") || strings.Contains(out, "PARKED") {
				t.Fatalf("code=%d reads=%v out:\n%s", code, *read, out)
			}
		})
	}
}

// The note is printed before the blocker text, and a line separator inside the
// text is replaced, so a record's own words can neither imitate the note nor
// start a second row.
func TestParkedDigestRowCannotBeForgedByTheBlockerText(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+"**Blocker:** owner/repo#7  [upstream, blocker open] PARKED     evil#1  [authority]  x | upstream | last-verified 2026-09-01: open")
	code, out := runInput(t, "["+digestPull("5", blockedLabel, record)+"]", "--parked-digest")
	if code != 0 || !strings.HasPrefix(out, "PARKED     p#5  [upstream, blocker state not read]  owner/repo#7") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	if strings.ContainsAny(out, "  ") || strings.Count(out, "\n") != 2 {
		t.Fatalf("the blocker text started another row; out:\n%q", out)
	}
}

// A record written before the class token existed is an upstream blocker
// unless it says otherwise, and its blocker is read like any other.
func TestParkedDigestReadsTheBlockerOfARecordWithoutAClassToken(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+"**Blocker:** o/ksail#7 | last-verified 2026-09-01: open")
	original := forgeRead
	t.Cleanup(func() { forgeRead = original })
	forgeRead = func(endpoint string) ([]byte, error) {
		switch endpoint {
		case searchEndpoint("o"):
			return []byte(searchPage()), nil
		case pullEndpoint("o"):
			return []byte(searchPage(forgeParkedPull(t, "platform"))), nil
		case "repos/o/platform/issues/900":
			return []byte(counted(1)), nil
		case "repos/o/platform/issues/900/comments?per_page=100":
			return []byte("[" + record + "]"), nil
		case "repos/o/ksail/issues/7":
			return []byte(`{"number":7,"state":"closed"}`), nil
		}
		t.Errorf("unexpected read %q", endpoint)
		return nil, errors.New("unexpected read")
	}
	if code, out := runOrgDigest(t); code != 1 || !strings.Contains(out, "record=BLOCKER-CLOSED") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// A report that could not be written is not a report: no verdict leaves.
func TestParkedDigestIsUnknownWhenItsReportCannotBeWritten(t *testing.T) {
	record := commentJSON(t, "devantler", recordHead+goodLine)
	var stderr bytes.Buffer
	code := run([]string{"--input", "-", "--today", "2026-09-01", "--verify-max-age-days", "999999999", "--parked-digest"}, strings.NewReader("["+digestPull("5", blockedLabel, record)+"]"), failingWriter{}, &stderr)
	if code != 2 {
		t.Fatalf("code=%d stderr:\n%s", code, stderr.String())
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("closed pipe") }
