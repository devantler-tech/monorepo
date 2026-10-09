package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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
		{"push is excluded on purpose, git push or notification (monorepo#3243)", "maintainer authority | authority | last-verified 2026-09-01: pending | asked push 2026-09-01", "NO-ASK"},
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

// A caller reading only --help has no other definition of the ask channels,
// and the help once sent a Slack ask to "the declared Slack channel" while the
// guides send it to the maintainer's self-DM, because every channel in the
// workspace is public (#3784). Pin the help to what the check enforces: the
// tokens it advertises are exactly the ones classify accepts, the words it
// rules out are ones classify reads as NO-ASK, and each is defined.
func TestHelpDefinesTheEnforcedAskVocabulary(t *testing.T) {
	today, err := civilDate("2026-09-05")
	if err != nil {
		t.Fatal(err)
	}
	verdict := func(word string) string {
		got, _ := classify("**Blocker:** maintainer authority | authority | last-verified 2026-09-01: pending | asked "+word+" 2026-09-01", today, 14)
		return got
	}
	grammars := regexp.MustCompile(`asked <([^>]*)>`).FindAllStringSubmatch(help, -1)
	if len(grammars) == 0 {
		t.Fatal("help no longer shows the `asked <...>` grammar, so its tokens cannot be checked")
	}
	for _, grammar := range grammars {
		if grammar[1] != strings.Join(askChannels, "|") {
			t.Errorf("help advertises asked <%s>, the check accepts %q", grammar[1], askChannels)
		}
	}
	// The paragraph is reflowed: its sentences wrap across source lines.
	_, after, found := strings.Cut(help, "\nAsk channels: ")
	paragraph, _, closed := strings.Cut(after, "\n\n")
	if !found || !closed {
		t.Fatal("help has no `Ask channels:` paragraph, so its definitions cannot be checked")
	}
	paragraph = strings.Join(strings.Fields(paragraph), " ")
	var defined []string
	for _, definition := range regexp.MustCompile(`([a-z]+) = `).FindAllStringSubmatch(paragraph, -1) {
		defined = append(defined, definition[1])
	}
	if strings.Join(defined, "|") != strings.Join(askChannels, "|") {
		t.Errorf("help defines %q, the check accepts %q", defined, askChannels)
	}
	for _, token := range askChannels {
		if got := verdict(token); got != "CONFORMS" {
			t.Errorf("help defines %q as a channel, but the check reads it as %s", token, got)
		}
	}
	for _, word := range []string{"push", "issue"} {
		if got := verdict(word); got != "NO-ASK" {
			t.Errorf("%q must read as NO-ASK, got %s", word, got)
		}
	}
	for _, clause := range []string{
		"slack = the Slack DM to the maintainer's own user (his self-DM), never a Slack channel, because every channel in the workspace is public;",
		"No other word is a channel token, and the check reads any other word as NO-ASK.",
		"That includes push, whether it means a git push or the runtime's push notification, and issue:",
	} {
		if !strings.Contains(paragraph, clause) {
			t.Errorf("help no longer says %q in:\n%s", clause, paragraph)
		}
	}
}

// A token is matched as the text it is. Spliced into the expression unquoted, a
// token such as "self.dm" would also accept "selfXdm" and quietly widen what
// counts as asked.
func TestAskExpressionMatchesEachTokenLiterally(t *testing.T) {
	expression := askExpression([]string{"self.dm", "a|b"})
	for record, want := range map[string]bool{
		"x | asked self.dm 2026-09-01": true,
		"x | asked selfXdm 2026-09-01": false,
		"x | asked a|b 2026-09-01":     true,
		"x | asked a 2026-09-01":       false,
		"x | asked b 2026-09-01":       false,
	} {
		if got := expression.MatchString(record); got != want {
			t.Errorf("%q: matched=%v, want %v", record, got, want)
		}
	}
}

