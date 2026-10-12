package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// transportFixture models a full first page, validator changes, and later-page failures.
func transportFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	stub := `#!/usr/bin/env bash
set -euo pipefail
endpoint=""; validator=""
for argument in "$@"; do
 case "$argument" in
  repos/*) endpoint=$argument ;;
  "If-None-Match: "*) validator=${argument#If-None-Match: } ;;
 esac
done
printf '%s\n' "$endpoint" >> "$TRANSPORT_CALLS"
tag='"page-1"'; body=$(cat "$TRANSPORT_FULL")
if [[ "$endpoint" == *"page=2"* ]]; then
 tag='"page-2"'; body='[]'
 if [ "$TRANSPORT_MODE" = growing ]; then tag='"page-2-new"'; body='[{"new":true}]'; fi
fi
if [ "$TRANSPORT_MODE" = mismatch ]; then
 printf 'HTTP/2.0 304 Not Modified\r\nETag: "different"\r\n\r\n'
 exit 1
fi
if [ "$TRANSPORT_MODE" = unsolicited ]; then
 printf 'HTTP/2.0 304 Not Modified\r\n\r\n'
 exit 1
fi
if [ "$TRANSPORT_MODE" = failure ] && [[ "$endpoint" == *"page=2"* ]]; then
 printf 'HTTP/2.0 304 Not Modified\r\n\r\n'
 exit 17
fi
if [ "${validator#W/}" = "$tag" ]; then
 printf 'HTTP/2.0 304 Not Modified\r\nETag: %s\r\n\r\n' "$tag"
 exit 1
fi
if [ "$TRANSPORT_MODE" = weak ]; then tag="W/$tag"; fi
printf 'HTTP/2.0 200 OK\r\nETag: %s\r\n\r\n%s' "$tag" "$body"
`
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	full := "[" + strings.TrimSuffix(strings.Repeat("{\"n\":1},", 100), ",") + "]"
	if err := os.WriteFile(filepath.Join(dir, "full"), []byte(full), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TRANSPORT_CALLS", filepath.Join(dir, "calls"))
	t.Setenv("TRANSPORT_FULL", filepath.Join(dir, "full"))
	t.Setenv("TRANSPORT_MODE", "initial")
	return filepath.Join(dir, "cache")
}

