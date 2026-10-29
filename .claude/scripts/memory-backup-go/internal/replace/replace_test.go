package replace

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T) (string, string, string, []byte, []byte) {
	t.Helper()
	dir := t.TempDir()
	source, candidate := filepath.Join(dir, "source.md"), filepath.Join(dir, "candidate.md")
	old, next := []byte("# Notes\noriginal\n"), []byte("# Notes\nreplacement\n")
	for path, data := range map[string][]byte{source: old, candidate: next} {
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return source, candidate, fmt.Sprintf("%x", sha256.Sum256(old)), old, next
}

func sameBytes(t *testing.T, path string, want []byte) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("bytes at %s: %q, error %v", path, got, err)
	}
}

func TestCommitNativeExchangeRetainsDisplacedInode(t *testing.T) {
	source, candidate, digest, old, next := fixture(t)
	before, err := os.Stat(source)
	if err != nil {
		t.Fatal(err)
	}
	displaced, err := Commit(source, candidate, digest)
	if err != nil {
		t.Fatal(err)
	}
	sameBytes(t, source, next)
	sameBytes(t, displaced, old)
	sameBytes(t, candidate, next)
	after, err := os.Stat(displaced)
	if err != nil || !os.SameFile(before, after) {
		t.Fatal("actual displaced inode was not retained")
	}
}

func TestCommitRetainsLateAppendAndAtomicReplacement(t *testing.T) {
	for _, kind := range []string{"append", "replacement", "identical replacement"} {
		t.Run(kind, func(t *testing.T) {
			source, candidate, digest, old, next := fixture(t)
			late := append(bytes.Clone(old), []byte("late write\n")...)
			if kind == "identical replacement" {
				late = old
			}
			calls := 0
			displaced, err := commitWith(source, candidate, digest, func(prepared, target string) error {
				calls++
				if kind == "append" {
					f, e := os.OpenFile(source, os.O_APPEND|os.O_WRONLY, 0)
					if e != nil {
						return e
					}
					_, e = f.Write([]byte("late write\n"))
					closeErr := f.Close()
					if e != nil {
						return e
					}
					if closeErr != nil {
						return closeErr
					}
				} else {
					path := source + ".new"
					if e := os.WriteFile(path, late, 0600); e != nil {
						return e
					}
					if e := os.Rename(path, source); e != nil {
						return e
					}
				}
				return exchangeFiles(prepared, target)
			})
			if err == nil || !strings.Contains(err.Error(), "displaced source changed") || calls != 1 {
				t.Fatalf("late writer was reported complete: path=%q calls=%d err=%v", displaced, calls, err)
			}
			sameBytes(t, source, next)
			sameBytes(t, displaced, late)
		})
	}
}

func TestCommitRetainsWritesThroughOldOpenDescriptorAfterSuccess(t *testing.T) {
	source, candidate, digest, old, next := fixture(t)
	f, err := os.OpenFile(source, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	displaced, err := Commit(source, candidate, digest)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write([]byte("old descriptor write\n")); err != nil {
		t.Fatal(err)
	}
	sameBytes(t, source, next)
	sameBytes(t, displaced, append(old, []byte("old descriptor write\n")...))
}

func TestCommitDoesNotRollbackOrRetryAfterExchange(t *testing.T) {
	for _, mode := range []string{"lost response", "later live write"} {
		t.Run(mode, func(t *testing.T) {
			source, candidate, digest, old, next := fixture(t)
			calls := 0
			displaced, err := commitWith(source, candidate, digest, func(prepared, target string) error {
				calls++
				if e := exchangeFiles(prepared, target); e != nil {
					return e
				}
				if mode == "lost response" {
					return errors.New("lost exchange response")
				}
				return os.WriteFile(target, []byte("later live write\n"), 0600)
			})
			if err == nil || calls != 1 {
				t.Fatalf("uncertain commit was accepted or retried: calls=%d err=%v", calls, err)
			}
			if mode == "later live write" {
				next = []byte("later live write\n")
			}
			sameBytes(t, source, next)
			sameBytes(t, displaced, old)
		})
	}
}

func TestCommitExchangeFailureDoesNotFallBackToRename(t *testing.T) {
	source, candidate, digest, old, _ := fixture(t)
	calls := 0
	displaced, err := commitWith(source, candidate, digest, func(string, string) error { calls++; return os.ErrPermission })
	if !errors.Is(err, os.ErrPermission) || calls != 1 || displaced != "" || !strings.Contains(err.Error(), "exchange refused; no swap occurred") {
		t.Fatalf("exchange failure was hidden: %v", err)
	}
	sameBytes(t, source, old)
	entries, readErr := os.ReadDir(filepath.Dir(source))
	if readErr != nil || len(entries) != 2 {
		t.Fatal("proven exchange refusal retained an incorrectly labeled displaced file")
	}
}

func TestCommitStaleSnapshotRefusesBeforeArtifacts(t *testing.T) {
	source, candidate, _, old, _ := fixture(t)
	displaced, err := Commit(source, candidate, strings.Repeat("0", 64))
	if err == nil || !strings.Contains(err.Error(), "stale snapshot") || displaced != "" {
		t.Fatalf("stale snapshot accepted: %q %v", displaced, err)
	}
	sameBytes(t, source, old)
	entries, err := os.ReadDir(filepath.Dir(source))
	if err != nil || len(entries) != 2 {
		t.Fatal("stale refusal wrote recovery artifacts")
	}
}
