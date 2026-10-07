package main

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// The composer dates and judges a record by the real clock; pin it so the
// fixtures below keep meaning the same thing as the calendar moves.
func init() {
	composeToday = func() time.Time { return time.Date(2026, 10, 6, 0, 0, 0, 0, time.UTC) }
}

func compose(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := run(append([]string{"compose"}, args...), strings.NewReader(""), &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

var (
	upstreamArgs  = []string{"--target", "o/r#5", "--kind", "upstream", "--blocker", "o/other#7", "--result", "still open"}
	outcomeArgs   = []string{"--target", "o/r#5", "--kind", "outcome", "--blocker", "a release newer than v1.2.3 carrying o/other#7", "--result", "tag exists, release not published"}
	authorityArgs = []string{"--target", "o/r#5", "--kind", "authority", "--blocker", "rotate the registry token", "--result", "token still expired", "--asked", "slack", "2026-10-05"}
)

// replaced returns args with the value of one flag swapped, so each refusal
// case differs from an accepted record by exactly the thing it tests.
func replaced(args []string, flag, value string) []string {
	out := append([]string{}, args...)
	for i := range out {
		if out[i] == flag {
			out[i+1] = value
			return out
		}
	}
	panic("no " + flag + " in the fixture")
}

// The composed comment must be the one the sweep accepts: fed back through the
// --input seam as a parked pull request's only comment, it reports no finding.
func TestComposedRecordIsAcceptedByTheSweep(t *testing.T) {
	for name, args := range map[string][]string{"upstream": upstreamArgs, "authority": authorityArgs, "outcome": outcomeArgs} {
		t.Run(name, func(t *testing.T) {
			code, body, stderr := compose(args...)
			if code != 0 || stderr != "" {
				t.Fatalf("compose exited %d, stderr %q", code, stderr)
			}
			if !strings.HasPrefix(body, disclosurePrefix+"Agentic Engineer\n") {
				t.Errorf("record does not open with the disclosure line: %q", body)
			}
			var stdout, errOut bytes.Buffer
			sweep := run([]string{"--input", "-", "--today", "2026-10-06"}, strings.NewReader(parkedPull(commentJSON(t, "devantler", body))), &stdout, &errOut)
			if sweep != 0 || !strings.Contains(stdout.String(), "all 1 open blocked-labelled pull request(s) carry one conforming record comment") {
				t.Errorf("sweep exited %d on the composed record: %s%s", sweep, stdout.String(), errOut.String())
			}
		})
	}
}

func TestComposeLineOnlyAndActor(t *testing.T) {
	code, out, _ := compose(append(append([]string{}, upstreamArgs...), "--line-only")...)
	if want := "**Blocker:** o/other#7 | upstream | last-verified 2026-10-06: still open\n"; code != 0 || out != want {
		t.Errorf("--line-only printed %q (exit %d), want %q", out, code, want)
	}
	code, out, _ = compose(append(append([]string{}, authorityArgs...), "--actor", "improver")...)
	if code != 0 || !strings.HasPrefix(out, disclosurePrefix+"Agent Improver\n") ||
		!strings.HasSuffix(out, "**Blocker:** rotate the registry token | authority | last-verified 2026-10-06: token still expired | asked slack 2026-10-05\n") {
		t.Errorf("improver authority record is %q (exit %d)", out, code)
	}
}

// Every refusal prints nothing on stdout: a partly written record must not be
// postable. Each case names the reason, so it cannot pass on another refusal.
func TestComposeRefusals(t *testing.T) {
	for _, tc := range []struct {
		name   string
		args   []string
		reason string
	}{
		{"readiness work as a blocker", replaced(upstreamArgs, "--blocker", "current-head review, CI and evaluation"), "its own unfinished work"},
		{"an item with trailing prose", replaced(upstreamArgs, "--blocker", "o/other#7 and review"), "exactly one tracked item"},
		{"a bare number", replaced(upstreamArgs, "--blocker", "#7"), "exactly one tracked item"},
		{"the target as its own blocker", replaced(upstreamArgs, "--blocker", "O/R#5"), "cannot be its own blocker"},
		{"a kind that does not exist", replaced(upstreamArgs, "--kind", "external"), "exactly upstream, authority or outcome"},
		{"a kind with a second word", replaced(upstreamArgs, "--kind", "external service"), "exactly upstream, authority or outcome"},
		{"an outcome that is a tracked item", replaced(outcomeArgs, "--blocker", "o/other#7"), "is --kind upstream"},
		{"an outcome that is a link to a tracked item", replaced(outcomeArgs, "--blocker", "[o/other#7](https://example.com/issue)"), "is --kind upstream"},
		{"an outcome that is two tracked items", replaced(outcomeArgs, "--blocker", "o/other#7, o/other#8"), "is --kind upstream"},
		{"an outcome with no words", replaced(outcomeArgs, "--blocker", "2026-10-08"), "which event the delivered work waits on"},
		{"an outcome on two lines", replaced(outcomeArgs, "--blocker", "the next release\n**Blocker:** x/y#1"), "which event the delivered work waits on"},
		{"an outcome carrying a delimiter", replaced(outcomeArgs, "--blocker", "the next release | upstream"), "which event the delivered work waits on"},
		{"an ask on an outcome record", append(append([]string{}, outcomeArgs...), "--asked", "slack", "2026-10-05"), "belongs to --kind authority"},
		{"a delimiter in the result", replaced(upstreamArgs, "--result", "open | authority"), "--result must be one non-empty line"},
		{"a second line in the result", replaced(upstreamArgs, "--result", "open\n**Blocker:** x/y#1"), "--result must be one non-empty line"},
		{"a hidden comment in the result", replaced(upstreamArgs, "--result", "open <!-- x -->"), "--result must be one non-empty line"},
		{"an empty result", replaced(upstreamArgs, "--result", " "), "--result must be one non-empty line"},
		{"an unusable target", replaced(upstreamArgs, "--target", "r#5"), "--target must be one item"},
		{"an ask on an upstream record", append(append([]string{}, upstreamArgs...), "--asked", "slack", "2026-10-05"), "belongs to --kind authority"},
		{"an ask dated after today", append(replaced(authorityArgs, "--asked", "slack")[:10], "2026-10-07"), "reads the composed record as MALFORMED"},
		{"an unknown actor", append(append([]string{}, upstreamArgs...), "--actor", "maintainer"), "--actor must be"},
		{"authority without an ask", authorityArgs[:8], "ask the maintainer first"},
		{"authority with no words", replaced(authorityArgs, "--blocker", "#"), "what only the maintainer can do"},
		{"an ask channel that does not exist", replaced(authorityArgs, "--asked", "issue"), "the channels are pr, slack, session"},
		{"an ask channel carrying a second record", replaced(authorityArgs, "--asked", "x | asked slack"), "the channels are pr, slack, session"},
		{"an ask date with trailing space", append(replaced(authorityArgs, "--asked", "slack")[:10], "2026-10-05 "), "--asked needs a real"},
		{"an ask with one value", authorityArgs[:10], "--asked needs a channel and a date"},
		{"an empty ask on an upstream record", append(append([]string{}, upstreamArgs...), "--asked", "", "2026-10-05"), "belongs to --kind authority"},
		{"a caller-chosen date", append(append([]string{}, upstreamArgs...), "--today", "2020-01-01"), "unknown argument"},
		{"help after other arguments", append(append([]string{}, upstreamArgs...), "--help"), "unknown argument"},
		{"a hidden direction override in the result", replaced(upstreamArgs, "--result", "open\u202e"), "--result must be one non-empty line"},
		{"a tab in the result", replaced(upstreamArgs, "--result", "open\tnow"), "--result must be one non-empty line"},
		{"invalid text in the result", replaced(upstreamArgs, "--result", "open\xff"), "--result must be one non-empty line"},
		{"a dot-only repository", replaced(upstreamArgs, "--blocker", "../..#1"), "exactly one tracked item"},
		{"authority naming only an item", replaced(authorityArgs, "--blocker", "o/r#5"), "what only the maintainer can do"},
		{"authority with a delimiter", replaced(authorityArgs, "--blocker", "rotate | upstream"), "what only the maintainer can do"},
		{"a flag with no value", append(append([]string{}, upstreamArgs...), "--actor"), "--actor needs a value"},
		{"a missing target", upstreamArgs[2:], "--target is required"},
		{"an ask that has gone stale", append(replaced(authorityArgs, "--asked", "slack")[:10], "2026-09-01"), "reads the composed record as STALE-ASK"},
		{"a flag given twice", append(append([]string{}, upstreamArgs...), "--kind", "authority"), "--kind given more than once"},
		{"a missing result", upstreamArgs[:6], "--result is required"},
		{"an unknown flag", append(append([]string{}, upstreamArgs...), "--org", "o"), "unknown argument"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, stdout, stderr := compose(tc.args...)
			if code != 2 || stdout != "" {
				t.Errorf("exit %d with stdout %q, want a refusal that prints nothing", code, stdout)
			}
			if !strings.Contains(stderr, tc.reason) || !strings.Contains(stderr, "nothing printed") {
				t.Errorf("refused for %q, want the reason %q", stderr, tc.reason)
			}
		})
	}
}

// The help is the only definition a caller reads, so it names the same kinds
// and ask channels the composer enforces, and the sweep's help points at it.
// The help is the only definition of the kinds a caller sees: it must offer
// outcome and say what it is not, or work that can still be done gets parked.
func TestHelpDefinesTheOutcomeKind(t *testing.T) {
	for name, text := range map[string]string{"compose": composeHelp, "park": parkHelp, "check": help} {
		if !strings.Contains(text, "outcome") {
			t.Errorf("%s help does not mention the outcome kind", name)
		}
	}
	for _, want := range []string{"--kind outcome   --blocker <the event waited on, in words>", "Work an agent can still do is never an outcome."} {
		if !strings.Contains(composeHelp, want) {
			t.Errorf("compose help lacks %q", want)
		}
	}
}

func TestComposeHelp(t *testing.T) {
	code, out, _ := compose("--help")
	if code != 0 || out != composeHelp {
		t.Fatalf("compose --help exited %d", code)
	}
	for _, want := range []string{"upstream", "authority", "<" + strings.Join(askChannels, "|") + ">", "--body-file"} {
		if !strings.Contains(out, want) {
			t.Errorf("compose help does not mention %q", want)
		}
	}
	if !strings.Contains(help, "compose --help") {
		t.Error("the sweep's help no longer points at the composer")
	}
}
