package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
		{"mailto alone cannot identify authority", "mailto:admin@example.com | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "MALFORMED"},
		{"tel alone cannot identify authority", "tel:+4512345678 | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "MALFORMED"},
		{"opaque scheme is case insensitive", "URN:uuid:12345678 | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "MALFORMED"},
		{"description alongside opaque URL", "Account activation mailto:admin@example.com | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "CONFORMS"},
		{"description with punctuation", "Account action: enable signing | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01", "CONFORMS"},
		{"legacy authority with punctuation", "maintainer authority: enable signing | last-verified 2026-09-01: pending | asked pr 2026-09-01", "CONFORMS"},
		{"upstream repository with punctuation", "owner/repo: pending release | upstream | last-verified 2026-09-01: pending", "CONFORMS"},
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

func TestQuietEmitsOnlyFindingRecords(t *testing.T) {
	for _, tc := range []struct {
		name, input, want string
		code              int
	}{
		{"empty", `[]`, "", 0},
		{"conforming", `[{"repo":"r","number":1,"body":"**Blocker:** o/r#7 | upstream | last-verified 2026-09-01: pending"}]`, "", 0},
		{"finding", `[{"repo":"r","number":2}]`, "MISSING    r#2\n", 1},
		{"mixed", `[{"repo":"r","number":1,"body":"**Blocker:** o/r#7 | upstream | last-verified 2026-09-01: pending"},{"repo":"r","number":2}]`, "MISSING    r#2\n", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var out, stderr bytes.Buffer
			code := run([]string{"--quiet", "--input", "-"}, strings.NewReader(tc.input), &out, &stderr)
			if code != tc.code || out.String() != tc.want || stderr.Len() != 0 {
				t.Fatalf("code=%d output=%q stderr=%q; want code=%d output=%q", code, out.String(), stderr.String(), tc.code, tc.want)
			}
		})
	}
}

func TestOutputFailureReturnsUnknown(t *testing.T) {
	for _, tc := range []struct {
		name, input string
		args        []string
	}{
		{"help", "", []string{"--help"}},
		{"conforming", `[]`, []string{"--input", "-"}},
		{"finding", `[{"repo":"r","number":2}]`, []string{"--input", "-"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader, writer := io.Pipe()
			_ = reader.Close()
			t.Cleanup(func() { _ = writer.Close() })
			var stderr bytes.Buffer
			code := run(tc.args, strings.NewReader(tc.input), writer, &stderr)
			if code != 2 || !strings.Contains(stderr.String(), "UNKNOWN") {
				t.Fatalf("undelivered output: code=%d stderr=%q, want UNKNOWN", code, stderr.String())
			}
		})
	}
}

func TestCLIClosedPipeReturnsUnknown(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "blocker-guard")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if output, err := exec.CommandContext(ctx, "go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v\n%s", err, output)
	}
	for _, tc := range []struct {
		name, input string
		args        []string
		closeStderr bool
	}{
		{"help stdout", "", []string{"--help"}, false},
		{"conforming stdout", `[]`, []string{"--input", "-"}, false},
		{"finding stdout", `[{"repo":"r","number":2}]`, []string{"--input", "-"}, false},
		{"usage stderr", "", []string{"--invalid"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader, writer, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := reader.Close(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = writer.Close() })
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, tc.args...)
			cmd.Stdin = strings.NewReader(tc.input)
			var diagnostic bytes.Buffer
			if tc.closeStderr {
				cmd.Stderr = writer
			} else {
				cmd.Stdout = writer
				cmd.Stderr = &diagnostic
			}
			// A real descriptor 1 or 2 with no reader exercises SIGPIPE in the
			// public entrypoint. Passing an io.Pipe to run cannot do that.
			err = cmd.Run()
			var exitErr *exec.ExitError
			if !errors.As(err, &exitErr) || exitErr.ExitCode() != 2 {
				t.Fatalf("closed pipe: error=%v stderr=%q, want exit 2", err, diagnostic.String())
			}
			if !tc.closeStderr && !strings.Contains(diagnostic.String(), "could not write report -- UNKNOWN") {
				t.Fatalf("missing report-delivery diagnostic: %q", diagnostic.String())
			}
		})
	}
}

