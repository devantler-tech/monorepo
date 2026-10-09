// The read subcommand lends the conditional forge reads (cache.go) to the
// other helpers of this directory, so a start-of-run count that re-reads the
// same unchanged lists every hour stops charging them to the hourly request
// budget (#4055). It reads and never writes to the forge.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
)

// readEndpointRE admits a relative organisation or repository path with a
// plain query, and nothing that could name another host or another verb.
var readEndpointRE = regexp.MustCompile(`^(orgs|repos)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*(\?[A-Za-z0-9_=&-]+)?$`)

// readableEndpoint reports whether endpoint is such a path. A repository may be
// named ".github", so a leading dot is allowed and a relative segment is not.
func readableEndpoint(endpoint string) bool {
	if !readEndpointRE.MatchString(endpoint) {
		return false
	}
	// Two page sizes leave it to the forge which one applies.
	if strings.Count(endpoint, "per_page=") > 1 {
		return false
	}
	path, _, _ := strings.Cut(endpoint, "?")
	for _, segment := range strings.Split(path, "/") {
		if segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

// perPageRE finds the page size an endpoint asks for.
var perPageRE = regexp.MustCompile(`[?&]per_page=([0-9]{1,3})(&|$)`)

// forgePageSize is the page size the forge applies when none is asked for.
const forgePageSize = 30

// forgeLargestPage is the largest page the forge returns.
const forgeLargestPage = 100

// pagesOf splits what conditionalRead returned into its pages.
func pagesOf(raw []byte) ([]json.RawMessage, error) {
	pages := []json.RawMessage{}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	for {
		var page json.RawMessage
		err := decoder.Decode(&page)
		if err == io.EOF {
			return pages, nil
		}
		if err != nil {
			return nil, errors.New("unreadable forge page")
		}
		pages = append(pages, page)
	}
}

// lastPageIsFull reports whether the last page is a list holding a whole page.
// A kept page the forge confirms says nothing about a page that has appeared
// after it, so a list ending on a full page may have grown past its kept end.
func lastPageIsFull(endpoint string, pages []json.RawMessage) bool {
	if len(pages) == 0 {
		return false
	}
	var items []json.RawMessage
	if json.Unmarshal(pages[len(pages)-1], &items) != nil {
		return false
	}
	size := forgePageSize
	if match := perPageRE.FindStringSubmatch(endpoint); match != nil {
		if asked, err := strconv.Atoi(match[1]); err == nil && asked > 0 {
			size = asked
		}
	}
	// The forge never returns more than its largest page, whatever was asked.
	if size > forgeLargestPage {
		size = forgeLargestPage
	}
	return len(items) >= size
}

// listOrOneObject reports whether pages are the pages of a plain list, or one
// object. A list wrapped in an object could continue unseen, since its length
// is not read here, so it is refused rather than answered short.
func listOrOneObject(pages []json.RawMessage) bool {
	lists := 0
	for _, page := range pages {
		if trimmed := bytes.TrimSpace(page); len(trimmed) > 0 && trimmed[0] == '[' {
			lists++
		} else if len(trimmed) == 0 || trimmed[0] != '{' {
			return false
		}
	}
	return lists == len(pages) || (lists == 0 && len(pages) == 1)
}

// readPages returns every page of endpoint as one JSON array. Pages the forge
// confirms unchanged come from the kept copy, except where that copy could
// hide a continuation: then the whole endpoint is read anew.
func readPages(endpoint string) ([]byte, error) {
	if !readableEndpoint(endpoint) {
		return nil, errors.New("not a readable endpoint")
	}
	for _, reuse := range []bool{true, false} {
		raw, err := conditionalRead(endpoint, reuse)
		if err != nil {
			return nil, err
		}
		pages, err := pagesOf(raw)
		if err != nil {
			return nil, err
		}
		if len(pages) == 0 {
			return nil, errors.New("empty forge answer")
		}
		if !listOrOneObject(pages) {
			return nil, errors.New("not a list and not a single object")
		}
		if reuse && lastPageIsFull(endpoint, pages) {
			continue
		}
		return json.Marshal(pages)
	}
	return nil, errors.New("unreachable")
}

// readRun prints one line per endpoint, in order: the JSON array of its pages.
// It prints nothing unless every endpoint was read in full.
func readRun(args []string, stdout, stderr io.Writer) int {
	refuse := func(err error) int {
		_, _ = fmt.Fprintln(stderr, "blocked-label-blocker-line.sh read:", err, "-- UNKNOWN")
		return 2
	}
	if len(args) == 0 {
		return refuse(errors.New("usage: read <endpoint>..."))
	}
	var out bytes.Buffer
	for _, endpoint := range args {
		line, err := readPages(endpoint)
		if err != nil {
			return refuse(fmt.Errorf("%s: %w", endpoint, err))
		}
		out.Write(line)
		out.WriteByte('\n')
	}
	if _, err := stdout.Write(out.Bytes()); err != nil {
		return refuse(err)
	}
	return 0
}
