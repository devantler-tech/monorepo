package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
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
//
// A park is still not a resting place. A dependency pull request whose park
// holds is STRANDED, and so still work, while an in-portfolio blocker it waits
// on is held by nobody, or once it has been parked past a bound without a
// current record of the engineering route tried and the next one. Parked
// Dependabot pull requests once filled an ecosystem's open-pull-request limit
// for weeks while every run read them as finished
// (devantler-tech/agent-plugins#699).

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

// blockerRecord is what the digest reads of one issue or pull request a
// record names: its state and, for a parked dependency pull request, whether
// the blocker is held by anyone (see blockerState).
type blockerRecord struct {
	Number      int64           `json:"number"`
	State       string          `json:"state"`
	PullRequest json.RawMessage `json:"pull_request"`
	Labels      *[]struct {
		Name string `json:"name"`
	} `json:"labels"`
}

// forgeBlocker reads one issue or pull request of this organization. The
// answer must be that of the object asked for and one of the forge's two
// states: anything else is UNKNOWN, never open.
func forgeBlocker(org, repo string, number int64) (blockerRecord, error) {
	var record blockerRecord
	path, err := pullPath(org, repo, number)
	if err != nil {
		return record, err
	}
	raw, err := forgeRead(path)
	if err != nil {
		return record, errors.New("forge read failed -- UNKNOWN, never zero")
	}
	if json.Unmarshal(raw, &record) != nil || record.Number != number || (record.State != "open" && record.State != "closed") {
		return record, fmt.Errorf("blocker %s#%d carries no readable state -- UNKNOWN", repo, number)
	}
	return record, nil
}

// blockerState reports what is known about the blocker of one parked pull
// request: "closed" when any issue or pull request it names has closed, "open"
// when every one that was read is open, "" when none could be read, "self" when
// it names the parked pull request itself and "unreadable" when a reference
// carries no usable number. Under --org only a reference inside the
// organization is read: another owner's repository is outside what a sweep may
// query. An --input record states the answer in "blocker_state".
//
// When claims is set, the pull request is a dependency pull request, and
// unclaimed reports whether an open issue it waits on is held by nobody: not
// parked itself (its own record is then checked by the issue sweep), and not
// referred to by any open pull request in pulls, which holds only those not
// parked themselves. An open pull request is work
// in flight and always held. An assignee does not hold it, because a claim
// lapses after about two hours. A label set it cannot read is UNKNOWN. An
// --input record states the answer in "blocker_claim".
func blockerState(item issue, blocker string, pulls []issue, claims bool, o options) (state string, unclaimed bool, err error) {
	if o.org == "" {
		switch item.BlockerState {
		case "", "open", "closed":
		default:
			return "", false, fmt.Errorf("pull request %s#%d carries an unreadable blocker_state -- UNKNOWN", item.Repo, item.Number)
		}
		if !claims || item.BlockerState != "open" {
			return item.BlockerState, false, nil
		}
		switch item.BlockerClaim {
		case "held":
			return "open", false, nil
		case "unclaimed":
			return "open", true, nil
		}
		return "", false, fmt.Errorf("dependency pull request %s#%d carries no readable blocker_claim -- UNKNOWN", item.Repo, item.Number)
	}
	text := urlRE.ReplaceAllString(blocker, " ")
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
			return "unreadable", false, nil
		}
		if strings.EqualFold(repo, item.Repo) && number == item.Number {
			return "self", false, nil
		}
		answer, err := forgeBlocker(o.org, repo, number)
		if err != nil {
			return "", false, err
		}
		if answer.State == "closed" {
			return "closed", false, nil
		}
		state = "open"
		if !claims || (len(answer.PullRequest) > 0 && string(answer.PullRequest) != "null") {
			continue
		}
		if answer.Labels == nil {
			return "", false, fmt.Errorf("blocker %s#%d carries no labels, so whether anyone holds it is unproven -- UNKNOWN", repo, number)
		}
		held := issue{Repo: repo, Number: number, Labels: answer.Labels}
		if !held.blocked() && !mentioned(held, pulls, o.org) {
			unclaimed = true
		}
	}
	return state, unclaimed, nil
}

