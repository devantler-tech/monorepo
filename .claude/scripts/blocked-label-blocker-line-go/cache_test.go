package main

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// pageForge answers forgeFetch from a table of pages and records, per target,
// the validator each request offered.
type pageForge struct {
	pages   map[string]forgePage
	offered map[string][]string
}

func servePages(t *testing.T, pages map[string]forgePage) *pageForge {
	t.Helper()
	forge := &pageForge{pages: pages, offered: map[string][]string{}}
	original := forgeFetch
	t.Cleanup(func() { forgeFetch = original })
	forgeFetch = func(_ context.Context, target, validator string) (forgePage, error) {
		forge.offered[target] = append(forge.offered[target], validator)
		page, ok := forge.pages[target]
		if !ok {
			return forgePage{}, errors.New("no such page")
		}
		if validator != "" && validator == page.validator {
			return forgePage{status: 304}, nil
		}
		return page, nil
	}
	return forge
}

func keepPagesIn(t *testing.T) string {
	t.Helper()
	// A park test earlier in the run leaves reuse off.
	original := reuseKeptPages
	t.Cleanup(func() { reuseKeptPages = original })
	reuseKeptPages = true
	dir := filepath.Join(t.TempDir(), "kept")
	t.Setenv("BLOCKER_LINE_CACHE_DIR", dir)
	return dir
}

func mustRead(t *testing.T, endpoint string, reuse bool) string {
	t.Helper()
	raw, err := conditionalRead(endpoint, reuse)
	if err != nil {
		t.Fatalf("read of %s failed: %v", endpoint, err)
	}
	return string(raw)
}

func TestConditionalReadReusesAPageTheForgeConfirms(t *testing.T) {
	keepPagesIn(t)
	forge := servePages(t, map[string]forgePage{
		"repos/o/r/issues/1": {status: 200, validator: `W/"a1"`, body: []byte(`{"number":1}`)},
	})
	first := mustRead(t, "repos/o/r/issues/1", true)
	second := mustRead(t, "repos/o/r/issues/1", true)
	if first != `{"number":1}` || second != first {
		t.Fatalf("reads differ: %q then %q", first, second)
	}
	offered := forge.offered["repos/o/r/issues/1"]
	if len(offered) != 2 || offered[0] != "" || offered[1] != `W/"a1"` {
		t.Fatalf("the second read must offer the kept validator, offered %q", offered)
	}
}

func TestConditionalReadTakesTheNewPageWhenItChanged(t *testing.T) {
	keepPagesIn(t)
	forge := servePages(t, map[string]forgePage{
		"repos/o/r/issues/1": {status: 200, validator: `W/"a1"`, body: []byte(`{"comments":1}`)},
	})
	mustRead(t, "repos/o/r/issues/1", true)
	forge.pages["repos/o/r/issues/1"] = forgePage{status: 200, validator: `W/"a2"`, body: []byte(`{"comments":2}`)}
	if got := mustRead(t, "repos/o/r/issues/1", true); got != `{"comments":2}` {
		t.Fatalf("a changed page must replace the kept one, got %q", got)
	}
	// The replacement is what the next run offers.
	mustRead(t, "repos/o/r/issues/1", true)
	if offered := forge.offered["repos/o/r/issues/1"]; offered[2] != `W/"a2"` {
		t.Fatalf("the third read must offer the new validator, offered %q", offered)
	}
}

func TestConditionalReadFollowsEveryPage(t *testing.T) {
	keepPagesIn(t)
	second := forgeHost + "repositories/1/issues/1/comments?per_page=100&page=2"
	forge := servePages(t, map[string]forgePage{
		"repos/o/r/issues/1/comments?per_page=100": {status: 200, validator: `W/"p1"`, next: second, body: []byte(`[{"id":1}]`)},
		second: {status: 200, validator: `W/"p2"`, body: []byte(`[{"id":2}]`)},
	})
	for run := 0; run < 2; run++ {
		if got := mustRead(t, "repos/o/r/issues/1/comments?per_page=100", true); got != `[{"id":1}][{"id":2}]` {
			t.Fatalf("run %d returned %q", run, got)
		}
	}
	if offered := forge.offered[second]; len(offered) != 2 || offered[1] != `W/"p2"` {
		t.Fatalf("the kept continuation must be followed conditionally, offered %q", offered)
	}
}

