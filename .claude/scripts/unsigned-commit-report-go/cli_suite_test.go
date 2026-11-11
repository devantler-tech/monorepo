package main

// The launcher suite, ported one assertion for one from the retired
// unsigned-commit-report.test.sh (monorepo#3224). Every subtest keeps the shell
// assertion's name, so the two can be compared row by row.
//
// Hermetic: every case drives the installed shell entrypoint through the
// --input seam or a stub `gh` placed first on PATH; nothing reaches the network.
// The last section runs the workflow's own report step from ci.yaml.

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

const suiteInstances = `{"version":1,"policyPublisher":"codex-local","instances":{
  "claude-local":{"namespace":"claude","authors":{"cli":"devantler","rest":"devantler","graphql":"devantler","search":"devantler"},"definitionAdapter":"claude","roles":["agentic-engineer","agent-improver"]},
  "codex-local":{"namespace":"codex","authors":{"cli":"devantler","rest":"devantler","graphql":"devantler","search":"devantler"},"definitionAdapter":"codex","roles":["agentic-engineer","agent-improver"]},
  "build-worker":{"namespace":"worker","authors":{"cli":"app/build-worker","rest":"build-worker[bot]","graphql":"build-worker","search":"app/build-worker"},"definitionAdapter":"local-runtime","roles":["agentic-engineer"]}
}}
`

// The stub `gh` returns exactly the row counts asked for, so the listing caps
// can be pinned without a network.
const stubGH = `#!/usr/bin/env bash
case "$*" in
  *"pr list"*)
    i=0; while [ "$i" -lt "${FAKE_PRS:-0}" ]; do i=$((i + 1)); printf '%s\t%s/x-%s\t%s\t%s\n' "$i" "${FAKE_LANE:-claude}" "$i" "${FAKE_AUTHOR:-devantler}" "${FAKE_CROSS:-false}"; done
    # a fork PR whose branch merely LOOKS like lane work: wrong author, wrong head-repository owner
    i=0; while [ "$i" -lt "${FAKE_FOREIGN:-0}" ]; do i=$((i + 1)); printf '%s\tclaude/foreign-%s\tstranger\ttrue\n' "$((10000 + i))" "$i"; done ;;
  *"/commits"*)
    [ "${FAKE_COMMIT_READ_FAIL:-0}" = 0 ] || exit 98
    jq -n --argjson n "${FAKE_COMMITS:-0}" '[range($n) | {sha: ("c" + tostring), commit: {verification: {verified: true, reason: "valid"}}}]' ;;
  *"api repos/o/r/pulls/7"*)
    [ "${FAKE_PR_READ_FAIL:-0}" = 0 ] || exit 97
    if [ "${FAKE_PR_MISSING:-0}" = 1 ]; then printf '{}\n'
    elif [ "${!#}" = '.head.ref' ]; then printf '%s\n' "${FAKE_PR_HEAD:-claude/x-7}"
    else
      jq -n --arg head "${FAKE_PR_HEAD:-claude/x-7}" --arg owner "${FAKE_PR_OWNER:-o}" --arg repo "${FAKE_PR_REPO:-o/r}" --arg author "${FAKE_PR_AUTHOR:-devantler}" \
        '{head:{ref:$head,repo:{owner:{login:$owner},full_name:$repo}},user:{login:$author}}'
    fi ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 99 ;;
esac
`

type suite struct {
	t         *testing.T
	dir       string
	check     string
	instances string
	bin       string
}

func newSuite(t *testing.T) *suite {
	t.Helper()
	check, err := filepath.Abs(filepath.Join("..", "unsigned-commit-report.sh"))
	if err != nil {
		t.Fatal(err)
	}
	s := &suite{t: t, dir: t.TempDir(), check: check}
	s.instances = s.write("instances.json", suiteInstances)
	s.bin = filepath.Join(s.dir, "bin")
	if err := os.MkdirAll(s.bin, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.bin, "gh"), []byte(stubGH), 0o700); err != nil {
		t.Fatal(err)
	}
	return s
}

func (s *suite) write(name, content string) string {
	s.t.Helper()
	path := filepath.Join(s.dir, name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		s.t.Fatal(err)
	}
	return path
}

// environ is this process's environment without the named keys, plus extra.
func environ(drop []string, extra ...string) []string {
	var kept []string
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		removed := false
		for _, d := range drop {
			if key == d {
				removed = true
			}
		}
		if !removed {
			kept = append(kept, kv)
		}
	}
	return append(kept, extra...)
}

// The suite never writes to an enclosing Actions job: these two are dropped
// from every invocation unless a case sets them explicitly.
var actionsVars = []string{"GITHUB_ACTIONS", "GITHUB_STEP_SUMMARY"}

// execute runs name with stdout and stderr interleaved as `2>&1` captures them,
// with the trailing newlines `$(...)` strips removed.
func execute(t *testing.T, dir string, env []string, name string, args ...string) (int, string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = env
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	rc := 0
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			t.Fatalf("run %s: %v", name, err)
		}
		rc = exitErr.ExitCode()
	}
	return rc, strings.TrimRight(out.String(), "\n")
}