// A parked dependency pull request is not finished work
// (devantler-tech/agent-plugins#699). Past the bound, waiting is no longer a
// route: its record keeps, in the result, what was "tried:", the "next:" route
// and the "re-check <YYYY-MM-DD>" by which the agent looks again. The result is
// read as a list of ";"-separated segments, and only these shapes count: a
// segment that starts with "tried:" or "next:" and carries a word, and a
// segment that is exactly "re-check <YYYY-MM-DD>". Any other segment that
// mentions re-check is no route at all, so a date cannot be hidden in prose.
// All of it is read only from the result, after "last-verified", so a
// blocker's own text cannot supply it.
var recheckSegmentRE = regexp.MustCompile(`(?i)^re-check ([0-9]{4}-[0-9]{2}-[0-9]{2})$`)

// hasWord reports whether a segment's value holds a letter or a digit, so a
// value of punctuation alone is no route.
func hasWord(value string) bool {
	return strings.IndexFunc(value, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }) >= 0
}

// civilDays counts whole days from one civil date to another.
func civilDays(from, to time.Time) int64 {
	// Unix days avoid time.Duration's roughly 290-year subtraction limit.
	return to.Unix()/86400 - from.Unix()/86400
}

// parkAge reads how many days ago a dependency pull request was parked, from
// the creation time of its one record comment. A time that is missing,
// unreadable or later than today is UNKNOWN, never a new park.
func parkAge(item issue, today time.Time) (int64, error) {
	created, err := recordCreated(item.thread)
	if err != nil {
		return 0, fmt.Errorf("pull request %s#%d: %w", item.Repo, item.Number, err)
	}
	at, err := time.Parse(time.RFC3339, created)
	if err != nil {
		return 0, fmt.Errorf("pull request %s#%d record comment carries an unreadable created_at -- UNKNOWN", item.Repo, item.Number)
	}
	day, err := civilDate(at.UTC().Format("2006-01-02"))
	if err != nil {
		return 0, fmt.Errorf("pull request %s#%d record comment carries an unusable created_at -- UNKNOWN", item.Repo, item.Number)
	}
	age := civilDays(day, today)
	if age < 0 {
		return 0, fmt.Errorf("pull request %s#%d record comment is dated after today -- UNKNOWN", item.Repo, item.Number)
	}
	return age, nil
}

// routeReason judges the route record a long-parked record carries: "" when
// its result holds exactly one "tried:" segment and one "next:" segment, each
// with a value, and exactly one "re-check <YYYY-MM-DD>" segment from today to
// bound days ahead; ROUTE-LAPSED when that date has passed; NO-ROUTE
// otherwise. A re-check further out than the bound is no record: it would park
// the pull request past every later look.
func routeReason(line string, today time.Time, bound int64) string {
	parts := strings.SplitN(line, " | last-verified ", 2)
	if len(parts) != 2 {
		return "NO-ROUTE"
	}
	// The result follows "<date>: " and ends where an ask record begins.
	_, result, found := strings.Cut(strings.SplitN(parts[1], " | asked ", 2)[0], ": ")
	if !found {
		return "NO-ROUTE"
	}
	tried, next := 0, 0
	var dates []string
	for _, segment := range strings.Split(result, ";") {
		segment = strings.TrimSpace(segment)
		lower := strings.ToLower(segment)
		switch {
		case strings.HasPrefix(lower, "tried:"):
			if !hasWord(segment[len("tried:"):]) {
				return "NO-ROUTE"
			}
			tried++
		case strings.HasPrefix(lower, "next:"):
			if !hasWord(segment[len("next:"):]) {
				return "NO-ROUTE"
			}
			next++
		case strings.Contains(lower, "re-check"):
			date := recheckSegmentRE.FindStringSubmatch(segment)
			if date == nil {
				return "NO-ROUTE"
			}
			dates = append(dates, date[1])
		}
	}
	if tried != 1 || next != 1 || len(dates) != 1 {
		return "NO-ROUTE"
	}
	recheck, err := civilDate(dates[0])
	if err != nil {
		return "NO-ROUTE"
	}
	switch ahead := civilDays(today, recheck); {
	case ahead < 0:
		return "ROUTE-LAPSED"
	case ahead > bound:
		return "NO-ROUTE"
	}
	return ""
}

