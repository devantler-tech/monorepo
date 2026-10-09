// Conditional forge reads. Every sweep re-reads the same parked pull requests,
// and almost none of them changed since the last one. The forge answers a
// request that carries the validator of an earlier answer with "not modified"
// and does not charge it to the hourly request budget (#4055), so each page is
// kept beside its validator and offered back. Nothing is ever served on age:
// a kept page is used only when the forge itself confirms it in this run.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// forgeHost is the only place a continuation link may point.
const forgeHost = "https://api.github.com/"

// maxPages bounds one read; a longer one is an error, never a short answer.
const maxPages = 50

// keptPageAge is how long an unused page stays on disk.
const keptPageAge = 7 * 24 * time.Hour

// validatorRE admits a forge entity tag and nothing that could end the header
// it is sent in.
var validatorRE = regexp.MustCompile(`^(W/)?"[A-Za-z0-9+/=_.:-]{1,200}"$`)

// forgePage is one answer of the forge: its status, the validator and the
// continuation link it carried, and its body.
type forgePage struct {
	status    int
	validator string
	next      string
	body      []byte
}

// keptPage is a page as it is stored between runs.
type keptPage struct {
	Target    string `json:"target"`
	Validator string `json:"validator"`
	Next      string `json:"next"`
	Body      []byte `json:"body"`
}

// forgeFetch asks the forge for one page before ctx ends, offering validator
// when it is set; tests replace it.
var forgeFetch = func(ctx context.Context, target, validator string) (forgePage, error) {
	args := []string{"api", "--include"}
	if validator != "" {
		args = append(args, "-H", "If-None-Match: "+validator)
	}
	raw, err := exec.CommandContext(ctx, "gh", append(args, target)...).Output()
	page, ok := parsePage(raw)
	if !ok {
		if err == nil {
			err = errors.New("unreadable forge answer")
		}
		return forgePage{}, err
	}
	// gh exits non-zero on "not modified", which is the one answer a failed
	// command may still carry: any other one may have been cut short.
	if err != nil && page.status != 304 {
		return forgePage{}, err
	}
	return page, nil
}

// parsePage splits what `gh api --include` printed into the answer's head and
// body. It reports false when no status line can be read.
func parsePage(raw []byte) (forgePage, bool) {
	head, body, found := bytes.Cut(raw, []byte("\r\n\r\n"))
	if !found {
		if head, body, found = bytes.Cut(raw, []byte("\n\n")); !found {
			head, body = raw, nil
		}
	}
	lines := strings.Split(strings.ReplaceAll(string(head), "\r\n", "\n"), "\n")
	status := strings.Fields(lines[0])
	if len(status) < 2 || !strings.HasPrefix(status[0], "HTTP/") {
		return forgePage{}, false
	}
	code, err := strconv.Atoi(status[1])
	if err != nil {
		return forgePage{}, false
	}
	page := forgePage{status: code, body: body}
	for _, line := range lines[1:] {
		name, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		value = strings.TrimSpace(value)
		switch strings.ToLower(strings.TrimSpace(name)) {
		case "etag":
			page.validator = value
		case "link":
			// A second Link line must not erase the continuation of the first.
			if next := nextLink(value); next != "" {
				page.next = next
			}
		}
	}
	return page, true
}

// nextLink returns the rel="next" target of a Link header, or "".
func nextLink(header string) string {
	for _, part := range strings.Split(header, ",") {
		target, params, found := strings.Cut(strings.TrimSpace(part), ";")
		if !found || !strings.Contains(params, `rel="next"`) {
			continue
		}
		target = strings.TrimSpace(target)
		if strings.HasPrefix(target, "<") && strings.HasSuffix(target, ">") {
			return target[1 : len(target)-1]
		}
	}
	return ""
}

// reuseKeptPages is false where every read must be the forge's own answer of
// this moment: the park subcommand reads back what it has just written.
var reuseKeptPages = true

