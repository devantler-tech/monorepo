package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testRegistry = `{"version":1,"policyPublisher":"codex-local","instances":{
  "claude-local":{"namespace":"claude","authors":{"cli":"devantler","rest":"devantler","graphql":"devantler","search":"devantler"},"definitionAdapter":"claude","roles":["agentic-engineer"]},
  "codex-local":{"namespace":"codex","authors":{"cli":"devantler","rest":"devantler","graphql":"devantler","search":"devantler"},"definitionAdapter":"codex","roles":["agentic-engineer"]},
  "build-worker":{"namespace":"worker","authors":{"cli":"app/build-worker","rest":"build-worker[bot]","graphql":"build-worker","search":"app/build-worker"},"definitionAdapter":"local-runtime","roles":["agentic-engineer"]}
}}`

type fakeEnv struct {
	files map[string]string
	gh    func(args []string) (string, error)
	vars  map[string]string
	calls []string
}

func (f *fakeEnv) env(stdout, stderr io.Writer) env {
	return env{
		gh: func(_ io.Reader, args ...string) (string, error) {
			f.calls = append(f.calls, strings.Join(args, " "))
			if f.gh == nil {
				return "", errors.New("unexpected gh call")
			}
			return f.gh(args)
		},
		lookPath: func(string) (string, error) { return "/usr/bin/gh", nil },
		getenv:   func(k string) string { return f.vars[k] },
		readFile: func(name string) ([]byte, error) {
			if text, ok := f.files[name]; ok {
				return []byte(text), nil
			}
			return nil, os.ErrNotExist
		},
		stdin:  strings.NewReader(""),
		stdout: stdout,
		stderr: stderr,
	}
}

func runReport(t *testing.T, f *fakeEnv, args ...string) (int, string, string) {
	t.Helper()
	if f.files == nil {
		f.files = map[string]string{}
	}
	if _, ok := f.files["reg.json"]; !ok {
		f.files["reg.json"] = testRegistry
	}
	var stdout, stderr bytes.Buffer
	code := run(append([]string{"--instances", "reg.json"}, args...), f.env(&stdout, &stderr))
	return code, stdout.String(), stderr.String()
}

func commitJSON(sha, verified, reason string) string {
	return `{"sha":"` + sha + `","commit":{"verification":{"verified":` + verified + `,"reason":"` + reason + `"}}}`
}

func TestClassOf(t *testing.T) {
	for reason, want := range map[string]string{
		"valid": "G", "unsigned": "N", "invalid": "B", "malformed_signature": "B", "bad_cert": "B",
		"unknown_signature_type": "B", "malformed_ssh_signature": "B", "bad_email": "E",
		"unknown_key": "E", "missing": "E", "some_future_reason": "E", "": "E",
	} {
		if got := classOf(reason); got != want {
			t.Errorf("classOf(%q) = %q, want %q", reason, got, want)
		}
	}
}

func TestPayloadModeReportsWithoutFailing(t *testing.T) {
	f := &fakeEnv{files: map[string]string{"p.json": "[" + commitJSON("aaaa1111", "true", "valid") + "," +
		commitJSON("cccc3333", "false", "unsigned") + "," + commitJSON("d2", "false", "bad_email") + "," +
		commitJSON("d3", "false", "invalid") + "]"}}
	code, out, _ := runReport(t, f, "--input", "p.json", "--head-ref", "codex/y-2")
	want := "N  cccc3333  unsigned  codex/y-2\nE  d2  bad_email  codex/y-2\nB  d3  invalid  codex/y-2\n" +
		"examined=4 signed=1 unsigned=1 bad=1 unverifiable=1 head=codex/y-2 lane=codex\n"
	if code != 0 || out != want {
		t.Fatalf("code=%d out=%q", code, out)
	}
	if len(f.calls) != 0 {
		t.Fatalf("payload mode reached the forge: %q", f.calls)
	}
}

func TestPayloadDefaultsAndUnknowns(t *testing.T) {
	f := &fakeEnv{files: map[string]string{
		"noverif.json":   `[{"sha":"f1","commit":{}}]`,
		"obj.json":       `{"not":"an array"}`,
		"multi.json":     "{}\n[]\n",
		"badcell.json":   `[{"sha":{"x":1},"commit":{}}]`,
		"nested.json":    `[{"sha":"f1","commit":"text"}]`,
		"lookalike.json": "[" + commitJSON("a", "true", "valid") + "]",
	}}
	if code, out, _ := runReport(t, f, "--input", "noverif.json"); code != 0 || !strings.HasPrefix(out, "E  f1  missing  \n") {
		t.Fatalf("missing verification: code=%d out=%q", code, out)
	}
	for _, name := range []string{"obj.json", "multi.json", "badcell.json", "nested.json", "absent.json"} {
		if code, _, errText := runReport(t, f, "--input", name); code != 2 || !strings.Contains(errText, "unsigned-commit-report.sh: ") {
			t.Errorf("%s: code=%d err=%q", name, code, errText)
		}
	}
	for _, ref := range []string{"cursor/z-3", "feature/thing", "claudex/thing"} {
		if code, out, _ := runReport(t, f, "--input", "lookalike.json", "--head-ref", ref); code != 0 || !strings.HasSuffix(out, "lane=none skipped=non-agent-head\n") {
			t.Errorf("%s: code=%d out=%q", ref, code, out)
		}
	}
}

