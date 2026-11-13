package main

// The compiled-CLI suite, ported one assertion for one from the retired
// blocked-label-blocker-line.test.sh (monorepo#3224). Every subtest keeps the
// shell assertion's name, so the two can be compared row by row.
//
// No network and no real issue is touched: every case is a hand-built JSON
// payload fed through the --input seam, or a stub `gh` placed first on PATH.
// The cases run the compiled binary and the shell entrypoint as a caller does,
// because a direct run() test cannot catch a main() or launcher regression.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
)

var (
	cliOnce sync.Once
	cliDir  string
	cliPath string
	cliErr  error
)

func TestMain(m *testing.M) {
	code := m.Run()
	if cliDir != "" {
		_ = os.RemoveAll(cliDir)
	}
	os.Exit(code)
}

// guardBinary builds the CLI once per test binary.
func guardBinary(t *testing.T) string {
	t.Helper()
	cliOnce.Do(func() {
		cliDir, cliErr = os.MkdirTemp("", "blocker-cli-suite")
		if cliErr != nil {
			return
		}
		cliPath = filepath.Join(cliDir, "guard")
		if output, err := exec.Command("go", "build", "-o", cliPath, ".").CombinedOutput(); err != nil {
			cliErr = fmt.Errorf("build CLI: %v\n%s", err, output)
		}
	})
	if cliErr != nil {
		t.Fatal(cliErr)
	}
	return cliPath
}

// invocation is one process run: stdout and stderr interleaved as `2>&1`
// captures them, with the trailing newlines `$(...)` strips removed.
type invocation struct {
	stdin string
	env   []string
	split bool // keep stderr out of the output, as a bare `$(...)` does
	raw   bool // keep the trailing newlines, as a redirect to a file does
}

func execute(t *testing.T, inv invocation, name string, args ...string) (int, string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Stdin = strings.NewReader(inv.stdin)
	cmd.Env = append(os.Environ(), inv.env...)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	if inv.split {
		cmd.Stderr = &stderr
	} else {
		cmd.Stderr = &out
	}
	rc := 0
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			t.Fatalf("run %s: %v", name, err)
		}
		rc = exitErr.ExitCode()
	}
	if inv.raw {
		return rc, out.String()
	}
	if inv.split {
		return rc, strings.TrimRight(out.String(), "\n") + "\x00" + stderr.String()
	}
	return rc, strings.TrimRight(out.String(), "\n")
}

// shapes runs the guard with the verification-age bound switched off: the
// fixtures pin record SHAPES and carry fixed dates, so without this the suite
// would turn red as the calendar moves. The STALE cases use guard instead.
func shapes(t *testing.T, inv invocation, args ...string) (int, string) {
	t.Helper()
	return execute(t, inv, guardBinary(t), append([]string{"--verify-max-age-days", "999999999"}, args...)...)
}

func guard(t *testing.T, inv invocation, args ...string) (int, string) {
	t.Helper()
	return execute(t, inv, guardBinary(t), args...)
}

// wrapper runs the installed shell entrypoint, which builds the guard itself.
func wrapper(t *testing.T, inv invocation, args ...string) (int, string) {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "blocked-label-blocker-line.sh"))
	if err != nil {
		t.Fatal(err)
	}
	return execute(t, inv, path, args...)
}

// payloadFile writes a payload into the test's temporary directory.
func payloadFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "payload.json")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// bodyPayload is one issue whose body is the given text, as `jq -Rs` builds it.
func bodyPayload(repo string, number int, body string) string {
	raw, err := json.Marshal([]map[string]any{{"repo": repo, "number": number, "body": body}})
	if err != nil {
		panic(err)
	}
	return string(raw)
}

// line reports whether any line of out matches the extended regular expression,
// as `grep -qE` does.
func line(out, pattern string) bool {
	return regexp.MustCompile("(?m)" + pattern).MatchString(out)
}

func assert(t *testing.T, name string, ok bool, detail string, args ...any) {
	t.Helper()
	t.Run(name, func(t *testing.T) {
		t.Helper()
		if !ok {
			t.Fatalf(detail, args...)
		}
	})
}

func expectRC(t *testing.T, name string, want int, payload string, args ...string) {
	t.Helper()
	rc, out := shapes(t, invocation{}, append([]string{"--input", payloadFile(t, payload)}, args...)...)
	assert(t, name, rc == want, "expected rc=%d got rc=%d; out: %.200s", want, rc, out)
}

func expectOut(t *testing.T, name, pattern, payload string, args ...string) {
	t.Helper()
	_, out := shapes(t, invocation{}, append([]string{"--input", payloadFile(t, payload)}, args...)...)
	assert(t, name, line(out, pattern), "no match for /%s/; out: %.200s", pattern, out)
}

// shim installs an executable `gh` stub and returns the PATH entry naming it.
func shim(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return "PATH=" + dir + string(os.PathListSeparator) + os.Getenv("PATH")
}

const (
	good    = `[{"repo":"a","number":1,"body":"lead\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped\n\ntail"}]`
	missing = `[{"repo":"b","number":2,"body":"this body has no blocker line"}]`
	mixed   = `[{"repo":"a","number":1,"body":"**Blocker:** o/r#1 | upstream | last-verified 2026-08-01: x"},
 {"repo":"b","number":2,"body":"none"},
 {"repo":"c","number":3,"body":"none either"}]`
	clsAuthOK     = `[{"repo":"a","number":2,"body":"**Blocker:** maintainer authority — an R2 bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-09-01"}]`
	clsUpstream   = `[{"repo":"a","number":1,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped"}]`
	clsLegacyAuth = `[{"repo":"a","number":10,"body":"**Blocker:** maintainer authority (Cloudflare account action) | last-verified 2026-09-01: not provisioned"}]`
)

