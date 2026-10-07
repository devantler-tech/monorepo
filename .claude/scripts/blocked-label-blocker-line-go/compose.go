package main

import (
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// A blocker record written by hand drifts: half of the parked pull requests
// once carried one this guard could not read -- a list of unfinished review,
// CI and evaluation work, a kind that does not exist, or the pull request
// named as its own blocker (#3879). compose prints the record in the one shape
// the guard accepts and refuses everything else, and what it prints is read
// back through the guard's own parser before it leaves, so the composer and
// the check can never disagree about what conforms.
const composeHelp = `Compose a blocker record in the one shape the guard accepts.

  compose --target <owner/repo#N> --kind upstream  --blocker <owner/repo#N> --result <text>
  compose --target <owner/repo#N> --kind authority --blocker <what only the maintainer can do>
          --result <text> --asked <pr|slack|session> <YYYY-MM-DD>
  compose --target <owner/repo#N> --kind outcome   --blocker <the event waited on, in words> --result <text>

  --target    the pull request or issue being parked.
  --kind      upstream (another tracked item must move first), authority (only
              the maintainer can clear it) or outcome (the work is delivered and
              waits on an event nobody performs on request: a release being
              published, the next production occurrence). No other word is a
              kind. Work an agent can still do is never an outcome.
  --blocker   upstream: exactly one tracked item, written owner/repo#N, and never
              the target itself. Review, CI and evaluation of the target are its
              own readiness work, not a blocker, and have no item to name.
              authority: the action in plain words, on one line.
              outcome: the event in plain words, on one line. An item that
              must move first is an upstream blocker, so a bare reference is
              refused; a reference may appear beside the words.
  --result    what the live check found today, on one line.
  --asked     authority only, and required: where and when the maintainer was
              asked. Ask first; a record without a fresh ask is refused.
  --actor     engineer (default) or improver: selects the disclosure line.
  --line-only print only the **Blocker:** line, for an issue body. Without it the
              whole pull-request record comment is printed: disclosure line,
              marker, record. --target is still required.

To park a pull request use park, which posts or edits this comment and adds
the blocked label in one step; posted by hand, the comment goes with --body-file. A parked pull request has exactly one record:
it is edited in place, never joined by another.
The last-verified date is always today (UTC): a record states what a check
found now, so no other date can be written.
Exit: 0 record (or this help, when --help is the only argument) printed;
      2 refused, nothing printed.
`

var (
	// One tracked item and nothing else: the composer names a blocker a later
	// run can look up, where the guard's own identifier test only asks that
	// something identifier-shaped appears somewhere in the text.
	trackedItemRE = regexp.MustCompile(`^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#([1-9][0-9]*)$`)
	// composeToday is the clock a record is dated and judged by. It is a variable
	// only so tests can pin it: a caller-chosen date would be judged against
	// itself, and a stale or future one would read as fresh (#3879 review).
	composeToday = func() time.Time { return time.Now().UTC().Truncate(24 * time.Hour) }
	actors       = map[string]string{"engineer": "Agentic Engineer", "improver": "Agent Improver"}
)

type composition struct {
	target, kind, blocker, result string
	askChannel, askDate           string
	actor                         string
	asked, lineOnly               bool
	today                         time.Time
}

func composeArguments(args []string) (composition, bool, error) {
	c := composition{actor: "engineer", today: composeToday()}
	// Help is honoured only on its own, so a mistyped call can never put the
	// help text where a record was expected.
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		return c, true, nil
	}
	seen := map[string]bool{}
	for i := 0; i < len(args); i++ {
		name := args[i]
		switch name {
		case "--line-only":
			c.lineOnly = true
			continue
		case "--target", "--kind", "--blocker", "--result", "--actor", "--asked":
		default:
			return c, false, fmt.Errorf("unknown argument %q", name)
		}
		if seen[name] {
			return c, false, fmt.Errorf("%s given more than once", name)
		}
		seen[name] = true
		if i+1 >= len(args) {
			return c, false, fmt.Errorf("%s needs a value", name)
		}
		i++
		switch name {
		case "--target":
			c.target = args[i]
		case "--kind":
			c.kind = args[i]
		case "--blocker":
			c.blocker = args[i]
		case "--result":
			c.result = args[i]
		case "--actor":
			c.actor = args[i]
		case "--asked":
			if i+1 >= len(args) {
				return c, false, errors.New("--asked needs a channel and a date")
			}
			c.askChannel, c.askDate = args[i], args[i+1]
			i++
			c.asked = true
		}
	}
	for _, required := range []string{"--target", "--kind", "--blocker", "--result"} {
		if !seen[required] {
			return c, false, fmt.Errorf("%s is required", required)
		}
	}
	return c, false, nil
}