// A kept first page cannot show that a second page has appeared since: its
// body is unchanged, so the forge confirms it. Reading anew must find it.
func TestReadingAnewFindsAPageAKeptAnswerHides(t *testing.T) {
	keepPagesIn(t)
	first := "repos/o/r/issues/1/comments?per_page=100"
	second := forgeHost + "repositories/1/issues/1/comments?per_page=100&page=2"
	forge := servePages(t, map[string]forgePage{
		first: {status: 200, validator: `W/"p1"`, body: []byte(`[{"id":1}]`)},
	})
	mustRead(t, first, true)
	forge.pages[first] = forgePage{status: 200, validator: `W/"p1"`, next: second, body: []byte(`[{"id":1}]`)}
	forge.pages[second] = forgePage{status: 200, validator: `W/"p2"`, body: []byte(`[{"id":2}]`)}
	if got := mustRead(t, first, true); got != `[{"id":1}]` {
		t.Fatalf("the control must show the hidden page: a reused read returned %q", got)
	}
	if got := mustRead(t, first, false); got != `[{"id":1}][{"id":2}]` {
		t.Fatalf("reading anew returned %q", got)
	}
	if offered := forge.offered[first]; offered[len(offered)-1] != "" {
		t.Fatalf("reading anew must offer no validator, offered %q", offered)
	}
	// Reading anew also repairs the kept copy for the next run.
	if got := mustRead(t, first, true); got != `[{"id":1}][{"id":2}]` {
		t.Fatalf("the next reused read returned %q", got)
	}
}

func TestForgeCommentsRetriesAnewWhenAKeptThreadIsShort(t *testing.T) {
	var reused, anew int
	original, originalAnew := forgeRead, forgeReadAnew
	t.Cleanup(func() { forgeRead, forgeReadAnew = original, originalAnew })
	forgeRead = func(endpoint string) ([]byte, error) {
		reused++
		if strings.HasSuffix(endpoint, "/comments?per_page=100") {
			return []byte(`[{"id":1}]`), nil
		}
		return []byte(`{"number":900,"comments":2}`), nil
	}
	forgeReadAnew = func(endpoint string) ([]byte, error) {
		anew++
		if strings.HasSuffix(endpoint, "/comments?per_page=100") {
			return []byte(`[{"id":1}][{"id":2}]`), nil
		}
		return []byte(`{"number":900,"comments":2}`), nil
	}
	thread, err := forgeComments("o", issue{Repo: "platform", Number: 900})
	if err != nil || len(thread) != 2 {
		t.Fatalf("expected the full thread from the second try, got %d comment(s), err %v", len(thread), err)
	}
	if reused != 2 || anew != 2 {
		t.Fatalf("expected one reused try and one anew, got %d reused and %d anew reads", reused, anew)
	}
}