// Sections 1-13 of the shell suite: record shapes, counting, the UNKNOWN paths
// and the stdin seam.
func TestCLIRecordShapes(t *testing.T) {
	expectRC(t, "conforming line exits 0", 0, good)
	expectRC(t, "missing line exits 1", 1, missing)
	expectOut(t, "missing line is reported", `^MISSING +b#2`, missing)

	prose := `[{"repo":"d","number":4,"body":"**Blocker:** waiting on upstream someday"}]`
	expectRC(t, "prose blocker exits 1", 1, prose)
	expectOut(t, "prose blocker is MALFORMED", `^MALFORMED +d#4`, prose)
	expectRC(t, "two-digit year is MALFORMED", 1, `[{"repo":"e","number":5,"body":"**Blocker:** owner/repo#9 | upstream | last-verified 26-08-01: bad date"}]`)

	// A real body soft-wraps the blocker line; both halves are asserted, so a
	// join that silently stops working is caught by the positive control.
	expectRC(t, "wrapped conforming line exits 0", 0, `[{"repo":"c","number":3,"body":"**Blocker:** maintainer authority - an org-owned App with packages read, installed on at\nleast one tenant repository | upstream | last-verified 2026-08-21: not provisioned\n\nnext"}]`)
	expectRC(t, "control: same line unwrapped also exits 0", 0, `[{"repo":"c","number":3,"body":"**Blocker:** maintainer authority - an org-owned App with packages read, installed on at least one tenant repository | upstream | last-verified 2026-08-21: not provisioned\n\nnext"}]`)
	expectRC(t, "wrapped NON-conforming line still exits 1", 1, `[{"repo":"c","number":9,"body":"**Blocker:** something external and vague\nthat merely continues onto another line\n\nnext"}]`)
	expectRC(t, "join stops at the blank line", 1, `[{"repo":"c","number":10,"body":"**Blocker:** something vague\n\n| last-verified 2026-08-21: not provisioned\n"}]`)

	// A body far larger than a pipe buffer: the regression it guards is only
	// reachable past it, so the size is asserted rather than assumed.
	big := strings.Repeat("filler line that is here only to exceed the pipe buffer\n", 6000) +
		"\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped\n"
	assert(t, "oversized fixture built", len(big) > 200000, "only %d bytes -- the SIGPIPE case would be vacuous", len(big))
	rc, out := shapes(t, invocation{}, "--input", payloadFile(t, bodyPayload("big", 11, big)))
	assert(t, "large body does not raise SIGPIPE", rc == 0, "rc=%d; out: %.200s", rc, out)

	expectRC(t, "CRLF body conforms", 0, `[{"repo":"f","number":6,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped\r\n\r\ntail"}]`)
	expectOut(t, "reports 2 of 3", `2 of 3 open blocked-labelled`, mixed)
	expectRC(t, "empty payload exits 0", 0, `[]`)
	expectOut(t, "empty payload says all 0", `all 0 open blocked-labelled`, `[]`)

	expectRC(t, "non-array payload is UNKNOWN(2)", 2, `{"not":"an array"}`)
	// The specific diagnostic: the right exit code for the wrong reason would
	// let the type guard rot untested.
	expectOut(t, "non-array payload names the type guard", `not a JSON array`, `{"not":"an array"}`)
	expectRC(t, "unparseable payload is UNKNOWN(2)", 2, "not json at all")

	rc, out = shapes(t, invocation{}, "--input", filepath.Join(t.TempDir(), "does-not-exist.json"))
	assert(t, "unreadable payload is UNKNOWN(2)", rc == 2, "rc=%d", rc)
	rc, _ = shapes(t, invocation{})
	assert(t, "no source is UNKNOWN(2)", rc == 2, "rc=%d", rc)
	rc, _ = shapes(t, invocation{}, "--org", "x", "--input", payloadFile(t, good))
	assert(t, "--org with --input is UNKNOWN(2)", rc == 2, "rc=%d", rc)
	rc, _ = shapes(t, invocation{}, "--org")
	assert(t, "--org without a value is UNKNOWN(2)", rc == 2, "rc=%d", rc)
	// The org name reaches a search URL, so a value outside GitHub's shape is
	// refused rather than interpolated.
	rc, out = shapes(t, invocation{}, "--org", "foo bar&x")
	assert(t, "malformed --org is refused", rc == 2 && strings.Contains(out, "must match"), "rc=%d; out: %.150s", rc, out)

	rc, out = shapes(t, invocation{stdin: good}, "--input", "-")
	assert(t, "--input - reads stdin", rc == 0, "rc=%d; %.150s", rc, out)

	rc, out = shapes(t, invocation{}, "--quiet", "--input", payloadFile(t, mixed))
	assert(t, "--quiet prints every finding row without a summary", rc == 1 && out == "MISSING    b#2\nMISSING    c#3", "rc=%d; out: %.200s", rc, out)

	expectRC(t, "dated prose with no identifier is MALFORMED", 1, `[{"repo":"p","number":20,"body":"**Blocker:** waiting on upstream | upstream | last-verified 2026-08-01: no response"}]`)
	expectRC(t, "every identifier idiom in live use still CONFORMS", 0, `[{"repo":"a","number":1,"body":"**Blocker:** loft-sh/vcluster#3805 | upstream | last-verified 2026-08-25: not shipped"},
 {"repo":"b","number":2,"body":"**Blocker:** maintainer authority - an org admin must set the property | upstream | last-verified 2026-08-25: still false"},
 {"repo":"c","number":3,"body":"**Blocker:** crossplane-contrib/provider-upjet-github (a settings resource) | upstream | last-verified 2026-08-25: not shipped"},
 {"repo":"d","number":4,"body":"**Blocker:** child #3274 (installation token) | upstream | last-verified 2026-08-24: not provisioned"},
 {"repo":"e","number":5,"body":"**Blocker:** maintainer authority (an account-scoped provider quota) | upstream | last-verified 2026-08-19: still limited"}]`)
}

const securityItem = `{"repository_url":"https://api.github.com/repos/o/sec","number":99,"labels":[],"type":{"name":"Security"},"created_at":"2026-01-01T00:00:00Z","assignees":[],"issue_dependencies_summary":{"blocked_by":1},"sub_issues_summary":{"total":0,"completed":0},"body":"plain"}`

// Section 14 and 17: the org read through a stubbed `gh`.
func TestCLIOrgRead(t *testing.T) {
	// A timed-out search returns a MATCHING total_count, so only
	// incomplete_results separates a truncated sweep from a clean one.
	path := shim(t, `#!/usr/bin/env bash
cat <<'JSON'
{"total_count":1,"incomplete_results":true,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1,"labels":[{"name":"blocked"}],"body":"no blocker line"}]}
JSON
`)
	rc, out := shapes(t, invocation{env: []string{path}}, "--org", "devantler-tech")
	assert(t, "a timed-out search is UNKNOWN(2), not a clean sweep", rc == 2 && strings.Contains(out, "incomplete_results"), "rc=%d; out: %.200s", rc, out)

	// CONTROL: the same page without the flag is evaluated normally. An org read
	// that sees no Security issue is UNKNOWN (#3822), so one is served.
	path = shim(t, `#!/usr/bin/env bash
case "$*" in
  *is:pr*) echo '{"total_count":0,"incomplete_results":false,"items":[]}' ;;
  *) echo '{"total_count":2,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1,"labels":[{"name":"blocked"}],"type":null,"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"sub_issues_summary":{"total":0,"completed":0},"body":"no blocker line"},`+securityItem+`]}' ;;
esac
`)
	rc, out = shapes(t, invocation{env: []string{path}}, "--org", "devantler-tech")
	assert(t, "control: the same page without the flag is evaluated normally", rc == 1 && strings.Contains(out, "MISSING"), "rc=%d; out: %.200s", rc, out)

	// The pull-request read fails closed like the issue read. The shim prints a
	// COMPLETE page and then fails, so the guard has to refuse it for its status.
	for _, status := range []int{1, 0} {
		path = shim(t, fmt.Sprintf(`#!/usr/bin/env bash
case "$*" in
  *is:pr*) echo '{"total_count":0,"incomplete_results":false,"items":[]}'; exit %d ;;
  *) echo '{"total_count":1,"incomplete_results":false,"items":[%s]}' ;;
esac
`, status, securityItem))
		rc, out = shapes(t, invocation{env: []string{path}}, "--org", "devantler-tech")
		if status == 1 {
			assert(t, "a pull-request read that fails after printing a complete page is UNKNOWN(2)",
				rc == 2 && strings.Contains(out, "forge read failed -- UNKNOWN") && !strings.Contains(out, "all 0 open"), "rc=%d; out: %.200s", rc, out)
		} else {
			assert(t, "CONTROL: the same pages from a read that succeeds are a clean sweep",
				rc == 0 && strings.Contains(out, "all 0 open"), "rc=%d; out: %.200s", rc, out)
		}
	}

	// Archived repositories are out of scope: both reads carry the qualifier,
	// and each zero is confirmed by one read without it (#4435).
	log := filepath.Join(t.TempDir(), "argv.log")
	path = shim(t, `#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ARGV_LOG:?}"
cat <<'JSON'
{"total_count":0,"incomplete_results":false,"items":[]}
JSON
`)
	shapes(t, invocation{env: []string{path, "ARGV_LOG=" + log}}, "--org", "devantler-tech")
	raw, _ := os.ReadFile(log)
	argv := string(raw)
	count := func(s string) int {
		n := 0
		for _, l := range strings.Split(argv, "\n") {
			if l != "" && strings.Contains(l, s) {
				n++
			}
		}
		return n
	}
	assert(t, "both org queries exclude archived repositories",
		count("archived:false") == 2 && count("") == 4 && count("is:issue") == 2 && count("is:pr") == 2, "argv: %s", argv)
}