// The digest exists so a run can deliver one consolidated ask instead of
// assembling nineteen by hand. It must therefore carry exactly the unasked
// authority blockers -- a digest that echoed every finding would re-create the
// hand-assembly problem, so the conforming and malformed rows are the control.
func TestAskDigestSelectsOnlyUnaskedAuthorityBlockersOldestFirst(t *testing.T) {
	input := `[
	  {"repo":"beta","number":2,"created_at":"2026-08-01T00:00:00Z","body":"**Blocker:** maintainer authority - newer account action | last-verified 2026-09-01: pending"},
	  {"repo":"alpha","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - oldest account action | last-verified 2026-09-01: pending"},
	  {"repo":"gamma","number":3,"created_at":"2026-07-01T00:00:00Z","body":"**Blocker:** o/r#7 | upstream | last-verified 2026-09-01: pending"},
	  {"repo":"delta","number":4,"created_at":"2026-07-02T00:00:00Z","body":"**Blocker:** nonsense"}
	]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 {
		t.Fatalf("code=%d, want 1; output=%q stderr=%q", code, got, stderr.String())
	}
	for _, want := range []string{"alpha#1", "beta#2", "oldest account action", "newer account action", "81d", "36d"} {
		if !strings.Contains(got, want) {
			t.Fatalf("digest missing %q; got %q", want, got)
		}
	}
	// Control: a conforming record and a malformed one are both excluded.
	for _, absent := range []string{"gamma#3", "delta#4"} {
		if strings.Contains(got, absent) {
			t.Fatalf("digest must exclude %q; got %q", absent, got)
		}
	}
	if strings.Index(got, "alpha#1") > strings.Index(got, "beta#2") {
		t.Fatalf("digest must be oldest-first; got %q", got)
	}
}

// An unparseable or absent creation date must not drop the row or fail the
// read: the ask is still owed. It sorts last so the aged head stays stable.
func TestAskDigestKeepsRowsWithUnknownAge(t *testing.T) {
	input := `[
	  {"repo":"nodate","number":9,"body":"**Blocker:** maintainer authority - undated action | last-verified 2026-09-01: pending"},
	  {"repo":"dated","number":8,"created_at":"2026-08-01T00:00:00Z","body":"**Blocker:** maintainer authority - dated action | last-verified 2026-09-01: pending"}
	]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 || !strings.Contains(got, "nodate#9") || !strings.Contains(got, "dated#8") {
		t.Fatalf("code=%d output=%q stderr=%q", code, got, stderr.String())
	}
	if strings.Index(got, "dated#8") > strings.Index(got, "nodate#9") {
		t.Fatalf("undated rows sort last; got %q", got)
	}
}

// A malformed record is still a finding, so the exit status must stay 1 even
// when the digest itself is empty. Reporting 0 here would let a real repair
// need vanish behind an empty ask sheet.
func TestAskDigestEmptyStillReportsOtherFindings(t *testing.T) {
	input := `[{"repo":"r","number":4,"created_at":"2026-07-02T00:00:00Z","body":"**Blocker:** nonsense"}]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 {
		t.Fatalf("code=%d, want 1; output=%q", code, got)
	}
	if !strings.Contains(got, "no declared authority blocker") {
		t.Fatalf("empty digest must say so; got %q", got)
	}
}

// The digest is opt-in: without the flag the verdict report is byte-identical
// to what every existing caller already parses.
func TestAskDigestIsOptIn(t *testing.T) {
	input := `[{"repo":"r","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - an action | last-verified 2026-09-01: pending"}]`
	var out, stderr bytes.Buffer
	code := run([]string{"--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 || !strings.Contains(got, "NO-ASK") || strings.Contains(got, "ASK DIGEST") {
		t.Fatalf("default output changed: code=%d output=%q", code, got)
	}
}

// A stale ask record still needs verification, so the sheet must carry it,
// distinguished from a missing ask record.
// The fresh ask is the control: it conforms, so it must NOT appear.
func TestAskDigestIncludesStaleAsksAndExcludesFreshOnes(t *testing.T) {
	input := `[
	  {"repo":"stale","number":5,"created_at":"2026-07-01T00:00:00Z","body":"**Blocker:** maintainer authority - stale action | last-verified 2026-09-01: pending | asked pr 2026-08-01"},
	  {"repo":"fresh","number":6,"created_at":"2026-07-02T00:00:00Z","body":"**Blocker:** maintainer authority - fresh action | last-verified 2026-09-01: pending | asked pr 2026-09-05"}
	]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 {
		t.Fatalf("code=%d, want 1; output=%q stderr=%q", code, got, stderr.String())
	}
	if !strings.Contains(got, "stale#5") || !strings.Contains(got, "verify before renewing") {
		t.Fatalf("stale ask must appear and be marked; got %q", got)
	}
	if strings.Contains(got, "fresh#6") {
		t.Fatalf("a fresh ask conforms and must be excluded; got %q", got)
	}
}

