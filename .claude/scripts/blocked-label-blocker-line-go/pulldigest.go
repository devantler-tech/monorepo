package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// The parked digest answers one question for a survey: which open pull
// requests have already reached the terminal state "parked on a named
// blocker", and which only look that way. Without it every stalled dependency
// pull request was reported as breakage on every run and re-diagnosed, though
// its blocker was already on record (#3288).
//
// The label alone never parks a pull request here. A row is PARKED only when
// the one record comment conforms and was re-verified recently, exactly as the
// verdict report judges it, and the blocker it names is not known to be
// closed. Anything else is ACTIONABLE and names what kept it there, so neither
// a label nobody backed with a record nor a park that outlived its blocker can
// hide work. The bracketed note stands before the blocker text, which is the
// record's own words and could otherwise imitate it.

// blockerReferenceRE finds every issue or pull request a blocker names:
// "owner/repo#N", "repo#N" for one in this organization, or "#N" for one in the
// parked pull request's own repository. classify accepts a blocker that holds a
// reference anywhere in its text, so every one is found, not only a blocker
// that is a single reference: a closed blocker must not escape behind a word
// of prose beside it.
var blockerReferenceRE = regexp.MustCompile(`(?:(?:([A-Za-z0-9._-]+)/)?([A-Za-z0-9._-]+))?#([0-9]+)`)

// recordBlocker returns the blocker and the class of a record classify
// accepted. A record without a class token is the earlier shape, which classify
// reads as an authority blocker only when it says so.
func recordBlocker(line string) (blocker, kind string) {
	head := strings.Split(strings.TrimPrefix(strings.Split(line, " | last-verified ")[0], "**Blocker:** "), " | ")
	kind = "upstream"
	if len(head) > 1 {
		kind = head[1]
	} else if strings.Contains(head[0], "maintainer authority") {
		kind = "authority"
	}
	return strings.TrimSpace(head[0]), kind
}

// forgeBlockerState reads whether one issue or pull request of this
// organization is open. The answer must be that of the object asked for and one
// of the forge's two states: anything else is UNKNOWN, never open.
func forgeBlockerState(org, repo string, number int64) (string, error) {
	path, err := pullPath(org, repo, number)
	if err != nil {
		return "", err
	}
	raw, err := forgeRead(path)
	if err != nil {
		return "", errors.New("forge read failed -- UNKNOWN, never zero")
	}
	var record struct {
		Number int64  `json:"number"`
		State  string `json:"state"`
	}
	if json.Unmarshal(raw, &record) != nil || record.Number != number || (record.State != "open" && record.State != "closed") {
		return "", fmt.Errorf("blocker %s#%d carries no readable state -- UNKNOWN", repo, number)
	}
	return record.State, nil
}

// blockerState reports what is known about the blocker of one parked pull
// request: "closed" when any issue or pull request it names has closed, "open"
// when every one that was read is open, "" when none could be read, "self" when
// it names the parked pull request itself and "unreadable" when a reference
// carries no usable number. Under --org only a reference inside the
// organization is read: another owner's repository is outside what a sweep may
// query. An --input record states the answer in "blocker_state".
func blockerState(item issue, blocker string, o options) (string, error) {
	if o.org == "" {
		switch item.BlockerState {
		case "", "open", "closed":
			return item.BlockerState, nil
		}
		return "", fmt.Errorf("pull request %s#%d carries an unreadable blocker_state -- UNKNOWN", item.Repo, item.Number)
	}
	text := urlRE.ReplaceAllString(blocker, " ")
	state := ""
	for _, at := range blockerReferenceRE.FindAllStringSubmatchIndex(text, -1) {
		// A match that continues a longer path or word names something else.
		if at[0] > 0 {
			if before := text[at[0]-1]; before == '/' || before == '.' || before == '_' || before == '-' || before >= '0' && before <= '9' || before >= 'A' && before <= 'Z' || before >= 'a' && before <= 'z' {
				continue
			}
		}
		group := func(i int) string {
			if at[2*i] < 0 {
				return ""
			}
			return text[at[2*i]:at[2*i+1]]
		}
		owner, repo := group(1), group(2)
		if owner != "" && !strings.EqualFold(owner, o.org) {
			continue
		}
		if repo == "" {
			repo = item.Repo
		}
		number, err := strconv.ParseInt(group(3), 10, 64)
		if err != nil || number <= 0 {
			return "unreadable", nil
		}
		if strings.EqualFold(repo, item.Repo) && number == item.Number {
			return "self", nil
		}
		answer, err := forgeBlockerState(o.org, repo, number)
		if err != nil {
			return "", err
		}
		if answer == "closed" {
			return "closed", nil
		}
		state = "open"
	}
	return state, nil
}

// parkedDigestReport renders one row per blocked-labelled pull request and a
// closing line that accounts for every one read, so an empty digest is told
// apart from one that examined nothing. It reports whether any is actionable.
func parkedDigestReport(pulls []issue, o options) (string, bool, error) {
	var report strings.Builder
	labelled, parked := 0, 0
	for _, item := range pulls {
		// A pull request record with no labels array was never read for the
		// label, so the digest cannot say it is not parked.
		if item.Labels == nil {
			return "", false, fmt.Errorf("pull request %s#%d carries no labels array, so whether it is parked is unproven -- UNKNOWN", item.Repo, item.Number)
		}
		if !item.parked() {
			continue
		}
		labelled++
		verdict, line, _ := parkVerdict(parkRecords(item.thread), o)
		if verdict != "CONFORMS" {
			_, _ = fmt.Fprintf(&report, "%-10s %s#%d  record=%s\n", "ACTIONABLE", item.Repo, item.Number, verdict)
			continue
		}
		blocker, kind := recordBlocker(line)
		state := ""
		// An authority blocker waits on a decision, not on the object it may name.
		if kind == "upstream" {
			var err error
			if state, err = blockerState(item, blocker, o); err != nil {
				return "", false, err
			}
		}
		if reason, refused := map[string]string{"closed": "BLOCKER-CLOSED", "self": "BLOCKER-SELF", "unreadable": "BLOCKER-UNREADABLE"}[state]; refused {
			_, _ = fmt.Fprintf(&report, "%-10s %s#%d  record=%s  %s\n", "ACTIONABLE", item.Repo, item.Number, reason, snippet(blocker))
			continue
		}
		parked++
		note := kind
		switch {
		case state == "open":
			note += ", blocker open"
		case kind == "upstream":
			note += ", blocker state not read"
		}
		_, _ = fmt.Fprintf(&report, "%-10s %s#%d  [%s]  %s\n", "PARKED", item.Repo, item.Number, note, snippet(blocker))
	}
	_, _ = fmt.Fprintf(&report, "CHECKED labelled=%d parked=%d actionable=%d\n", labelled, parked, labelled-parked)
	return report.String(), labelled > parked, nil
}
