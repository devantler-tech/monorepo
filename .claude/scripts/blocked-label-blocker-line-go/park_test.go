package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
)

// fakeForge is o/r#5 as park sees it: one record, its labels and its thread.
// Every write is logged, so a test can assert that a refusal touched nothing.
type fakeForge struct {
	t           *testing.T
	state       string
	pullRequest bool
	labels      []string
	noLabels    bool // the record carries no labels array at all
	comments    []comment
	nextID      int64
	writes      []string
	failRead    string // endpoint whose read fails
	failReadAt  int    // which read of failRead fails; 0 means every one
	reads       map[string]int
	login       string          // who gh is signed in as
	number      int64           // the number the target record answers with
	nullPull    bool            // the record carries "pull_request": null
	failWrite   map[string]bool // "METHOD endpoint-suffix" whose write fails
	dropWrite   map[string]bool // write that returns success and changes nothing
}

const (
	parkIssuePath    = "repos/o/r/issues/5"
	parkCommentsPath = parkIssuePath + "/comments?per_page=100"
)

func newFakeForge(t *testing.T) *fakeForge {
	t.Helper()
	f := &fakeForge{t: t, state: "open", pullRequest: true, nextID: 100, failWrite: map[string]bool{}, dropWrite: map[string]bool{}, reads: map[string]int{}, login: recordAuthor, number: 5}
	originalRead, originalWrite := forgeRead, forgeWrite
	t.Cleanup(func() { forgeRead, forgeWrite = originalRead, originalWrite })
	forgeRead = f.read
	forgeWrite = f.write
	return f
}

func (f *fakeForge) read(endpoint string) ([]byte, error) {
	f.reads[endpoint]++
	if endpoint == f.failRead && (f.failReadAt == 0 || f.failReadAt == f.reads[endpoint]) {
		return nil, errors.New("exit status 1")
	}
	switch endpoint {
	case "user":
		raw, _ := json.Marshal(map[string]string{"login": f.login})
		return raw, nil
	case parkIssuePath:
		record := map[string]any{"number": f.number, "state": f.state, "comments": len(f.comments)}
		if !f.noLabels {
			labels := []map[string]string{}
			for _, name := range f.labels {
				labels = append(labels, map[string]string{"name": name})
			}
			record["labels"] = labels
		}
		if f.pullRequest {
			record["pull_request"] = map[string]string{"url": "x"}
		}
		if f.nullPull {
			record["pull_request"] = nil
		}
		raw, _ := json.Marshal(record)
		return raw, nil
	case parkCommentsPath:
		raw, _ := json.Marshal(append([]comment{}, f.comments...))
		return raw, nil
	}
	f.t.Errorf("unexpected read %q", endpoint)
	return nil, errors.New("unexpected read")
}

func (f *fakeForge) write(method, endpoint string, payload []byte) error {
	key := method + " " + endpoint
	f.writes = append(f.writes, key)
	if f.failWrite[key] {
		return errors.New("exit status 1")
	}
	if f.dropWrite[key] {
		return nil
	}
	var body struct {
		Body   string   `json:"body"`
		Labels []string `json:"labels"`
	}
	if json.Unmarshal(payload, &body) != nil {
		f.t.Errorf("unreadable payload for %s", key)
	}
	switch {
	case key == "POST "+parkIssuePath+"/comments":
		f.add(recordAuthor, body.Body)
	case key == "POST "+parkIssuePath+"/labels":
		f.labels = append(f.labels, body.Labels...)
	case method == "PATCH" && strings.HasPrefix(endpoint, "repos/o/r/issues/comments/"):
		id, _ := strconv.ParseInt(strings.TrimPrefix(endpoint, "repos/o/r/issues/comments/"), 10, 64)
		for i := range f.comments {
			if f.comments[i].ID == id {
				f.comments[i].Body = body.Body
				return nil
			}
		}
		f.t.Errorf("edit of unknown comment %d", id)
	default:
		f.t.Errorf("unexpected write %q", key)
	}
	return nil
}

func (f *fakeForge) add(login, body string) int64 {
	c := comment{ID: f.nextID, Body: body}
	c.User.Login = login
	f.nextID++
	f.comments = append(f.comments, c)
	return c.ID
}

// park runs the subcommand against owner o, as every case but the owner ones does.
func park(args ...string) (int, string, string) {
	if len(args) != 1 || args[0] != "--help" {
		args = append([]string{"--org", "o"}, args...)
	}
	return parkRaw(args...)
}