// The two record states must stay distinguishable without claiming that a
// missing record proves no ask was delivered.
func TestAskDigestLabelsNeverAskedRows(t *testing.T) {
	input := `[{"repo":"r","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - an action | last-verified 2026-09-01: pending"}]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 || !strings.Contains(got, "no ask recorded") || strings.Contains(got, "verify before renewing") {
		t.Fatalf("code=%d output=%q", code, got)
	}
}

// The sheet is built to be pasted into a PR, Slack or a session, and issue
// bodies are attacker-authorable. A live mention or bot command surviving into
// it would fire when delivered, from our own authenticated account.
func TestAskDigestNeutralizesActiveSyntaxInUntrustedText(t *testing.T) {
	input := `[{"repo":"r","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - ping @codex review and @devantler about #123 | last-verified 2026-09-01: pending"}]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 {
		t.Fatalf("code=%d output=%q", code, got)
	}
	for _, live := range []string{"@codex", "@devantler", "#123"} {
		if strings.Contains(got, live) {
			t.Fatalf("live token %q survived into the digest: %q", live, got)
		}
	}
	// Control: the words are still there, only the trigger characters are inert.
	for _, want := range []string{"codex", "devantler", "123"} {
		if !strings.Contains(got, want) {
			t.Fatalf("neutralizing must keep the text readable, lost %q: %q", want, got)
		}
	}
	// And it is marked as quoted untrusted text, not presented as instruction.
	if !strings.Contains(got, "\n  > ") {
		t.Fatalf("request must be quoted; got %q", got)
	}
}

func TestAskRequestOmitsURLs(t *testing.T) {
	for _, link := range []string{
		"https://example.invalid/path",
		"HTTP://example.invalid/path",
		"www.example.invalid/path",
		"//example.invalid/path",
		"example.invalid/path",
		"mailto:person@example.invalid",
	} {
		t.Run(link, func(t *testing.T) {
			line := "**Blocker:** inspect " + link + " then continue | authority | last-verified 2026-09-06: pending"
			if got := askRequest(line); got != "inspect \\[URL omitted] then continue" {
				t.Fatalf("URL must not survive in the quoted request: %q", got)
			}
		})
	}
	if got := askRequest("**Blocker:** inspect the account setting | authority"); got != "inspect the account setting" {
		t.Fatalf("ordinary description changed: %q", got)
	}
}