func TestProvenanceSkipsForeignWork(t *testing.T) {
	f := &fakeEnv{files: map[string]string{"p.json": "[" + commitJSON("c1", "false", "unsigned") + "]"}}
	base := []string{"--input", "p.json", "--head-ref", "worker/change", "--repo", "o/r"}
	cases := []struct {
		extra []string
		want  string
	}{
		{[]string{"--head-repo", "o/r", "--pr-author", "build-worker[bot]"}, "examined=1 "},
		{[]string{"--head-repo", "o/fork", "--pr-author", "build-worker[bot]"}, "skipped=foreign-head"},
		{[]string{"--head-owner", "x", "--head-repo", "o/r", "--pr-author", "build-worker[bot]"}, "skipped=foreign-head"},
		// The REST spelling is the one that counts; the CLI spelling of the same App is foreign.
		{[]string{"--head-repo", "o/r", "--pr-author", "app/build-worker"}, "skipped=foreign-author"},
	}
	for _, tc := range cases {
		code, out, _ := runReport(t, f, append(append([]string{}, base...), tc.extra...)...)
		if code != 0 || !strings.Contains(out, tc.want) {
			t.Errorf("%v: code=%d out=%q", tc.extra, code, out)
		}
	}
	if code, _, errText := runReport(t, f, append(append([]string{}, base...), "--pr-author", "x")...); code != 2 || !strings.Contains(errText, "incomplete") {
		t.Fatalf("incomplete provenance: code=%d err=%q", code, errText)
	}
}

func TestRegistryIsTheAuthority(t *testing.T) {
	valid, ok := loadRegistry([]byte(testRegistry))
	if !ok || len(valid.instances) != 3 || valid.instances[0].namespace != "claude" || valid.instances[2].namespace != "worker" {
		t.Fatalf("valid registry misread: %+v %v", valid, ok)
	}
	broken := []string{
		``, `[]`, `{}`, testRegistry + testRegistry,
		strings.Replace(testRegistry, `"version":1`, `"version":2`, 1),
		strings.Replace(testRegistry, `"policyPublisher":"codex-local"`, `"policyPublisher":"absent"`, 1),
		strings.Replace(testRegistry, `"namespace":"worker"`, `"namespace":"claude"`, 1),
		strings.Replace(testRegistry, `"namespace":"worker"`, `"namespace":"Worker"`, 1),
		strings.Replace(testRegistry, `"search":"app/build-worker"`, `"search":""`, 1),
		strings.Replace(testRegistry, `"definitionAdapter":"local-runtime",`, ``, 1),
		strings.Replace(testRegistry, `"roles":["agentic-engineer"]}`, `"roles":[]}`, 1),
		// jq reads exact key spellings, a numeric version and one value per instance key.
		strings.Replace(testRegistry, `"version":1`, `"version":"1"`, 1),
		strings.Replace(testRegistry, `"namespace":"worker","authors"`, `"namespace":"worker","Authors"`, 1),
		strings.Replace(testRegistry, `"build-worker":{"namespace":"worker"`, `"build-worker":{"NameSpace":"worker"`, 1),
		strings.Replace(testRegistry, `"build-worker":{`, `"claude-local":{`, 1),
	}
	for _, text := range broken {
		if _, ok := loadRegistry([]byte(text)); ok {
			t.Errorf("accepted malformed registry %q", text)
		}
	}
	f := &fakeEnv{files: map[string]string{"reg.json": `{}`, "p.json": "[]"}}
	if code, _, errText := runReport(t, f, "--input", "p.json"); code != 2 || !strings.Contains(errText, "instance registry is unreadable or malformed -- UNKNOWN") {
		t.Fatalf("malformed registry: code=%d err=%q", code, errText)
	}
}

