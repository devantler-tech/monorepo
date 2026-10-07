package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Parking a pull request is two writes: the blocked label and the one record
// comment. Done by hand they came apart -- a label with no record is skipped
// by every lane for ever, and a record with no label is re-diagnosed every run
// (#3879). park makes both in one call and reports success only after reading
// both back, so one run cannot leave half of a parking behind unnoticed.
const parkHelp = `Park a pull request: write its one blocker record and add the blocked label.

  park --org <owner> --target <owner/repo#N> --kind upstream  --blocker <owner/repo#N> --result <text>
  park --org <owner> --target <owner/repo#N> --kind authority --blocker <what only the maintainer can do>
       --result <text> --asked <pr|slack|session> <YYYY-MM-DD>
  park --org <owner> --target <owner/repo#N> --kind outcome   --blocker <the event waited on, in words> --result <text>

--org is required and names the one owner park may write to: a target under
any other owner is refused, so a mistyped target cannot put a comment and a
label on a repository outside the portfolio.

The record is the one compose prints, with the same refusals (compose --help);
--actor selects the disclosure line. --line-only is refused: an issue keeps its
record in its body, so compose --line-only is the tool there.

The target must be an open pull request. Its existing record comment is edited
in place and its whole body replaced, so prose added to it by hand is lost; a
new one is posted only when it has none. gh must be signed in as the record
author (devantler): a record posted by anyone else is not read as one, so park
refuses before writing. The record is written first and the label second, so a
failure in between leaves a pull request that is still worked, never one
parked with nothing to say why. When only the label write failed, running park
again with the same arguments finishes the job: it edits the same comment and
adds the label. Success is reported only after both are read back from the
forge.

Exit: 0 parked, the label and exactly one conforming record read back (or this
        help, when --help is the only argument);
      2 refused or unproven: the message says what, if anything, was written.
`

// forgeWrite is the one place park changes the forge; tests replace it.
var forgeWrite = func(method, endpoint string, payload []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "gh", "api", "--method", method, endpoint, "--input", "-")
	command.Stdin = bytes.NewReader(payload)
	return command.Run()
}

// parkTarget is what one read of the target says about it.
type parkTarget struct {
	Number      int64           `json:"number"`
	State       string          `json:"state"`
	PullRequest json.RawMessage `json:"pull_request"`
	Labels      *[]struct {
		Name string `json:"name"`
	} `json:"labels"`
}

func (t parkTarget) labelled() bool {
	for _, label := range *t.Labels {
		if strings.EqualFold(label.Name, "blocked") {
			return true
		}
	}
	return false
}

// readParkTarget reads the target and refuses a record that is not the item
// asked for or lacks a fact the decision needs: an absent labels array read as
// "no label" would report a parked pull request as unparked.
func readParkTarget(path string, number int64) (parkTarget, error) {
	var target parkTarget
	raw, err := forgeRead(path)
	if err != nil {
		return target, errors.New("could not read the target -- UNKNOWN")
	}
	if json.Unmarshal(raw, &target) != nil || target.Number != number || target.Labels == nil || target.State == "" {
		return target, errors.New("the target's record is unreadable -- UNKNOWN")
	}
	return target, nil
}

// ownRecords returns this deployment's record comments on the thread, by the
// same test the sweep applies.
func ownRecords(comments []comment) []comment {
	var own []comment
	for _, c := range comments {
		if len(parkRecords([]comment{c})) == 1 {
			own = append(own, c)
		}
	}
	return own
}