// oneLine reports whether text can stand as one segment of the record: it has
// content, stays on one line, and holds neither a segment delimiter nor a
// Markdown comment opener, which the parser would read as hidden text. Format
// and separator characters are refused with the control ones, so what renders
// is what the bytes say.
func oneLine(text string) bool {
	return utf8.ValidString(text) && strings.TrimSpace(text) != "" && text == strings.TrimSpace(text) &&
		!strings.Contains(text, "|") && !strings.Contains(text, "<!--") &&
		strings.IndexFunc(text, func(r rune) bool {
			return unicode.IsControl(r) || unicode.In(r, unicode.Cf, unicode.Zl, unicode.Zp)
		}) < 0
}

// trackedItem reports whether text is exactly one item written owner/repo#N.
func trackedItem(text string) bool {
	m := trackedItemRE.FindStringSubmatch(text)
	return m != nil && strings.Trim(m[1], ".") != "" && strings.Trim(m[2], ".") != ""
}

// composeRecord returns the record line and the whole comment body, or the
// reason nothing may be written.
func composeRecord(c composition, maxAge, verifyMaxAge int64) (line, body string, err error) {
	if !trackedItem(c.target) {
		return "", "", errors.New("--target must be one item written owner/repo#N")
	}
	disclosure, ok := actors[c.actor]
	if !ok {
		return "", "", errors.New("--actor must be engineer or improver")
	}
	if !oneLine(c.result) {
		return "", "", errors.New("--result must be one non-empty line without \"|\" or a Markdown comment")
	}
	switch c.kind {
	case "upstream":
		if !trackedItem(c.blocker) {
			return "", "", errors.New("an upstream --blocker must be exactly one tracked item written owner/repo#N; review, CI and evaluation of the target are its own unfinished work, not a blocker")
		}
		if strings.EqualFold(c.blocker, c.target) {
			return "", "", errors.New("the target cannot be its own blocker")
		}
		if c.asked {
			return "", "", errors.New("--asked records a maintainer ask and belongs to --kind authority only")
		}
	case "authority":
		if !oneLine(c.blocker) || strings.IndexFunc(c.blocker, unicode.IsLetter) < 0 || requestIsOpaque("**Blocker:** "+c.blocker) {
			return "", "", errors.New("an authority --blocker must say on one line, in words, what only the maintainer can do")
		}
		if !c.asked {
			return "", "", errors.New("--kind authority needs --asked <pr|slack|session> <YYYY-MM-DD>: ask the maintainer first, then record it")
		}
		known := false
		for _, channel := range askChannels {
			known = known || channel == c.askChannel
		}
		if !known {
			return "", "", fmt.Errorf("--asked names the channel %q; the channels are %s", c.askChannel, strings.Join(askChannels, ", "))
		}
		if _, err := civilDate(c.askDate); err != nil {
			return "", "", errors.New("--asked needs a real YYYY-MM-DD calendar date")
		}
	case "outcome":
		if !oneLine(c.blocker) || !namesAnEvent(c.blocker) {
			return "", "", errors.New("an outcome --blocker must say on one line, in words, which event the delivered work waits on; a tracked item that must move first is --kind upstream")
		}
		if c.asked {
			return "", "", errors.New("--asked records a maintainer ask and belongs to --kind authority only")
		}
	default:
		return "", "", errors.New("--kind must be exactly upstream, authority or outcome")
	}
	line = fmt.Sprintf("**Blocker:** %s | %s | last-verified %s: %s", c.blocker, c.kind, c.today.Format("2006-01-02"), c.result)
	if c.kind == "authority" {
		line += fmt.Sprintf(" | asked %s %s", c.askChannel, c.askDate)
	}
	body = fmt.Sprintf("%s%s\n\n%s\n\n%s\n", disclosurePrefix, disclosure, recordMarker, line)
	// The guard is the only judge of the shape. Read the comment back exactly as
	// a sweep would, so nothing leaves here that the sweep would then report.
	records := parkRecords([]comment{{User: struct {
		Login string `json:"login"`
	}{Login: recordAuthor}, Body: body}})
	if len(records) != 1 || records[0] != line {
		return "", "", errors.New("the composed comment does not read back as one record")
	}
	verdict, legacy := classify(line, c.today, maxAge)
	if verdict != "CONFORMS" {
		return "", "", fmt.Errorf("the guard reads the composed record as %s, not CONFORMS", verdict)
	}
	if legacy || staleVerification(line, c.today, verifyMaxAge) {
		return "", "", errors.New("the guard reads the composed record as a legacy or stale one")
	}
	return line, body, nil
}

func composeRun(args []string, stdout, stderr io.Writer) int {
	refuse := func(err error) int {
		_, _ = fmt.Fprintln(stderr, "blocked-label-blocker-line.sh compose:", err, "-- nothing printed")
		return 2
	}
	c, wantsHelp, err := composeArguments(args)
	if err != nil {
		return refuse(err)
	}
	out := composeHelp
	if !wantsHelp {
		defaults := defaultOptions()
		line, body, err := composeRecord(c, defaults.maxAge, defaults.verifyMaxAge)
		if err != nil {
			return refuse(err)
		}
		out = body
		if c.lineOnly {
			out = line + "\n"
		}
	}
	if _, err := io.WriteString(stdout, out); err != nil {
		return refuse(fmt.Errorf("could not write the record: %w", err))
	}
	return 0
}