func TestUsageErrorsAreUnknown(t *testing.T) {
	f := &fakeEnv{files: map[string]string{"p.json": "[]"}}
	for _, args := range [][]string{
		{}, {"--input", "p.json", "--pr", "1", "--repo", "a/b"}, {"--pr", "1"}, {"--pr", "x", "--repo", "a/b"},
		{"--repo", "a/b", "--merged-since", "yesterday"}, {"--input", "p.json", "--lanes", "claude,claude"},
		{"--input", "p.json", "--lanes", "claude,,codex"}, {"--input", "p.json", "--lanes", "cursor"},
		{"--pr", "1", "--repo", "a/b;rm"}, {"--bogus"}, {"--input"},
	} {
		if code, _, _ := runReport(t, f, args...); code != 2 {
			t.Errorf("%q: code=%d, want 2", args, code)
		}
	}
	var stdout bytes.Buffer
	if code := run([]string{"--help"}, f.env(&stdout, io.Discard)); code != 0 || !strings.HasPrefix(stdout.String(), "unsigned-commit-report.sh — report unsigned") {
		t.Fatalf("help: code=%d out=%q", code, stdout.String())
	}
}

func TestPRModeReadsProvenanceAndCapsCommits(t *testing.T) {
	metadata := `{"head":{"ref":"claude/x-7","repo":{"owner":{"login":"o"},"full_name":"o/r"}},"user":{"login":"devantler"}}`
	commits := "[" + commitJSON("c1", "true", "valid") + "]\n[" + commitJSON("c2", "false", "unsigned") + "]"
	f := &fakeEnv{gh: func(args []string) (string, error) {
		switch strings.Join(args, " ") {
		case "api repos/o/r/pulls/7":
			return metadata, nil
		case "api repos/o/r/pulls/7/commits --paginate":
			return commits, nil
		}
		return "", errors.New("unexpected")
	}}
	code, out, _ := runReport(t, f, "--pr", "7", "--repo", "o/r")
	if code != 0 || out != "N  c2  unsigned  claude/x-7\nexamined=2 signed=1 unsigned=1 bad=0 unverifiable=0 head=claude/x-7 lane=claude\n" {
		t.Fatalf("code=%d out=%q", code, out)
	}
	if code, _, errText := runReport(t, f, "--pr", "7", "--repo", "o/r", "--head-ref", "claude/other"); code != 2 || !strings.Contains(errText, "differs") {
		t.Fatalf("mismatched head: code=%d err=%q", code, errText)
	}
	many := make([]string, prCommitCap)
	for i := range many {
		many[i] = commitJSON("s", "true", "valid")
	}
	commits = "[" + strings.Join(many, ",") + "]"
	if code, _, errText := runReport(t, f, "--pr", "7", "--repo", "o/r"); code != 2 || !strings.Contains(errText, "TRUNCATED") {
		t.Fatalf("commit cap: code=%d err=%q", code, errText)
	}
}

func TestActionsAnnotationsAndStepSummary(t *testing.T) {
	summary := filepath.Join(t.TempDir(), "summary.md")
	f := &fakeEnv{
		files: map[string]string{"p.json": "[" + commitJSON("cccc3333aaaa", "false", "unsigned") + "]"},
		vars:  map[string]string{"GITHUB_ACTIONS": "true", "GITHUB_STEP_SUMMARY": summary},
	}
	code, out, _ := runReport(t, f, "--input", "p.json", "--head-ref", "codex/y-2")
	if code != 0 || !strings.HasPrefix(out, "::warning title=Unsigned or unverifiable commit (N)::cccc3333aa unsigned on codex/y-2\n") {
		t.Fatalf("code=%d out=%q", code, out)
	}
	written, err := os.ReadFile(summary)
	if err != nil || !strings.Contains(string(written), "| N | `cccc3333aa` | unsigned | codex/y-2 |") {
		t.Fatalf("step summary: %q %v", written, err)
	}
}

func TestReadFieldsMatchesShellRead(t *testing.T) {
	cases := map[string][]string{
		"a\tb\tc\td":     {"a", "b", "c", "d"},
		"a\tb\tc\td\te":  {"a", "b", "c", "d\te"},
		"\ta\t\tb\tc\t":  {"a", "b", "c", ""},
		"a\tb":           {"a", "b", "", ""},
		"a\tb\tc\td\t\t": {"a", "b", "c", "d"},
		"":               {"", "", "", ""},
	}
	for line, want := range cases {
		got := readFields(line, 4)
		if strings.Join(got, "|") != strings.Join(want, "|") {
			t.Errorf("readFields(%q) = %q, want %q", line, got, want)
		}
	}
	if got := splitLanes("a,b,,"); len(got) != 3 || got[2] != "" {
		t.Errorf("splitLanes kept the wrong fields: %q", got)
	}
}
