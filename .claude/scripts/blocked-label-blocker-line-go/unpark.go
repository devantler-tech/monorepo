package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Unparking preserves the comment and its edit history instead of requiring
// an irreversible comment deletion (#4364). The caller still verifies that
// the blocker cleared and that it may drive this PR; this helper grants no
// ownership, readiness or merge exception.
const unparkHelp = `Clear a verified blocker without deleting its record comment.

  unpark --org <owner> --target <owner/repo#N> --result <live-check result>
         [--actor engineer|improver]

First verify the blocker has cleared and that you may drive this pull request.
The target must be an open PR under the declared owner. The authenticated
record author must be devantler. Exactly one trusted record is cleared in
place, retaining its previous text; only after that edit reads back is the
blocked label removed. No comment or unrelated label is deleted.

An already cleared record is reused on retry and by park. A cleared record
cannot park a PR if its label returns without a new verified blocker. Success
requires fresh readback of both the record and labels. A partial write is
reported as UNKNOWN; inspect it before retrying. This does not promote or
merge the PR, or change its review, CI or ownership requirements.

Exit: 0 cleared and unlabelled (or help); 2 refused or unproven.
`

func unparkRun(args []string, stdout, stderr io.Writer) int {
	reuseKeptPages = false
	refuse := func(written string, err error) int {
		_, _ = fmt.Fprintln(stderr, "blocked-label-blocker-line.sh unpark:", err, "--", written)
		return 2
	}
	const nothing = "nothing written"
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		if _, err := io.WriteString(stdout, unparkHelp); err != nil {
			return refuse(nothing, err)
		}
		return 0
	}
	values := map[string]string{"--actor": "engineer"}
	seen := map[string]bool{}
	for i := 0; i < len(args); i++ {
		name := args[i]
		if name != "--org" && name != "--target" && name != "--result" && name != "--actor" {
			return refuse(nothing, fmt.Errorf("unknown argument %q", name))
		}
		if seen[name] || i+1 >= len(args) {
			return refuse(nothing, fmt.Errorf("%s needs exactly one value", name))
		}
		i++
		values[name], seen[name] = args[i], true
	}
	for _, name := range []string{"--org", "--target", "--result"} {
		if !seen[name] {
			return refuse(nothing, fmt.Errorf("%s is required", name))
		}
	}
	org, targetName := values["--org"], values["--target"]
	disclosure, actorOK := actors[values["--actor"]]
	if !trackedItem(targetName) || !oneLine(values["--result"]) || !actorOK {
		return refuse(nothing, errors.New("target, one-line result or actor is invalid"))
	}
	ref := trackedItemRE.FindStringSubmatch(targetName)
	if ref[1] != org {
		return refuse(nothing, errors.New("target is outside the declared owner"))
	}
	number, err := strconv.ParseInt(ref[3], 10, 64)
	if err != nil {
		return refuse(nothing, errors.New("target number is unusable"))
	}
	path, err := pullPath(org, ref[2], number)
	if err != nil {
		return refuse(nothing, err)
	}
	var viewer struct {
		Login string `json:"login"`
	}
	if raw, err := forgeRead("user"); err != nil || json.Unmarshal(raw, &viewer) != nil || viewer.Login != recordAuthor {
		return refuse(nothing, errors.New("record author identity is unproven -- UNKNOWN"))
	}
	target, err := readParkTarget(path, number)
	if err != nil {
		return refuse(nothing, err)
	}
	if target.State != "open" || len(target.PullRequest) == 0 || string(target.PullRequest) == "null" {
		return refuse(nothing, errors.New("target is not an open pull request"))
	}
	item := issue{Repo: ref[2], Number: number}
	comments, err := forgeComments(org, item)
	if err != nil {
		return refuse(nothing, err)
	}
	owned := ownRecords(comments)
	if len(owned) != 1 || owned[0].ID <= 0 {
		return refuse(nothing, errors.New("exactly one trusted record with a usable id is required"))
	}
	record := owned[0]
	body := record.Body
	if visibleRecord(body) != "**Blocker:** none" {
		body = fmt.Sprintf("%s%s\n\n%s\n\n**Blocker:** none\n\nCleared %s: %s\n\nPrevious record (historical):\n\n    %s\n",
			disclosurePrefix, disclosure, recordMarker, composeToday().Format("2006-01-02"), values["--result"],
			strings.ReplaceAll(strings.TrimSuffix(record.Body, "\n"), "\n", "\n    "))
		payload, err := json.Marshal(map[string]string{"body": body})
		if err != nil {
			return refuse(nothing, err)
		}
		if forgeWrite("PATCH", "repos/"+org+"/"+item.Repo+"/issues/comments/"+strconv.FormatInt(record.ID, 10), payload) != nil {
			return refuse("record edit may have landed; blocked label was not touched", errors.New("could not clear record -- UNKNOWN"))
		}
	}
	// Confirm the edit before removing a label. A dropped write must never
	// leave the old blocker ready to return with that label.
	verifyRecord := func() error {
		current, err := forgeComments(org, item)
		if err != nil {
			return err
		}
		records := ownRecords(current)
		if len(records) != 1 || records[0].ID != record.ID || records[0].Body != body || visibleRecord(records[0].Body) != "**Blocker:** none" {
			return errors.New("cleared record did not read back unchanged -- UNKNOWN")
		}
		return nil
	}
	if err := verifyRecord(); err != nil {
		return refuse("record edit is unproven; blocked label was not touched", err)
	}
	after, err := readParkTarget(path, number)
	if err != nil || after.State != "open" {
		return refuse("record is cleared; blocked label was not touched", errors.New("target readback is unproven -- UNKNOWN"))
	}
	if after.labelled() {
		if forgeWrite("DELETE", path+"/labels/blocked", []byte(`{}`)) != nil {
			return refuse("record is cleared; blocked label removal is unproven", errors.New("could not remove blocked label -- UNKNOWN"))
		}
	}
	after, err = readParkTarget(path, number)
	if err != nil || after.State != "open" || after.labelled() {
		return refuse("record is cleared; blocked label removal is unproven", errors.New("blocked label readback failed -- UNKNOWN"))
	}
	if err := verifyRecord(); err != nil {
		return refuse("blocked label is off; record is unproven", err)
	}
	if _, err := fmt.Fprintf(stdout, "UNPARKED %s record %d preserved and cleared, blocked label off\n", targetName, record.ID); err != nil {
		return refuse("record is cleared and blocked label is off", err)
	}
	return 0
}