// Sections 15-22: identifiers, calendar dates, comments and fences.
func TestCLIIdentifiersDatesAndFences(t *testing.T) {
	expectRC(t, "hyphenated prose is not an identifier", 1, `[{"repo":"p","number":21,"body":"**Blocker:** waiting on third-party response | upstream | last-verified 2026-08-25: no response"}]`)
	expectRC(t, "control: the same prose WITH an identifier conforms", 0, `[{"repo":"p","number":22,"body":"**Blocker:** waiting on third-party response from owner/repo#7 | upstream | last-verified 2026-08-25: no response"}]`)
	expectRC(t, "an impossible date is MALFORMED", 1, `[{"repo":"p","number":23,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-99-99: nope"}]`)
	expectRC(t, "month 13 is MALFORMED", 1, `[{"repo":"p","number":24,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-13-01: nope"}]`)
	expectRC(t, "control: a real boundary date conforms", 0, `[{"repo":"p","number":25,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2025-12-31: nope"}]`)

	expectRC(t, "a URL identifier is MALFORMED", 1, `[{"repo":"p","number":30,"body":"**Blocker:** https://github.com/owner/repo/issues/7 | upstream | last-verified 2026-08-25: not shipped"}]`)
	expectRC(t, "a scheme-less URL identifier is MALFORMED", 1, `[{"repo":"p","number":36,"body":"**Blocker:** github.com/owner/repo/issues/7 | upstream | last-verified 2026-08-25: not shipped"}]`)
	expectRC(t, "control: a real identifier alongside a link still CONFORMS", 0, `[{"repo":"p","number":37,"body":"**Blocker:** owner/repo#7 (see https://github.com/owner/repo/issues/7) | upstream | last-verified 2026-08-25: x"}]`)

	expectRC(t, "31 February is MALFORMED", 1, `[{"repo":"p","number":31,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-02-31: nope"}]`)
	expectRC(t, "31 April is MALFORMED", 1, `[{"repo":"p","number":40,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-04-31: nope"}]`)
	expectRC(t, "29 February in a non-leap year is MALFORMED", 1, `[{"repo":"p","number":38,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-02-29: nope"}]`)
	expectRC(t, "control: 29 February in a leap year CONFORMS", 0, `[{"repo":"p","number":39,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2024-02-29: leap"}]`)

	inComment := `[{"repo":"p","number":32,"body":"real text\n\n<!--\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: stale\n-->\n\nmore"}]`
	expectRC(t, "a marker inside an HTML comment is MISSING", 1, inComment)
	expectOut(t, "a commented marker reports MISSING", `^MISSING +p#32`, inComment)
	expectRC(t, "a marker inside a code fence is MISSING", 1, "[{\"repo\":\"p\",\"number\":33,\"body\":\"Example of the format:\\n\\n```\\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: example\\n```\\n\\nend\"}]")
	expectRC(t, "control: a comment elsewhere does not hide a real record", 0, `[{"repo":"p","number":34,"body":"x <!-- hidden --> y\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: real\n\nend"}]`)
	expectRC(t, "control: a record after a closed fence still CONFORMS", 0, "[{\"repo\":\"p\",\"number\":35,\"body\":\"```\\nexample fence\\n```\\n\\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: real\\n\\nend\"}]")

	// CommonMark closes a fence only on a run of the SAME character, at least
	// as long as the opening, carrying no info string.
	record := "**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: "
	fence4 := bodyPayload("p", 50, "Example:\n\n````\n```\n"+record+"example\n```\n````\n\nend\n")
	expectRC(t, "a shorter run inside a longer fence does not close it", 1, fence4)
	expectOut(t, "the 4-backtick fence body reports MISSING", `^MISSING +p#50`, fence4)
	expectRC(t, "a mismatched fence character does not close it", 1, bodyPayload("p", 52, "Example:\n\n~~~\n```\n"+record+"example\n```\n~~~\n\nend\n"))
	expectRC(t, "control: a record after a closed 4-backtick fence CONFORMS", 0, bodyPayload("p", 54, "Example:\n\n````\n```\ninner\n```\n````\n\n"+record+"real\n\nend\n"))
	expectRC(t, "control: a longer closing run closes a shorter fence", 0, bodyPayload("p", 55, "Example:\n\n```\ninner\n````\n\n"+record+"real\n\nend\n"))

	// Comment stripping must not run inside a fence, where it could forge a
	// closing delimiter (CodeRabbit on PR #3053).
	forged := bodyPayload("p", 56, "Example:\n\n```\n<!-- x -->```\n"+record+"example\n```\n\nend\n")
	expectRC(t, "a commented prefix cannot forge a closing fence", 1, forged)
	expectOut(t, "the forged-close body reports MISSING", `^MISSING +p#56`, forged)
	expectRC(t, "a commented prefix cannot forge a shorter closing run either", 1, bodyPayload("p", 57, "Example:\n\n````\n<!-- ignored -->```\n"+record+"example\n````\n\nend\n"))
	expectRC(t, "control: a commented prefix still OPENS a fence outside one", 1, bodyPayload("p", 58, "Example:\n\n<!-- lead-in -->```\n"+record+"example\n```\n\nend\n"))
	expectRC(t, "control: a record after that fence still CONFORMS", 0, bodyPayload("p", 59, "Example:\n\n```\n<!-- x -->```\ninner\n```\n\n"+record+"real\n\nend\n"))
	expectRC(t, "control: a multi-line commented record is still MISSING", 1, bodyPayload("p", 60, "<!--\n"+record+"retired\n-->\n\nend\n"))
}

// withToday runs the shapes guard on a payload against a pinned clock.
func withToday(t *testing.T, payload string, args ...string) (int, string) {
	t.Helper()
	return shapes(t, invocation{}, append([]string{"--input", payloadFile(t, payload), "--today", "2026-09-05"}, args...)...)
}

func authorityAsk(number int, ask string) string {
	return fmt.Sprintf(`[{"repo":"a","number":%d,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked %s"}]`, number, ask)
}