// strandedReason reports why a dependency pull request whose park otherwise
// holds is still owned work, or "" when it is parked. An unclaimed
// in-portfolio blocker comes first: it is work nobody is doing. Past the bound
// every park needs a current route record, whatever its blocker kind: a
// maintainer ask is a question of direction, never a handoff, so it does not
// pause the work, and no bound ever makes contacting the maintainer the
// outcome.
func strandedReason(line string, unclaimed bool, age int64, o options) string {
	switch {
	case unclaimed:
		return "UNCLAIMED"
	case age > o.strandedMaxAge:
		return routeReason(line, o.today, o.strandedMaxAge)
	}
	return ""
}

// parkedDigestReport renders one row per blocked-labelled pull request and a
// closing line that accounts for every one read, so an empty digest is told
// apart from one that examined nothing. It reports whether any is actionable.
func parkedDigestReport(pulls []issue, o options) (string, bool, error) {
	var report strings.Builder
	labelled, parked := 0, 0
	// Only an open pull request that is not itself parked can hold a blocker:
	// a parked one is waiting, not working, so one parked on the very issue it
	// refers to would otherwise hold that issue for every pull request behind it.
	var working []issue
	for _, item := range pulls {
		if item.Labels != nil && !item.parked() {
			working = append(working, item)
		}
	}
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
		// A dependency pull request is matched by its exact author. A labelled
		// pull request whose author is not named, under --org or --input, is
		// UNKNOWN: it might be a dependency pull request.
		if item.User.Login == "" {
			return "", false, fmt.Errorf("pull request %s#%d carries no author, so whether it is a dependency pull request is unproven -- UNKNOWN", item.Repo, item.Number)
		}
		dependency := dependencyBots[item.User.Login]
		verdict, line, _ := parkVerdict(parkRecords(item.thread), o)
		if verdict != "CONFORMS" {
			_, _ = fmt.Fprintf(&report, "%-10s %s#%d  record=%s\n", "ACTIONABLE", item.Repo, item.Number, verdict)
			continue
		}
		blocker, kind := recordBlocker(line)
		state, unclaimed := "", false
		if kind == "authority" {
			ask := askRE.FindStringSubmatch(line)
			if ask == nil || ask[1] != "digest" || ask[2] == "" {
				_, _ = fmt.Fprintf(&report, "%-10s %s#%d  record=ASK-ISSUE-MISSING\n", "ACTIONABLE", item.Repo, item.Number)
				continue
			}
			askState := item.AskState
			if o.org != "" {
				var err error
				askState, err = readDigestAsk(ask[2], o.org)
				if err != nil {
					return "", false, err
				}
			}
			if askState == "unlabelled" {
				_, _ = fmt.Fprintf(&report, "%-10s %s#%d  record=ASK-UNLABELLED\n", "ACTIONABLE", item.Repo, item.Number)
				continue
			}
			if askState != "open" && askState != "closed" {
				return "", false, errors.New("linked ask state is unproven -- UNKNOWN")
			}
			if askState == "closed" {
				_, _ = fmt.Fprintf(&report, "%-10s %s#%d  record=ASK-CLOSED\n", "ACTIONABLE", item.Repo, item.Number)
				continue
			}
		}
		// An authority blocker waits on a decision and an outcome blocker on an
		// event, not on the object either may name.
		if kind == "upstream" {
			var err error
			if state, unclaimed, err = blockerState(item, blocker, working, dependency, o); err != nil {
				return "", false, err
			}
		}
		if reason, refused := map[string]string{"closed": "BLOCKER-CLOSED", "self": "BLOCKER-SELF", "unreadable": "BLOCKER-UNREADABLE"}[state]; refused {
			_, _ = fmt.Fprintf(&report, "%-10s %s#%d  record=%s  %s\n", "ACTIONABLE", item.Repo, item.Number, reason, snippet(blocker))
			continue
		}
		if dependency {
			age, err := parkAge(item, o.today)
			if err != nil {
				return "", false, err
			}
			if reason := strandedReason(line, unclaimed, age, o); reason != "" {
				_, _ = fmt.Fprintf(&report, "%-10s %s#%d  reason=%s  age=%dd  %s\n", "STRANDED", item.Repo, item.Number, reason, age, snippet(blocker))
				continue
			}
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
