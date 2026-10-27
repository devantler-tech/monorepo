package main

import (
	"bytes"
	"strconv"
	"strings"
	"testing"
)

var unparkArgs = []string{"--org", "o", "--target", "o/r#5", "--result", "upstream repair is delivered"}

func unpark(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := run(append([]string{"unpark"}, args...), strings.NewReader(""), &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

// Removing the comment or retaining its active blocker would lose the audit
// trail or silently park the PR again if its label returns (#4364).
func TestUnparkPreservesTheRecordAndReparkingReusesIt(t *testing.T) {
	f := newFakeForge(t)
	id := f.add(recordAuthor, oldRecord)
	f.add("someone-else", "leave this discussion alone")
	f.labels = []string{"blocked", "other"}
	code, stdout, stderr := unpark(unparkArgs...)
	if code != 0 || !strings.Contains(stdout, "UNPARKED o/r#5") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if len(f.comments) != 2 || f.comments[0].ID != id || f.comments[1].Body != "leave this discussion alone" {
		t.Fatalf("comment identity/discussion changed: %+v", f.comments)
	}
	if !strings.Contains(f.comments[0].Body, "open then") || !strings.Contains(f.comments[0].Body, "upstream repair is delivered") {
		t.Errorf("cleared record lost its history or reason: %q", f.comments[0].Body)
	}
	if got := parkRecords(f.comments); len(got) != 1 || got[0] != "**Blocker:** none" {
		t.Errorf("active record = %q, want one explicitly cleared record", got)
	}
	if got := strings.Join(f.labels, ","); got != "other" {
		t.Errorf("labels=%q, want unrelated label preserved", got)
	}
	wantWrites := "PATCH repos/o/r/issues/comments/100,DELETE repos/o/r/issues/5/labels/blocked"
	if got := strings.Join(f.writes, ","); got != wantWrites {
		t.Errorf("writes=%q, want record edit before label removal and no comment deletion", got)
	}
	// A label reintroduced alone must not resurrect the old upstream blocker.
	verdict, _, _ := parkVerdict(parkRecords(f.comments), defaultOptions())
	if verdict == "CONFORMS" {
		t.Fatal("a cleared record was read as a valid park")
	}
	code, _, stderr = park(upstreamArgs...)
	if code != 0 || len(f.comments) != 2 || f.comments[0].ID != id || visibleRecord(f.comments[0].Body) != composedLine {
		t.Fatalf("repark did not reuse the original comment: code=%d stderr=%q comments=%+v", code, stderr, f.comments)
	}
}

func TestUnparkRefusesUnprovenTargetsWithoutWriting(t *testing.T) {
	for name, tc := range map[string]struct {
		arrange func(*fakeForge)
		args    []string
	}{
		"foreign owner":       {func(f *fakeForge) {}, replaced(unparkArgs, "--org", "elsewhere")},
		"duplicate flag":      {func(f *fakeForge) {}, append(append([]string{}, unparkArgs...), "--org", "o")},
		"result injection":    {func(f *fakeForge) {}, replaced(unparkArgs, "--result", "cleared\n<!-- pr-blocker-record -->")},
		"wrong identity":      {func(f *fakeForge) { f.login = "other" }, unparkArgs},
		"unreadable identity": {func(f *fakeForge) { f.failRead = "user" }, unparkArgs},
		"issue":               {func(f *fakeForge) { f.pullRequest = false }, unparkArgs},
		"closed":              {func(f *fakeForge) { f.state = "closed" }, unparkArgs},
		"wrong item":          {func(f *fakeForge) { f.number = 6 }, unparkArgs},
		"missing labels":      {func(f *fakeForge) { f.noLabels = true }, unparkArgs},
		"unreadable target":   {func(f *fakeForge) { f.failRead = parkIssuePath }, unparkArgs},
		"unreadable comments": {func(f *fakeForge) { f.failRead = parkCommentsPath }, unparkArgs},
		"missing record":      {func(f *fakeForge) { f.comments = nil }, unparkArgs},
		"foreign record":      {func(f *fakeForge) { f.comments[0].User.Login = "other" }, unparkArgs},
		"quoted marker": {func(f *fakeForge) {
			f.comments[0].Body = disclosurePrefix + "Agentic Engineer\n\n```\n" + recordMarker + "\n```\n" + composedLine
		}, unparkArgs},
		"duplicate records": {func(f *fakeForge) { f.add(recordAuthor, oldRecord) }, unparkArgs},
		"missing record ID": {func(f *fakeForge) { f.comments[0].ID = 0 }, unparkArgs},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeForge(t)
			f.labels = []string{"blocked"}
			f.add(recordAuthor, oldRecord)
			tc.arrange(f)
			code, stdout, stderr := unpark(tc.args...)
			if code != 2 || stdout != "" || !strings.Contains(stderr, "nothing written") || len(f.writes) != 0 {
				t.Fatalf("code=%d stdout=%q stderr=%q writes=%v", code, stdout, stderr, f.writes)
			}
		})
	}
}