// Sections 23-42: the cause class, the ask record and its cadence.
func TestCLICauseClassAndAsk(t *testing.T) {
	expectRC(t, "explicit upstream class conforms", 0, clsUpstream)
	rc, out := withToday(t, clsAuthOK)
	assert(t, "authority class with a fresh ask conforms", rc == 0, "rc=%d out=%.200s", rc, out)

	noAsk := `[{"repo":"a","number":3,"body":"**Blocker:** maintainer authority — an R2 bucket | authority | last-verified 2026-09-01: not provisioned"}]`
	expectRC(t, "authority class with no ask is a finding", 1, noAsk)
	expectOut(t, "authority with no ask is reported as NO-ASK", `^NO-ASK +a#3`, noAsk)
	expectRC(t, "NEGATIVE CONTROL: upstream with no ask is NOT flagged", 0, `[{"repo":"a","number":4,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-09-01: not shipped"}]`)

	legacy := `[{"repo":"a","number":5,"body":"**Blocker:** owner/repo#7 | last-verified 2026-09-01: not shipped"}]`
	expectRC(t, "absent class is inferred, not refused", 0, legacy)
	expectOut(t, "an unclassed record is marked legacy", `legacy: no class token`, legacy)
	expectRC(t, "an unknown class token is a finding", 1, `[{"repo":"a","number":6,"body":"**Blocker:** owner/repo#7 | sometimes | last-verified 2026-09-01: not shipped"}]`)

	rc, out = withToday(t, authorityAsk(7, "pr 2026-08-01"))
	assert(t, "an ask older than the cadence is a finding", rc == 1, "rc=%d out=%.200s", rc, out)
	assert(t, "a stale ask is reported as STALE-ASK", line(out, `^STALE-ASK +a#7`), "out=%.200s", out)
	rc, out = withToday(t, authorityAsk(8, "pr 2026-08-30"))
	assert(t, "BOUNDARY: an ask inside the cadence passes", rc == 0, "rc=%d out=%.200s", rc, out)
	expectRC(t, "an ask carrying an impossible date is a finding", 1, authorityAsk(9, "pr 2026-02-31"))

	// An unclassed record whose identifier says "maintainer authority" is
	// inferred as authority, so the ask requirement bites without a migration.
	expectRC(t, "an unclassed AUTHORITY record still demands an ask", 1, clsLegacyAuth)
	expectOut(t, "and is reported as NO-ASK", `^NO-ASK +a#10`, clsLegacyAuth)
	rc, out = withToday(t, `[{"repo":"a","number":11,"body":"**Blocker:** maintainer authority (Cloudflare account action) | last-verified 2026-09-01: not provisioned | asked pr 2026-09-01"}]`)
	assert(t, "CONTROL: the same unclassed record with an ask conforms", rc == 0, "rc=%d out=%.200s", rc, out)
	expectRC(t, "CONTROL: an explicit class overrides the inference", 0, `[{"repo":"a","number":12,"body":"**Blocker:** maintainer authority (an account-scoped provider quota) | upstream | last-verified 2026-09-01: still limited"}]`)

	// The ask channel is a closed set: `issue` records an ask, it is not one.
	rc, out = withToday(t, authorityAsk(13, "issue 2026-09-01"))
	assert(t, "an ask on a non-attention channel is a finding", rc == 1, "rc=%d out=%.200s", rc, out)
	assert(t, "and is reported as NO-ASK, not as delivered", line(out, `^NO-ASK +a#13`), "out=%.200s", out)
	for _, channel := range []string{"slack", "session"} {
		rc, out = withToday(t, authorityAsk(14, channel+" 2026-09-01"))
		assert(t, "CONTROL: an ask via '"+channel+"' conforms", rc == 0, "rc=%d out=%.200s", rc, out)
	}

	// A future ask date is not a fresh ask.
	rc, out = withToday(t, authorityAsk(15, "pr 2030-01-01"))
	assert(t, "an ask dated after today is a finding", rc == 1, "rc=%d out=%.200s", rc, out)
	assert(t, "a future ask is reported as MALFORMED", line(out, `^MALFORMED +a#15`), "out=%.200s", out)
	rc, out = withToday(t, authorityAsk(16, "pr 2026-09-05"))
	assert(t, "BOUNDARY: an ask dated today conforms", rc == 0, "rc=%d out=%.200s", rc, out)

	// --today must name a real day.
	rc, out = shapes(t, invocation{}, "--input", payloadFile(t, clsAuthOK), "--today", "2026-02-31")
	assert(t, "--today on an impossible date is a usage error", rc == 2, "rc=%d out=%.200s", rc, out)
	assert(t, "and names --today as the cause", strings.Contains(out, "--today must be a real"), "out=%.200s", out)
	rc, out = shapes(t, invocation{}, "--input", payloadFile(t, clsUpstream), "--today", "2026-12-31")
	assert(t, "CONTROL: --today on a real boundary date is accepted", rc == 0, "rc=%d out=%.200s", rc, out)

	// Year zero is outside the arithmetic domain.
	year0 := payloadFile(t, `[{"repo":"p","number":60,"body":"**Blocker:** maintainer authority | authority | last-verified 0000-02-29: pending | asked pr 0000-03-01"}]`)
	rc, out = shapes(t, invocation{}, "--input", year0, "--today", "0000-02-29", "--ask-max-age-days", "0")
	assert(t, "--today in year zero is a usage error", rc == 2, "rc=%d out=%.200s", rc, out)
	rc, out = shapes(t, invocation{}, "--input", year0, "--today", "2026-09-05", "--ask-max-age-days", "0")
	assert(t, "a year-zero ask date is MALFORMED", rc == 1 && line(out, `^MALFORMED +p#60`), "rc=%d out=%.200s", rc, out)
	rc, out = shapes(t, invocation{}, "--input", payloadFile(t, `[{"repo":"p","number":61,"body":"**Blocker:** maintainer authority | authority | last-verified 0001-03-01: pending | asked pr 0001-03-01"}]`), "--today", "0001-03-01", "--ask-max-age-days", "0")
	assert(t, "CONTROL: year one is inside the domain and conforms", rc == 0, "rc=%d out=%.200s", rc, out)

	// The cadence must fit the integer comparison.
	staleAsk := `[{"repo":"p","number":62,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-09-05: pending | asked pr 2026-08-01"}]`
	rc, out = withToday(t, staleAsk, "--ask-max-age-days", "999999999999999999999999")
	assert(t, "an out-of-range cadence is a usage error", rc == 2 && strings.Contains(out, "at most 9 digits"), "rc=%d out=%.200s", rc, out)
	rc, out = withToday(t, staleAsk, "--ask-max-age-days", "999999999")
	assert(t, "CONTROL: a nine-digit cadence is accepted and evaluates", rc == 0, "rc=%d out=%.200s", rc, out)
	rc, out = withToday(t, staleAsk)
	assert(t, "CONTROL: the default cadence still reports the stale ask", rc == 1 && line(out, `^STALE-ASK +p#62`), "rc=%d out=%.200s", rc, out)

	// --quiet keeps NO-ASK rows, and prints no row for an all-conforming payload.
	rc, out = shapes(t, invocation{}, "--quiet", "--input", payloadFile(t, clsLegacyAuth), "--today", "2026-09-05")
	assert(t, "--quiet still prints the NO-ASK row", rc == 1 && line(out, `^NO-ASK +a#10`), "rc=%d out=%.200s", rc, out)
	rc, out = shapes(t, invocation{}, "--quiet", "--input", payloadFile(t, good))
	assert(t, "CONTROL: --quiet on an all-conforming payload prints no row", rc == 0 && !line(out, `^(CONFORMS|MISSING|MALFORMED|NO-ASK|STALE-ASK) `), "rc=%d out=%.200s", rc, out)

	// The legacy annotation reaches non-conforming rows too.
	rc, out = withToday(t, clsLegacyAuth)
	assert(t, "a legacy NO-ASK row carries the legacy annotation", rc == 1 && line(out, `^NO-ASK +a#10 +\[legacy: no class token\]`), "rc=%d out=%.200s", rc, out)
	rc, out = withToday(t, `[{"repo":"a","number":41,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned"}]`)
	assert(t, "CONTROL: an explicitly classed NO-ASK row is not marked legacy", rc == 1 && line(out, `^NO-ASK +a#41`) && !strings.Contains(out, "legacy: no class token"), "rc=%d out=%.200s", rc, out)

	// Trailing whitespace after the ask date is a Markdown hard break, not a missing ask.
	rc, out = withToday(t, authorityAsk(42, "pr 2026-09-01  "))
	assert(t, "trailing whitespace after the ask date still conforms", rc == 0 && line(out, `^CONFORMS +a#42`), "rc=%d out=%.200s", rc, out)
	rc, out = withToday(t, authorityAsk(43, "pr 2026-09-01 maybe"))
	assert(t, "CONTROL: trailing text after the ask date is still NO-ASK", rc == 1 && line(out, `^NO-ASK +a#43`), "rc=%d out=%.200s", rc, out)

	// An EMPTY verification result is MALFORMED, ask or no ask.
	rc, out = withToday(t, `[{"repo":"a","number":44,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: | asked pr 2026-09-01"}]`)
	assert(t, "an authority record with an ask but no verification result is MALFORMED", rc == 1 && line(out, `^MALFORMED +a#44`), "rc=%d out=%.200s", rc, out)
	rc, out = shapes(t, invocation{}, "--input", payloadFile(t, `[{"repo":"a","number":45,"body":"**Blocker:** o/r#1 | upstream | last-verified 2026-08-01:   "}]`))
	assert(t, "an upstream record whose result is only whitespace is MALFORMED", rc == 1 && line(out, `^MALFORMED +a#45`), "rc=%d out=%.200s", rc, out)
	rc, out = withToday(t, `[{"repo":"a","number":46,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01"}]`)
	assert(t, "CONTROL: a real result with the same ask suffix conforms", rc == 0 && line(out, `^CONFORMS +a#46`), "rc=%d out=%.200s", rc, out)

	// --help documents the class and the ask record, and stops before the code.
	rc, out = shapes(t, invocation{}, "--help")
	assert(t, "--help shows the class token, the authority ask suffix and the cadence option",
		rc == 0 && strings.Contains(out, "| <blocker-kind> | last-verified") &&
			strings.Contains(out, "| authority | last-verified <YYYY-MM-DD>: <result> | asked <pr|slack|session|digest> <YYYY-MM-DD>") &&
			strings.Contains(out, "--ask-max-age-days <n>"), "rc=%d out=%.300s", rc, out)
	assert(t, "and --help stops before the code", !line(out, `^set -euo pipefail`), "help leaked code")
}

// flat joins a span onto one line and squeezes whitespace, as
// `tr '\n' ' ' | tr -s '[:space:]' ' '` does.
func flat(s string) string {
	return regexp.MustCompile(`[[:space:]]+`).ReplaceAllString(s, " ")
}

// section returns the lines from the one holding start up to the first later
// line holding end (no end: the next blank line), flattened. It returns nothing
// unless BOTH anchors were seen, so a renamed end anchor cannot stretch the span
// to the end of the file.
func section(text, start, end string) string {
	var buf strings.Builder
	inside := false
	blank := regexp.MustCompile(`^[[:space:]]*$`)
	for _, l := range strings.SplitAfter(text, "\n") {
		l = strings.TrimSuffix(l, "\n")
		if !inside {
			if strings.Contains(l, start) {
				inside = true
				buf.WriteString(l + "\n")
			}
			continue
		}
		if (end == "" && blank.MatchString(l)) || (end != "" && strings.Contains(l, end)) {
			return flat(buf.String())
		}
		buf.WriteString(l + "\n")
	}
	return ""
}

