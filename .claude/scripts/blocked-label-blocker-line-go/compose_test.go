package main

import (
	"bytes"
	"strings"
	"testing"
)

func compose(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := run(append([]string{"compose"}, args...), strings.NewReader(""), &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

var (
	upstreamArgs  = []string{"--target", "o/r#5", "--kind", "upstream", "--blocker", "o/other#7", "--result", "still open", "--today", "2026-10-06"}
	authorityArgs = []string{"--target", "o/r#5", "--kind", "authority", "--blocker", "rotate the registry token", "--result", "token still expired", "--asked", "slack", "2026-10-05", "--today", "2026-10-06"}
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
	for name, args := range map[string][]string{"upstream": upstreamArgs, "authority": authorityArgs} {
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
		{"a kind that does not exist", replaced(upstreamArgs, "--kind", "external"), "exactly upstream or authority"},
		{"a kind with a second word", replaced(upstreamArgs, "--kind", "external service"), "exactly upstream or authority"},
		{"a delimiter in the result", replaced(upstreamArgs, "--result", "open | authority"), "--result must be one non-empty line"},
		{"a second line in the result", replaced(upstreamArgs, "--result", "open\n**Blocker:** x/y#1"), "--result must be one non-empty line"},
		{"a hidden comment in the result", replaced(upstreamArgs, "--result", "open <!-- x -->"), "--result must be one non-empty line"},
		{"an empty result", replaced(upstreamArgs, "--result", " "), "--result must be one non-empty line"},
		{"an unusable target", replaced(upstreamArgs, "--target", "r#5"), "--target must be one item"},
		{"an ask on an upstream record", append(append([]string{}, upstreamArgs...), "--asked", "slack", "2026-10-05"), "belongs to --kind authority"},
		{"an impossible date", replaced(upstreamArgs, "--today", "2026-13-01"), "--today must be a real"},
		{"an ask dated after today", append(replaced(authorityArgs, "--asked", "slack")[:10], "2026-10-07", "--today", "2026-10-06"), "reads the composed record as MALFORMED"},
		{"an unknown actor", append(append([]string{}, upstreamArgs...), "--actor", "maintainer"), "--actor must be"},
		{"authority without an ask", authorityArgs[:8], "ask the maintainer first"},
		{"authority with no words", replaced(authorityArgs, "--blocker", "#"), "what only the maintainer can do"},
		{"an ask channel that does not exist", replaced(authorityArgs, "--asked", "issue"), "reads the composed record as NO-ASK"},
		{"an ask that has gone stale", append(replaced(authorityArgs, "--asked", "slack")[:10], "2026-09-01", "--today", "2026-10-06"), "reads the composed record as STALE-ASK"},
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