// TestRevalidationFindsNewPageAfterFullCachedPage prevents stale pagination from hiding new records.
func TestRevalidationFindsNewPageAfterFullCachedPage(t *testing.T) {
	dir := transportFixture(t)
	endpoint := "repos/owner/repo/issues/1/comments"
	first, err := read(context.Background(), endpoint, dir, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(first, []byte("[]\n")) {
		t.Fatalf("initial: %s", first)
	}
	t.Setenv("TRANSPORT_MODE", "growing")
	next, err := read(context.Background(), endpoint, dir, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(next, []byte("[{\"new\":true}]\n")) {
		t.Fatalf("new last page was lost: %s", next)
	}
	calls, err := os.ReadFile(os.Getenv("TRANSPORT_CALLS"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(calls), "page=2"); got != 2 {
		t.Fatalf("last page read %d times", got)
	}
}

// TestLaterPageFailureCannotReturnPartialEvidence rejects partial success after a producer failure.
func TestLaterPageFailureCannotReturnPartialEvidence(t *testing.T) {
	dir := transportFixture(t)
	endpoint := "repos/owner/repo/issues/1/comments"
	if _, err := read(context.Background(), endpoint, dir, false, false); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TRANSPORT_MODE", "failure")
	body, err := read(context.Background(), endpoint, dir, false, false)
	if err == nil || len(body) != 0 {
		t.Fatalf("failed producer returned evidence: %q %v", body, err)
	}
}

// TestUnsolicitedNotModifiedCannotUseLocalData requires a validator bound to a retained page.
func TestUnsolicitedNotModifiedCannotUseLocalData(t *testing.T) {
	dir := transportFixture(t)
	t.Setenv("TRANSPORT_MODE", "unsolicited")
	if body, err := read(context.Background(), "repos/owner/repo/issues/1/comments", dir, true, false); err == nil || len(body) != 0 {
		t.Fatalf("unbound 304 accepted: %q %v", body, err)
	}
}

// TestInvalidEndpointsNeverReachGitHub prevents unsupported scope from reaching the transport.
func TestInvalidEndpointsNeverReachGitHub(t *testing.T) {
	dir := transportFixture(t)
	for _, endpoint := range []string{
		"https://example.com/repos/owner/repo/issues/1/comments",
		"repos/owner/repo/issues/1/comments#fragment",
		"repos/owner/repo/issues/1/comments?since=a&since=b",
		"repos/owner/repo/issues/1/comments?redirect=evil",
		"repos/owner/repo/issues/1/comments?page=1",
		"repos/owner/repo/issues/1/comments?per_page=%zz",
	} {
		if _, err := read(context.Background(), endpoint, dir, false, false); err == nil {
			t.Errorf("accepted %s", endpoint)
		}
	}
	if _, err := os.Stat(os.Getenv("TRANSPORT_CALLS")); !os.IsNotExist(err) {
		t.Fatalf("invalid scope reached gh: %v", err)
	}
}

// TestUnsafeRetainedPagesAreNeverReused rejects corrupt, expired, shared, or symlinked records.
func TestUnsafeRetainedPagesAreNeverReused(t *testing.T) {
	target := "repos/owner/repo/issues/1/comments?page=1&per_page=100"
	for _, kind := range []string{"corrupt", "wrong-target", "public-file", "expired", "symlink", "public-directory"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.Chmod(dir, 0700); err != nil {
				t.Fatal(err)
			}
			store(dir, target, response{etag: "\"ok\"", body: []byte("[]")})
			name := fileName(dir, target)
			switch kind {
			case "corrupt":
				if err := os.WriteFile(name, []byte("{}"), 0600); err != nil {
					t.Fatal(err)
				}
			case "wrong-target":
				raw, err := json.Marshal(retained{Version: cacheVersion, Target: target + "x", ETag: "\"ok\"", Body: []byte("[]"), SHA256: digest([]byte("[]"))})
				if err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(name, raw, 0600); err != nil {
					t.Fatal(err)
				}
			case "public-file":
				if err := os.Chmod(name, 0644); err != nil {
					t.Fatal(err)
				}
			case "expired":
				old := time.Now().Add(-keepAge - time.Hour)
				if err := os.Chtimes(name, old, old); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				victim := filepath.Join(dir, "unrelated")
				if err := os.Rename(name, victim); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(victim, name); err != nil {
					t.Fatal(err)
				}
			case "public-directory":
				if err := os.Chmod(dir, 0755); err != nil {
					t.Fatal(err)
				}
			}
			if _, ok := load(dir, target); ok {
				t.Fatal("unsafe retained page accepted")
			}
		})
	}
}

// TestPrunePreservesUnrelatedFiles limits eviction to verifiable transport-owned records.
func TestPrunePreservesUnrelatedFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	unrelated := filepath.Join(dir, strings.Repeat("a", 64)+".json")
	if err := os.WriteFile(unrelated, []byte("private unrelated data"), 0600); err != nil {
		t.Fatal(err)
	}
	target := "repos/owner/repo/issues/1/comments?page=1&per_page=100"
	store(dir, target, response{etag: "\"ok\"", body: []byte("[]")})
	expired := fileName(dir, target)
	old := time.Now().Add(-keepAge - time.Hour)
	for _, name := range []string{unrelated, expired} {
		if err := os.Chtimes(name, old, old); err != nil {
			t.Fatal(err)
		}
	}
	prune(dir)
	got, err := os.ReadFile(unrelated)
	if err != nil || string(got) != "private unrelated data" {
		t.Fatalf("unrelated file changed: %q %v", got, err)
	}
	if _, err = os.Stat(expired); !os.IsNotExist(err) {
		t.Fatalf("expired owned page retained: %v", err)
	}
}

// TestMalformedSourceAnswersFailClosed rejects malformed headers and incomplete list bodies.
func TestMalformedSourceAnswersFailClosed(t *testing.T) {
	for _, raw := range []string{"[]", "HTTP/2.0 nope\r\n\r\n[]", "HTTP/2.0 200 OK\r\nETag: \"a\"\r\nETag: \"b\"\r\n\r\n[]", "HTTP/2.0 200 OK\r\nbad-header\r\n\r\n[]"} {
		if _, err := parse([]byte(raw)); err == nil {
			t.Errorf("accepted malformed headers %q", raw)
		}
	}
	for _, body := range [][]byte{[]byte("null"), []byte("{}"), []byte("[invalid]"), {0xff}, []byte("[] []")} {
		if _, err := validBody(body); err == nil {
			t.Errorf("accepted malformed body %q", body)
		}
	}
}

// TestWeakETagRevalidationAcceptsEquivalentStrongValidator covers GitHub's live weak/strong equivalence.
func TestWeakETagRevalidationAcceptsEquivalentStrongValidator(t *testing.T) {
	dir := transportFixture(t)
	t.Setenv("TRANSPORT_MODE", "weak")
	endpoint := "repos/owner/repo/issues/1/comments"
	first, err := read(context.Background(), endpoint, dir, true, false)
	if err != nil {
		t.Fatal(err)
	}
	second, err := read(context.Background(), endpoint, dir, true, false)
	if err != nil || !bytes.Equal(first, second) {
		t.Fatalf("equivalent weak validator rejected: %v", err)
	}
}

// TestDotRepositoryAndMismatchedValidator keeps .github supported while rejecting a different ETag.
func TestDotRepositoryAndMismatchedValidator(t *testing.T) {
	dir := transportFixture(t)
	endpoint := "repos/devantler-tech/.github/issues/1/comments"
	if _, err := read(context.Background(), endpoint, dir, true, false); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TRANSPORT_MODE", "mismatch")
	if body, err := read(context.Background(), endpoint, dir, true, false); err == nil || !strings.Contains(err.Error(), "unbound not-modified answer") || len(body) != 0 {
		t.Fatalf("different validator accepted: %q %v", body, err)
	}
}
