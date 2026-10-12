// conditional-get is the disclosure wrapper's bounded GitHub list transport.
// It preserves response bytes and confirms each retained page with the forge.
// The comment classifier remains network-free (monorepo#4055).
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const maxBody = 32 << 20
const maxTotal = 64 << 20
const maxCache = 64 << 20
const keepAge = 7 * 24 * time.Hour
const cacheVersion = "disclosure-conditional-get-v1"

var endpointRE = regexp.MustCompile(`^repos/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+/(issues/(comments|[0-9]+/comments)|pulls(/comments|/[0-9]+/(comments|reviews))?)$`)
var etagRE = regexp.MustCompile(`^(W/)?"[A-Za-z0-9+/=_.:-]{1,200}"$`)
var cacheNameRE = regexp.MustCompile(`^[0-9a-f]{64}\.json$`)

type response struct {
	status int
	etag   string
	body   []byte
}
type retained struct {
	Version string `json:"version"`
	Target  string `json:"target"`
	ETag    string `json:"etag"`
	Body    []byte `json:"body"`
	SHA256  string `json:"sha256"`
}

func digest(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func fileName(dir, target string) string {
	return filepath.Join(dir, digest([]byte("github.com\n2022-11-28\n"+target))+".json")
}
func private(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid() && info.Mode().Perm()&0077 == 0
}
func privateDir(dir string) bool {
	info, err := os.Lstat(dir)
	return err == nil && info.IsDir() && private(info)
}
func validBody(body []byte) (int, error) {
	if len(body) == 0 || len(body) > maxBody || !utf8.Valid(body) || !json.Valid(body) {
		return 0, errors.New("invalid source body")
	}
	var items []json.RawMessage
	if json.Unmarshal(body, &items) != nil || items == nil {
		return 0, errors.New("source is not a JSON array")
	}
	if len(items) > 100 {
		return 0, errors.New("source exceeded requested page size")
	}
	return len(items), nil
}
func readRecord(path string) (retained, os.FileInfo, bool) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return retained{}, nil, false
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || !private(info) || info.Size() > maxCache {
		return retained{}, nil, false
	}
	var record retained
	decoder := json.NewDecoder(io.LimitReader(file, maxCache+1))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&record) != nil || decoder.Decode(new(any)) != io.EOF || record.Version != cacheVersion || !etagRE.MatchString(record.ETag) || record.SHA256 != digest(record.Body) {
		return retained{}, nil, false
	}
	if _, err := validBody(record.Body); err != nil {
		return retained{}, nil, false
	}
	if filepath.Base(path) != filepath.Base(fileName(filepath.Dir(path), record.Target)) {
		return retained{}, nil, false
	}
	return record, info, true
}
func load(dir, target string) (retained, bool) {
	if !privateDir(dir) {
		return retained{}, false
	}
	record, info, ok := readRecord(fileName(dir, target))
	if !ok || record.Target != target || time.Since(info.ModTime()) > keepAge {
		return retained{}, false
	}
	return record, true
}
func store(dir, target string, page response) {
	if dir == "" || !etagRE.MatchString(page.etag) {
		return
	}
	if os.MkdirAll(dir, 0700) != nil || !privateDir(dir) {
		return
	}
	raw, err := json.Marshal(retained{Version: cacheVersion, Target: target, ETag: page.etag, Body: page.body, SHA256: digest(page.body)})
	if err != nil || len(raw) > maxCache {
		return
	}
	file, err := os.CreateTemp(dir, ".part-")
	if err != nil {
		return
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err = file.Write(raw); err != nil {
		file.Close()
		return
	}
	if file.Close() != nil {
		return
	}
	if os.Rename(name, fileName(dir, target)) == nil {
		prune(dir)
	}
}
func prune(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil || !privateDir(dir) {
		return
	}
	type candidate struct {
		name string
		size int64
		used time.Time
	}
	var files []candidate
	var total int64
	for _, entry := range entries {
		if !cacheNameRE.MatchString(entry.Name()) {
			continue
		}
		_, info, ok := readRecord(filepath.Join(dir, entry.Name()))
		if !ok {
			continue
		}
		total += info.Size()
		files = append(files, candidate{entry.Name(), info.Size(), info.ModTime()})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].used.Before(files[j].used) })
	for _, file := range files {
		if total <= maxCache && time.Since(file.used) <= keepAge {
			continue
		}
		if os.Remove(filepath.Join(dir, file.name)) == nil {
			total -= file.size
		}
	}
}