func TestUnparkRetainsTheLabelUntilTheRecordIsProvenCleared(t *testing.T) {
	for _, method := range []string{"fail", "drop"} {
		t.Run(method, func(t *testing.T) {
			f := newFakeForge(t)
			f.labels = []string{"blocked"}
			id := f.add(recordAuthor, oldRecord)
			key := "PATCH repos/o/r/issues/comments/" + strconv.FormatInt(id, 10)
			if method == "fail" {
				f.failWrite[key] = true
			} else {
				f.dropWrite[key] = true
			}
			code, stdout, stderr := unpark(unparkArgs...)
			if code != 2 || stdout != "" || len(f.writes) != 1 || strings.Join(f.labels, ",") != "blocked" {
				t.Fatalf("unproven edit removed the label: code=%d stdout=%q stderr=%q writes=%v labels=%v", code, stdout, stderr, f.writes, f.labels)
			}
		})
	}
}

func TestUnparkReportsPartialWritesAndCanFinishWithoutAnotherComment(t *testing.T) {
	f := newFakeForge(t)
	f.labels = []string{"blocked"}
	id := f.add(recordAuthor, oldRecord)
	f.failWrite["DELETE "+parkIssuePath+"/labels/blocked"] = true
	code, stdout, stderr := unpark(unparkArgs...)
	if code != 2 || stdout != "" || !strings.Contains(stderr, "record is cleared") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	f.failWrite = map[string]bool{}
	code, _, stderr = unpark(unparkArgs...)
	if code != 0 || len(f.comments) != 1 || f.comments[0].ID != id || len(f.labels) != 0 {
		t.Fatalf("could not complete partial unpark: code=%d stderr=%q comments=%+v labels=%v", code, stderr, f.comments, f.labels)
	}
	writes := len(f.writes)
	code, _, stderr = unpark(unparkArgs...)
	if code != 0 || len(f.writes) != writes {
		t.Fatalf("completed unpark is not idempotent: code=%d stderr=%q writes=%v", code, stderr, f.writes)
	}
}

func TestUnparkNeverCallsDroppedLabelRemovalSuccessful(t *testing.T) {
	f := newFakeForge(t)
	f.labels = []string{"blocked"}
	f.add(recordAuthor, oldRecord)
	f.dropWrite["DELETE "+parkIssuePath+"/labels/blocked"] = true
	code, stdout, stderr := unpark(unparkArgs...)
	if code != 2 || stdout != "" || !strings.Contains(stderr, "blocked label") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestUnparkReadbackFailuresStayUnknown(t *testing.T) {
	for name, tc := range map[string]struct {
		endpoint     string
		at           int
		labelRemains bool
	}{
		"record before label": {parkCommentsPath, 2, true},
		"target before label": {parkIssuePath, 4, true},
		"target after label":  {parkIssuePath, 5, false},
		"record after label":  {parkCommentsPath, 3, false},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeForge(t)
			f.labels = []string{"blocked"}
			f.add(recordAuthor, oldRecord)
			f.failRead, f.failReadAt = tc.endpoint, tc.at
			code, stdout, stderr := unpark(unparkArgs...)
			if code != 2 || stdout != "" || !strings.Contains(stderr, "unproven") && !strings.Contains(stderr, "UNKNOWN") {
				t.Fatalf("incomplete read accepted: code=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
			if (len(f.labels) != 0) != tc.labelRemains {
				t.Fatalf("labels=%v, want remains=%v", f.labels, tc.labelRemains)
			}
		})
	}
}