// run is the shell suite's run(): the launcher with the fixture registry, and
// the Actions variables always cleared.
func (s *suite) run(args ...string) (int, string) {
	s.t.Helper()
	return execute(s.t, "", environ(actionsVars), s.check, append([]string{"--instances", s.instances}, args...)...)
}

// actions runs the launcher with the given Actions environment.
func (s *suite) actions(extra []string, args ...string) (int, string) {
	s.t.Helper()
	return execute(s.t, "", environ(actionsVars, extra...), s.check, append([]string{"--instances", s.instances}, args...)...)
}

// stub runs the launcher against the stub forge reporting prs pull requests of
// commits commits each.
func (s *suite) stub(prs, commits int, fake []string, args ...string) (int, string) {
	s.t.Helper()
	extra := append([]string{"PATH=" + s.bin + string(os.PathListSeparator) + os.Getenv("PATH"),
		"FAKE_PRS=" + strconv.Itoa(prs), "FAKE_COMMITS=" + strconv.Itoa(commits)}, fake...)
	return execute(s.t, "", environ(actionsVars, extra...), s.check, append([]string{"--instances", s.instances}, args...)...)
}

func line(out, pattern string) bool {
	return regexp.MustCompile("(?m)" + pattern).MatchString(out)
}

func countLines(out, pattern string) int {
	n := 0
	re := regexp.MustCompile(pattern)
	for _, l := range strings.Split(out, "\n") {
		if re.MatchString(l) {
			n++
		}
	}
	return n
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

func (s *suite) expectRC(name string, want int, args ...string) {
	s.t.Helper()
	rc, out := s.run(args...)
	assert(s.t, name, rc == want, "expected rc=%d got rc=%d; out: %.300s", want, rc, out)
}

func (s *suite) expectOut(name, pattern string, args ...string) {
	s.t.Helper()
	_, out := s.run(args...)
	assert(s.t, name, line(out, pattern), "no match for /%s/; out: %.300s", pattern, out)
}

func commit(sha, verified, reason string) string {
	return `{"sha":"` + sha + `","commit":{"verification":{"verified":` + verified + `,"reason":"` + reason + `"}}}`
}

func validCommits(n int) string {
	list := make([]string, n)
	for i := range list {
		list[i] = commit("c"+strconv.Itoa(i), "true", "valid")
	}
	return "[" + strings.Join(list, ",") + "]"
}

func TestLauncherSuite(t *testing.T) {
	s := newSuite(t)

	// 1. all signed: exit 0, nothing reported, coverage stated
	signed := s.write("signed.json", "["+commit("aaaa1111", "true", "valid")+","+commit("bbbb2222", "true", "valid")+"]\n")
	s.expectRC("all-signed payload exits 0", 0, "--input", signed, "--head-ref", "claude/x-1")
	s.expectOut("all-signed summary states coverage", `^examined=2 signed=2 unsigned=0 bad=0 unverifiable=0 head=claude/x-1 lane=claude$`, "--input", signed, "--head-ref", "claude/x-1")
	_, out := s.run("--input", signed, "--head-ref", "claude/x-1")
	assert(t, "all-signed output is the summary line alone", strings.Count(out, "\n") == 0, "out: %s", out)

	// 2. THE CONTRACT: an unsigned commit is reported and does NOT fail
	unsigned := s.write("unsigned.json", "["+commit("aaaa1111", "true", "valid")+","+commit("cccc3333", "false", "unsigned")+"]\n")
	s.expectRC("an unsigned commit still exits 0 (non-blocking)", 0, "--input", unsigned, "--head-ref", "codex/y-2")
	s.expectOut("the unsigned commit is reported as class N", `^N  cccc3333  unsigned  codex/y-2$`, "--input", unsigned, "--head-ref", "codex/y-2")
	s.expectOut("the summary counts it under unsigned=", `examined=2 signed=1 unsigned=1 bad=0 unverifiable=0 head=codex/y-2 lane=codex`, "--input", unsigned, "--head-ref", "codex/y-2")

	// 3. N is never conflated with B/E
	mixed := s.write("mixed.json", "["+commit("d1", "false", "unsigned")+","+commit("d2", "false", "bad_email")+","+commit("d3", "false", "invalid")+","+commit("d4", "false", "unknown_key")+"]\n")
	s.expectOut("bad_email is class E, not N", `^E  d2  bad_email`, "--input", mixed)
	s.expectOut("invalid is class B", `^B  d3  invalid`, "--input", mixed)
	s.expectOut("unknown_key is class E", `^E  d4  unknown_key`, "--input", mixed)
	s.expectOut("the three classes are counted separately", `unsigned=1 bad=1 unverifiable=2`, "--input", mixed)
	// NEGATIVE CONTROL: the same four commits with valid reasons report nothing.
	mixedOK := s.write("mixed-ok.json", "["+commit("d1", "true", "valid")+","+commit("d2", "true", "valid")+","+commit("d3", "true", "valid")+","+commit("d4", "true", "valid")+"]\n")
	_, out = s.run("--input", mixedOK)
	assert(t, "NEGATIVE CONTROL: valid reasons report no finding", !line(out, `^[NBE]  `), "out: %s", out)

	// 4. an unseen reason is E (unverifiable), never a pass
	s.expectOut("an unrecognised reason is class E", `^E  e1  some_future_reason`, "--input", s.write("unseen.json", "["+commit("e1", "false", "some_future_reason")+"]\n"))
	s.expectOut("the reason outranks a contradictory verified flag", `^E  e2  bad_email`, "--input", s.write("contra.json", "["+commit("e2", "true", "bad_email")+"]\n"))

	// 5. a missing verification object is not silently a pass
	s.expectOut("a commit with no verification object is reported, reason=missing", `^E  f1  missing`, "--input", s.write("noverif.json", `[{"sha":"f1","commit":{}}]`+"\n"))

	// 6. coverage: the lane is stated, and a non-lane branch is lane=none
	s.expectOut("a registered neutral namespace is classified", `lane=worker$`, "--input", signed, "--head-ref", "worker/z-3")
	s.expectOut("an unregistered retired namespace is skipped", `lane=none skipped=non-agent-head$`, "--input", signed, "--head-ref", "cursor/z-3")
	s.expectOut("a non-lane head is lane=none and skipped", `^examined=0 .* head=feature/thing lane=none skipped=non-agent-head$`, "--input", signed, "--head-ref", "feature/thing")
	s.expectOut("a lookalike prefix is not a lane", `lane=none skipped=non-agent-head$`, "--input", signed, "--head-ref", "claudex/thing")
	s.expectOut("--lanes narrows the namespace set", `lane=none skipped=non-agent-head$`, "--input", signed, "--head-ref", "claude/x", "--lanes", "codex")

	// 7. an empty payload states it examined nothing
	empty := s.write("empty.json", "[]\n")
	s.expectRC("an empty payload exits 0", 0, "--input", empty)
	s.expectOut("an empty payload reports examined=0", `^examined=0 signed=0 unsigned=0`, "--input", empty)

	// 8. UNKNOWN is exit 2, never 0
	obj := s.write("obj.json", `{"not":"an array"}`+"\n")
	s.expectRC("a non-array payload is UNKNOWN(2)", 2, "--input", obj)
	s.expectOut("and says so", `not a JSON array`, "--input", obj)
	s.expectRC("an unparseable payload is UNKNOWN(2)", 2, "--input", s.write("nonjson.json", "nope\n"))
	s.expectRC("multiple JSON documents are UNKNOWN, not an empty report", 2, "--input", s.write("multiple.json", "{}\n[]\n"))
	s.expectRC("a missing payload file is UNKNOWN(2)", 2, "--input", filepath.Join(s.dir, "does-not-exist.json"))
	s.expectRC("no mode at all is a usage error", 2)
	s.expectRC("two modes at once is a usage error", 2, "--input", empty, "--pr", "1", "--repo", "a/b")
	s.expectRC("--pr without --repo is a usage error", 2, "--pr", "1")
	s.expectRC("a non-numeric --pr is a usage error", 2, "--pr", "x", "--repo", "a/b")
	s.expectRC("a malformed --merged-since is a usage error", 2, "--repo", "a/b", "--merged-since", "yesterday")

	// 9. under GitHub Actions the finding is an annotation and the summary lands
	// in the step summary. run() clears both variables, so an ordinary fixture
	// call cannot reach the Actions surface even when they are set.
	leak := filepath.Join(s.dir, "fixture-leak.md")
	t.Setenv("GITHUB_ACTIONS", "true")
	t.Setenv("GITHUB_STEP_SUMMARY", leak)
	_, out = s.run("--input", unsigned, "--head-ref", "codex/y-2")
	_, statErr := os.Stat(leak)
	assert(t, "ordinary fixture calls do not emit Actions annotations or summaries", errors.Is(statErr, os.ErrNotExist) && !line(out, `^::warning`), "fixture output reached the Actions surface")
	summary := s.write("summary.md", "")
	rc, out := s.actions([]string{"GITHUB_ACTIONS=true", "GITHUB_STEP_SUMMARY=" + summary}, "--input", unsigned, "--head-ref", "codex/y-2")
	assert(t, "a finding is a ::warning:: annotation under Actions", line(out, `^::warning title=Unsigned or unverifiable commit \(N\)::cccc3333 unsigned on codex/y-2`), "out: %s", out)
	assert(t, "and never an ::error:: (non-blocking)", !line(out, `^::error`), "out: %s", out)
	written, _ := os.ReadFile(summary)
	assert(t, "the step summary carries the summary and the finding table",
		strings.Contains(string(written), "examined=2 signed=1 unsigned=1") && strings.Contains(string(written), "| N | `cccc3333` | unsigned | codex/y-2 |"), "%s", written)
	assert(t, "and the Actions run still exits 0", rc == 0, "rc=%d", rc)
	// CONTROL: outside Actions no annotation is printed. The suite itself runs
	// under Actions, so the control clears the variables explicitly.
	_, out = s.run("--input", unsigned, "--head-ref", "codex/y-2")
	assert(t, "CONTROL: no annotation outside Actions", !line(out, `^::warning`), "out: %s", out)

	// 10. the two listing caps fail CLOSED (stubbed gh). Direct mode obtains
	// provenance from the PR API even when --head-ref is supplied.
	rc, out = s.stub(0, 2, []string{"FAKE_PR_OWNER=contributor", "FAKE_COMMIT_READ_FAIL=1"}, "--pr", "7", "--repo", "o/r")
	assert(t, "direct PR mode skips a foreign head before reading commits", rc == 0 && line(out, `examined=0 .*skipped=foreign-head`), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(0, 2, []string{"FAKE_PR_AUTHOR=contributor", "FAKE_COMMIT_READ_FAIL=1"}, "--pr", "7", "--repo", "o/r", "--head-ref", "claude/x-7")
	assert(t, "a supplied head ref does not replace the PR author lookup", rc == 0 && line(out, `examined=0 .*skipped=foreign-author`), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(0, 2, []string{"FAKE_PR_READ_FAIL=1"}, "--pr", "7", "--repo", "o/r", "--head-ref", "claude/x-7")
	assert(t, "failed PR metadata is UNKNOWN even with a supplied head ref", rc == 2, "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(0, 2, []string{"FAKE_PR_MISSING=1"}, "--pr", "7", "--repo", "o/r", "--head-ref", "claude/x-7")
	assert(t, "missing PR provenance is UNKNOWN", rc == 2, "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(0, 2, nil, "--pr", "7", "--repo", "o/r")
	assert(t, "CONTROL: direct PR mode still reports our own branch", rc == 0 && line(out, `^examined=2 signed=2`), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(3, 250, nil, "--pr", "7", "--repo", "o/r", "--head-ref", "claude/x-7")
	assert(t, "a PR at the 250-commit cap is UNKNOWN, not a partial count", rc == 2 && strings.Contains(out, "at the 250-commit endpoint cap"), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(3, 249, nil, "--pr", "7", "--repo", "o/r", "--head-ref", "claude/x-7")
	assert(t, "CONTROL: one below the commit cap reports the full set", rc == 0 && line(out, `^examined=249 signed=249`), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(1000, 1, nil, "--repo", "o/r", "--merged-since", "2026-09-01")
	assert(t, "a lane at the merged-PR cap is UNKNOWN, not a partial sweep", rc == 2 && strings.Contains(out, "at the 1000-PR cap"), "rc=%d out=%.200s", rc, out)
	// Foreign results consume the same search limit as lane-owned PRs.
	rc, out = s.stub(1, 2, []string{"FAKE_FOREIGN=999"}, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "foreign results count toward the merged-PR completeness cap", rc == 2 && strings.Contains(out, "at the 1000-PR cap"), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(1, 2, []string{"FAKE_FOREIGN=998"}, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "CONTROL: mixed provenance below the listing cap remains complete", rc == 0 && line(out, `^examined=2 signed=2 .* prs=1 foreign=998 `), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(3, 2, nil, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "CONTROL: a lane below the cap sweeps every PR", rc == 0 && line(out, `^examined=6 signed=6 .* prs=3 foreign=0 lanes=claude lane=sweep$`), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(0, 0, nil, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "CONTROL: an empty listing states prs=0", rc == 0 && line(out, `^examined=0 .* prs=0 `), "rc=%d out=%.200s", rc, out)

	// 11. a non-agent head is SKIPPED: no classification, no annotation
	s.expectRC("an unsigned commit on a non-agent head exits 0", 0, "--input", unsigned, "--head-ref", "feature/thing")
	rc, out = s.run("--input", unsigned, "--head-ref", "feature/thing")
	assert(t, "a non-agent head classifies nothing and states the skip",
		!line(out, `^N  `) && line(out, `^examined=0 signed=0 unsigned=0 bad=0 unverifiable=0 head=feature/thing lane=none skipped=non-agent-head$`), "rc=%d out=%.200s", rc, out)
	rc, out = s.actions([]string{"GITHUB_ACTIONS=1"}, "--input", unsigned, "--head-ref", "feature/thing")
	assert(t, "and emits no annotation under Actions", rc == 0 && !strings.Contains(out, "::warning"), "rc=%d out=%.200s", rc, out)
	rc, out = s.actions([]string{"GITHUB_ACTIONS=1"}, "--input", unsigned, "--head-ref", "codex/y-2")
	assert(t, "CONTROL: an agent head is still classified and annotated", rc == 0 && line(out, `^N  cccc3333`) && strings.Contains(out, "::warning"), "rc=%d out=%.200s", rc, out)
	s.expectOut("CONTROL: a payload with no head ref is still classified", `^N  cccc3333`, "--input", unsigned)

	// 12. the sweep NAMES its targets even when everything is signed
	rc, out = s.stub(3, 2, nil, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "the sweep prints one target line per PR with its examined SHAs",
		rc == 0 && countLines(out, `^T  o/r#[0-9]*  claude/x-[0-9]*  commits=2  `) == 3 && line(out, `^T  o/r#2  claude/x-2  commits=2  c0 c1$`), "rc=%d out=%.300s", rc, out)
	rc, out = s.stub(3, 2, nil, "--pr", "7", "--repo", "o/r", "--head-ref", "claude/x-7")
	assert(t, "CONTROL: --pr mode prints no target line", rc == 0 && !line(out, `^T  `), "rc=%d out=%.200s", rc, out)

	// 13. --input honours the commit cap
	s.expectRC("an --input payload at the 250-commit cap is UNKNOWN", 2, "--input", s.write("cap.json", validCommits(250)), "--head-ref", "claude/x-1")
	s.expectOut("CONTROL: one below the cap reports the full set", `^examined=249 signed=249`, "--input", s.write("cap-1.json", validCommits(249)), "--head-ref", "claude/x-1")

	// 14. a fork PR with a lane-looking branch is NOT lane work
	rc, out = s.stub(3, 2, []string{"FAKE_FOREIGN=1"}, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "a foreign-provenance PR is excluded from the sweep and counted as foreign=1",
		rc == 0 && line(out, `^examined=6 signed=6 .* prs=3 foreign=1 lanes=claude lane=sweep$`) && !line(out, `^T  o/r#10001 `), "rc=%d out=%.300s", rc, out)
	rc, out = s.stub(3, 2, nil, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "CONTROL: an all-own sweep reports foreign=0", rc == 0 && strings.Contains(out, " prs=3 foreign=0 "), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(1, 2, []string{"FAKE_CROSS=true"}, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude")
	assert(t, "a cross-repository head by the lane's own writer is foreign, not examined",
		rc == 0 && line(out, `^examined=0 .* prs=0 foreign=1 lanes=claude lane=sweep$`) && !line(out, `^T  `), "rc=%d out=%.300s", rc, out)

	// 15. a repeated lane name is refused, never double-counted
	rc, out = s.stub(3, 2, nil, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude,claude")
	assert(t, "--lanes with a repeated name is UNKNOWN (usage error), not a doubled count", rc == 2 && strings.Contains(out, "repeats"), "rc=%d out=%.200s", rc, out)
	rc, out = s.stub(3, 2, nil, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "claude,codex")
	assert(t, "CONTROL: distinct lane names still sweep", rc == 0, "rc=%d out=%.200s", rc, out)

	// 16. the PER-PR path checks provenance, not just the branch NAME
	prov := s.write("prov.json", "["+commit("1111111111111111111111111111111111111111", "false", "unsigned")+"]")
	s.expectOut("a fork head is skipped as foreign, not classified", `examined=0 .*skipped=foreign-head`,
		"--input", prov, "--head-ref", "codex/foo", "--repo", "devantler-tech/monorepo", "--head-owner", "stranger", "--head-repo", "stranger/monorepo", "--pr-author", "stranger")
	s.expectOut("an author that is not the lane's writer identity is skipped as foreign", `examined=0 .*skipped=foreign-author`,
		"--input", prov, "--head-ref", "codex/foo", "--repo", "devantler-tech/monorepo", "--head-owner", "devantler-tech", "--head-repo", "devantler-tech/monorepo", "--pr-author", "stranger")
	s.expectOut("CONTROL: our own head and writer identity is still classified", `^N  1111111111`,
		"--input", prov, "--head-ref", "codex/foo", "--repo", "devantler-tech/monorepo", "--head-repo", "devantler-tech/monorepo", "--head-owner", "devantler-tech", "--pr-author", "devantler")
	s.expectOut("CONTROL: no provenance supplied still classifies", `^N  1111111111`, "--input", prov, "--head-ref", "codex/foo")
	for _, headRepo := range []string{"devantler-tech/monorepo", "stranger/fork"} {
		rc, out = s.run("--input", prov, "--repo", "devantler-tech/monorepo", "--head-repo", headRepo, "--pr-author", "stranger")
		assert(t, "supplied provenance with absent branch is UNKNOWN for "+headRepo, rc == 2 && strings.Contains(out, "UNKNOWN") && !line(out, `^N  `), "rc=%d out=%s", rc, out)
	}
	rc, out = s.run("--input", prov, "--head-ref", "", "--repo", "devantler-tech/monorepo", "--head-repo", "devantler-tech/monorepo", "--pr-author", "devantler")
	assert(t, "explicitly empty authoritative branch is UNKNOWN", rc == 2 && strings.Contains(out, "UNKNOWN"), "rc=%d out=%s", rc, out)
	s.expectOut("CONTROL: payload-only classification remains available", `^N  1111111111`, "--input", prov)

	// 17. configured API spellings, and only those
	s.expectOut("REST input accepts the registered neutral writer", `^N  1111111111`,
		"--input", prov, "--head-ref", "worker/foo", "--repo", "devantler-tech/monorepo", "--head-repo", "devantler-tech/monorepo", "--head-owner", "devantler-tech", "--pr-author", "build-worker[bot]")
	for _, spelling := range []string{"build-worker", "app/build-worker", "stranger", "build-worker[bot]-forged"} {
		s.expectOut("REST input refuses foreign or wrong-surface author "+spelling, `skipped=foreign-author`,
			"--input", prov, "--head-ref", "worker/foo", "--repo", "devantler-tech/monorepo", "--head-owner", "devantler-tech", "--head-repo", "devantler-tech/monorepo", "--pr-author", spelling)
	}
	noneInstances := s.write("none-instances.json", strings.Replace(suiteInstances, `"namespace":"worker"`, `"namespace":"none"`, 1))
	s.expectOut("a registered namespace named none is classified", `^N  1111111111`,
		"--input", prov, "--instances", noneInstances, "--head-ref", "none/work", "--repo", "devantler-tech/monorepo", "--head-repo", "devantler-tech/monorepo", "--pr-author", "build-worker[bot]")
	rc, out = s.stub(1, 2, []string{"FAKE_LANE=worker", "FAKE_AUTHOR=app/build-worker"}, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "worker")
	assert(t, "CLI sweep accepts the registered neutral writer", rc == 0 && line(out, `^examined=2 signed=2 .*prs=1 foreign=0`), "rc=%d out=%s", rc, out)
	rc, out = s.stub(1, 2, []string{"FAKE_LANE=worker", "FAKE_AUTHOR=build-worker[bot]"}, "--repo", "o/r", "--merged-since", "2026-09-01", "--lanes", "worker")
	assert(t, "CLI sweep refuses the REST spelling", rc == 0 && line(out, `^examined=0 .*prs=0 foreign=1`), "rc=%d out=%s", rc, out)
	rc, out = s.stub(0, 2, []string{"FAKE_PR_REPO=o/fork", "FAKE_COMMIT_READ_FAIL=1"}, "--pr", "7", "--repo", "o/r")
	assert(t, "direct PR excludes a same-owner sibling repository", rc == 0 && strings.Contains(out, "skipped=foreign-head"), "rc=%d out=%s", rc, out)
	s.expectRC("owner-only payload provenance cannot establish the head repository", 2, "--input", prov, "--head-ref", "codex/foo", "--repo", "devantler-tech/monorepo", "--head-owner", "devantler-tech", "--pr-author", "devantler")
	s.expectOut("same-owner fork is excluded by full repository provenance", `skipped=foreign-head`,
		"--input", prov, "--head-ref", "worker/foo", "--repo", "devantler-tech/monorepo", "--head-owner", "devantler-tech", "--head-repo", "devantler-tech/fork", "--pr-author", "build-worker[bot]")
	s.expectRC("--lanes cannot register an unknown namespace", 2, "--input", prov, "--head-ref", "unknown/foo", "--lanes", "unknown")
	missingInstances := filepath.Join(s.dir, "missing-instances.json")
	s.expectRC("missing registry is UNKNOWN", 2, "--input", prov, "--instances", missingInstances)
	s.expectOut("missing registry explicitly states UNKNOWN", `UNKNOWN`, "--input", prov, "--instances", missingInstances)
	// Each mutation is the jq expression the shell suite applied, made as an
	// edit of the same document so its key order is kept.
	for _, m := range []struct{ name, from, to string }{
		{".version = 2", `"version":1`, `"version":2`},
		{".instances = {}", suiteInstances[strings.Index(suiteInstances, `"instances":`):], `"instances":{}}` + "\n"},
		{`.instances["build-worker"].namespace = "codex"`, `"namespace":"worker"`, `"namespace":"codex"`},
		{`.instances["build-worker"].authors.rest = ""`, `"rest":"build-worker[bot]"`, `"rest":""`},
		{`.policyPublisher = "missing"`, `"policyPublisher":"codex-local"`, `"policyPublisher":"missing"`},
	} {
		mutated := strings.Replace(suiteInstances, m.from, m.to, 1)
		if mutated == suiteInstances {
			t.Fatalf("mutation %s changed nothing", m.name)
		}
		s.expectRC("malformed registry fails closed: "+m.name, 2, "--input", prov, "--instances", s.write("bad-instances.json", mutated))
	}

	testWorkflowWiring(t, s, prov)
}

// jobLines is the report-unsigned-commits job of ci.yaml, from its key line up
// to the next job.
func jobLines(ci []string) []string {
	var job []string
	inside := false
	for _, l := range ci {
		if l == "  report-unsigned-commits:" {
			inside = true
		} else if inside && regexp.MustCompile(`^  [a-z]`).MatchString(l) {
			break
		}
		if inside {
			job = append(job, l)
		}
	}
	return job
}

// 18. workflow wiring. These check wiring, not expression evaluation: they run
// the workflow's own report-step shell, with no Actions expression emulation
// and no authenticated operation.
func testWorkflowWiring(t *testing.T, s *suite, prov string) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", ".github", "workflows", "ci.yaml"))
	if err != nil {
		assert(t, "the workflow is readable for the wiring assertions", false, "missing ci.yaml: %v", err)
		return
	}
	ci := strings.Split(string(raw), "\n")
	job := jobLines(ci)

	// The job is scoped to pull requests, so a push to main never reports.
	gate := ""
	for _, l := range job[min(1, len(job)):] {
		if strings.HasPrefix(l, "    if: ") {
			gate = strings.TrimPrefix(l, "    if: ")
			break
		}
	}
	assert(t, "the reporting job runs on every pull request event and only there", gate == "github.event_name == 'pull_request'", "gate=%s", gate)
	step := false
	for _, l := range job {
		if strings.Contains(l, "unsigned-commit-report.sh") {
			step = true
		}
	}
	wired := strings.Contains(string(raw), `--head-owner "$HEAD_OWNER"`) && strings.Contains(string(raw), `--pr-author "$PR_AUTHOR"`)
	assert(t, "CI passes the pull request's provenance to the reporter", step && wired, "step=%v wired=%v", step, wired)

	// The report step's shell, as the workflow carries it.
	var run []string
	instep, inrun := false, false
scan:
	for _, l := range job[min(1, len(job)):] {
		switch {
		case inrun && strings.HasPrefix(l, "          "):
			run = append(run, strings.TrimPrefix(l, "          "))
			continue
		case inrun && strings.TrimSpace(l) == "":
			continue
		case inrun:
		case instep && l == "        run: |":
			inrun = true
			continue
		case l == "      - name: Report unsigned commits on this pull request":
			instep = true
			continue
		default:
			continue
		}
		break scan
	}
	ciRun := strings.Join(run, "\n")
	if ciRun == "" || exec.Command("bash", "-n", "-c", ciRun).Run() != nil {
		assert(t, "the workflow report-step shell is present and executable", false, "missing or malformed report run block")
		return
	}

	fix := filepath.Join(s.dir, "ci-step")
	for _, d := range []string{"bin", "temp", "trusted-base/.claude/scripts", "trusted-base/.claude/plugin-consumption", ".claude/scripts", ".claude/plugin-consumption"} {
		if err := os.MkdirAll(filepath.Join(fix, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	put := func(rel, content string, mode os.FileMode) {
		if err := os.WriteFile(filepath.Join(fix, rel), []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	payload, err := os.ReadFile(prov)
	if err != nil {
		t.Fatal(err)
	}
	put("temp/pr-commits.json", string(payload), 0o600)
	// A conflicting PR-head registry and a poisoned PR-head reporter, so neither
	// can accidentally satisfy the trusted-base contract.
	put(".claude/plugin-consumption/agent-instances.json", strings.Replace(suiteInstances, `"rest":"build-worker[bot]"`, `"rest":"forged-writer"`, 1), 0o600)
	put(".claude/scripts/unsigned-commit-report.sh", "#!/usr/bin/env bash\nprintf 'UNTRUSTED_REPORTER_EXECUTED\\n' >\"$CI_EXEC_MARKER\"\nexit 93\n", 0o700)
	put("bin/gh", "#!/usr/bin/env bash\nprintf 'UNEXPECTED_FORGE_CALL\\n' >\"$CI_FORGE_MARKER\"\nexit 94\n", 0o700)
	// The real reporter runs from a detached path behind a transparent wrapper.
	// Its default registry path does not exist there, so reporting also proves
	// the workflow forwards --instances explicitly.
	launcher, err := os.ReadFile(s.check)
	if err != nil {
		t.Fatal(err)
	}
	put("real-reporter.sh", string(launcher), 0o700)

	// The fixture carries exactly the scripts the trusted sparse checkout lists.
	var sparse []string
	insparse := false
	for _, l := range job {
		if l == "          sparse-checkout: |" {
			insparse = true
			continue
		}
		if insparse && regexp.MustCompile(`^            [^ ]`).MatchString(l) {
			sparse = append(sparse, strings.TrimPrefix(l, "            "))
			continue
		}
		if insparse {
			break
		}
	}
	for _, need := range []string{".claude/scripts/unsigned-commit-report-go/", ".claude/scripts/go-helper-build.sh"} {
		found := false
		for _, entry := range sparse {
			if entry == need {
				found = true
			}
		}
		assert(t, "CI trusted checkout carries "+need, found, "sparse list: %v", sparse)
	}
	for _, entry := range sparse {
		if entry == ".claude/scripts/unsigned-commit-report.sh" || !strings.HasPrefix(entry, ".claude/scripts/") {
			continue
		}
		rel := strings.TrimSuffix(strings.TrimPrefix(entry, ".claude/scripts/"), "/")
		if output, err := exec.Command("cp", "-R", filepath.Join("..", rel), filepath.Join(fix, rel)).CombinedOutput(); err != nil {
			t.Fatalf("copy %s: %v\n%s", rel, err, output)
		}
	}
	jobText := strings.Join(job, "\n")
	goFilesOK := false
	for _, l := range job {
		if strings.Contains(l, "go-version-file:") {
			if !strings.Contains(l, "trusted-base/") {
				goFilesOK = false
				break
			}
			goFilesOK = true
		}
	}
	assert(t, "CI trusted job sets Go up only from the trusted copy, and only when it carries the port",
		strings.Contains(jobText, "if: hashFiles('trusted-base/.claude/scripts/unsigned-commit-report-go/go.mod') != ''") &&
			strings.Contains(jobText, "go-version-file: trusted-base/.claude/scripts/unsigned-commit-report-go/go.mod") && goFilesOK, "%s", jobText)
	put("trusted-base/.claude/scripts/unsigned-commit-report.sh", "#!/usr/bin/env bash\nprintf 'TRUSTED_REPORTER_EXECUTED\\n' >\"$CI_EXEC_MARKER\"\nexec bash \"$CI_REAL_REPORTER\" \"$@\"\n", 0o700)

	reporterCalled := filepath.Join(fix, "reporter-called")
	forgeCalled := filepath.Join(fix, "forge-called")
	exists := func(p string) bool { _, err := os.Stat(p); return err == nil }
	ciStep := func(shell, headRepo string) (int, string) {
		_ = os.Remove(reporterCalled)
		_ = os.Remove(forgeCalled)
		env := environ(append([]string{"GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"}, actionsVars...),
			"PATH="+filepath.Join(fix, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"), "RUNNER_TEMP="+filepath.Join(fix, "temp"),
			"CI_EXEC_MARKER="+reporterCalled, "CI_FORGE_MARKER="+forgeCalled, "CI_REAL_REPORTER="+filepath.Join(fix, "real-reporter.sh"),
			"GITHUB_REPOSITORY=devantler-tech/monorepo", "HEAD_REF=worker/change", "HEAD_OWNER=devantler-tech",
			"HEAD_REPO="+headRepo, "PR_AUTHOR=build-worker[bot]")
		rc, out := execute(t, fix, env, "bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", shell)
		if exists(forgeCalled) {
			t.Errorf("CI report step never calls the forge: %s", out)
		}
		return rc, out
	}
	oldBaseOK := func(rc int, out string) bool {
		return rc == 0 && line(out, `UNKNOWN.*trusted base`) && !exists(reporterCalled)
	}
	currentBaseOK := func(rc int, out string) bool {
		marker, _ := os.ReadFile(reporterCalled)
		return rc == 0 && line(out, `^N  1111111111`) && line(string(marker), `^TRUSTED_REPORTER_EXECUTED$`)
	}
	perLine := func(shell, from, to string) string {
		ls := strings.Split(shell, "\n")
		for i := range ls {
			ls[i] = strings.Replace(ls[i], from, to, 1)
		}
		return strings.Join(ls, "\n")
	}

	rc, out := ciStep(ciRun, "devantler-tech/monorepo")
	assert(t, "CI old base reports UNKNOWN without executing either reporter or the PR registry", oldBaseOK(rc, out), "rc=%d out=%s", rc, out)
	// Mutation control: removing the compatibility guard must break that exact
	// outcome, even though the real reporter also returns an UNKNOWN diagnostic.
	var unguarded []string
	skip := false
	for _, l := range run {
		if strings.HasPrefix(l, "if [[ ! -r ") {
			skip = true
			continue
		}
		if skip && l == "fi" {
			skip = false
			continue
		}
		if !skip {
			unguarded = append(unguarded, l)
		}
	}
	noGuard := strings.Join(unguarded, "\n")
	rc, out = ciStep(noGuard, "devantler-tech/monorepo")
	assert(t, "CONTROL: the old-base assertion catches removal of the compatibility guard", noGuard != ciRun && !oldBaseOK(rc, out), "rc=%d out=%s", rc, out)

	put("trusted-base/.claude/plugin-consumption/agent-instances.json", suiteInstances, 0o600)
	rc, out = ciStep(ciRun, "devantler-tech/monorepo")
	assert(t, "CI current base executes the trusted reporter with its explicit registry", currentBaseOK(rc, out), "rc=%d out=%s", rc, out)
	prRegistry := perLine(ciRun, "--instances trusted-base/", "--instances ")
	rc, out = ciStep(prRegistry, "devantler-tech/monorepo")
	assert(t, "CONTROL: the current-base assertion catches use of the PR-head registry", prRegistry != ciRun && !currentBaseOK(rc, out), "rc=%d out=%s", rc, out)
	prReporter := perLine(ciRun, "bash trusted-base/", "bash ")
	rc, out = ciStep(prReporter, "devantler-tech/monorepo")
	assert(t, "CONTROL: the current-base assertion catches execution of the PR-head reporter", prReporter != ciRun && !currentBaseOK(rc, out), "rc=%d out=%s", rc, out)
	rc, out = ciStep(ciRun, "devantler-tech/sibling-fork")
	assert(t, "CI forwards full head repository provenance and excludes same-owner forks", rc == 0 && strings.Contains(out, "skipped=foreign-head"), "rc=%d out=%s", rc, out)
	put("trusted-base/.claude/plugin-consumption/agent-instances.json", "{}\n", 0o600)
	rc, out = ciStep(ciRun, "devantler-tech/monorepo")
	assert(t, "CI malformed trusted registry stays UNKNOWN instead of falling back to the PR registry", rc == 2 && line(out, `instance registry.*UNKNOWN`), "rc=%d out=%s", rc, out)
}
