package main

import (
	"bufio"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

// --- numbers and instants --------------------------------------------------------------------

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// leadingZero reports a multi-digit number written with a leading zero. Bash arithmetic reads such
// a value as octal (or fails on 8 and 9), so the scripts never measured what the caller wrote; it
// is refused rather than read either way.
func leadingZero(s string) bool { return len(s) > 1 && s[0] == '0' }

// parseCount reads a validated decimal knob. Values too long for an int64 are refused.
func parseCount(s string) (int64, bool) {
	if !allDigits(s) || leadingZero(s) || len(s) > 18 {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		n = n*10 + int64(s[i]-'0')
	}
	return n, true
}

// cronNumber reads a cron field the way `$((10#$v))` does for every value a schedule can sensibly
// hold; anything longer than three significant digits is reported as out of range.
func cronNumber(s string) (int, bool) {
	if !allDigits(s) {
		return 0, false
	}
	s = strings.TrimLeft(s, "0")
	if len(s) > 3 {
		return 1000, true
	}
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n, true
}

var isoBase = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$`)

// parseUTCBase reads YYYY-MM-DDTHH:MM:SS as UTC. An impossible date is refused, not normalised,
// and an instant before 1970 is refused, as the scripts' digits-only epoch check did.
func parseUTCBase(base string) (int64, bool) {
	if !isoBase.MatchString(base) {
		return 0, false
	}
	t, err := time.Parse("2006-01-02T15:04:05", base)
	if err != nil || t.Unix() < 0 {
		return 0, false
	}
	return t.Unix(), true
}

// livenessInstant is claude-lane-liveness.sh's reading of a store or transcript timestamp: drop
// everything from the first dot, then one trailing Z, and read the rest as UTC.
func livenessInstant(raw string) (int64, bool) {
	base := raw
	if i := strings.IndexByte(base, '.'); i >= 0 {
		base = base[:i]
	}
	return parseUTCBase(strings.TrimSuffix(base, "Z"))
}

// strictInstant is claude-dispatch-rate.sh's reading: the value must end in Z, and a fraction must
// be digits, so an offset-bearing value is never read as UTC.
func strictInstant(raw string) (int64, bool) {
	if !strings.HasSuffix(raw, "Z") {
		return 0, false
	}
	base := raw[:len(raw)-1]
	if i := strings.IndexByte(base, '.'); i >= 0 {
		if !allDigits(base[i+1:]) {
			return 0, false
		}
		base = base[:i]
	}
	return parseUTCBase(base)
}

func isoUTC(e int64) string { return time.Unix(e, 0).UTC().Format("2006-01-02T15:04:05Z") }

// --- files -----------------------------------------------------------------------------------

func isRegularFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// readable is `[ -r path ]`.
func readable(p string) bool { return p != "" && syscall.Access(p, 4) == nil }

// readFirstLine is `head -n 1`, without the newline.
func readFirstLine(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	return strings.TrimSuffix(line, "\n"), nil
}

// readFirstLines is `head -n n`.
func readFirstLines(p string, n int) ([]byte, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	r := bufio.NewReader(f)
	var out []byte
	for i := 0; i < n; i++ {
		line, err := r.ReadBytes('\n')
		out = append(out, line...)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

// --- the scheduled-tasks store ---------------------------------------------------------------

// storeCandidates is the glob `<root>/*/*/scheduled-tasks.json`: two directory levels whose names
// do not start with a dot, then a regular file. Glob characters in root are literal, as the
// script quoted it.
func storeCandidates(root string) []string {
	var out []string
	for _, a := range visibleEntries(root) {
		for _, b := range visibleEntries(filepath.Join(root, a)) {
			p := root + "/" + a + "/" + b + "/scheduled-tasks.json"
			if isRegularFile(p) {
				out = append(out, p)
			}
		}
	}
	sort.Strings(out)
	return out
}

func visibleEntries(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".") {
			out = append(out, e.Name())
		}
	}
	return out
}

func readDocs(p string) ([]any, error) {
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	return decodeAll(data)
}

// jqExit is `jq -e <filter> file` succeeding: every document evaluates without an error and the
// last one's result is true.
func jqExit(docs []any, pred func(any) (bool, error)) bool {
	if len(docs) == 0 {
		return false
	}
	last := false
	for _, d := range docs {
		r, err := pred(d)
		if err != nil {
			return false
		}
		last = r
	}
	return last
}

var errIndex = errors.New("cannot index")

// tasksOf is `.scheduledTasks[]?`: an error when the document cannot be indexed by name.
func tasksOf(doc any) ([]any, error) {
	v, ok := field(doc, "scheduledTasks")
	if !ok {
		return nil, errIndex
	}
	return iterate(v), nil
}

// enabledIDs is `[.scheduledTasks[]? | select(.enabled == true) | .id]`.
func enabledIDs(doc any) ([]any, error) {
	tasks, err := tasksOf(doc)
	if err != nil {
		return nil, err
	}
	var ids []any
	for _, t := range tasks {
		en, ok := field(t, "enabled")
		if !ok {
			return nil, errIndex
		}
		if isTrue(en) {
			id, _ := field(t, "id")
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func hasEnabledTask(doc any) (bool, error) {
	ids, err := enabledIDs(doc)
	return len(ids) > 0, err
}

// --- transcripts -----------------------------------------------------------------------------

// transcripts is `find <root> -maxdepth 2 -name '*.jsonl' -type f -newer <reference at cutoff>`.
// A root that is itself a symbolic link is not descended, as find does not follow one, and any
// directory that cannot be read fails the whole enumeration.
func transcripts(root string, cutoff int64) ([]string, error) {
	st, err := os.Lstat(root)
	if err != nil {
		return nil, err
	}
	if !st.IsDir() {
		return nil, nil
	}
	ref := time.Unix(cutoff, 0)
	var out []string
	consider := func(dir string, e os.DirEntry) error {
		if !e.Type().IsRegular() || !strings.HasSuffix(e.Name(), ".jsonl") {
			return nil
		}
		info, err := e.Info()
		if err != nil {
			return err
		}
		if info.ModTime().After(ref) {
			out = append(out, dir+"/"+e.Name())
		}
		return nil
	}
	top, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	for _, e := range top {
		if err := consider(root, e); err != nil {
			return nil, err
		}
		if !e.IsDir() {
			continue
		}
		sub := root + "/" + e.Name()
		inner, err := os.ReadDir(sub)
		if err != nil {
			return nil, err
		}
		for _, e2 := range inner {
			if err := consider(sub, e2); err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}

const markerNeedle = "<scheduled-task name="

// ws is the whitespace Oniguruma's [[:space:]] matches in UTF-8, which is wider than Go's.
const ws = `[\t\n\v\f\r \x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]`

var (
	leadingReminders = regexp.MustCompile(`^(?:<system-reminder>[\s\S]*?</system-reminder>` + ws + `*)+`)
	openingMarker    = regexp.MustCompile(`^<scheduled-task name="([A-Za-z0-9._-]+)"(?:` + ws + `|>)`)
)

// attributedTask names the scheduled task whose marker OPENS the first user message (a queued
// enqueue's content, or a user record's message content), after complete leading system-reminder
// blocks. A marker anywhere else attributes nothing. withBlocks also reads array-form content,
// whose first text block carries the marker; the liveness check reads string content only.
func attributedTask(doc any, withBlocks bool) string {
	obj, ok := doc.(map[string]any)
	if !ok {
		return ""
	}
	var content any
	switch {
	case obj["type"] == "queue-operation" && obj["operation"] == "enqueue":
		content = obj["content"]
	case obj["type"] == "user":
		msg, ok := field(obj["message"], "role")
		if !ok || msg != "user" {
			return ""
		}
		content, _ = field(obj["message"], "content")
	default:
		return ""
	}
	if blocks, ok := content.([]any); ok && withBlocks {
		content = nil
		for _, b := range blocks {
			if bo, ok := b.(map[string]any); ok && bo["type"] == "text" {
				content = bo["text"]
				break
			}
		}
	}
	s, ok := content.(string)
	if !ok {
		return ""
	}
	s = leadingReminders.ReplaceAllString(s, "")
	m := openingMarker.FindStringSubmatch(s)
	if m == nil {
		return ""
	}
	return m[1]
}