func TestConditionalReadIgnoresAKeptPageItCannotTrust(t *testing.T) {
	page := keptPage{Target: "repos/o/r/issues/1", Validator: `W/"a1"`, Body: []byte(`{"number":666}`)}
	cases := map[string]func(t *testing.T, dir, path string){
		"readable by others": func(t *testing.T, dir, path string) {
			if err := os.Chmod(path, 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"a symbolic link": func(t *testing.T, dir, path string) {
			elsewhere := filepath.Join(dir, "elsewhere")
			if err := os.Rename(path, elsewhere); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(elsewhere, path); err != nil {
				t.Fatal(err)
			}
		},
		"kept for another target": func(t *testing.T, dir, path string) {
			other := keptPagePath(dir, "repos/o/r/issues/2")
			if err := os.Rename(other, path); err != nil {
				t.Fatal(err)
			}
		},
		"a validator that would end its header": func(t *testing.T, dir, path string) {
			raw := `{"target":"repos/o/r/issues/1","validator":"W/\"a1\"\r\nX-Evil: 1","next":"","body":"e30="}`
			if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"not a kept page": func(t *testing.T, dir, path string) {
			if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, spoil := range cases {
		t.Run(name, func(t *testing.T) {
			dir := keepPagesIn(t)
			forge := servePages(t, map[string]forgePage{
				"repos/o/r/issues/1": {status: 200, validator: `W/"a1"`, body: []byte(`{"number":1}`)},
			})
			storeKeptPage(dir, page)
			storeKeptPage(dir, keptPage{Target: "repos/o/r/issues/2", Validator: `W/"a1"`, Body: []byte(`{"number":666}`)})
			if _, ok := loadKeptPage(dir, page.Target); !ok {
				t.Fatal("the control must load before it is spoiled")
			}
			spoil(t, dir, keptPagePath(dir, page.Target))
			if got := mustRead(t, page.Target, true); got != `{"number":1}` {
				t.Fatalf("an untrusted kept page was served: %q", got)
			}
			if offered := forge.offered[page.Target]; len(offered) != 1 || offered[0] != "" {
				t.Fatalf("an untrusted kept page must not be offered, offered %q", offered)
			}
		})
	}
}

func TestConditionalReadFailsRatherThanAnswerShort(t *testing.T) {
	t.Run("a continuation that leaves the forge", func(t *testing.T) {
		keepPagesIn(t)
		servePages(t, map[string]forgePage{
			"repos/o/r/issues/1/comments": {status: 200, validator: `W/"p1"`, next: "https://example.invalid/page2", body: []byte(`[]`)},
		})
		if _, err := conditionalRead("repos/o/r/issues/1/comments", true); err == nil || !strings.Contains(err.Error(), "leaves the forge") {
			t.Fatalf("expected the continuation to be refused, got %v", err)
		}
	})
	t.Run("not modified with nothing kept", func(t *testing.T) {
		keepPagesIn(t)
		original := forgeFetch
		t.Cleanup(func() { forgeFetch = original })
		forgeFetch = func(context.Context, string, string) (forgePage, error) { return forgePage{status: 304}, nil }
		if _, err := conditionalRead("repos/o/r/issues/1", true); err == nil || !strings.Contains(err.Error(), "304") {
			t.Fatalf("expected an error, got %v", err)
		}
	})
	t.Run("a refused request", func(t *testing.T) {
		keepPagesIn(t)
		servePages(t, map[string]forgePage{
			"repos/o/r/issues/1": {status: 403, body: []byte(`{"message":"rate limit"}`)},
		})
		if _, err := conditionalRead("repos/o/r/issues/1", true); err == nil || !strings.Contains(err.Error(), "403") {
			t.Fatalf("expected an error, got %v", err)
		}
	})
	t.Run("a failed request", func(t *testing.T) {
		keepPagesIn(t)
		servePages(t, map[string]forgePage{})
		if _, err := conditionalRead("repos/o/r/issues/1", true); err == nil {
			t.Fatal("expected an error")
		}
	})
	t.Run("a read without end", func(t *testing.T) {
		keepPagesIn(t)
		original := forgeFetch
		t.Cleanup(func() { forgeFetch = original })
		forgeFetch = func(_ context.Context, target, _ string) (forgePage, error) {
			return forgePage{status: 200, next: forgeHost + "loop", body: []byte(`[]`)}, nil
		}
		if _, err := conditionalRead("repos/o/r/issues/1/comments", true); err == nil || !strings.Contains(err.Error(), "page bound") {
			t.Fatalf("expected the page bound, got %v", err)
		}
	})
}

func TestConditionalReadKeepsNothingWhenSwitchedOff(t *testing.T) {
	t.Setenv("BLOCKER_LINE_CACHE_DIR", "off")
	forge := servePages(t, map[string]forgePage{
		"repos/o/r/issues/1": {status: 200, validator: `W/"a1"`, body: []byte(`{"number":1}`)},
	})
	mustRead(t, "repos/o/r/issues/1", true)
	mustRead(t, "repos/o/r/issues/1", true)
	if offered := forge.offered["repos/o/r/issues/1"]; len(offered) != 2 || offered[1] != "" {
		t.Fatalf("no validator may be offered when nothing is kept, offered %q", offered)
	}
}

func TestParsePage(t *testing.T) {
	raw := "HTTP/2.0 200 OK\r\nEtag: W/\"abc\"\r\nLink: <https://api.github.com/x?page=2>; rel=\"next\", <https://api.github.com/x?page=9>; rel=\"last\"\r\n\r\n[1]\n\n[2]"
	page, ok := parsePage([]byte(raw))
	if !ok || page.status != 200 || page.validator != `W/"abc"` || page.next != "https://api.github.com/x?page=2" || string(page.body) != "[1]\n\n[2]" {
		t.Fatalf("unexpected page %+v (ok %v)", page, ok)
	}
	notModified, ok := parsePage([]byte("HTTP/2.0 304 Not Modified\r\nEtag: \"abc\"\r\n\r\n"))
	if !ok || notModified.status != 304 || len(notModified.body) != 0 {
		t.Fatalf("unexpected page %+v (ok %v)", notModified, ok)
	}
	last, ok := parsePage([]byte("HTTP/2.0 200 OK\r\nLink: <https://api.github.com/x?page=1>; rel=\"prev\"\r\n\r\n[]"))
	if !ok || last.next != "" {
		t.Fatalf("a last page must carry no continuation, got %+v (ok %v)", last, ok)
	}
	for _, unreadable := range []string{"", "gh: HTTP 500", "HTTP/2.0 OK\r\n\r\n{}"} {
		if _, ok := parsePage([]byte(unreadable)); ok {
			t.Fatalf("%q must not read as an answer", unreadable)
		}
	}
}

func TestPruneKeptPagesDropsOnlyOldPages(t *testing.T) {
	dir := keepPagesIn(t)
	storeKeptPage(dir, keptPage{Target: "old", Validator: `"a"`, Body: []byte(`{}`)})
	storeKeptPage(dir, keptPage{Target: "new", Validator: `"a"`, Body: []byte(`{}`)})
	unrelated := filepath.Join(dir, "package.json")
	if err := os.WriteFile(unrelated, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	long := now.Add(-keptPageAge - time.Hour)
	for _, path := range []string{keptPagePath(dir, "old"), unrelated} {
		if err := os.Chtimes(path, long, long); err != nil {
			t.Fatal(err)
		}
	}
	pruneKeptPages(dir, now)
	if _, ok := loadKeptPage(dir, "old"); ok {
		t.Fatal("an old page must be dropped")
	}
	if _, ok := loadKeptPage(dir, "new"); !ok {
		t.Fatal("a recent page must stay")
	}
	if _, err := os.Stat(unrelated); err != nil {
		t.Fatal("a file that is not a kept page must stay")
	}
}

func TestParsePageReadsOtherAnswerShapes(t *testing.T) {
	plain, ok := parsePage([]byte("HTTP/1.1 200 OK\nETag: \"abc\"\n\n{\"a\":1}"))
	if !ok || plain.status != 200 || plain.validator != `"abc"` || string(plain.body) != `{"a":1}` {
		t.Fatalf("unexpected page %+v (ok %v)", plain, ok)
	}
	// A second Link line that names no continuation must not erase the first.
	two, ok := parsePage([]byte("HTTP/2.0 200 OK\r\nLink: <https://api.github.com/x?page=2>; rel=\"next\"\r\nLink: <https://api.github.com/x?page=1>; rel=\"first\"\r\n\r\n[]"))
	if !ok || two.next != "https://api.github.com/x?page=2" {
		t.Fatalf("the continuation was lost: %+v (ok %v)", two, ok)
	}
}

func TestConditionalReadKeepsNothingInADirectoryOthersCanEnter(t *testing.T) {
	dir := keepPagesIn(t)
	forge := servePages(t, map[string]forgePage{
		"repos/o/r/issues/1": {status: 200, validator: `W/"a1"`, body: []byte(`{"number":1}`)},
	})
	mustRead(t, "repos/o/r/issues/1", true)
	if _, ok := loadKeptPage(dir, "repos/o/r/issues/1"); !ok {
		t.Fatal("the control must keep the page in a private directory")
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustRead(t, "repos/o/r/issues/1", true)
	if offered := forge.offered["repos/o/r/issues/1"]; len(offered) != 2 || offered[1] != "" {
		t.Fatalf("a page from a directory others can enter must not be offered, offered %q", offered)
	}
	if err := os.Remove(keptPagePath(dir, "repos/o/r/issues/1")); err != nil {
		t.Fatal(err)
	}
	mustRead(t, "repos/o/r/issues/1", true)
	if _, err := os.Stat(keptPagePath(dir, "repos/o/r/issues/1")); err == nil {
		t.Fatal("no page may be kept in a directory others can enter")
	}
}

func TestParkNeverReusesAKeptPage(t *testing.T) {
	keepPagesIn(t)
	original := reuseKeptPages
	t.Cleanup(func() { reuseKeptPages = original })
	forge := servePages(t, map[string]forgePage{
		"repos/o/r/issues/1": {status: 200, validator: `W/"a1"`, body: []byte(`{"number":1}`)},
	})
	mustRead(t, "repos/o/r/issues/1", true)
	// Any park invocation switches reuse off before it reads; a usage error is enough.
	if rc := parkRun([]string{"--no-such-flag"}, io.Discard, io.Discard); rc != 2 {
		t.Fatalf("expected the usage error, got %d", rc)
	}
	mustRead(t, "repos/o/r/issues/1", true)
	if offered := forge.offered["repos/o/r/issues/1"]; len(offered) != 2 || offered[1] != "" {
		t.Fatalf("park must read anew, offered %q", offered)
	}
}

func TestAPageInUseIsNotPruned(t *testing.T) {
	dir := keepPagesIn(t)
	servePages(t, map[string]forgePage{
		"repos/o/r/issues/1": {status: 200, validator: `W/"a1"`, body: []byte(`{"number":1}`)},
	})
	mustRead(t, "repos/o/r/issues/1", true)
	long := time.Now().Add(-keptPageAge - time.Hour)
	if err := os.Chtimes(keptPagePath(dir, "repos/o/r/issues/1"), long, long); err != nil {
		t.Fatal(err)
	}
	mustRead(t, "repos/o/r/issues/1", true)
	pruneKeptPages(dir, time.Now())
	if _, ok := loadKeptPage(dir, "repos/o/r/issues/1"); !ok {
		t.Fatal("a page the forge has just confirmed must stay")
	}
}