// The digest tells an agent where to deliver the ask, so it names the same
// closed set and, like the help, the one private Slack destination (#3784).
func TestAskDigestNamesTheEnforcedChannelsAndTheSlackDestination(t *testing.T) {
	input := `[{"repo":"r","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - an action | last-verified 2026-09-01: pending"}]`
	var out, stderr bytes.Buffer
	run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	for _, want := range []string{
		"(" + strings.Join(askChannels, " | ") + "), then append `| asked <channel> <YYYY-MM-DD>`",
		"slack means the maintainer's own Slack self-DM, never a Slack channel: every channel in the workspace is public.\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("digest no longer says %q in:\n%s", want, got)
		}
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
		{"all pages", `{"total_count":2,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1,"labels":[],"type":null,"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"sub_issues_summary":{"total":0,"completed":0}}]} {"total_count":2,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":2,"labels":[{"name":"blocked"}],"type":{"name":"Bug"},"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"sub_issues_summary":{"total":0,"completed":0}}]}`, 2, false},
		{"item without labels", `{"total_count":1,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1}]}`, 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := searchIssues([]byte(tc.raw), true)
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
			code := run([]string{"--quiet", "--today", "2026-09-02", "--input", "-"}, strings.NewReader(tc.input), &out, &stderr)
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
	for _, want := range []string{"alpha#\u200b1", "beta#\u200b2", "oldest account action", "newer account action", "81d", "36d"} {
		if !strings.Contains(got, want) {
			t.Fatalf("digest missing %q; got %q", want, got)
		}
	}
	// Control: a conforming record and a malformed one are both excluded.
	for _, absent := range []string{"gamma#\u200b3", "delta#\u200b4"} {
		if strings.Contains(got, absent) {
			t.Fatalf("digest must exclude %q; got %q", absent, got)
		}
	}
	if strings.Index(got, "alpha#\u200b1") > strings.Index(got, "beta#\u200b2") {
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
	if code != 1 || !strings.Contains(got, "nodate#\u200b9") || !strings.Contains(got, "dated#\u200b8") {
		t.Fatalf("code=%d output=%q stderr=%q", code, got, stderr.String())
	}
	if strings.Index(got, "dated#\u200b8") > strings.Index(got, "nodate#\u200b9") {
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
	if !strings.Contains(got, "1 finding(s) outside this digest") || !strings.Contains(got, "without `--ask-digest`") {
		t.Fatalf("other repair needs must remain discoverable; got %q", got)
	}
}

func TestAskDigestMixedFindingsRemainDiscoverable(t *testing.T) {
	input := `[{"repo":"r","number":1,"body":"**Blocker:** inspect account access | authority | last-verified 2026-09-06: pending"},{"repo":"r","number":2}]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 || !strings.Contains(got, "r#\u200b1") || !strings.Contains(got, "1 finding(s) outside this digest") || !strings.Contains(got, "without `--ask-digest`") {
		t.Fatalf("mixed input must expose the separate repair need: code=%d output=%q", code, got)
	}
	if strings.Contains(got, "r#\u200b2") {
		t.Fatalf("non-ask findings must not enter the ask rows: %q", got)
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
	if !strings.Contains(got, "stale#\u200b5") || !strings.Contains(got, "verify before renewing") {
		t.Fatalf("stale ask must appear and be marked; got %q", got)
	}
	if strings.Contains(got, "fresh#\u200b6") {
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
	input := `[{"repo":"r","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - @codex review @devantler #123 /close &sol;reopen | last-verified 2026-09-01: pending"}]`
	var out, stderr bytes.Buffer
	code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
	got := out.String()
	if code != 1 {
		t.Fatalf("code=%d output=%q", code, got)
	}
	for _, live := range []string{"@codex", "@devantler", "#123", "/close", "/reopen"} {
		if strings.Contains(got, live) {
			t.Fatalf("live token %q survived into the digest: %q", live, got)
		}
	}
	// Control: the words are still there, only the trigger characters are inert.
	for _, want := range []string{"codex", "devantler", "123", "close", "reopen"} {
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
			name:        "GH reference spellings",
			description: "GH-123 gh-123 Gh-123",
			want:        "G\u200bH-123 g\u200bh-123 G\u200bh-123",
		},
		{
			name:        "HTML stays literal",
			description: "<b>inspect the account</b>",
			want:        "&lt;b&gt;inspect the account&lt;/\u200bb&gt;",
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
	for _, input := range []string{
		`[{"repo":"r","number":1,"created_at":"2026-06-17T00:00:00Z","body":"**Blocker:** maintainer authority - an action | last-verified 2026-09-01: pending"}]`,
		`[]`,
		`[{"repo":"r","number":1,"body":"**Blocker:** nonsense"}]`,
	} {
		var out, stderr bytes.Buffer
		run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, strings.NewReader(input), &out, &stderr)
		if !strings.HasPrefix(out.String(), "> 🤖 Generated by the ") {
			t.Fatalf("digest must begin with the disclosure; got %q", out.String())
		}
	}
}

func TestAskDigestNeutralizesRepositoryNames(t *testing.T) {
	for _, tc := range []struct{ repo, want string }{
		{"@codex review", "@\u200bcodex review"},
		{"&commat;codex review&NewLine;GH-123", "@\u200bcodex review\ufffdG\u200bH-123"},
		{"[example](https&colon;&sol;&sol;example.invalid)", "\\[example](\\[URL omitted]"},
		{"ordinary.repo-name", "ordinary.repo-name"},
	} {
		t.Run(tc.repo, func(t *testing.T) {
			input, err := json.Marshal([]issue{{Repo: tc.repo, Number: 1, Body: "**Blocker:** inspect account access | authority | last-verified 2026-09-06: pending"}})
			if err != nil {
				t.Fatal(err)
			}
			var out, stderr bytes.Buffer
			code := run([]string{"--ask-digest", "--today", "2026-09-06", "--input", "-"}, bytes.NewReader(input), &out, &stderr)
			got := out.String()
			if code != 1 || !strings.Contains(got, "confirmed public: "+tc.want+"\n") || !strings.Contains(got, "  "+tc.want+"#\u200b1 ") {
				t.Fatalf("repository text must be inert in both display locations: code=%d output=%q", code, got)
			}
		})
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
	  {"repo":"explicit","number":2,"created_at":"2026-08-01T00:00:00Z","body":"**Blocker:** rotate the signing key | authority | last-verified 2026-09-01: pending"},
	  {"repo":"encoded","number":3,"created_at":"2026-08-01T00:00:00Z","body":"**Blocker:** &num;7 | authority | last-verified 2026-09-01: pending"},
	  {"repo":"ghref","number":4,"body":"**Blocker:** GH-123 | authority | last-verified 2026-09-01: pending"},
	  {"repo":"shortref","number":5,"body":"**Blocker:** monorepo#7 | authority | last-verified 2026-09-01: pending"},
	  {"repo":"lowergh","number":6,"body":"**Blocker:** gh-123 | authority | last-verified 2026-09-01: pending"}
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
	opaqueRows := map[string]bool{"encoded#\u200b3": false, "ghref#\u200b4": false, "shortref#\u200b5": false, "lowergh#\u200b6": false}
	for _, l := range strings.Split(got, "\n") {
		if strings.Contains(l, "explicit#\u200b2") {
			line = l
		}
		for identifier := range opaqueRows {
			if strings.Contains(l, identifier) && strings.Contains(l, "NO ACTION DESCRIBED") {
				opaqueRows[identifier] = true
			}
		}
	}
	if line == "" || strings.Contains(line, "legacy") || strings.Contains(line, "NO ACTION") {
		t.Fatalf("descriptive explicit row must be unmarked; got line %q in %q", line, got)
	}
	for identifier, flagged := range opaqueRows {
		if !flagged {
			t.Errorf("identifier-only row %q must be flagged; got %q", identifier, got)
		}
	}
}

// A record re-verified long ago still has a conforming shape, but a blocker
// skip needs a live check, so it is reported STALE (#3161).
func TestStaleVerificationIsAFinding(t *testing.T) {
	record := func(date string) string {
		return `[{"repo":"r","number":1,"body":"**Blocker:** o/r#7 | upstream | last-verified ` + date + `: pending"}]`
	}
	for _, tc := range []struct {
		name, input string
		args        []string
		want        string
		code        int
	}{
		{"fresh today", record("2026-09-10"), nil, "CONFORMS", 0},
		{"exactly at the bound", record("2026-09-03"), nil, "CONFORMS", 0},
		{"one day past the bound", record("2026-09-02"), nil, "STALE", 1},
		{"bound is a flag", record("2026-09-02"), []string{"--verify-max-age-days", "8"}, "CONFORMS", 0},
		{"zero bound flags yesterday", record("2026-09-09"), []string{"--verify-max-age-days", "0"}, "STALE", 1},
		{"future date is never fresh", record("2026-09-11"), nil, "MALFORMED", 1},
		{"stale authority without an ask stays NO-ASK", `[{"repo":"r","number":1,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-08-01: pending"}]`, nil, "NO-ASK", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var out, stderr bytes.Buffer
			args := append([]string{"--today", "2026-09-10", "--input", "-"}, tc.args...)
			code := run(args, strings.NewReader(tc.input), &out, &stderr)
			if code != tc.code || !strings.HasPrefix(out.String(), tc.want+" ") {
				t.Fatalf("code=%d output=%q stderr=%q; want code=%d verdict=%s", code, out.String(), stderr.String(), tc.code, tc.want)
			}
		})
	}
}

func TestVerifyMaxAgeRejectsNonIntegers(t *testing.T) {
	for _, value := range []string{"", "-1", "7d", "1234567890"} {
		var out, stderr bytes.Buffer
		code := run([]string{"--verify-max-age-days", value, "--input", "-"}, strings.NewReader(`[]`), &out, &stderr)
		if code != 2 || !strings.Contains(stderr.String(), "--verify-max-age-days") {
			t.Fatalf("value %q: code=%d stderr=%q; want UNKNOWN naming the flag", value, code, stderr.String())
		}
	}
}

// runInput feeds a payload through the --input seam the forge path shares.
func runInput(t *testing.T, payload string, extra ...string) (int, string) {
	t.Helper()
	var out, stderr bytes.Buffer
	args := append([]string{"--input", "-", "--today", "2026-09-01", "--verify-max-age-days", "999999999"}, extra...)
	code := run(args, strings.NewReader(payload), &out, &stderr)
	return code, out.String() + stderr.String()
}

// The two actions issues #3142 names declare "**Blocker:** none" and are
// correctly unlabelled; the five it names declare a real blocker without the
// label. Bodies are reduced to their record lines.
const unlabelledPopulation = `[
 {"repo":"actions","number":1025,"labels":[],"type":null,"body":"**Blocker:** none — agent-actionable"},
 {"repo":"actions","number":1028,"labels":[{"name":"bug"}],"type":{"name":"Bug"},"body":"text\n\n**Blocker:** None. Ready to pick up."},
 {"repo":"platform","number":3251,"labels":[],"body":"**Blocker:** Cloudflare account action | authority | last-verified 2026-08-30: not done"},
 {"repo":"ksail","number":5150,"labels":[{"name":"enhancement"}],"body":"**Blocker:** homebrew/cask notability policy"},
 {"repo":"platform","number":9,"labels":[],"type":null,"body":"ordinary work with no record"},
 {"repo":"platform","number":10,"labels":[{"name":"blocked"}],"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-30: open"}
]`

func TestUnlabelledDeclaredBlockerIsItsOwnFinding(t *testing.T) {
	code, out := runInput(t, unlabelledPopulation)
	if code != 1 {
		t.Fatalf("code=%d, want 1; out:\n%s", code, out)
	}
	for _, want := range []string{"UNLABELLED platform#3251", "UNLABELLED ksail#5150", "2 open issue(s) declare a blocker without the blocked label"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// The class is distinct: neither unlabelled row is folded into MISSING or
	// MALFORMED, and the labelled conforming record keeps its own verdict.
	for _, unwanted := range []string{"MISSING", "MALFORMED", "blocked-labelled issue(s) need repair"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("unexpected %q in:\n%s", unwanted, out)
		}
	}
	if !strings.Contains(out, "CONFORMS   platform#10") {
		t.Errorf("labelled record lost its verdict:\n%s", out)
	}
}

func TestBlockerNoneAndRecordlessIssuesAreNotReported(t *testing.T) {
	_, out := runInput(t, unlabelledPopulation)
	for _, unwanted := range []string{"actions#1025", "actions#1028", "platform#9"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("%s reported:\n%s", unwanted, out)
		}
	}
	// Ablation: without the "none" exemption both actions issues would be
	// flagged, which is the naive check #3142 rejects.
	for _, line := range []string{"**Blocker:** none — agent-actionable", "**Blocker:** None. Ready to pick up.", "**Blocker:**none", "**Blocker:** none", "**Blocker:** NONE: nothing blocks this", "**Blocker:** none—agent-actionable"} {
		if declaresBlocker(line) {
			t.Errorf("%q read as a declared blocker", line)
		}
	}
	for _, line := range []string{"**Blocker:** nonexistent upstream fix", "**Blocker:** none/repo#7 | upstream | last-verified 2026-09-01: open", "**Blocker:** none.io/x#1 | upstream | last-verified 2026-09-01: open", "**Blocker:** none-x/r#2 | upstream | last-verified 2026-09-01: open", "**Blocker:** none_x/r#3", "**Blocker:** #12 | upstream | last-verified 2026-08-30: none shipped"} {
		if !declaresBlocker(line) {
			t.Errorf("%q read as declaring no blocker", line)
		}
	}
}

func TestLabelledOnlyPopulationKeepsItsReport(t *testing.T) {
	code, out := runInput(t, `[{"repo":"a","number":1,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-30: open"},
	 {"repo":"a","number":2,"labels":[],"type":null,"body":"plain"}]`)
	if code != 0 || !strings.Contains(out, "all 1 open blocked-labelled issue(s) carry a conforming **Blocker:** line") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

func TestUnlabelledFindingSurvivesQuietAndDigest(t *testing.T) {
	code, out := runInput(t, unlabelledPopulation, "--quiet")
	if code != 1 || !strings.Contains(out, "UNLABELLED ksail#5150") || strings.Contains(out, "CONFORMS") {
		t.Fatalf("quiet: code=%d out:\n%s", code, out)
	}
	code, out = runInput(t, unlabelledPopulation, "--ask-digest")
	if code != 1 || !strings.Contains(out, "2 finding(s) outside this digest") {
		t.Fatalf("digest: code=%d out:\n%s", code, out)
	}
}

func TestOrgReadIsIndependentOfTheBlockedLabel(t *testing.T) {
	endpoint := searchEndpoint("o")
	if strings.Contains(endpoint, "label") {
		t.Fatalf("org read still filters on a label: %s", endpoint)
	}
	for _, want := range []string{"org:o", "is:issue", "state:open", "archived:false"} {
		if !strings.Contains(endpoint, want) {
			t.Errorf("endpoint lost %q: %s", want, endpoint)
		}
	}
}

func TestBlockedLabelMatchesCaseInsensitively(t *testing.T) {
	// The label:blocked search this replaced matched "Blocked" too, so a
	// record-less issue labelled that way must stay MISSING, not vanish.
	code, out := runInput(t, `[{"repo":"c","number":1,"labels":[{"name":"Blocked"}],"body":"no record"}]`)
	if code != 1 || !strings.Contains(out, "MISSING    c#1") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

func TestReportedSnippetDropsInvisibleFormatCharacters(t *testing.T) {
	// A right-to-left override or zero-width space in untrusted issue text
	// could reorder or hide part of a reported row in the operator's terminal.
	if got := snippet("**Blocker:** a‮b​c"); strings.ContainsAny(got, "‮​") {
		t.Fatalf("format characters survived: %q", got)
	}
}

func TestLabelledAndUnlabelledSummariesAppearTogether(t *testing.T) {
	code, out := runInput(t, `[{"repo":"m","number":1,"labels":[{"name":"blocked"}],"body":"no record"},
	 {"repo":"m","number":2,"labels":[],"body":"**Blocker:** maintainer authority: sign it"}]`)
	for _, want := range []string{"1 of 1 open blocked-labelled issue(s) need repair", "1 open issue(s) declare a blocker without the blocked label"} {
		if code != 1 || !strings.Contains(out, want) {
			t.Errorf("code=%d, missing %q in:\n%s", code, want, out)
		}
	}
}

// A Security issue outranks every other issue regardless of age, so one that
// nobody has started for more than a week was passed over by every run that
// started anything else. Without a label or a declared blocker, the reason for
// that lives only in a run's private memory (#3415). parkedPayload builds that
// issue, and each control below changes one fact about it.
func parkedPayload(overrides string, others ...string) string {
	fields := map[string]json.RawMessage{}
	base := `{"repo":"platform","number":42,"labels":[],"type":{"name":"Security"},"created_at":"2026-08-20T10:00:00Z","assignees":[],
	 "issue_dependencies_summary":{"blocked_by":0},"sub_issues_summary":{"total":0,"completed":0},"body":"plain work, no record"}`
	for _, raw := range []string{base, overrides} {
		if raw == "" {
			continue
		}
		if err := json.Unmarshal([]byte(raw), &fields); err != nil {
			panic(err)
		}
	}
	record, err := json.Marshal(fields)
	if err != nil {
		panic(err)
	}
	return "[" + strings.Join(append([]string{string(record)}, others...), ",") + "]"
}

// pullRequest builds an open pull request as the search surface returns one.
func pullRequest(repo, author, body string) string {
	record, err := json.Marshal(map[string]any{
		"repo": repo, "number": 900, "labels": []any{}, "pull_request": map[string]any{},
		"user": map[string]string{"login": author}, "body": body,
	})
	if err != nil {
		panic(err)
	}
	return string(record)
}

func TestUnstartedSecurityIssueWithoutARecordIsItsOwnFinding(t *testing.T) {
	code, out := runInput(t, parkedPayload(""))
	if code != 1 {
		t.Fatalf("code=%d, want 1; out:\n%s", code, out)
	}
	for _, want := range []string{
		"UNRECORDED platform#42  opened 2026-08-20, unstarted for 12 day(s) with no record\n",
		"1 of the 1 open Security issue(s) read have gone unstarted for more than 7 day(s) with nothing on record",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	for _, unwanted := range []string{"MISSING", "UNLABELLED", "blocked-labelled issue(s) need repair", "declare a blocker without", "[assigned]"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("unexpected %q in:\n%s", unwanted, out)
		}
	}
}

// Each row is the parked issue with one fact changed. A row that stays a
// finding proves the neighbouring control clears it for its own reason.
func TestUnrecordedFindingNeedsEveryCondition(t *testing.T) {
	human := func(repo, body string) []string { return []string{pullRequest(repo, "devantler", body)} }
	for _, tc := range []struct {
		name      string
		overrides string
		others    []string
		finding   bool
	}{
		{"exactly at the bound is not past it", `{"created_at":"2026-08-25T23:59:59Z"}`, nil, false},
		{"one day past the bound", `{"created_at":"2026-08-24T00:00:00Z"}`, nil, true},
		{"open native blocker", `{"issue_dependencies_summary":{"blocked_by":1}}`, nil, false},
		{"every native blocker closed", `{"issue_dependencies_summary":{"blocked_by":0,"total_blocked_by":2}}`, nil, true},
		{"open sub-issue", `{"sub_issues_summary":{"total":3,"completed":2}}`, nil, false},
		{"every sub-issue completed", `{"sub_issues_summary":{"total":3,"completed":3}}`, nil, true},
		{"another type", `{"type":{"name":"Bug"}}`, nil, false},
		{"type name in another case", `{"type":{"name":"security"}}`, nil, true},
		{"untyped", `{"type":null}`, nil, false},
		{"opened by a dependency bot", `{"user":{"login":"renovate[bot]"}}`, nil, false},
		{"opened by the other dependency bot", `{"user":{"login":"dependabot[bot]"}}`, nil, false},
		{"a login that only resembles one", `{"user":{"login":"renovate"}}`, nil, true},
		{"pull request closes it", "", human("platform", "Fixes #42"), false},
		{"pull request is part of it", "", human("platform", "Part of #42."), false},
		{"pull request in another repository names it", "", human("ksail", "Needs devantler-tech/platform#42 first"), false},
		{"pull request links it", "", human("ksail", "See https://github.com/devantler-tech/platform/issues/42)."), false},
		{"bare number in another repository", "", human("ksail", "Fixes #42"), true},
		{"a longer number", "", human("platform", "Fixes #420 and devantler-tech/platform#421"), true},
		{"the same number elsewhere", "", human("platform", "Fixes devantler-tech/ksail#42"), true},
		{"a repository whose name only ends the same", "", human("ksail", "Fixes devantler-tech/my-platform#42"), true},
		{"an issue that mentions it is not work on it", "", []string{`{"repo":"platform","number":77,"labels":[],"type":null,"body":"after #42"}`}, true},
		// A dependency bot's pull request quotes upstream release notes.
		{"a dependency bot's pull request", "", []string{pullRequest("platform", "renovate[bot]", "Fixes #42")}, true},
		{"the other dependency bot's pull request", "", []string{pullRequest("platform", "dependabot[bot]", "Closes #42")}, true},
		// The same text a person pasted is still not a reference of ours: the
		// three shapes are the ones in open bot pull requests today.
		{"an HTML entity, as Renovate writes one", `{"number":8203}`, human("platform", "[#&#8203;1403](https://redirect.github.com/o/r/issues/1403)"), true},
		{"the text of an anchor, as Dependabot writes one", `{"repo":"ksail","number":32598}`, human("ksail", `<a href="https://redirect.github.com/helm/helm/issues/32598">#32598</a>`), true},
		{"a hex colour", "", human("platform", "color: #42a5f5;"), true},
		{"a number that runs into a word", "", human("platform", "see #42_old and #42x"), true},
		// A pull request can name an issue precisely to say it is not doing it.
		{"a Deferred line", "", human("platform", "Fixes #7\n\nDeferred: #42 — parked hardening"), true},
		{"a Deferred list item", "", human("platform", "Fixes #7\n\n- deferred: #42 — later"), true},
		{"a mention beside a Deferred line still counts", "", human("platform", "Part of #42\n\nDeferred: #43 — later"), false},
		{"hidden in an HTML comment", "", human("platform", "<!-- Fixes #42 -->\nFixes #7"), true},
		{"hidden in an HTML comment over several lines", "", human("platform", "<!--\nFixes #42\n-->\nFixes #7"), true},
		{"after an HTML comment left open", "", human("platform", "Fixes #7\n<!-- Fixes #42"), true},
		{"a mention after a closed HTML comment still counts", "", human("platform", "<!-- template -->\nFixes #42"), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := parkedPayload(tc.overrides, tc.others...)
			// The parked issue is the first record; an override may renumber it.
			var records []struct {
				Repo   string
				Number int64
			}
			if err := json.Unmarshal([]byte(payload), &records); err != nil {
				t.Fatal(err)
			}
			row := fmt.Sprintf("UNRECORDED %s#%d  ", records[0].Repo, records[0].Number)
			code, out := runInput(t, payload)
			if got := strings.Contains(out, row); got != tc.finding || (code == 1) != tc.finding {
				t.Fatalf("finding=%v code=%d, want finding=%v; out:\n%s", got, code, tc.finding, out)
			}
		})
	}
}

// An assignment is a claim that lapses after about two hours, not a start: an
// assignee left on an issue would otherwise hide it for good. The row says the
// issue is assigned, so the reader checks the lease instead of the guard
// trusting it.
func TestAnAssigneeDoesNotClearAnUnstartedIssue(t *testing.T) {
	code, out := runInput(t, parkedPayload(`{"assignees":[{"login":"devantler"}]}`))
	if code != 1 || !strings.Contains(out, "UNRECORDED platform#42  opened 2026-08-20, unstarted for 12 day(s) with no record  [assigned]\n") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// "**Blocker:** none" says nothing blocks the issue. On an unstarted Security
// issue that is the clearest case of parking without a reason, and it must not
// be a way to clear the row without starting anything.
func TestDeclaringNoBlockerDoesNotClearAnUnstartedIssue(t *testing.T) {
	code, out := runInput(t, parkedPayload(`{"body":"**Blocker:** none — agent-actionable"}`))
	if code != 1 || !strings.Contains(out, "UNRECORDED platform#42  opened 2026-08-20, unstarted for 12 day(s) while declaring no blocker\n") || strings.Contains(out, "UNLABELLED") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	// Control: within the bound the same record is not reported, as #3142 requires.
	if code, out := runInput(t, parkedPayload(`{"body":"**Blocker:** none — agent-actionable","created_at":"2026-08-30T00:00:00Z"}`)); code != 0 || strings.Contains(out, "platform#42") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// A label without a record is already MISSING, and a record without a label is
// already UNLABELLED: the new class is only the issue that declares no blocker.
func TestUnrecordedIsDistinctFromARecordThatIsPresent(t *testing.T) {
	for _, tc := range []struct{ name, overrides, want string }{
		{"labelled without a record", `{"labels":[{"name":"blocked"}]}`, "MISSING    platform#42"},
		{"record without the label", `{"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-30: open"}`, "UNLABELLED platform#42"},
		{"labelled and conforming", `{"labels":[{"name":"blocked"}],"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-30: open"}`, "CONFORMS   platform#42"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, out := runInput(t, parkedPayload(tc.overrides))
			if !strings.Contains(out, tc.want) || strings.Contains(out, "UNRECORDED") {
				t.Fatalf("want %q and no UNRECORDED row; out:\n%s", tc.want, out)
			}
		})
	}
}

func TestUnrecordedBoundIsAFlag(t *testing.T) {
	if code, out := runInput(t, parkedPayload(""), "--unrecorded-max-age-days", "12"); code != 0 || strings.Contains(out, "UNRECORDED") {
		t.Fatalf("12 days open is within a 12-day bound: code=%d out:\n%s", code, out)
	}
	if code, out := runInput(t, parkedPayload(""), "--unrecorded-max-age-days", "11"); code != 1 || !strings.Contains(out, "more than 11 day(s)") {
		t.Fatalf("12 days open is past an 11-day bound: code=%d out:\n%s", code, out)
	}
	for _, value := range []string{"", "-1", "7d", "1234567890"} {
		var out, stderr bytes.Buffer
		code := run([]string{"--unrecorded-max-age-days", value, "--input", "-"}, strings.NewReader(`[]`), &out, &stderr)
		if code != 2 || !strings.Contains(stderr.String(), "--unrecorded-max-age-days") {
			t.Fatalf("value %q: code=%d stderr=%q; want UNKNOWN naming the flag", value, code, stderr.String())
		}
	}
}

func TestUnrecordedFindingSurvivesQuietAndDigest(t *testing.T) {
	code, out := runInput(t, parkedPayload(""), "--quiet")
	if code != 1 || out != "UNRECORDED platform#42  opened 2026-08-20, unstarted for 12 day(s) with no record\n" {
		t.Fatalf("quiet: code=%d out:\n%s", code, out)
	}
	code, out = runInput(t, parkedPayload(""), "--ask-digest")
	if code != 1 || !strings.Contains(out, "1 finding(s) outside this digest") {
		t.Fatalf("digest: code=%d out:\n%s", code, out)
	}
}

// The verdict says how many Security issues it rests on. A type that was
// renamed or switched off would otherwise read as "none unstarted".
func TestTheVerdictCountsTheSecurityIssuesItRead(t *testing.T) {
	fresh := parkedPayload(`{"created_at":"2026-08-30T00:00:00Z"}`, `{"repo":"platform","number":43,"labels":[],"type":{"name":"Bug"},"body":"plain"}`)
	if code, out := runInput(t, fresh); code != 0 || !strings.Contains(out, "and none of the 1 open Security issue(s) read has gone unstarted for more than 7 day(s) with nothing on record.") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	if code, out := runInput(t, `[{"repo":"platform","number":43,"labels":[],"type":{"name":"Bug"},"body":"plain"}]`); code != 0 || !strings.Contains(out, "none of the 0 open Security issue(s) read") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	// Another class of finding does not hide the count.
	withMissing := parkedPayload(`{"created_at":"2026-08-30T00:00:00Z"}`, `{"repo":"platform","number":44,"labels":[{"name":"blocked"}],"body":"no record"}`)
	if code, out := runInput(t, withMissing); code != 1 || !strings.Contains(out, "MISSING    platform#44") || !strings.Contains(out, "none of the 1 open Security issue(s) read") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// A pull request's body is read only for the issues it mentions. Judged as an
// issue it would be MISSING under a blocked label and UNLABELLED under a
// record. A blocked-labelled one is judged by its record comment instead
// (parked_test.go); this one carries a conforming record and a body without.
func TestPullRequestsAreNeverJudgedAsIssues(t *testing.T) {
	code, out := runInput(t, `[
	 {"repo":"p","number":5,"pull_request":{},"labels":[{"name":"blocked"}],"body":"no record","comments":[{"user":{"login":"devantler"},"body":"> 🤖 Generated by the Agentic Engineer\n\n<!-- pr-blocker-record -->\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-09-01: open"}]},
	 {"repo":"p","number":6,"pull_request":{},"labels":[],"body":"**Blocker:** owner/repo#7"},
	 {"repo":"p","number":7,"pull_request":{},"labels":[],"type":{"name":"Security"},"created_at":"2026-01-01T00:00:00Z","body":"old"}]`)
	if code != 0 || !strings.Contains(out, "all 0 open blocked-labelled issue(s)") || !strings.Contains(out, "none of the 0 open Security issue(s) read") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// A fact the verdict rests on that cannot be read is neither a finding nor a
// clean result: an age is not shown to be within the bound, a type is not
// shown to be outside the population, and a missing blocker or sub-issue
// summary is not zero.
func TestUnreadableUnrecordedInputIsUnknown(t *testing.T) {
	for _, tc := range []struct{ name, overrides, want string }{
		{"no creation date", `{"created_at":""}`, "no readable created_at"},
		{"impossible creation date", `{"created_at":"2026-02-30T00:00:00Z"}`, "no readable created_at"},
		{"created after today", `{"created_at":"2026-09-02T00:00:00Z"}`, "no readable created_at on or before today"},
		{"type is not an object", `{"type":"Security"}`, "unreadable type"},
		{"type without a name", `{"type":{"id":7}}`, "unreadable type"},
		{"no assignees", `{"assignees":null}`, "carries no assignees"},
		{"no native-blocker summary", `{"issue_dependencies_summary":null}`, "carries no issue_dependencies_summary.blocked_by"},
		{"native-blocker summary without its count", `{"issue_dependencies_summary":{"total_blocked_by":0}}`, "carries no issue_dependencies_summary.blocked_by"},
		{"no sub-issue summary", `{"sub_issues_summary":null}`, "carries no sub_issues_summary"},
		{"sub-issue summary without its completed count", `{"sub_issues_summary":{"total":2}}`, "carries no sub_issues_summary"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, out := runInput(t, parkedPayload(tc.overrides))
			if code != 2 || !strings.Contains(out, tc.want) || !strings.Contains(out, "UNKNOWN") || strings.Contains(out, "all 0 open") {
				t.Fatalf("code=%d, want UNKNOWN naming %q; out:\n%s", code, tc.want, out)
			}
		})
	}
	// Control: the same unreadable facts on an issue outside the population are
	// not consulted, so a record of another type needs none of them.
	if code, out := runInput(t, parkedPayload(`{"created_at":"","type":{"name":"Bug"},"assignees":null,"issue_dependencies_summary":null,"sub_issues_summary":null}`)); code != 0 {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// An unlabelled issue that declares no blocker is judged by its type. Without
// the key the payload cannot say whether it is a Security issue, and reading
// that as "it is not" would print a clean result for a question nobody asked.
func TestAnIssueThatNeedsItsTypeMustCarryIt(t *testing.T) {
	for _, body := range []string{"plain work", "**Blocker:** none — agent-actionable"} {
		record, err := json.Marshal(map[string]any{"repo": "p", "number": 1, "labels": []any{}, "body": body})
		if err != nil {
			t.Fatal(err)
		}
		code, out := runInput(t, "["+string(record)+"]")
		if code != 2 || !strings.Contains(out, "p#1 carries no type") || strings.Contains(out, "all 0 open") {
			t.Fatalf("body %q: code=%d out:\n%s", body, code, out)
		}
	}
	// Controls: null is an answer, and a record that is judged without its type
	// needs none -- a labelled one, the earlier payload shape with no labels
	// array, and one that declares a blocker.
	for _, payload := range []string{
		`[{"repo":"p","number":1,"labels":[],"type":null,"body":"plain work"}]`,
		`[{"repo":"p","number":1,"labels":[{"name":"blocked"}],"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-30: open"}]`,
		`[{"repo":"p","number":1,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-30: open"}]`,
	} {
		if code, out := runInput(t, payload); code != 0 {
			t.Fatalf("code=%d for %s; out:\n%s", code, payload, out)
		}
	}
	if code, out := runInput(t, `[{"repo":"p","number":1,"labels":[],"body":"**Blocker:** owner/repo#7"}]`); code != 1 || !strings.Contains(out, "UNLABELLED p#1") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
}

// forgeIssue is one item of the issue read, with every key the forge sends
// that the guard reads. Each %s takes one more key, or drops one named in it.
const forgeIssue = `{"repository_url":"https://api.github.com/repos/o/platform","number":42,"labels":[],"type":{"name":"Security"},"created_at":"2026-08-20T10:00:00Z","assignees":[],"issue_dependencies_summary":{"blocked_by":0},"sub_issues_summary":{"total":0,"completed":0},"body":"plain"}`

func searchPage(items ...string) string {
	return fmt.Sprintf(`{"total_count":%d,"incomplete_results":false,"items":[%s]}`, len(items), strings.Join(items, ","))
}

// without drops one top-level key from a JSON object.
func without(t *testing.T, object, key string) string {
	t.Helper()
	fields := map[string]json.RawMessage{}
	if err := json.Unmarshal([]byte(object), &fields); err != nil {
		t.Fatal(err)
	}
	if _, present := fields[key]; !present {
		t.Fatalf("%s has no %q to drop", object, key)
	}
	delete(fields, key)
	out, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

// The forge sends type, assignees and both summaries on every issue. A page
// without one of them is a changed payload: read as empty it would turn every
// issue into "untyped", or into one with no blocker and no sub-issue.
func TestSearchItemWithoutAFactTheVerdictNeedsIsUnknown(t *testing.T) {
	if got, err := searchIssues([]byte(searchPage(forgeIssue)), true); err != nil || len(got) != 1 {
		t.Fatalf("complete item: got %d records, err=%v", len(got), err)
	}
	for _, key := range []string{"type", "assignees", "issue_dependencies_summary", "sub_issues_summary"} {
		item := without(t, forgeIssue, key)
		if _, err := searchIssues([]byte(searchPage(item)), true); err == nil || !strings.Contains(err.Error(), "search item without "+key) {
			t.Errorf("an issue without %s read as complete: err=%v", key, err)
		}
		// A pull request carries none of them to read, so its page needs none.
		if got, err := searchIssues([]byte(searchPage(item)), false); err != nil || len(got) != 1 {
			t.Errorf("pull-request page without %s: got %d records, err=%v", key, len(got), err)
		}
	}
	// null is the forge's answer for an untyped issue, not a missing key.
	untyped := strings.Replace(forgeIssue, `"type":{"name":"Security"}`, `"type":null`, 1)
	if got, err := searchIssues([]byte(searchPage(untyped)), true); err != nil || len(got) != 1 {
		t.Fatalf("untyped item: got %d records, err=%v", len(got), err)
	}
}

// serveForge answers the two org reads from fixed pages. A read named in
// failing returns its COMPLETE page together with an error, as gh does when it
// prints a page and then exits non-zero: the guard must refuse it for the
// error, not because the output happened to be empty.
func serveForge(t *testing.T, issuePage, pullPage string, failing string) {
	t.Helper()
	original := forgeRead
	t.Cleanup(func() { forgeRead = original })
	forgeRead = func(endpoint string) ([]byte, error) {
		var page string
		switch endpoint {
		case searchEndpoint("o"):
			page = issuePage
		case pullEndpoint("o"):
			page = pullPage
		default:
			t.Errorf("unexpected read %q", endpoint)
			return nil, errors.New("unexpected read")
		}
		if endpoint == failing {
			return []byte(page), errors.New("exit status 1")
		}
		return []byte(page), nil
	}
}

func runOrg(t *testing.T) (int, string) {
	t.Helper()
	var out, stderr bytes.Buffer
	code := run([]string{"--org", "o", "--today", "2026-09-01"}, strings.NewReader(""), &out, &stderr)
	return code, out.String() + stderr.String()
}

func forgePull(repo, author, body string) string {
	record, err := json.Marshal(map[string]any{
		"repository_url": "https://api.github.com/repos/o/" + repo, "number": 900, "labels": []any{},
		"pull_request": map[string]any{}, "user": map[string]string{"login": author}, "body": body,
	})
	if err != nil {
		panic(err)
	}
	return string(record)
}

// The org read is two reads. Either one failing, or coming back incomplete,
// must be UNKNOWN: without the pull requests every in-flight issue reads as
// unstarted, and without the issues there is nothing to judge.
func TestOrgReadFailsClosedOnEitherRead(t *testing.T) {
	issues := searchPage(forgeIssue)
	pulls := searchPage(forgePull("platform", "devantler", "Fixes #42"))
	t.Run("both reads complete, and the pull request clears the issue", func(t *testing.T) {
		serveForge(t, issues, pulls, "")
		if code, out := runOrg(t); code != 0 || strings.Contains(out, "UNRECORDED") || !strings.Contains(out, "none of the 1 open Security issue(s) read") {
			t.Fatalf("code=%d out:\n%s", code, out)
		}
	})
	t.Run("without that pull request the issue is a finding", func(t *testing.T) {
		serveForge(t, issues, searchPage(), "")
		if code, out := runOrg(t); code != 1 || !strings.Contains(out, "UNRECORDED platform#42") {
			t.Fatalf("code=%d out:\n%s", code, out)
		}
	})
	// Each failing read hands back a complete page, so ignoring the error would
	// print a verdict: a clean one above, a finding below.
	for name, failing := range map[string]string{"issue read fails": searchEndpoint("o"), "pull-request read fails": pullEndpoint("o")} {
		t.Run(name, func(t *testing.T) {
			serveForge(t, issues, pulls, failing)
			if code, out := runOrg(t); code != 2 || !strings.Contains(out, "forge read failed -- UNKNOWN") || strings.Contains(out, "open Security issue(s) read") {
				t.Fatalf("code=%d out:\n%s", code, out)
			}
		})
	}
	t.Run("pull-request read is incomplete", func(t *testing.T) {
		serveForge(t, issues, `{"total_count":2,"incomplete_results":false,"items":[]}`, "")
		if code, out := runOrg(t); code != 2 || !strings.Contains(out, "UNKNOWN") {
			t.Fatalf("code=%d out:\n%s", code, out)
		}
	})
}

// Under --org a qualified reference must name that org. Another owner's
// repository of the same name is a different repository, and its issue 42 is
// not ours.
func TestOrgReadPinsTheOwnerOfAQualifiedReference(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		finding    bool
	}{
		{"the org's own repository", "Needs o/platform#42 first", false},
		{"the org's own repository, in another case", "Needs O/Platform#42 first", false},
		{"the org's own repository, as a link", "See https://github.com/o/platform/issues/42", false},
		{"another owner's repository of the same name", "Needs fleetdm/platform#42 first", true},
		{"another owner's repository, as a link", "See https://github.com/fleetdm/platform/issues/42", true},
		{"an owner whose name only ends the same", "Needs not-o/platform#42 first", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			serveForge(t, searchPage(forgeIssue), searchPage(forgePull("ksail", "devantler", tc.body)), "")
			code, out := runOrg(t)
			if got := strings.Contains(out, "UNRECORDED platform#42"); got != tc.finding || (code == 1) != tc.finding {
				t.Fatalf("finding=%v code=%d, want finding=%v; out:\n%s", got, code, tc.finding, out)
			}
		})
	}
}

func TestPullRequestReadCoversEveryOpenPullRequest(t *testing.T) {
	endpoint := pullEndpoint("o")
	for _, want := range []string{"org:o", "is:pr", "state:open", "archived:false", "per_page=100"} {
		if !strings.Contains(endpoint, want) {
			t.Errorf("endpoint lost %q: %s", want, endpoint)
		}
	}
	if strings.Contains(endpoint, "draft") || strings.Contains(endpoint, "label") {
		t.Errorf("endpoint filters pull requests: %s", endpoint)
	}
}

// Delivered work that waits on an event had no record of its own, so every run
// re-derived "merged, come back after the next production event" (#3426). An
// outcome record names that event in words. It is not an upstream blocker (a
// bare tracked item is refused: waiting on one is upstream) and not an
// authority blocker (nobody can be asked for an event, so it needs no ask and
// may not carry one).
func TestOutcomeGrammar(t *testing.T) {
	today, err := civilDate("2026-09-05")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, record, want string }{
		{"an event in words, with no ask", "the next weekly credential rotation in production | outcome | last-verified 2026-09-01: not rotated yet", "CONFORMS"},
		{"an event beside the item that delivers it", "a release newer than v1.2.3 carrying owner/repo#7 | outcome | last-verified 2026-09-01: tag exists, release not published", "CONFORMS"},
		{"a bare item is an upstream blocker", "owner/repo#7 | outcome | last-verified 2026-09-01: open", "MALFORMED"},
		{"a bare number is an upstream blocker", "#7 | outcome | last-verified 2026-09-01: open", "MALFORMED"},
		{"a bare repository names no event", "owner/repo | outcome | last-verified 2026-09-01: open", "MALFORMED"},
		{"no words at all", "2026-10-08 | outcome | last-verified 2026-09-01: not yet", "MALFORMED"},
		{"a URL alone names no event", "https://example.com/release | outcome | last-verified 2026-09-01: not yet", "MALFORMED"},
		{"a URL beside a bare item still names no event", "https://example.com/release owner/repo#7 | outcome | last-verified 2026-09-01: not yet", "MALFORMED"},
		{"an encoded bare item still names no event", "owner/repo&#35;7 | outcome | last-verified 2026-09-01: not yet", "MALFORMED"},
		{"a link whose label is only a tracked item", "[owner/repo#7](https://example.com/issue) | outcome | last-verified 2026-09-01: open", "MALFORMED"},
		{"two tracked items and no words", "owner/repo#7, other/repo#8 | outcome | last-verified 2026-09-01: open", "MALFORMED"},
		{"a tracked item in brackets", "(owner/repo#7) | outcome | last-verified 2026-09-01: open", "MALFORMED"},
		{"a short reference", "GH-7 | outcome | last-verified 2026-09-01: open", "MALFORMED"},
		{"a version alone names no event", "v1.14.1 | outcome | last-verified 2026-09-01: not yet", "MALFORMED"},
		{"an event named in another script", "næste ugentlige rotation | outcome | last-verified 2026-09-01: not yet", "CONFORMS"},
		{"an empty identifier", " | outcome | last-verified 2026-09-01: not yet", "MALFORMED"},
		{"an ask contradicts the kind", "the next release | outcome | last-verified 2026-09-01: not yet | asked slack 2026-09-01", "MALFORMED"},
		{"an ask in a channel that is not one still contradicts it", "the next release | outcome | last-verified 2026-09-01: not yet | asked issue 2026-09-01", "MALFORMED"},
		{"a second kind", "the next release | outcome | upstream | last-verified 2026-09-01: not yet", "MALFORMED"},
		{"a future check date", "the next release | outcome | last-verified 2026-09-06: not yet", "MALFORMED"},
		{"an empty result", "the next release | outcome | last-verified 2026-09-01: ", "MALFORMED"},
		{"the kind is case sensitive", "the next release | Outcome | last-verified 2026-09-01: not yet", "MALFORMED"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, legacy := classify("**Blocker:** "+tc.record, today, 14)
			if got != tc.want || legacy {
				t.Fatalf("got %s (legacy=%t), want %s", got, legacy, tc.want)
			}
		})
	}
}

// An outcome wait is skipped only while somebody keeps checking for the event:
// it goes STALE on the same bound as every other record, never asks the
// maintainer, and needs the blocked label like any declared blocker.
func TestOutcomeRecordIsCheckedLikeAnyOtherRecord(t *testing.T) {
	line := "**Blocker:** the next weekly credential rotation | outcome | last-verified 2026-09-01: not rotated yet"
	labelled := `[{"repo":"r","number":1,"labels":[{"name":"blocked"}],"body":"` + line + `"}]`
	check := func(input string, args ...string) (int, string) {
		t.Helper()
		var stdout, stderr bytes.Buffer
		code := run(append([]string{"--input", "-"}, args...), strings.NewReader(input), &stdout, &stderr)
		return code, stdout.String() + stderr.String()
	}
	if code, out := check(labelled, "--today", "2026-09-05"); code != 0 || !strings.Contains(out, "CONFORMS") {
		t.Fatalf("a fresh outcome record: code=%d out:\n%s", code, out)
	}
	if code, out := check(labelled, "--today", "2026-09-09"); code != 1 || !strings.Contains(out, "STALE") {
		t.Fatalf("an outcome record nobody re-checked for 8 days: code=%d out:\n%s", code, out)
	}
	if code, out := check(labelled, "--today", "2026-09-05", "--ask-digest"); code != 0 || !strings.Contains(out, "no declared authority blocker has a missing or stale ask record") {
		t.Fatalf("an outcome record must never reach the ask digest: code=%d out:\n%s", code, out)
	}
	unlabelled := `[{"repo":"r","number":1,"labels":[],"type":{"name":"Bug"},"body":"` + line + `"}]`
	if code, out := check(unlabelled, "--today", "2026-09-05"); code != 1 || !strings.Contains(out, "UNLABELLED") {
		t.Fatalf("an outcome record without the blocked label: code=%d out:\n%s", code, out)
	}
}

// A number in running prose is not a reference: "we chose option #7" must not
// clear Security issue #7 (#3822). A bare #N counts only where the text is
// built as a reference: straight after a reference word, or in a list one
// opens. A qualified reference and an issue link name the issue outright.
func TestABareNumberCountsOnlyAsAReference(t *testing.T) {
	human := func(body string) []string { return []string{pullRequest("platform", "devantler", body)} }
	for _, tc := range []struct {
		name, body string
		finding    bool
	}{
		{"a number in running prose", "We chose option #42 over the others.", true},
		{"a step number", "Step #42 of the rollout is unchanged.", true},
		{"a number alone on a line", "#42", true},
		{"a word that only ends in a reference word", "The prefix #42 is unchanged; we oversee #42 too.", true},
		{"a reference word further back in the sentence", "Fixes the retry bug by choosing option #42", true},
		{"a cross-reference that is not work on it", "As you can see #42 is unaffected. See #42 for background.", true},
		{"a closing keyword", "Closes #42", false},
		{"a closing keyword in another case, with a colon", "RESOLVES: #42", false},
		{"a Part of line", "Part of #42", false},
		{"a Part of line in bold", "**Part of** #42", false},
		{"a list item", "- Refs #42", false},
		{"second in a list a keyword opens", "Fixes #7, #42", false},
		{"last in a list joined by and", "Fixes #7 and #42", false},
		{"after a qualified reference in the same list", "Fixes devantler-tech/ksail#7, #42", false},
		{"related work", "Related to #42.", false},
		{"an issue link", "https://github.com/devantler-tech/platform/issues/42", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, out := runInput(t, parkedPayload("", human(tc.body)...))
			if got := strings.Contains(out, "UNRECORDED platform#42  "); got != tc.finding || (code == 1) != tc.finding {
				t.Fatalf("finding=%v code=%d, want finding=%v; out:\n%s", got, code, tc.finding, out)
			}
		})
	}
}

// A pull request can name its issue only in its title (#3822).
func TestAReferenceInAPullRequestTitleCounts(t *testing.T) {
	titled := func(repo, title string) []string {
		record, err := json.Marshal(map[string]any{
			"repo": repo, "number": 900, "labels": []any{}, "pull_request": map[string]any{},
			"user": map[string]string{"login": "devantler"}, "title": title, "body": "",
		})
		if err != nil {
			t.Fatal(err)
		}
		return []string{string(record)}
	}
	for _, tc := range []struct {
		name, repo, title string
		finding           bool
	}{
		{"a trailing parenthesised number", "platform", "fix(auth): bound the retry (#42)", false},
		{"a parenthesised list", "platform", "fix(auth): bound the retry (#7, #42)", false},
		{"a closing keyword", "platform", "Fixes #42: bound the retry", false},
		{"a qualified reference from another repository", "ksail", "fix: adapt to devantler-tech/platform#42", false},
		{"a number in the title's prose", "platform", "fix: choose option #42 for retries", true},
		{"a parenthesised number in another repository", "ksail", "fix(auth): bound the retry (#42)", true},
		{"no reference at all", "platform", "fix(auth): bound the retry", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, out := runInput(t, parkedPayload("", titled(tc.repo, tc.title)...))
			if got := strings.Contains(out, "UNRECORDED platform#42  "); got != tc.finding || (code == 1) != tc.finding {
				t.Fatalf("finding=%v code=%d, want finding=%v; out:\n%s", got, code, tc.finding, out)
			}
		})
	}
}

// Across a whole organisation, reading no Security issue at all is far more
// likely a type that was renamed or hidden from the token than a portfolio
// with none, so "none unstarted" is unproven (#3822). A recorded input keeps
// its count: whoever recorded it chose what it holds.
func TestAnOrgReadWithNoSecurityIssueIsUnknown(t *testing.T) {
	bug := strings.Replace(forgeIssue, `"type":{"name":"Security"}`, `"type":{"name":"Bug"}`, 1)
	if bug == forgeIssue {
		t.Fatal("the fixture no longer carries the Security type this test rewrites")
	}
	serveForge(t, searchPage(bug), searchPage(), "")
	code, out := runOrg(t)
	if code != 2 || !strings.Contains(out, "read no open Security issue") || strings.Contains(out, "none of the 0") {
		t.Fatalf("code=%d out:\n%s", code, out)
	}
	t.Run("the parked digest does not read issue types and is unaffected", func(t *testing.T) {
		serveForge(t, searchPage(bug), searchPage(), "")
		var stdout, stderr bytes.Buffer
		if code := run([]string{"--org", "o", "--today", "2026-09-01", "--parked-digest"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
			t.Fatalf("code=%d out:\n%s%s", code, stdout.String(), stderr.String())
		}
	})
}

// freshSecurityIssue is a Security issue still inside the bound: an org read
// that serves it has read the type, and it is not itself a finding. Tests of
// the verdict report that are about something else serve it, because an org
// read with no Security issue at all is UNKNOWN (#3822).
var freshSecurityIssue = strings.Replace(forgeIssue, "2026-08-20T10:00:00Z", "2026-08-30T10:00:00Z", 1)
