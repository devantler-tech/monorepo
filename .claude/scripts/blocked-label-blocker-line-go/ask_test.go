package main

import (
	"strings"
	"testing"
)

func TestDigestReceiptRetainsTheAskClock(t *testing.T) {
	today, _ := civilDate("2026-09-20")
	for _, tc := range []struct{ date, want string }{{"2026-09-06", "CONFORMS"}, {"2026-09-05", "STALE-ASK"}} {
		got, _ := classify("**Blocker:** choose the retention rule | authority | last-verified 2026-09-20: pending | asked digest o/monorepo#40 "+tc.date, today, 14)
		if got != tc.want {
			t.Errorf("%s: got %s want %s", tc.date, got, tc.want)
		}
	}
}

func TestAuthorityParkMustReachAnOpenAskIssue(t *testing.T) {
	for _, tc := range []struct {
		receipt, state, want string
		code                 int
	}{
		{"slack 2026-08-30", "", "ASK-ISSUE-MISSING", 1},
		{"digest o/monorepo#40 2026-08-30", "open", "PARKED", 0},
		{"digest o/monorepo#40 2026-08-30", "closed", "ASK-CLOSED", 1},
		{"digest o/monorepo#40 2026-08-30", "", "UNKNOWN", 2},
	} {
		record := commentJSON(t, "devantler", recordHead+"**Blocker:** choose the retention rule | authority | last-verified 2026-09-01: pending | asked "+tc.receipt)
		labels := blockedLabel + `"ask_state":"` + tc.state + `",`
		code, out := runInput(t, "["+digestPull("5", labels, record)+"]", "--parked-digest")
		if code != tc.code || !strings.Contains(out, tc.want) {
			t.Errorf("%s/%s: code=%d out=%s", tc.receipt, tc.state, code, out)
		}
	}
}

func TestComposeLinksDigestAsk(t *testing.T) {
	args := replaced(authorityArgs, "--asked", "digest")
	code, out, err := compose(append(args, "--ask-issue", "o/monorepo#40")...)
	if code != 0 || !strings.Contains(out, "| asked digest o/monorepo#40 2026-10-05") {
		t.Fatalf("code=%d out=%s err=%s", code, out, err)
	}
}