// tokens is every backticked span, however it is spelt, joined with '|'. A
// pattern that knew only lowercase words would never examine `self-dm`.
func tokens(s string) string {
	var spans []string
	for _, m := range regexp.MustCompile("`[^`]*`").FindAllString(s, -1) {
		spans = append(spans, strings.Trim(m, "`"))
	}
	return strings.Join(spans, "|")
}

// ruleTokens is the tokens between two clauses of the rule, or nothing unless
// both clauses are there in that order.
func ruleTokens(rule, start, end string) string {
	i := strings.Index(rule, start)
	if i < 0 {
		return ""
	}
	rest := rule[i+len(start):]
	j := strings.Index(rest, end)
	if j < 0 {
		return ""
	}
	return tokens(rest[:j])
}

func readGuide(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// Section 43: --help and the guides define the same ask channels (#3784). The
// vocabulary is read out of the guide's own ask-record rule, so a token or an
// exclusion that changes in the guide alone turns this red.
func TestCLIHelpAndGuidesDefineTheSameAskChannels(t *testing.T) {
	ruleGuide := readGuide(t, "guides/work-selection.md")
	destinationGuide := readGuide(t, "guides/maintainer-channels.md")
	const ruleAnchor = "**An `authority` line MUST also record the ask"
	askRule := section(ruleGuide, ruleAnchor, "")
	slackDestination := section(destinationGuide, "- **Destination:**", "- **Surface:**")
	_, help := shapes(t, invocation{raw: true}, "--help")
	helpChannels := section(help, "Ask channels:", "")
	guideChannels := ruleTokens(askRule, "names where it actually landed", "No other word is a channel token")
	guideExcluded := ruleTokens(askRule, "That includes", "Re-raise on a cadence")
	helpExcluded := ""
	if i := strings.Index(helpChannels, "No other word is a channel token"); i >= 0 {
		helpExcluded = helpChannels[i+len("No other word is a channel token"):]
	}

	// Fail closed, and name the first anchor that went.
	missingAnchor := ""
	missing := func(s string) {
		if missingAnchor == "" {
			missingAnchor = s
		}
	}
	if !strings.Contains(ruleGuide, ruleAnchor) {
		missing(`work-selection.md has no "` + ruleAnchor + `" rule`)
	}
	if askRule == "" {
		missing("the ask-record rule in work-selection.md has no blank line ending it")
	}
	for _, anchor := range []string{"names where it actually landed", "No other word is a channel token", "That includes", "Re-raise on a cadence"} {
		if !strings.Contains(askRule, anchor) {
			missing("the ask-record rule in work-selection.md lacks '" + anchor + "'")
		}
	}
	for _, anchor := range []string{"- **Destination:**", "- **Surface:**"} {
		if !strings.Contains(destinationGuide, anchor) {
			missing("maintainer-channels.md has no '" + anchor + "' bullet")
		}
	}
	if slackDestination == "" {
		missing("maintainer-channels.md has no '- **Surface:**' bullet after '- **Destination:**'")
	}
	for _, anchor := range []string{"Ask channels:", "No other word is a channel token"} {
		if !strings.Contains(helpChannels, anchor) {
			missing("the Ask channels paragraph of --help lacks '" + anchor + "'")
		}
	}
	detail := missingAnchor
	if detail == "" {
		detail = "every anchor is present, but out of order or around no token"
	}
	assert(t, "the guides' ask-record rule and Slack destination, and the help's channel paragraph, are found",
		missingAnchor == "" && guideChannels != "" && guideExcluded != "", "%s; channels='%s' excluded='%s'", detail, guideChannels, guideExcluded)

	// MUTATION: with its end anchor renamed, the destination reads as not found
	// instead of running on to the end of the guide.
	mutatedGuide := strings.ReplaceAll(destinationGuide, "- **Surface:**", "- **Tooling:**")
	assert(t, "MUTATION: a section whose end anchor is gone is not read to the end of the file",
		mutatedGuide != destinationGuide && section(mutatedGuide, "- **Destination:**", "- **Surface:**") == "",
		"the mutation changed nothing, or the span was still returned")

	helpAdvertises := func(channels string) bool { return strings.Contains(help, "| asked <"+channels+"> <YYYY-MM-DD>") }
	assert(t, "--help advertises exactly the guide's channel tokens", helpAdvertises(guideChannels), "guide='%s'", guideChannels)

	// MUTATION: a channel the guide spells with a capital, a hyphen or a digit is
	// read out of it like any other.
	mutatedRule := strings.Replace(askRule, "and `session` the native", "`SMS` a text, `self-dm` a second DM, `dm2` a third, and `session` the native", 1)
	mutatedChannels := ruleTokens(mutatedRule, "names where it actually landed", "No other word is a channel token")
	assert(t, "MUTATION: a guide channel of any spelling is read, and turns the comparison red",
		mutatedChannels == "pr|slack|SMS|self-dm|dm2|session|digest" && !helpAdvertises(mutatedChannels), "read '%s' from the mutated rule", mutatedChannels)

	// askVerdict is the check's verdict on an authority record asked through word.
	askVerdict := func(word string) string {
		receipt := word
		if receipt == "digest" {
			receipt = "digest o/monorepo#40"
		}
		payload := fmt.Sprintf(`[{"repo":"a","number":80,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-09-01: pending | asked %s 2026-09-01"}]`, receipt)
		_, out := withToday(t, payload)
		first := strings.SplitN(out, "\n", 2)[0]
		if fields := strings.Fields(first); len(fields) > 0 {
			return fields[0]
		}
		return ""
	}
	for _, token := range strings.Split(guideChannels, "|") {
		verdict := askVerdict(token)
		assert(t, "--help defines the guide's channel '"+token+"', and the check accepts it",
			token != "" && strings.Contains(helpChannels, " "+token+" = ") && verdict == "CONFORMS", "verdict=%s help=%.200s", verdict, helpChannels)
	}

	// The meaning, not only the token. Each row is a clause a guide states and
	// the clause that carries it in the help; an `excluded` row is looked for
	// only in the sentence of the help that rules words out.
	clauseTokens := "|"
	for _, row := range []struct{ source, token, guideClause, helpClause string }{
		{"rule", "slack", "`slack` historical receipts", "slack = the Slack DM to the maintainer's own user"},
		{"destination", "", "**Destination:** the public monorepo ask issue", "digest = a linked maintainer-ask issue in this repository"},
		{"destination", "", "with only sanitized public context", "digest = a linked maintainer-ask issue in this repository"},
		{"excluded", "push", "`push`, whether it means a git push or the runtime's push notification", "push, whether it means a git push or the runtime's push notification"},
		{"excluded", "issue", "`issue`: a GitHub comment is a durable **record** of an ask", "issue: a GitHub comment records an ask and is not one"},
	} {
		guideText, helpText := slackDestination, helpChannels
		switch row.source {
		case "rule":
			guideText = askRule
		case "excluded":
			guideText, helpText = askRule, helpExcluded
		}
		aboutToken := row.token == "" || strings.HasPrefix(row.guideClause, "`"+row.token+"`")
		ok := aboutToken && strings.Contains(guideText, row.guideClause) && strings.Contains(helpText, row.helpClause)
		assert(t, "--help carries the guide's '"+row.guideClause+"'", ok,
			"the guide must still say it, opening on its token '%s', and the help must say '%s'", row.token, row.helpClause)
		if ok && row.source == "excluded" {
			clauseTokens += row.token + "|"
		}
	}
	ruledOut := func(word string) bool {
		return strings.Contains(clauseTokens, "|"+word+"|") && askVerdict(word) == "NO-ASK"
	}
	for _, word := range strings.Split(guideExcluded, "|") {
		assert(t, "--help rules out the guide's non-channel '"+word+"', and the check reads it as NO-ASK",
			word != "" && ruledOut(word), "it needs an 'excluded' row that holds (rows hold for '%s'); verdict=%s", clauseTokens, askVerdict(word))
	}
	// MUTATION: the help says "a GitHub comment" and "the check reads" in
	// passing, and the check reads either word as NO-ASK. Neither counts as
	// ruled out unless a row says so.
	for _, word := range []string{"comment", "check"} {
		inHelp := regexp.MustCompile(`\b` + regexp.QuoteMeta(word) + `\b`).MatchString(helpExcluded)
		assert(t, "MUTATION: '"+word+"', which the help only uses in passing, is not ruled out without a row",
			inHelp && askVerdict(word) == "NO-ASK" && !ruledOut(word), "the control needs the word in the help's exclusion sentence, and no row for it")
	}
}

// Current-head review regressions, the ask digest, the entrypoint, the
// verification bound and the unlabelled and unrecorded finding classes.
func TestCLIFindingClassesAndEntrypoint(t *testing.T) {
	rc, out := withToday(t, `[{"repo":"a","number":70,"body":"**Blocker:** Cloudflare account action | authority | last-verified 2026-09-01: pending | asked session 2026-09-01"}]`)
	assert(t, "explicit authority accepts a descriptive account action", rc == 0, "rc=%d out=%s", rc, out)
	rc, out = withToday(t, `[{"repo":"a","number":71,"body":"**Blocker:** owner/repo#1 | authority | upstream | last-verified 2026-09-01: pending"}]`)
	assert(t, "multiple blocker kinds cannot bypass the authority ask", rc == 1 && line(out, `^MALFORMED`), "rc=%d out=%s", rc, out)
	rc, out = withToday(t, `[{"repo":"a","number":72,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-09-01: outage-cause=credentials/auth; access is still missing | asked pr 2026-09-01"}]`)
	assert(t, "a draft PR ask and separate outage cause conform", rc == 0, "rc=%d out=%s", rc, out)

	// Digest flag plumbing through the compiled CLI, with both selected and
	// excluded records.
	digest := `[{"repo":"pending","number":73,"body":"**Blocker:** Grant pending access | authority | last-verified 2026-09-05: unavailable"},
 {"repo":"fresh","number":74,"body":"**Blocker:** Already requested access | authority | last-verified 2026-09-05: unavailable | asked session 2026-09-05"}]`
	rc, out = shapes(t, invocation{}, "--ask-digest", "--input", payloadFile(t, digest), "--today", "2026-09-05")
	assert(t, "compiled CLI emits the digest and excludes a fresh ask",
		rc == 1 && line(out, `^ASK DIGEST -- 1 `) && line(out, `^  > Grant pending access$`) && !line(out, `fresh|Already requested access`), "rc=%d out=%s", rc, out)

	// The installed entrypoint as a caller: stdin and argument forwarding and
	// both the success and the findings exit codes.
	rc, out = wrapper(t, invocation{}, "--quiet", "--verify-max-age-days", "999999999", "--input", payloadFile(t, good))
	assert(t, "shell entrypoint forwards quiet success", rc == 0 && out == "", "rc=%d out=%s", rc, out)
	rc, out = wrapper(t, invocation{stdin: missing}, "--quiet", "--input", "-")
	assert(t, "shell entrypoint forwards stdin and findings status", rc == 1 && out == "MISSING    b#2", "rc=%d out=%s", rc, out)

	// A record verified longer ago than the bound is a finding (#3161). These run
	// the unwrapped guard, so the default bound applies.
	verifyAge := payloadFile(t, `[{"repo":"s","number":1,"body":"**Blocker:** o/r#7 | upstream | last-verified 2026-09-01: pending"}]`)
	rc, out = guard(t, invocation{}, "--input", verifyAge, "--today", "2026-09-08")
	assert(t, "a record verified exactly 7 days ago conforms", rc == 0 && line(out, `^CONFORMS`), "rc=%d out=%s", rc, out)
	rc, out = guard(t, invocation{}, "--input", verifyAge, "--today", "2026-09-09")
	assert(t, "a record verified 8 days ago is STALE by default", rc == 1 && line(out, `^STALE      s#1`), "rc=%d out=%s", rc, out)
	rc, out = guard(t, invocation{}, "--input", verifyAge, "--today", "2026-09-09", "--verify-max-age-days", "30")
	assert(t, "the verification bound is a flag", rc == 0, "rc=%d out=%s", rc, out)
	rc, out = guard(t, invocation{}, "--input", verifyAge, "--today", "2026-08-31")
	assert(t, "a future verification date is never fresh", rc == 1 && line(out, `^MALFORMED`), "rc=%d out=%s", rc, out)

	// A declared blocker on an issue without the blocked label (#3142).
	unlabelled := `[{"repo":"u","number":1,"labels":[{"name":"bug"}],"body":"**Blocker:** maintainer authority: sign the release"},
 {"repo":"u","number":2,"labels":[],"type":null,"body":"**Blocker:** none — agent-actionable"},
 {"repo":"u","number":3,"labels":[],"type":null,"body":"plain work"}]`
	rc, out = wrapper(t, invocation{}, "--quiet", "--input", payloadFile(t, unlabelled))
	assert(t, "an unlabelled declared blocker is UNLABELLED, and none is skipped",
		rc == 1 && out == "UNLABELLED u#1  >>**Blocker:** maintainer authority: sign the release", "rc=%d out=%s", rc, out)

	// An unstarted Security issue with no record (#3415); the Bug beside it is
	// the same in every other respect and is not reported.
	unstarted := func(number int, kind, created, assignees, nativeBlocker, body string) string {
		return fmt.Sprintf(`{"repo":"s","number":%d,"labels":[],"type":{"name":"%s"},"created_at":"%s","assignees":%s,%s"sub_issues_summary":{"total":0,"completed":0},"body":"%s"}`,
			number, kind, created, assignees, nativeBlocker, body)
	}
	const noBlocker = `"issue_dependencies_summary":{"blocked_by":0},`
	parkedSecurity := unstarted(1, "Security", "2026-09-01T00:00:00Z", "[]", noBlocker, "plain work")
	const unrecordedRow = "UNRECORDED s#1  opened 2026-09-01, unstarted for 19 day(s)"
	unrecorded := payloadFile(t, "["+parkedSecurity+","+unstarted(2, "Bug", "2026-09-01T00:00:00Z", "[]", noBlocker, "plain work")+"]")
	quiet := func(payload string, args ...string) (int, string) {
		return wrapper(t, invocation{}, append([]string{"--quiet", "--input", payload, "--today", "2026-09-20"}, args...)...)
	}
	rc, out = quiet(unrecorded)
	assert(t, "an unstarted Security issue with no record is UNRECORDED, and a Bug is not", rc == 1 && out == unrecordedRow+" with no record", "rc=%d out=%s", rc, out)
	rc, out = quiet(payloadFile(t, "["+parkedSecurity+`,{"repo":"s","number":9,"labels":[],"pull_request":{},"user":{"login":"devantler"},"body":"Part of #1"}]`))
	assert(t, "ABLATION: an open pull request that mentions it clears it", rc == 0 && out == "", "rc=%d out=%s", rc, out)
	rc, out = quiet(unrecorded, "--unrecorded-max-age-days", "19")
	assert(t, "ABLATION: within the bound it is only new", rc == 0 && out == "", "rc=%d out=%s", rc, out)
	rc, out = quiet(payloadFile(t, "["+parkedSecurity+`,{"repo":"s","number":9,"labels":[],"pull_request":{},"user":{"login":"renovate[bot]"},"body":"Fixes #1"}]`))
	assert(t, "a dependency bot's pull request does not clear it", rc == 1 && out == unrecordedRow+" with no record", "rc=%d out=%s", rc, out)
	rc, out = quiet(payloadFile(t, "["+unstarted(1, "Security", "2026-09-01T00:00:00Z", `[{"login":"devantler"}]`, noBlocker, "plain work")+"]"))
	assert(t, "an assignee does not clear it, and the row says it is assigned", rc == 1 && out == unrecordedRow+" with no record  [assigned]", "rc=%d out=%s", rc, out)
	rc, out = quiet(payloadFile(t, "["+unstarted(1, "Security", "2026-09-01T00:00:00Z", "[]", noBlocker, "**Blocker:** none — agent-actionable")+"]"))
	assert(t, "declaring no blocker does not clear it, and the row says what was declared", rc == 1 && out == unrecordedRow+" while declaring no blocker", "rc=%d out=%s", rc, out)

	// A fact the verdict rests on that cannot be read is UNKNOWN, never clean.
	loud := func(payload string, args ...string) (int, string) {
		return wrapper(t, invocation{}, append([]string{"--input", payload, "--today", "2026-09-20"}, args...)...)
	}
	rc, out = loud(payloadFile(t, "["+unstarted(1, "Security", "", "[]", noBlocker, "plain work")+"]"))
	assert(t, "an unstarted Security issue of unreadable age is UNKNOWN", rc == 2 && strings.Contains(out, "no readable created_at") && !strings.Contains(out, "all 0 open"), "rc=%d out=%s", rc, out)
	rc, out = loud(payloadFile(t, "["+unstarted(1, "Security", "2026-09-01T00:00:00Z", "[]", "", "plain work")+"]"))
	assert(t, "an unstarted Security issue with no native-blocker summary is UNKNOWN", rc == 2 && strings.Contains(out, "carries no issue_dependencies_summary") && !strings.Contains(out, "all 0 open"), "rc=%d out=%s", rc, out)
	rc, out = loud(unrecorded, "--unrecorded-max-age-days", "19")
	assert(t, "the clean verdict counts the Security issues it read", rc == 0 && strings.Contains(out, "none of the 1 open Security issue(s) read has gone unstarted for more than 19 day(s)"), "rc=%d out=%s", rc, out)
}

// parkedForge is the stub forge of the parked pull-request cases (#3424): the
// searches are read with --paginate, every other read is one `gh api --include`
// per page following the Link header, offering a kept page's validator (#4055).
type parkedForge struct {
	t     *testing.T
	calls string
	kept  string
}

// read serves a pull request that reports count comments, whose comment
// thread is page (read with exit status status) and, when second is not
// empty, a second page. It returns the sweep's status and output.
func (f *parkedForge) read(count int, page string, status int, second string) (int, string) {
	f.t.Helper()
	link := ""
	if second != "" {
		link = `Link: <https://api.github.com/repositories/1/issues/7/comments?per_page=100&page=2>; rel="next"\r\n`
	}
	n := strconv.Itoa(count)
	script := `#!/usr/bin/env bash
echo "$*" >>"` + f.calls + `"
case "$*" in
  *is:pr*) echo '{"total_count":1,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":7,"labels":[{"name":"blocked"}],"user":{"login":"renovate[bot]"},"comments":0,"body":"bump"}]}' ;;
  *is:issue*) echo '{"total_count":1,"incomplete_results":false,"items":[` + securityItem + `]}' ;;
  "api --include repos/devantler-tech/r/issues/7") printf 'HTTP/2.0 200 OK\r\nEtag: W/"record-` + n + `"\r\n\r\n%s\n' '{"number":7,"comments":` + n + `}' ;;
  "api --include -H If-None-Match: W/\"record-` + n + `\" repos/devantler-tech/r/issues/7") printf 'HTTP/2.0 304 Not Modified\r\n\r\n'; echo 'gh: HTTP 304' >&2; exit 1 ;;
  "api --include -H If-None-Match: "*" repos/devantler-tech/r/issues/7") printf 'HTTP/2.0 200 OK\r\nEtag: W/"record-` + n + `"\r\n\r\n%s\n' '{"number":7,"comments":` + n + `}' ;;
  "api --include repos/devantler-tech/r/issues/7/comments?per_page=100") printf 'HTTP/2.0 200 OK\r\nEtag: W/"thread"\r\n` + link + `\r\n%s\n' '` + page + `'; exit ` + strconv.Itoa(status) + ` ;;
  "api --include -H If-None-Match: W/\"thread\" repos/devantler-tech/r/issues/7/comments?per_page=100") printf 'HTTP/2.0 304 Not Modified\r\n\r\n'; echo 'gh: HTTP 304' >&2; exit 1 ;;
  "api --include https://api.github.com/repositories/1/issues/7/comments?per_page=100&page=2") printf 'HTTP/2.0 200 OK\r\n\r\n%s\n' '` + second + `' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
`
	path := shim(f.t, script)
	if err := os.WriteFile(f.calls, nil, 0o600); err != nil {
		f.t.Fatal(err)
	}
	return shapes(f.t, invocation{env: []string{path, "BLOCKER_LINE_CACHE_DIR=" + f.kept}}, "--org", "devantler-tech")
}

func (f *parkedForge) callLines(pattern string) int {
	raw, _ := os.ReadFile(f.calls)
	n := 0
	for _, l := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		if regexp.MustCompile(pattern).MatchString(l) {
			n++
		}
	}
	return n
}