type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > maxBody+16384 {
		return 0, errors.New("source response too large")
	}
	return b.Buffer.Write(p)
}
func parse(raw []byte) (response, error) {
	header, body, ok := bytes.Cut(raw, []byte("\r\n\r\n"))
	if !ok {
		header, body, ok = bytes.Cut(raw, []byte("\n\n"))
	}
	if !ok {
		return response{}, errors.New("incomplete source headers")
	}
	lines := strings.Split(strings.ReplaceAll(string(header), "\r\n", "\n"), "\n")
	words := strings.Fields(lines[0])
	if len(words) < 2 || !strings.HasPrefix(words[0], "HTTP/") {
		return response{}, errors.New("missing source status")
	}
	status, err := strconv.Atoi(words[1])
	if err != nil {
		return response{}, err
	}
	page := response{status: status, body: body}
	seen := false
	for _, line := range lines[1:] {
		name, value, ok := strings.Cut(line, ":")
		if !ok {
			return response{}, errors.New("malformed source header")
		}
		if strings.EqualFold(strings.TrimSpace(name), "etag") {
			if seen {
				return response{}, errors.New("ambiguous source validator")
			}
			seen = true
			page.etag = strings.TrimSpace(value)
		}
	}
	return page, nil
}
func fetch(ctx context.Context, target, etag string) (response, error) {
	args := []string{"api", "--include", "--hostname", "github.com", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28"}
	if etag != "" {
		args = append(args, "-H", "If-None-Match: "+etag)
	}
	cmd := exec.CommandContext(ctx, "gh", append(args, target)...)
	cmd.Env = append(os.Environ(), "GH_HOST=github.com")
	var output limitedBuffer
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	commandErr := cmd.Run()
	page, err := parse(output.Bytes())
	if err != nil {
		return response{}, err
	}
	if commandErr != nil {
		exit, ok := commandErr.(*exec.ExitError)
		if !ok || exit.ExitCode() != 1 || page.status != 304 || len(bytes.TrimSpace(page.body)) != 0 {
			return response{}, errors.New("source command failed")
		}
	}
	if page.status != 200 && page.status != 304 {
		return response{}, errors.New("source returned HTTP " + strconv.Itoa(page.status))
	}
	if page.status == 304 && len(bytes.TrimSpace(page.body)) != 0 {
		return response{}, errors.New("unexpected not-modified body")
	}
	return page, nil
}
func read(ctx context.Context, endpoint, dir string, single, trace bool) ([]byte, error) {
	uri, err := url.Parse(endpoint)
	if err != nil || uri.IsAbs() || uri.Host != "" || uri.Fragment != "" || uri.RawPath != "" || !endpointRE.MatchString(uri.Path) {
		return nil, errors.New("unsupported endpoint")
	}
	for _, segment := range strings.Split(uri.Path, "/") {
		if segment == "." || segment == ".." {
			return nil, errors.New("unsupported path segment")
		}
	}
	query, err := url.ParseQuery(uri.RawQuery)
	if err != nil {
		return nil, err
	}
	for key, values := range query {
		if len(values) != 1 {
			return nil, errors.New("ambiguous query")
		}
		switch key {
		case "since", "state", "sort", "direction", "page", "per_page":
		default:
			return nil, errors.New("unsupported query")
		}
	}
	start := 1
	if single && query.Get("page") != "" {
		start, err = strconv.Atoi(query.Get("page"))
		if err != nil || start < 1 || start > 50 {
			return nil, errors.New("invalid page")
		}
	} else if query.Get("page") != "" {
		return nil, errors.New("page requires single-page mode")
	}
	var output []byte
	for pageNumber := start; pageNumber <= 50; pageNumber++ {
		query.Set("page", strconv.Itoa(pageNumber))
		query.Set("per_page", "100")
		uri.RawQuery = query.Encode()
		target := uri.String()
		kept, have := load(dir, target)
		validator := ""
		if have {
			validator = kept.ETag
		}
		page, err := fetch(ctx, target, validator)
		if err != nil {
			return nil, err
		}
		status := page.status
		if status == 304 {
			// If-None-Match uses weak comparison (RFC 9110 section 13.1.2).
			// GitHub's 200 can prefix W/ while its equivalent 304 omits it.
			if !have || (page.etag != "" && (!etagRE.MatchString(page.etag) || strings.TrimPrefix(page.etag, "W/") != strings.TrimPrefix(kept.ETag, "W/"))) {
				return nil, errors.New("unbound not-modified answer")
			}
			page = response{status: 200, etag: kept.ETag, body: kept.Body}
		}
		count, err := validBody(page.body)
		if err != nil {
			return nil, err
		}
		if len(output)+len(page.body)+1 > maxTotal {
			return nil, errors.New("aggregate response too large")
		}
		if status == 200 {
			store(dir, target, page)
		}
		if trace {
			fmt.Fprintf(os.Stderr, "conditional-get: HTTP %d %s\n", status, target)
		}
		output = append(output, page.body...)
		output = append(output, '\n')
		// List pagination is deterministic. Probe after every full page even when
		// a 304 omits Link, so a new last page cannot disappear behind an old link.
		if single || count < 100 {
			return output, nil
		}
	}
	return nil, errors.New("source exceeds 50 pages")
}
func main() {
	endpoint := flag.String("endpoint", "", "GitHub list endpoint")
	dir := flag.String("cache-dir", "", "private retained-page directory")
	single := flag.Bool("single-page", false, "read only the requested page")
	trace := flag.Bool("trace", false, "print source status without response bodies")
	flag.Parse()
	if flag.NArg() != 0 || *endpoint == "" {
		fmt.Fprintln(os.Stderr, "conditional-get: endpoint required")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	output, err := read(ctx, *endpoint, *dir, *single, *trace)
	if err != nil {
		fmt.Fprintln(os.Stderr, "conditional-get: UNKNOWN:", err)
		os.Exit(2)
	}
	if _, err = os.Stdout.Write(output); err != nil {
		os.Exit(2)
	}
}