// conditionalRead returns every page of endpoint, concatenated as
// `gh api --paginate` prints them, within one deadline for the whole read.
// With reuse set, each page the forge confirms unchanged comes from the kept
// copy; without it every page is read anew.
//
// A confirmed page says nothing about a page that has appeared after it: the
// forge confirms a full first page of a list that has since grown onto a
// second. A caller reading a list must therefore hold the result against a
// count it read itself, and read anew when the two disagree (forgeComments).
func conditionalRead(endpoint string, reuse bool) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	dir := keptPageDir()
	var out []byte
	target := endpoint
	for pages := 0; target != ""; pages++ {
		if pages == maxPages {
			return nil, errors.New("forge read exceeds the page bound")
		}
		var kept keptPage
		have := false
		if reuse && reuseKeptPages && dir != "" {
			kept, have = loadKeptPage(dir, target)
		}
		validator := ""
		if have {
			validator = kept.Validator
		}
		page, err := forgeFetch(ctx, target, validator)
		if err != nil {
			return nil, err
		}
		if page.status == 304 && have {
			page = forgePage{status: 200, validator: kept.Validator, next: kept.Next, body: kept.Body}
			// A page still in use is not an old page.
			now := time.Now()
			os.Chtimes(keptPagePath(dir, target), now, now)
		} else if page.status != 200 {
			return nil, errors.New("forge answered " + strconv.Itoa(page.status))
		} else if dir != "" {
			storeKeptPage(dir, keptPage{Target: target, Validator: page.validator, Next: page.next, Body: page.body})
		}
		if page.next != "" && !strings.HasPrefix(page.next, forgeHost) {
			return nil, errors.New("forge continuation leaves the forge")
		}
		out = append(out, page.body...)
		target = page.next
	}
	return out, nil
}

// keptPageDir is the private per-user store, or "" when pages are not kept:
// BLOCKER_LINE_CACHE_DIR names it, and "off" there disables it. Pages hold
// what the forge returned, private repositories included, for up to
// keptPageAge after their last use.
func keptPageDir() string {
	if dir, set := os.LookupEnv("BLOCKER_LINE_CACHE_DIR"); set {
		if dir == "off" {
			return ""
		}
		return dir
	}
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".cache")
	}
	return filepath.Join(base, "blocked-label-blocker-line")
}

// keptPageNameRE is the only file name a kept page has.
var keptPageNameRE = regexp.MustCompile(`^[0-9a-f]{64}\.json$`)

// keptPagePath names the kept copy of target. The forge host is part of the
// name, so another host's answer for the same path is another page.
func keptPagePath(dir, target string) string {
	sum := sha256.Sum256([]byte(os.Getenv("GH_HOST") + "\n" + target))
	return filepath.Join(dir, hex.EncodeToString(sum[:])+".json")
}

// ownPrivate reports whether info describes something of this user that no
// one else can read or write.
func ownPrivate(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid() && info.Mode().Perm()&0o077 == 0
}

// privateDir reports whether dir is a real directory of this user that no one
// else can enter, so nobody else can place or replace a page in it.
func privateDir(dir string) bool {
	info, err := os.Lstat(dir)
	return err == nil && info.IsDir() && ownPrivate(info)
}

// loadKeptPage returns the kept copy of target only when it is a private
// regular file of this user, in a private directory of this user, that names
// this target and a sendable validator. Anything else reads as no copy, so
// the page is simply read anew.
func loadKeptPage(dir, target string) (keptPage, bool) {
	if !privateDir(dir) {
		return keptPage{}, false
	}
	// The file that was checked is the file that is read: it is opened once,
	// never through a link, and judged by its descriptor.
	file, err := os.OpenFile(keptPagePath(dir, target), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return keptPage{}, false
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || !ownPrivate(info) {
		return keptPage{}, false
	}
	var kept keptPage
	if json.NewDecoder(file).Decode(&kept) != nil || kept.Target != target || !validatorRE.MatchString(kept.Validator) {
		return keptPage{}, false
	}
	return kept, true
}

// storeKeptPage keeps one page for the next run. It is best-effort: a page that
// cannot be kept is read again next time, and the verdict never depends on it.
func storeKeptPage(dir string, page keptPage) {
	if !validatorRE.MatchString(page.Validator) {
		return
	}
	raw, err := json.Marshal(page)
	if err != nil || os.MkdirAll(dir, 0o700) != nil || !privateDir(dir) {
		return
	}
	part, err := os.CreateTemp(dir, ".part.*")
	if err != nil {
		return
	}
	_, writeErr := part.Write(raw)
	closeErr := part.Close()
	if writeErr != nil || closeErr != nil || os.Rename(part.Name(), keptPagePath(dir, page.Target)) != nil {
		os.Remove(part.Name())
	}
}

// pruneKeptPages drops pages no run has used for keptPageAge, so pull requests
// that merged or closed do not stay on disk. It touches nothing but kept pages
// and their unfinished parts, and only in a directory that is this store.
func pruneKeptPages(dir string, now time.Time) {
	if !privateDir(dir) {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if !keptPageNameRE.MatchString(name) && !strings.HasPrefix(name, ".part.") {
			continue
		}
		if info, err := entry.Info(); err == nil && info.Mode().IsRegular() && ownPrivate(info) && now.Sub(info.ModTime()) > keptPageAge {
			os.Remove(filepath.Join(dir, name))
		}
	}
}
