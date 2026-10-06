package main

import (
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"
	"unicode"
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

  --target    the pull request or issue being parked.
  --kind      upstream (another tracked item must move first) or authority (only
              the maintainer can clear it). No other word is a kind.
  --blocker   upstream: exactly one tracked item, written owner/repo#N, and never
              the target itself. Review, CI and evaluation of the target are its
              own readiness work, not a blocker, and have no item to name.
              authority: the action in plain words, on one line.
  --result    what the live check found today, on one line.
  --asked     authority only, and required: where and when the maintainer was
              asked. Ask first; a record without a fresh ask is refused.
  --actor     engineer (default) or improver: selects the disclosure line.
  --line-only print only the **Blocker:** line, for an issue body. Without it the
              whole pull-request record comment is printed: disclosure line,
              marker, record.
  --today     <YYYY-MM-DD> (default UTC today); the last-verified date.

Post the comment with --body-file. A parked pull request has exactly one record:
edit the existing comment in place rather than posting another.
Exit: 0 record printed; 2 refused, nothing printed.
`

var (
	// One tracked item and nothing else: the composer names a blocker a later
	// run can look up, where the guard's own identifier test only asks that
	// something identifier-shaped appears somewhere in the text.
	trackedItemRE = regexp.MustCompile(`^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#([1-9][0-9]*)$`)
	actors        = map[string]string{"engineer": "Agentic Engineer", "improver": "Agent Improver"}
)

type composition struct {
	target, kind, blocker, result string
	askChannel, askDate           string
	actor                         string
	lineOnly                      bool
	today                         time.Time
}

func composeArguments(args []string) (composition, bool, error) {
	c := composition{actor: "engineer"}
	today := time.Now().UTC().Format("2006-01-02")
	seen := map[string]bool{}
	for i := 0; i < len(args); i++ {
		name := args[i]
		switch name {
		case "--help", "-h":
			return c, true, nil
		case "--line-only":
			c.lineOnly = true
			continue
		case "--target", "--kind", "--blocker", "--result", "--actor", "--today", "--asked":
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
		case "--today":
			today = args[i]
		case "--asked":
			if i+1 >= len(args) {
				return c, false, errors.New("--asked needs a channel and a date")
			}
			c.askChannel, c.askDate = args[i], args[i+1]
			i++
		}
	}
	for _, required := range []string{"--target", "--kind", "--blocker", "--result"} {
		if !seen[required] {
			return c, false, fmt.Errorf("%s is required", required)
		}
	}
	var err error
	if c.today, err = civilDate(today); err != nil {
		return c, false, errors.New("--today must be a real YYYY-MM-DD calendar date")
	}
	return c, false, nil
}

// oneLine reports whether text can stand as one segment of the record: it has
// content, stays on one line and holds neither a segment delimiter nor a
// Markdown comment opener, which the parser would read as hidden text.
func oneLine(text string) bool {
	return strings.TrimSpace(text) != "" && text == strings.TrimSpace(text) &&
		!strings.ContainsAny(text, "|\r\n") && !strings.Contains(text, "<!--") &&
		strings.IndexFunc(text, unicode.IsControl) < 0
}

// composeRecord returns the record line and the whole comment body, or the
// reason nothing may be written.
func composeRecord(c composition, maxAge, verifyMaxAge int64) (line, body string, err error) {
	if !trackedItemRE.MatchString(c.target) {
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
		if !trackedItemRE.MatchString(c.blocker) {
			return "", "", errors.New("an upstream --blocker must be exactly one tracked item written owner/repo#N; review, CI and evaluation of the target are its own unfinished work, not a blocker")
		}
		if strings.EqualFold(c.blocker, c.target) {
			return "", "", errors.New("the target cannot be its own blocker")
		}
		if c.askChannel != "" {
			return "", "", errors.New("--asked records a maintainer ask and belongs to --kind authority only")
		}
	case "authority":
		if !oneLine(c.blocker) || strings.IndexFunc(c.blocker, unicode.IsLetter) < 0 {
			return "", "", errors.New("an authority --blocker must say on one line, in words, what only the maintainer can do")
		}
		if c.askChannel == "" {
			return "", "", errors.New("--kind authority needs --asked <pr|slack|session> <YYYY-MM-DD>: ask the maintainer first, then record it")
		}
	default:
		return "", "", errors.New("--kind must be exactly upstream or authority")
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
	if verdict != "CONFORMS" || legacy || staleVerification(line, c.today, verifyMaxAge) {
		return "", "", fmt.Errorf("the guard reads the composed record as %s, not CONFORMS", verdict)
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
