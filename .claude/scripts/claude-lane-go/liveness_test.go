package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fixtureNow = int64(1788000000)

func fixtureISO(e int64) string {
	return time.Unix(e, 0).UTC().Format("2006-01-02T15:04:05") + ".000Z"
}

// writeSession is the shell suite's mksession: a first line carrying the escaped task marker and
// the start, `turns` assistant records, and a closing record that fixes the span.
func writeSession(t *testing.T, dir, id string, start int64, turns int, span int64) string {
	t.Helper()
	var b strings.Builder
	fmt.Fprintf(&b, `{"type":"user","timestamp":"%s","message":{"role":"user","content":"<scheduled-task name=\"%s\" file=\"/x\">go</scheduled-task>"}}`+"\n", fixtureISO(start), id)
	for i := 0; i < turns; i++ {
		fmt.Fprintf(&b, `{"type":"assistant","timestamp":"%s"}`+"\n", fixtureISO(start+1))
	}
	fmt.Fprintf(&b, `{"type":"system","timestamp":"%s"}`+"\n", fixtureISO(start+span))
	p := filepath.Join(dir, fmt.Sprintf("sess-%s-%d.jsonl", id, start))
	if err := os.WriteFile(p, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	mt := time.Unix(start+span, 0)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	return p
}

func twoTaskFixture(t *testing.T) (store, projects, alpha string) {
	t.Helper()
	dir := t.TempDir()
	store = filepath.Join(dir, "store.json")
	projects = filepath.Join(dir, "projects")
	if err := os.MkdirAll(filepath.Join(projects, "proj-a"), 0o700); err != nil {
		t.Fatal(err)
	}
	var tasks []string
	for _, id := range []string{"alpha", "beta"} {
		tasks = append(tasks, fmt.Sprintf(`{"id":"%s","enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"0 * * * *"}`,
			id, fixtureISO(fixtureNow-3600), fixtureISO(fixtureNow-fixtureNow%3600)))
	}
	if err := os.WriteFile(store, []byte(`{"scheduledTasks":[`+strings.Join(tasks, ",")+"]}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	alpha = writeSession(t, filepath.Join(projects, "proj-a"), "alpha", fixtureNow-3599, 40, 1200)
	writeSession(t, filepath.Join(projects, "proj-a"), "beta", fixtureNow-3599, 40, 1200)
	return store, projects, alpha
}

func runLiveness(t *testing.T, env environment, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	if env.loc == nil {
		env.loc = time.UTC
	}
	code := liveness(args, &out, &errOut, env)
	return code, out.String(), errOut.String()
}

// The shell suite reached this case by shimming `head` on PATH so one header read failed; the Go
// implementation reads headers itself, so the same two assertions drive its read seam instead.
func TestUnreadableHeader(t *testing.T) {
	store, projects, alpha := twoTaskFixture(t)
	args := []string{"--store", store, "--projects", projects, "--now-epoch", fmt.Sprint(fixtureNow)}
	denying := func(denied string) func(string) (string, error) {
		return func(p string) (string, error) {
			if p == denied {
				return "", errors.New("permission denied")
			}
			return readFirstLine(p)
		}
	}
	t.Run("the header-read shim preserves readable healthy transcripts", func(t *testing.T) {
		code, _, stderr := runLiveness(t, environment{readHeader: denying(filepath.Join(projects, "absent.jsonl"))}, append(args, "--quiet")...)
		if code != 0 {
			t.Fatalf("exit %d, want 0: %s", code, stderr)
		}
	})
	t.Run("an unreadable candidate header is UNKNOWN even when another task keeps the index nonempty", func(t *testing.T) {
		code, _, stderr := runLiveness(t, environment{readHeader: denying(alpha)}, args...)
		if code != 2 {
			t.Fatalf("exit %d, want 2: %s", code, stderr)
		}
		want := "claude-lane-liveness: UNKNOWN -- could not read a transcript header; cannot establish attribution"
		if !strings.Contains(stderr, want) {
			t.Fatalf("stderr lacks %q: %s", want, stderr)
		}
	})
}

// The recovery note follows every UNKNOWN, as the script's die_unknown printed it.
func TestUnknownCarriesTheRecoveryNote(t *testing.T) {
	code, stdout, stderr := runLiveness(t, environment{readHeader: readFirstLine}, "--nope")
	want := "claude-lane-liveness: UNKNOWN -- unrecognised argument: --nope\n" + livenessRecovery + "\n"
	if code != 2 || stdout != "" || stderr != want {
		t.Fatalf("exit %d, stdout %q, stderr %q", code, stdout, stderr)
	}
}

// Bash arithmetic read a knob with a leading zero as octal, or failed on it outright; it is
// refused here rather than read either way.
func TestLeadingZeroKnobIsRefused(t *testing.T) {
	store, projects, _ := twoTaskFixture(t)
	for _, flag := range []string{"--grace-seconds", "--skew-seconds", "--lookback-hours", "--stall-seconds", "--now-epoch"} {
		code, _, stderr := runLiveness(t, environment{readHeader: readFirstLine},
			"--store", store, "--projects", projects, "--now-epoch", fmt.Sprint(fixtureNow), flag, "010")
		if code != 2 || !strings.Contains(stderr, "without a leading zero") {
			t.Errorf("%s 010: exit %d: %s", flag, code, stderr)
		}
	}
}

// A host without jq was UNKNOWN for both scripts and stays UNKNOWN, never a verdict.
func TestNoJQIsUnknown(t *testing.T) {
	store, projects, _ := twoTaskFixture(t)
	noJQ := func(string) (string, error) { return "", errors.New("not found") }
	code, _, stderr := runLiveness(t, environment{readHeader: readFirstLine, lookPath: noJQ},
		"--store", store, "--projects", projects, "--now-epoch", fmt.Sprint(fixtureNow))
	if code != 2 || !strings.Contains(stderr, "claude-lane-liveness: UNKNOWN -- jq is not available") {
		t.Errorf("liveness without jq: exit %d: %s", code, stderr)
	}
	var out, errOut bytes.Buffer
	code = dispatchRate([]string{"--task", "alpha", "--since", "2026-09-01T00:00:00Z", "--store", store, "--projects", projects},
		&out, &errOut, environment{readHeader: readFirstLine, lookPath: noJQ, loc: time.UTC, wallNow: fixtureNow})
	if code != 2 || errOut.String() != "claude-dispatch-rate: UNKNOWN -- jq is not available\n" {
		t.Errorf("dispatch-rate without jq: exit %d: %s", code, errOut.String())
	}
}