func parkRun(args []string, stdout, stderr io.Writer) int {
	refuse := func(written string, err error) int {
		_, _ = fmt.Fprintln(stderr, "blocked-label-blocker-line.sh park:", err, "--", written)
		return 2
	}
	const nothing = "nothing written"
	// --org belongs to park alone; everything else is the composer's to judge.
	org, orgs := "", 0
	var rest []string
	for i := 0; i < len(args); i++ {
		if args[i] != "--org" {
			rest = append(rest, args[i])
			continue
		}
		if i+1 >= len(args) {
			return refuse(nothing, errors.New("--org needs a value"))
		}
		i++
		org = args[i]
		orgs++
	}
	c, wantsHelp, err := composeArguments(rest)
	if err != nil {
		return refuse(nothing, err)
	}
	if wantsHelp && orgs != 0 {
		return refuse(nothing, errors.New("--help must be the only argument"))
	}
	if wantsHelp {
		if _, err := io.WriteString(stdout, parkHelp); err != nil {
			return refuse(nothing, fmt.Errorf("could not write the help: %w", err))
		}
		return 0
	}
	if orgs != 1 {
		return refuse(nothing, errors.New("--org <owner> is required, once: it names the one owner park may write to"))
	}
	if c.lineOnly {
		return refuse(nothing, errors.New("--line-only is for an issue body: use compose --line-only"))
	}
	defaults := defaultOptions()
	line, body, err := composeRecord(c, defaults.maxAge, defaults.verifyMaxAge)
	if err != nil {
		return refuse(nothing, err)
	}
	// composeRecord accepted the target, so it is exactly owner/repo#N.
	m := trackedItemRE.FindStringSubmatch(c.target)
	number, err := strconv.ParseInt(m[3], 10, 64)
	if err != nil {
		return refuse(nothing, errors.New("--target names an unusable number"))
	}
	if m[1] != org {
		return refuse(nothing, fmt.Errorf("the target is under %q, not --org %q: park writes to one owner only", m[1], org))
	}
	item := issue{Repo: m[2], Number: number}
	path, err := pullPath(m[1], item.Repo, number)
	if err != nil {
		return refuse(nothing, err)
	}
	// A record counts only when its author is recordAuthor. Posted under any other
	// login it would never read back, and every further call would post another.
	var viewer struct {
		Login string `json:"login"`
	}
	if raw, err := forgeRead("user"); err != nil || json.Unmarshal(raw, &viewer) != nil || viewer.Login != recordAuthor {
		return refuse(nothing, fmt.Errorf("gh is not proven to be signed in as %s, the only author whose record is read", recordAuthor))
	}
	target, err := readParkTarget(path, number)
	if err != nil {
		return refuse(nothing, err)
	}
	if len(target.PullRequest) == 0 || string(target.PullRequest) == "null" {
		return refuse(nothing, errors.New("the target is an issue, which keeps its record in its body: use compose --line-only"))
	}
	if target.State != "open" {
		return refuse(nothing, errors.New("the target is not open, so there is nothing to park"))
	}
	comments, err := forgeComments(m[1], item)
	if err != nil {
		return refuse(nothing, err)
	}
	existing := ownRecords(comments)
	if len(existing) > 1 {
		return refuse(nothing, fmt.Errorf("the target already carries %d record comments: delete all but one, then park again", len(existing)))
	}
	payload, err := json.Marshal(map[string]string{"body": body})
	if err != nil {
		return refuse(nothing, errors.New("could not encode the record"))
	}
	action := "posted"
	if len(existing) == 1 {
		if existing[0].ID <= 0 {
			return refuse(nothing, errors.New("the existing record comment carries no id -- UNKNOWN"))
		}
		action = "updated"
		err = forgeWrite("PATCH", "repos/"+m[1]+"/"+item.Repo+"/issues/comments/"+strconv.FormatInt(existing[0].ID, 10), payload)
	} else {
		err = forgeWrite("POST", path+"/comments", payload)
	}
	if err != nil {
		return refuse("the record write failed and may or may not have landed; the label was not touched", errors.New("could not write the record"))
	}
	if !target.labelled() {
		if forgeWrite("POST", path+"/labels", []byte(`{"labels":["blocked"]}`)) != nil {
			return refuse("the record is "+action+" but the label is NOT added: run park again", errors.New("could not add the blocked label"))
		}
	}
	// Both writes returned. Neither is believed until the forge shows it.
	after, err := readParkTarget(path, number)
	if err != nil {
		return refuse("the record is "+action+"; the label is unproven", err)
	}
	if !after.labelled() {
		return refuse("the record is "+action+" but the label does not read back: run park again", errors.New("the blocked label is missing"))
	}
	comments, err = forgeComments(m[1], item)
	if err != nil {
		return refuse("the record is "+action+" and the label is on; the record is unproven", err)
	}
	if records := parkRecords(comments); len(records) != 1 || records[0] != line {
		return refuse("the record write returned ("+action+") and the label is on; do NOT run park again before reading the thread", fmt.Errorf("the thread reads back %d record comment(s), not the one composed", len(records)))
	}
	if _, err := fmt.Fprintf(stdout, "PARKED %s record %s, blocked label on\n%s\n", c.target, action, line); err != nil {
		return refuse("the record is "+action+" and the label is on", fmt.Errorf("could not write the result: %w", err))
	}
	return 0
}
