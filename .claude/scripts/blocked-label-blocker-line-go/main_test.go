package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestAuthorityGrammar(t *testing.T) {
	today, err := civilDate("2026-09-05")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, record, want string }{
		{"descriptive authority", "Cloudflare account action | authority | last-verified 2026-09-01: pending | asked session 2026-09-01", "CONFORMS"},
		{"bare issue authority", "#7 | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "CONFORMS"},
		{"empty authority identifier", " | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "MALFORMED"},
		{"URL alone cannot identify authority", "https://example.com/account | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "MALFORMED"},
		{"multiple kinds", "owner/repo#1 | authority | upstream | last-verified 2026-09-01: pending", "MALFORMED"},
		{"hidden unspaced kind", "#7 |authority | upstream | last-verified 2026-09-01: pending", "MALFORMED"},
		{"duplicate same kind", "owner/repo#1 | upstream | upstream | last-verified 2026-09-01: pending", "MALFORMED"},
		{"draft PR is attention", "maintainer authority | authority | last-verified 2026-09-01: outage-cause=credentials/auth; pending | asked pr 2026-09-01", "CONFORMS"},
		{"undefined push token is not attention", "maintainer authority | authority | last-verified 2026-09-01: pending | asked push 2026-09-01", "NO-ASK"},
		{"issue alone is not attention", "maintainer authority | authority | last-verified 2026-09-01: pending | asked issue 2026-09-01", "NO-ASK"},
		{"outage cause cannot replace kind", "owner/repo#1 | credentials/auth | last-verified 2026-09-01: pending", "MALFORMED"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, _ := classify("**Blocker:** "+tc.record, today, 14)
			if got != tc.want {
				t.Fatalf("got %s, want %s", got, tc.want)
			}
		})
	}
}

func TestSearchCompleteness(t *testing.T) {
	for _, tc := range []struct {
		name, raw string
		count     int
		unknown   bool
	}{
		{"empty complete", `{"total_count":0,"incomplete_results":false,"items":[]}`, 0, false},
		{"empty response", "", 0, true},
		{"missing completeness", `{"total_count":0,"items":[]}`, 0, true},
		{"missing items", `{"total_count":0,"incomplete_results":false}`, 0, true},
		{"timed out", `{"total_count":0,"incomplete_results":true,"items":[]}`, 0, true},
		{"count mismatch", `{"total_count":1,"incomplete_results":false,"items":[]}`, 0, true},
		{"moving total", `{"total_count":0,"incomplete_results":false,"items":[]} {"total_count":1,"incomplete_results":false,"items":[]}`, 0, true},
		{"all pages", `{"total_count":2,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1}]} {"total_count":2,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":2}]}`, 2, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := searchIssues([]byte(tc.raw))
			if (err != nil) != tc.unknown {
				t.Fatalf("error=%v, want unknown=%v", err, tc.unknown)
			}
			if err == nil && len(got) != tc.count {
				t.Fatalf("got %d records, want %d", len(got), tc.count)
			}
		})
	}
}

func TestInvalidInputCannotProducePartialSuccess(t *testing.T) {
	for _, raw := range []string{`null`, `{}`, `[{"repo":"r","number":1,"body":"none"},{"repo":"r","number":0}]`, `[{"repo":"r\nspoof","number":1}]`, `[{"repo":"r","number":1,"body":12}]`} {
		var out, stderr bytes.Buffer
		if code := run([]string{"--input", "-"}, strings.NewReader(raw), &out, &stderr); code != 2 {
			t.Errorf("code=%d, want UNKNOWN for %s", code, raw)
		}
		if out.Len() != 0 {
			t.Errorf("partial verdict emitted: %s", out.String())
		}
	}
}

func TestCalendarAcrossDurationRange(t *testing.T) {
	today, _ := civilDate("9999-12-31")
	got, _ := classify("**Blocker:** maintainer authority | authority | last-verified 0001-01-01: pending | asked pr 0001-01-01", today, 999999999)
	if got != "CONFORMS" {
		t.Fatalf("large supported cadence: got %s", got)
	}
	got, _ = classify("**Blocker:** maintainer authority | authority | last-verified 0001-01-01: pending | asked pr 0001-01-01", today, 14)
	if got != "STALE-ASK" {
		t.Fatalf("ordinary cadence: got %s", got)
	}
}

func TestMalformedRecordCannotEmitTerminalControls(t *testing.T) {
	var out, stderr bytes.Buffer
	raw := `[{"repo":"r","number":1,"body":"**Blocker:** owner/repo#1 | upstream | last-verified 2026-09-01: \u001b[31mpending\b"}]`
	code := run([]string{"--input", "-"}, strings.NewReader(raw), &out, &stderr)
	if code != 1 || !strings.Contains(out.String(), "MALFORMED") {
		t.Fatalf("code=%d, out=%q", code, out.String())
	}
	if strings.ContainsAny(out.String(), "\x1b\b") {
		t.Fatalf("raw terminal control in output: %q", out.String())
	}
}