const parkRecord = `> 🤖 Generated by the Agentic Engineer\n\n<!-- pr-blocker-record -->\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: open`

// Parked pull requests through the real `gh api <endpoint> --paginate` read.
func TestCLIParkedPullRequestRead(t *testing.T) {
	f := &parkedForge{t: t, calls: filepath.Join(t.TempDir(), "gh-calls"), kept: "off"}
	record := `[{"user":{"login":"devantler"},"body":"` + parkRecord + `"}]`
	rebased := `[{"user":{"login":"renovate[bot]"},"body":"rebased"}]`

	rc, out := f.read(2, rebased, 0, record)
	assert(t, "a parked pull request with one record comment, read over two pages, conforms",
		rc == 0 && strings.Contains(out, "all 1 open blocked-labelled pull request(s) carry one conforming record comment"), "rc=%d; out: %.300s", rc, out)
	rc, out = f.read(1, rebased, 0, "")
	assert(t, "a parked pull request with no record comment is MISSING", rc == 1 && line(out, `^MISSING    r#7  \[pull request\]$`), "rc=%d; out: %.300s", rc, out)
	// The failing read prints the conforming record, so ignoring its status
	// would print a clean sweep.
	rc, out = f.read(1, record, 1, "")
	assert(t, "a comment read that fails after printing the record is UNKNOWN(2)",
		rc == 2 && strings.Contains(out, "forge read failed -- UNKNOWN") && !strings.Contains(out, "pull request(s)"), "rc=%d; out: %.300s", rc, out)
	rc, out = f.read(3, record, 0, "")
	assert(t, "a comment read shorter than the counted comments is UNKNOWN(2)",
		rc == 2 && strings.Contains(out, "truncated comment read") && !strings.Contains(out, "pull request(s)"), "rc=%d; out: %.300s", rc, out)

	// A second sweep offers each kept page back and reuses it when the forge
	// says it is unchanged. The first sweep is the control.
	f.kept = filepath.Join(t.TempDir(), "kept")
	firstRC, firstOut := f.read(1, record, 0, "")
	firstCalls := f.callLines(`If-None-Match`)
	rc, out = f.read(1, record, 0, "")
	conditional, total := f.callLines(`If-None-Match`), f.callLines(`^api --include`)
	assert(t, "a second sweep reuses every page the forge confirms unchanged",
		firstRC == 0 && firstCalls == 0 && rc == 0 && out == firstOut && conditional == total && conditional >= 2,
		"first rc=%d calls=%d; rc=%d; out: %.300s", firstRC, firstCalls, rc, out)
	// The pull request gained a comment: the thread the forge still confirms is
	// one comment short, so it is read again anew before it is judged.
	rc, out = f.read(2, record, 0, "")
	assert(t, "a kept thread that no longer adds up is read anew before it is judged",
		rc == 2 && strings.Contains(out, "truncated comment read") && f.callLines(`^api --include repos/devantler-tech/r/issues/7/comments\?per_page=100$`) > 0, "rc=%d; out: %.300s", rc, out)
}