func parkRaw(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := run(append([]string{"park"}, args...), strings.NewReader(""), &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

const (
	oldRecord    = disclosurePrefix + "Agentic Engineer\n\n" + recordMarker + "\n\n**Blocker:** o/other#7 | upstream | last-verified 2026-09-01: open then\n"
	composedLine = "**Blocker:** o/other#7 | upstream | last-verified 2026-10-06: still open"
)

func (f *fakeForge) assertParked(t *testing.T, records int) {
	t.Helper()
	got := parkRecords(f.comments)
	if len(got) != records || got[len(got)-1] != composedLine {
		t.Errorf("records = %q, want %d ending in the composed line", got, records)
	}
	if len(f.labels) != 1 || f.labels[0] != "blocked" {
		t.Errorf("labels = %q, want exactly blocked", f.labels)
	}
}

func TestParkWritesTheRecordAndTheLabelTogether(t *testing.T) {
	f := newFakeForge(t)
	f.add("renovate[bot]", "rebased")
	code, stdout, stderr := park(upstreamArgs...)
	if code != 0 || !strings.HasPrefix(stdout, "PARKED o/r#5 record posted, blocked label on\n"+composedLine) {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	f.assertParked(t, 1)
	if want := "POST " + parkIssuePath + "/comments,POST " + parkIssuePath + "/labels"; strings.Join(f.writes, ",") != want {
		t.Errorf("writes = %q, want the record first and the label second (%q)", f.writes, want)
	}
}

func TestParkEditsTheExistingRecordInPlace(t *testing.T) {
	f := newFakeForge(t)
	id := f.add(recordAuthor, oldRecord)
	f.labels = []string{"Blocked"}
	code, stdout, stderr := park(upstreamArgs...)
	if code != 0 || !strings.Contains(stdout, "record updated") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if want := "PATCH repos/o/r/issues/comments/" + strconv.FormatInt(id, 10); strings.Join(f.writes, ",") != want {
		t.Errorf("writes = %q, want only %q: an already labelled target needs no label write", f.writes, want)
	}
	if got := parkRecords(f.comments); len(got) != 1 || got[0] != composedLine {
		t.Errorf("records = %q, want the one record rewritten", got)
	}
}

// A marker comment from anyone else is data, as it is to the sweep: it is
// neither edited nor counted, and the deployment's own record is posted.
func TestParkIgnoresAnotherAuthorsRecord(t *testing.T) {
	f := newFakeForge(t)
	foreign := f.add("someone-else", oldRecord)
	if code, _, stderr := park(upstreamArgs...); code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	f.assertParked(t, 1)
	for _, c := range f.comments {
		if c.ID == foreign && c.Body != oldRecord {
			t.Error("another author's comment was edited")
		}
	}
}

func TestParkRefusalsWriteNothing(t *testing.T) {
	for name, tc := range map[string]struct {
		arrange func(*fakeForge)
		args    []string
		want    string
	}{
		"readiness work as the blocker": {func(*fakeForge) {}, replaced(upstreamArgs, "--blocker", "review and CI"), "its own unfinished work"},
		"the target as its own blocker": {func(*fakeForge) {}, replaced(upstreamArgs, "--blocker", "o/r#5"), "its own blocker"},
		"an issue body line":            {func(*fakeForge) {}, append(append([]string{}, upstreamArgs...), "--line-only"), "compose --line-only"},
		"an issue":                      {func(f *fakeForge) { f.pullRequest = false }, upstreamArgs, "is an issue"},
		"a closed pull request":         {func(f *fakeForge) { f.state = "closed" }, upstreamArgs, "not open"},
		"two record comments": {func(f *fakeForge) {
			f.add(recordAuthor, oldRecord)
			f.add(recordAuthor, oldRecord)
		}, upstreamArgs, "already carries 2 record comments"},
		"another signed-in account": {func(f *fakeForge) { f.login = "some-app[bot]" }, upstreamArgs, "not proven to be signed in as devantler"},
		"a failed identity read":    {func(f *fakeForge) { f.failRead = "user" }, upstreamArgs, "not proven to be signed in"},
		"a null pull request field": {func(f *fakeForge) { f.pullRequest, f.nullPull = false, true }, upstreamArgs, "is an issue"},
		"another item answering":    {func(f *fakeForge) { f.number = 6 }, upstreamArgs, "UNKNOWN"},
		"a record with no state":    {func(f *fakeForge) { f.state = "" }, upstreamArgs, "UNKNOWN"},
		"an existing record with no id": {func(f *fakeForge) {
			f.add(recordAuthor, oldRecord)
			f.comments[0].ID = 0
		}, upstreamArgs, "carries no id"},
		"a failed target read":    {func(f *fakeForge) { f.failRead = parkIssuePath }, upstreamArgs, "UNKNOWN"},
		"a record without labels": {func(f *fakeForge) { f.noLabels = true }, upstreamArgs, "UNKNOWN"},
		"a failed thread read":    {func(f *fakeForge) { f.failRead = parkCommentsPath }, upstreamArgs, "UNKNOWN"},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeForge(t)
			tc.arrange(f)
			code, stdout, stderr := park(tc.args...)
			if code != 2 || stdout != "" || !strings.Contains(stderr, tc.want) || !strings.Contains(stderr, "nothing written") {
				t.Errorf("code=%d stdout=%q stderr=%q, want exit 2 naming %q and nothing written", code, stdout, stderr, tc.want)
			}
			if len(f.writes) != 0 {
				t.Errorf("writes = %q, want none", f.writes)
			}
		})
	}
}

func TestParkNeverLabelsWhenTheRecordWriteFails(t *testing.T) {
	f := newFakeForge(t)
	f.failWrite["POST "+parkIssuePath+"/comments"] = true
	code, stdout, stderr := park(upstreamArgs...)
	if code != 2 || stdout != "" || !strings.Contains(stderr, "label was not touched") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if len(f.labels) != 0 || len(f.writes) != 1 {
		t.Errorf("labels=%q writes=%q, want no label and no label write", f.labels, f.writes)
	}
}

// The half-parked state a failed label write leaves is reported, and the same
// call finishes it without posting a second record.
func TestParkAgainFinishesAHalfParkedPullRequest(t *testing.T) {
	f := newFakeForge(t)
	f.failWrite["POST "+parkIssuePath+"/labels"] = true
	code, stdout, stderr := park(upstreamArgs...)
	if code != 2 || stdout != "" || !strings.Contains(stderr, "label is NOT added: run park again") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	f.failWrite = map[string]bool{}
	code, stdout, stderr = park(upstreamArgs...)
	if code != 0 || !strings.Contains(stdout, "record updated") {
		t.Fatalf("second call: code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	f.assertParked(t, 1)
}

func TestParkBelievesOnlyWhatReadsBack(t *testing.T) {
	t.Run("a label write that changed nothing", func(t *testing.T) {
		f := newFakeForge(t)
		f.dropWrite["POST "+parkIssuePath+"/labels"] = true
		code, stdout, stderr := park(upstreamArgs...)
		if code != 2 || stdout != "" || !strings.Contains(stderr, "label does not read back") {
			t.Errorf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
		}
	})
	t.Run("a record write that changed nothing", func(t *testing.T) {
		f := newFakeForge(t)
		f.dropWrite["POST "+parkIssuePath+"/comments"] = true
		code, stdout, stderr := park(upstreamArgs...)
		if code != 2 || stdout != "" || !strings.Contains(stderr, "reads back 0 record comment(s)") {
			t.Errorf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
		}
	})
}

func TestParkAuthorityRecordCarriesItsAsk(t *testing.T) {
	f := newFakeForge(t)
	code, stdout, stderr := park(authorityArgs...)
	if code != 0 || !strings.Contains(stdout, "| authority | last-verified 2026-10-06: token still expired | asked slack 2026-10-05") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if !strings.HasPrefix(f.comments[0].Body, disclosurePrefix+"Agentic Engineer\n") {
		t.Errorf("record body = %q, want the disclosure line first", f.comments[0].Body)
	}
}

func TestParkHelp(t *testing.T) {
	newFakeForge(t)
	code, stdout, _ := park("--help")
	if code != 0 || !strings.Contains(stdout, "The record is written first and the label second") {
		t.Errorf("code=%d stdout=%q", code, stdout)
	}
	if code, stdout, _ := park(append([]string{"--help"}, upstreamArgs...)...); code != 2 || stdout != "" {
		t.Errorf("help beside other arguments: code=%d stdout=%q, want a refusal", code, stdout)
	}
}

// park writes to one named owner. Without the pin, a mistyped target would put
// a comment and a label on somebody else's repository.
func TestParkWritesOnlyToTheNamedOwner(t *testing.T) {
	for name, args := range map[string][]string{
		"no owner named":       upstreamArgs,
		"another owner":        append([]string{"--org", "elsewhere"}, upstreamArgs...),
		"the owner twice":      append([]string{"--org", "o", "--org", "o"}, upstreamArgs...),
		"help beside an owner": {"--org", "o", "--help"},
		"a flag with no name":  append(append([]string{}, upstreamArgs...), "--org"),
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeForge(t)
			code, stdout, stderr := parkRaw(args...)
			if code != 2 || stdout != "" || !strings.Contains(stderr, "nothing written") {
				t.Errorf("code=%d stdout=%q stderr=%q, want a refusal with nothing written", code, stdout, stderr)
			}
			if len(f.writes) != 0 {
				t.Errorf("writes = %q, want none", f.writes)
			}
		})
	}
}

// Each write can return success and still not be there. Every such case ends
// unproven, and names what the writes reported so the next step is not a guess.
func TestParkReadBackFailuresAreUnproven(t *testing.T) {
	for name, tc := range map[string]struct {
		arrange func(*fakeForge)
		want    string
	}{
		"an edit that changed nothing": {func(f *fakeForge) {
			id := f.add(recordAuthor, oldRecord)
			f.dropWrite["PATCH repos/o/r/issues/comments/"+strconv.FormatInt(id, 10)] = true
		}, "do NOT run park again"},
		"a failed target read-back": {func(f *fakeForge) { f.failRead, f.failReadAt = parkIssuePath, 3 }, "the label is unproven"},
		"a failed thread read-back": {func(f *fakeForge) { f.failRead, f.failReadAt = parkCommentsPath, 2 }, "the record is unproven"},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeForge(t)
			tc.arrange(f)
			code, stdout, stderr := park(upstreamArgs...)
			if code != 2 || stdout != "" || !strings.Contains(stderr, tc.want) {
				t.Errorf("code=%d stdout=%q stderr=%q, want exit 2 naming %q", code, stdout, stderr, tc.want)
			}
		})
	}
}