func TestAskDigestOmitsAllURLsInDescription(t *testing.T) {
	input := `[{"repo":"r","number":1,"body":"**Blocker:** inspect https://one.invalid then www.two.invalid and //three.invalid | authority | last-verified 2026-09-06: pending"}]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 || !strings.Contains(got, "  > inspect \\[URL omitted] then \\[URL omitted] and \\[URL omitted]\n") {
		t.Fatalf("code=%d output=%q stderr=%q", code, got, stderr.String())
	}
}

func TestAskRequestNeutralizesEncodedDestinationsAndControls(t *testing.T) {
	for _, tc := range []struct {
		name, description, want string
	}{
		{
			name:        "named entity destination",
			description: "[example](https&colon;&sol;&sol;example.invalid)",
			want:        "\\[example](\\[URL omitted]",
		},
		{
			name:        "numeric entity destination",
			description: "inspect https&#58;&#47;&#47;example.invalid",
			want:        "inspect \\[URL omitted]",
		},
		{
			name:        "encoded newline and mention",
			description: "inspect&NewLine;&commat;codex review",
			want:        "inspect\ufffd@\u200bcodex review",
		},
		{
			name:        "nested entities cannot decode into a URL later",
			description: "[example](https&amp;colon;&amp;sol;&amp;sol;example.invalid)",
			want:        "\\[example](https&amp;colon;&amp;sol;&amp;sol;example.invalid)",
		},
		{
			name:        "backslash cannot unescape a bracket",
			description: `\[example](https&amp;colon;&amp;sol;&amp;sol;example.invalid)`,
			want:        `\\\[example](https&amp;colon;&amp;sol;&amp;sol;example.invalid)`,
		},
		{
			name:        "HTML stays literal",
			description: "<b>inspect the account</b>",
			want:        "&lt;b&gt;inspect the account&lt;/b&gt;",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := askRequest("**Blocker:** " + tc.description + " | authority"); got != tc.want {
				t.Fatalf("got %q; want %q", got, tc.want)
			}
		})
	}
}

// Slack authenticates as the maintainer's own account, so a digest delivered
// without a leading disclosure reads as him writing to himself.
func TestAskDigestLeadsWithTheAgentDisclosure(t *testing.T) {
	input := `[{"repo":"r","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - an action | last-verified 2026-09-01: pending"}]`
	var out, stderr bytes.Buffer
	run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	if !strings.HasPrefix(out.String(), "> 🤖 Generated by the ") {
		t.Fatalf("digest must begin with the disclosure; got %q", out.String())
	}
}

// Visibility is not in the search payload, so the sheet must not imply it is
// safe for a public channel, and must name the repositories to check.
func TestAskDigestCautionsOnRepositoryVisibility(t *testing.T) {
	input := `[
	  {"repo":"beta","number":2,"created_at":"2026-08-01T00:00:00Z","body":"**Blocker:** maintainer authority - b | last-verified 2026-09-01: pending"},
	  {"repo":"alpha","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - a | last-verified 2026-09-01: pending"}
	]`
	var out, stderr bytes.Buffer
	run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if !strings.Contains(got, "CHECK BEFORE DELIVERY") || !strings.Contains(got, "alpha, beta") {
		t.Fatalf("digest must caution and list distinct repositories; got %q", got)
	}
	// Verification may establish a maintainer action, not an agent-owned decision to defer.
	if strings.Contains(got, "maintainer decision") || !strings.Contains(got, "maintainer action") {
		t.Fatalf("digest must ask for an action, not a decision; got %q", got)
	}
}

// A legacy record still needs migrating to an explicit class token, and a row
// naming only an identifier cannot communicate what to actually do. Both must
// stay visible, or an ask gets recorded as delivered while being useless.
func TestAskDigestFlagsLegacyAndActionlessRows(t *testing.T) {
	input := `[
	  {"repo":"legacyrepo","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority | last-verified 2026-09-01: pending"},
	  {"repo":"explicit","number":2,"created_at":"2026-08-01T00:00:00Z","body":"**Blocker:** rotate the signing key | authority | last-verified 2026-09-01: pending"}
	]`
	var out, stderr bytes.Buffer
	run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if !strings.Contains(got, "[legacy: no class token]") {
		t.Fatalf("legacy annotation must survive into the digest; got %q", got)
	}
	if !strings.Contains(got, "NO ACTION DESCRIBED") {
		t.Fatalf("an identifier-only record must be flagged; got %q", got)
	}
	// Control: the explicit, descriptive row carries neither marker.
	line := ""
	for _, l := range strings.Split(got, "\n") {
		if strings.Contains(l, "explicit#2") {
			line = l
		}
	}
	if line == "" || strings.Contains(line, "legacy") || strings.Contains(line, "NO ACTION") {
		t.Fatalf("descriptive explicit row must be unmarked; got line %q in %q", line, got)
	}
}