// readSplit splits an invocation run with split set into stdout and stderr.
func readSplit(out string) (string, string) {
	parts := strings.SplitN(out, "\x00", 2)
	return parts[0], parts[1]
}

// The composer, the parked digest, and the guides that define both.
func TestCLIComposerDigestAndContract(t *testing.T) {
	// The record a run posts is printed by the wrapper, not typed (#3879): feed
	// what it printed back through the sweep as a parked pull request's only
	// comment, and a refusal must leave nothing on stdout to post.
	rc, both := wrapper(t, invocation{split: true}, "compose", "--target", "o/r#5", "--kind", "upstream", "--blocker", "o/other#7", "--result", "still open")
	composed, _ := readSplit(both)
	sweep := ""
	sweepRC := -1
	if rc == 0 && composed != "" {
		raw, err := json.Marshal([]map[string]any{{"repo": "r", "number": 5, "pull_request": map[string]any{}, "labels": []any{map[string]string{"name": "blocked"}}, "body": "",
			"comments": []any{map[string]any{"user": map[string]string{"login": "devantler"}, "body": composed}}}})
		if err != nil {
			t.Fatal(err)
		}
		sweepRC, sweep = guard(t, invocation{stdin: string(raw)}, "--input", "-")
	}
	assert(t, "the wrapper composes a record the sweep accepts",
		sweepRC == 0 && strings.Contains(sweep, "all 1 open blocked-labelled pull request(s) carry one conforming record comment"),
		"rc=%d; composed: %.200s; sweep: %.300s", rc, composed, sweep)
	rc, both = wrapper(t, invocation{split: true}, "compose", "--target", "o/r#5", "--kind", "upstream", "--blocker", "review, CI and evaluation", "--result", "pending")
	stdout, stderr := readSplit(both)
	assert(t, "the wrapper refuses readiness work as a blocker and prints nothing",
		rc == 2 && stdout == "" && strings.Contains(stderr, "its own unfinished work"), "rc=%d; out: %.200s; err: %.300s", rc, stdout, stderr)

	// CONTRACT: the merge policy tells a run how to write the record the check
	// accepts. Scoped to the paragraph that defines it, and failing when that
	// paragraph cannot be found.
	mergeGuide := readGuide(t, "guides/merge-policy.md")
	parkRule := parkSection(mergeGuide)
	// MUTATION: with its closing heading gone, the paragraph reads as not found instead of running
	// on to the end of the guide, where a later section could satisfy the assertions below.
	unclosed := strings.ReplaceAll(mergeGuide, parkEnd, "**Is anyone working on it?**")
	assert(t, "MUTATION: a parked-PR rule whose closing heading is gone is not read to the end of the guide",
		unclosed != mergeGuide && parkSection(unclosed) == "", "the mutation changed nothing, or the paragraph was still returned")
	rc, both = guard(t, invocation{split: true}, "--help")
	help, _ := readSplit(both)
	assert(t, "the merge policy defines the parked-PR record", parkRule != "", "no paragraph starting '**A parked PR carries one blocker record' in merge-policy.md")
	if parkRule != "" {
		for _, token := range []string{"<!-- pr-blocker-record -->", "`blocked` label", "on a line of its own", "edit that comment in place", "`MISSING`", "`DUPLICATE`", "by `devantler`", "**Blocker:** none", "blocked-label-blocker-line.sh --org devantler-tech", "blocked-label-blocker-line.sh compose --target", "blocked-label-blocker-line.sh park --org devantler-tech --target", "blocked-label-blocker-line.sh unpark --org devantler-tech --target", "only after reading both", "never a blocker"} {
			assert(t, "the parked-PR rule states: "+token, strings.Contains(parkRule, token), "not found in the rule paragraph")
		}
		normalized := flat(parkRule)
		assert(t, "unparking preserves the blocker record", !regexp.MustCompile(`(?i)delet(e[sd]?|ing|ion)[^.!?;]*(comment|record)`).MatchString(normalized), "the guide still requires irreversible comment deletion")
		for _, token := range []string{"<!-- pr-blocker-record -->", "DUPLICATE", "devantler", "on a line of its own"} {
			assert(t, "--help states: "+token, strings.Contains(help, token), "not found in --help")
		}
	}

	// The parked digest (#3288) through the compiled CLI and the installed
	// entrypoint: flag plumbing, the three row shapes and both exit codes.
	const digestRecord = `> 🤖 Generated by the Agentic Engineer\n\n<!-- pr-blocker-record -->\n**Blocker:** o/r#7 | upstream | last-verified 2026-09-01: open`
	digestPull := func(number int, state, comments string) string {
		return fmt.Sprintf(`{"repo":"d","number":%d,"pull_request":{},"labels":[{"name":"blocked"}],%s"body":"x","comments":[%s]}`, number, state, comments)
	}
	comment := `{"user":{"login":"devantler"},"body":"` + digestRecord + `"}`
	digest := payloadFile(t, "["+digestPull(1, `"blocker_state":"open",`, comment)+","+digestPull(2, `"blocker_state":"closed",`, comment)+","+digestPull(3, "", "")+"]")
	raw, err := os.ReadFile(digest)
	if err != nil {
		t.Fatal(err)
	}
	const expected = "PARKED     d#1  [upstream, blocker open]  o/r#7\nACTIONABLE d#2  record=BLOCKER-CLOSED  o/r#7\nACTIONABLE d#3  record=MISSING\nCHECKED labelled=3 parked=1 actionable=2"
	rc, out := guard(t, invocation{}, "--parked-digest", "--input", digest, "--today", "2026-09-05")
	assert(t, "compiled CLI emits the parked digest", rc == 1 && out == expected, "rc=%d out=%s", rc, out)
	rc, out = wrapper(t, invocation{stdin: string(raw)}, "--parked-digest", "--input", "-", "--today", "2026-09-05")
	assert(t, "shell entrypoint forwards the parked digest and its findings status", rc == 1 && out == expected, "rc=%d out=%s", rc, out)
	rc, out = wrapper(t, invocation{}, "--parked-digest", "--input", payloadFile(t, "["+digestPull(1, `"blocker_state":"open",`, comment)+"]"), "--today", "2026-09-05")
	assert(t, "shell entrypoint exits 0 when every labelled pull request is parked", rc == 0 && line(out, `^CHECKED labelled=1 parked=1 actionable=0$`), "rc=%d out=%s", rc, out)
	// An unreadable payload is UNKNOWN and must not print a digest that reads
	// as "nothing parked".
	rc, out = wrapper(t, invocation{stdin: "{\n"}, "--parked-digest", "--input", "-")
	assert(t, "the parked digest is UNKNOWN on an unreadable payload", rc == 2 && !strings.Contains(out, "CHECKED"), "rc=%d out=%s", rc, out)

	// CONTRACT: the merge policy and the run procedure tell a run to read the
	// digest and what each row means.
	if parkRule != "" {
		for _, token := range []string{"blocked-label-blocker-line.sh --org devantler-tech --parked-digest", "`PARKED <repo>#<n>  [<note>]  <blocker>`", "`ACTIONABLE <repo>#<n>", "`record=BLOCKER-CLOSED`", "`BLOCKER-SELF`", "never reads an authority blocker", "do not count it against `nothing_on_fire`", "`2` is UNKNOWN", "Only this digest makes a PR parked",
			// A park is owned work, never a resting place (devantler-tech/agent-plugins#699).
			"`STRANDED <repo>#<n>  reason=<reason>  age=<n>d  <blocker>`", "`reason=UNCLAIMED`", "`reason=NO-DECISION`", "`reason=DECISION-LAPSED`", "`reason=ESCALATE`", "`awaits <the exact upstream event>`", "`re-check <YYYY-MM-DD>`", "**A park is never a resting place**", "Its blocker is still owned work", "Raising the limit alone hides the stall", "**A mis-park is unparked and driven.**"} {
			assert(t, "the parked-PR rule states: "+token, strings.Contains(parkRule, token), "not found in the rule paragraph")
		}
		for _, token := range []string{"--parked-digest", "BLOCKER-CLOSED", "CHECKED"} {
			assert(t, "--help states: "+token, strings.Contains(help, token), "not found in --help")
		}
	}
	assert(t, "the run procedure runs the parked digest after the survey",
		strings.Contains(readGuide(t, "skills/portfolio-maintenance/SKILL.md"), "blocked-label-blocker-line.sh --org devantler-tech --parked-digest"), "command not found in the run procedure")
	assert(t, "the run procedure reads a STRANDED row as rung-1 work",
		strings.Contains(flat(readGuide(t, "skills/portfolio-maintenance/SKILL.md")), "An `ACTIONABLE` or `STRANDED` row is rung-1 work this run"), "STRANDED is not work in the run procedure")
}

const (
	parkStart = "**A parked PR carries one blocker record"
	parkEnd   = `**"Is someone actively working on it?"`
)

// parkSection is the merge policy's parked-PR rule: the lines from the one opening on parkStart
// up to the next line opening on parkEnd. It returns nothing unless BOTH anchors are there, in that
// order, so a renamed closing heading cannot stretch the rule to the end of the guide. (The
// retired shell suite read to the end of the file in that case; requiring the end only tightens it.)
func parkSection(text string) string {
	var rule strings.Builder
	inside := false
	for _, l := range strings.Split(text, "\n") {
		if !inside && strings.HasPrefix(l, parkStart) {
			inside = true
		}
		if inside && strings.HasPrefix(l, parkEnd) {
			return rule.String()
		}
		if inside {
			rule.WriteString(l + "\n")
		}
	}
	return ""
}
