package main

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"testing"
)

func TestMain(m *testing.M) {
	zeroConfirmDelay = 0
	os.Exit(m.Run())
}

// A zero search is read once more before it is believed (#4435): a transient
// zero followed by open items is UNKNOWN, and a zero read twice stays clean.
func TestZeroSearchIsConfirmed(t *testing.T) {
	pull := forgeParkedPull(t, "platform")
	for _, tc := range []struct {
		name    string
		parked  bool
		replies []string
		errs    []error
		code    int
		want    string
	}{
		{"pull zero then items", true, []string{searchPage(), searchPage(pull)}, nil, 2, "search answered zero, then 1"},
		{"pull zero then failure", true, []string{searchPage(), ""}, []error{nil, errors.New("down")}, 2, "confirming a zero search"},
		{"pull zero then malformed", true, []string{searchPage(), "not JSON"}, nil, 2, "unreadable search page"},
		{"pull zero twice", true, []string{searchPage(), searchPage()}, nil, 0, "CHECKED labelled=0 parked=0 actionable=0"},
		{"issue zero then items", false, []string{searchPage(), searchPage(forgeIssue)}, nil, 2, "search answered zero, then 1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			original := forgeRead
			t.Cleanup(func() { forgeRead = original })
			target := pullEndpoint("o")
			if !tc.parked {
				target = searchEndpoint("o")
			}
			reads := 0
			forgeRead = func(endpoint string) ([]byte, error) {
				switch endpoint {
				case target:
					i := reads
					reads++
					if i >= len(tc.replies) {
						return nil, errors.New("read a zero search more than twice")
					}
					var err error
					if i < len(tc.errs) {
						err = tc.errs[i]
					}
					return []byte(tc.replies[i]), err
				case searchEndpoint("o"), pullEndpoint("o"):
					return []byte(searchPage(forgeIssue)), nil
				default:
					return nil, errors.New("unexpected read: " + endpoint)
				}
			}
			args := []string{"--org", "o", "--today", "2026-09-01"}
			if tc.parked {
				args = append(args, "--parked-digest")
			}
			var out, stderr bytes.Buffer
			code := run(args, strings.NewReader(""), &out, &stderr)
			got := out.String() + stderr.String()
			if code != tc.code || !strings.Contains(got, tc.want) {
				t.Fatalf("code=%d, want %d containing %q; out:\n%s", code, tc.code, tc.want, got)
			}
			if code == 2 && strings.Contains(got, "CHECKED") {
				t.Fatalf("UNKNOWN still printed a digest; out:\n%s", got)
			}
			if reads != 2 {
				t.Fatalf("zero search read %d times, want 2", reads)
			}
		})
	}
}
