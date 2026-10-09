package main

import (
	"bytes"
	"strings"
	"testing"
)

func runRead(t *testing.T, endpoints ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := run(append([]string{"read"}, endpoints...), strings.NewReader(""), &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestReadPrintsOneLineOfPagesPerEndpoint(t *testing.T) {
	keepPagesIn(t)
	second := forgeHost + "organizations/1/repos?per_page=2&page=2"
	servePages(t, map[string]forgePage{
		"orgs/o":                           {status: 200, validator: `W/"o1"`, body: []byte(`{"public_repos":3}`)},
		"orgs/o/repos?type=all&per_page=2": {status: 200, validator: `W/"r1"`, next: second, body: []byte(`[{"name":"a"},{"name":"b"}]`)},
		second:                             {status: 200, validator: `W/"r2"`, body: []byte(`[{"name":"c"}]`)},
	})
	code, out, _ := runRead(t, "orgs/o", "orgs/o/repos?type=all&per_page=2")
	want := `[{"public_repos":3}]` + "\n" + `[[{"name":"a"},{"name":"b"}],[{"name":"c"}]]` + "\n"
	if code != 0 || out != want {
		t.Fatalf("read returned %d and %q, want %q", code, out, want)
	}
}

func TestReadReusesWhatTheForgeConfirms(t *testing.T) {
	keepPagesIn(t)
	endpoint := "repos/o/r/pulls?state=open&per_page=100"
	forge := servePages(t, map[string]forgePage{
		endpoint: {status: 200, validator: `W/"p1"`, body: []byte(`[{"draft":true}]`)},
	})
	_, first, _ := runRead(t, endpoint)
	code, second, _ := runRead(t, endpoint)
	if code != 0 || first != second || first != `[[{"draft":true}]]`+"\n" {
		t.Fatalf("reads differ: %q then %q (exit %d)", first, second, code)
	}
	if offered := forge.offered[endpoint]; len(offered) != 2 || offered[1] != `W/"p1"` {
		t.Fatalf("the second read must be conditional, offered %q", offered)
	}
}

// A kept full page the forge confirms cannot show a page that has appeared
// after it, so a list ending on a full page is read anew and finds it.
func TestReadFindsAPageThatAppearedAfterAFullKeptPage(t *testing.T) {
	keepPagesIn(t)
	endpoint := "repos/o/r/pulls?state=open&per_page=2"
	second := forgeHost + "repositories/1/pulls?state=open&per_page=2&page=2"
	forge := servePages(t, map[string]forgePage{
		endpoint: {status: 200, validator: `W/"p1"`, body: []byte(`[{"n":1},{"n":2}]`)},
	})
	if code, out, _ := runRead(t, endpoint); code != 0 || out != `[[{"n":1},{"n":2}]]`+"\n" {
		t.Fatalf("first read returned %d and %q", code, out)
	}
	forge.pages[endpoint] = forgePage{status: 200, validator: `W/"p1"`, next: second, body: []byte(`[{"n":1},{"n":2}]`)}
	forge.pages[second] = forgePage{status: 200, validator: `W/"p2"`, body: []byte(`[{"n":3}]`)}
	// The control: the kept copy alone still ends where it used to.
	if got := mustRead(t, endpoint, true); got != `[{"n":1},{"n":2}]` {
		t.Fatalf("the control must show the hidden page: a reused read returned %q", got)
	}
	code, out, _ := runRead(t, endpoint)
	if code != 0 || out != `[[{"n":1},{"n":2}],[{"n":3}]]`+"\n" {
		t.Fatalf("read returned %d and %q", code, out)
	}
}

// A list that ends on a short page is complete, so it is not read twice.
func TestReadDoesNotReadAShortListAnew(t *testing.T) {
	keepPagesIn(t)
	endpoint := "repos/o/r/pulls?state=open&per_page=2"
	forge := servePages(t, map[string]forgePage{
		endpoint: {status: 200, validator: `W/"p1"`, body: []byte(`[{"n":1}]`)},
	})
	runRead(t, endpoint)
	if offered := forge.offered[endpoint]; len(offered) != 1 {
		t.Fatalf("a short list must be read once, read %d times", len(offered))
	}
}

func TestReadAppliesTheForgePageSizeWhenNoneIsAsked(t *testing.T) {
	full := "[" + strings.TrimSuffix(strings.Repeat(`{},`, forgePageSize), ",") + "]"
	pages, err := pagesOf([]byte(full))
	if err != nil || !lastPageIsFull("repos/o/r/pulls", pages) {
		t.Fatalf("a page of %d must count as full without per_page (err %v)", forgePageSize, err)
	}
	if lastPageIsFull("repos/o/r/pulls?per_page=100", pages) {
		t.Fatalf("a page of %d is not full at per_page=100", forgePageSize)
	}
	object, _ := pagesOf([]byte(`{"public_repos":3}`))
	if lastPageIsFull("orgs/o", object) {
		t.Fatal("an object is never a full list page")
	}
}

func TestReadPrintsNothingUnlessEveryEndpointWasRead(t *testing.T) {
	keepPagesIn(t)
	servePages(t, map[string]forgePage{
		"orgs/o": {status: 200, validator: `W/"o1"`, body: []byte(`{"public_repos":3}`)},
	})
	code, out, errOut := runRead(t, "orgs/o", "repos/o/missing/pulls")
	if code != 2 || out != "" || !strings.Contains(errOut, "repos/o/missing/pulls") {
		t.Fatalf("a failed endpoint must be UNKNOWN with no output: %d, %q, %q", code, out, errOut)
	}
	servePages(t, map[string]forgePage{
		"orgs/o": {status: 200, validator: `W/"o2"`, body: []byte(`{"public_repos":`)},
	})
	if code, out, _ := runRead(t, "orgs/o"); code != 2 || out != "" {
		t.Fatalf("a cut-short page must be UNKNOWN with no output: %d, %q", code, out)
	}
	servePages(t, map[string]forgePage{
		"orgs/o": {status: 200, validator: `W/"o3"`},
	})
	if code, out, _ := runRead(t, "orgs/o"); code != 2 || out != "" {
		t.Fatalf("an empty answer must be UNKNOWN with no output: %d, %q", code, out)
	}
}

func TestReadRefusesWhatIsNotAPlainOrganisationOrRepositoryPath(t *testing.T) {
	keepPagesIn(t)
	forge := servePages(t, map[string]forgePage{})
	for _, endpoint := range []string{
		"", "search/issues?q=x", "https://example.invalid/orgs/o", "/orgs/o", "orgs/../user", "repos/o/./r", "repos/o/r/..",
		"orgs/o -X DELETE", "-XDELETE", "orgs/o?a=b c", "graphql", "repos/o/r/pulls?state=open#x",
	} {
		if code, out, _ := runRead(t, endpoint); code != 2 || out != "" {
			t.Fatalf("%q must be refused, got %d and %q", endpoint, code, out)
		}
	}
	if code, _, _ := runRead(t); code != 2 {
		t.Fatalf("no endpoint must be a usage error, got %d", code)
	}
	if len(forge.offered) != 0 {
		t.Fatalf("a refused endpoint must never reach the forge, reached %v", forge.offered)
	}
}

// The forge caps a page at its largest size, so a larger one asked for must
// not make a full page look short; two sizes are refused outright.
func TestReadJudgesAFullPageByWhatTheForgeReturns(t *testing.T) {
	full := "[" + strings.TrimSuffix(strings.Repeat(`{},`, forgeLargestPage), ",") + "]"
	pages, err := pagesOf([]byte(full))
	if err != nil || !lastPageIsFull("repos/o/r/pulls?per_page=200", pages) {
		t.Fatalf("a page of %d is full even when 200 were asked for (err %v)", forgeLargestPage, err)
	}
	if readableEndpoint("repos/o/r/pulls?per_page=100&per_page=5") {
		t.Fatal("an endpoint naming two page sizes must be refused")
	}
}

// A list wrapped in an object could continue past a kept page unseen.
func TestReadRefusesAListWrappedInAnObject(t *testing.T) {
	keepPagesIn(t)
	second := forgeHost + "repositories/1/actions/runs?page=2"
	servePages(t, map[string]forgePage{
		"repos/o/r/actions/runs": {status: 200, validator: `W/"a1"`, next: second, body: []byte(`{"total_count":2,"workflow_runs":[{}]}`)},
		second:                   {status: 200, validator: `W/"a2"`, body: []byte(`{"total_count":2,"workflow_runs":[{}]}`)},
		"repos/o/r/mixed":        {status: 200, validator: `W/"m1"`, next: second, body: []byte(`[{}]`)},
		"repos/o/r/scalar":       {status: 200, validator: `W/"s1"`, body: []byte(`3`)},
	})
	for _, endpoint := range []string{"repos/o/r/actions/runs", "repos/o/r/mixed", "repos/o/r/scalar"} {
		if code, out, _ := runRead(t, endpoint); code != 2 || out != "" {
			t.Fatalf("%s must be UNKNOWN with no output: %d, %q", endpoint, code, out)
		}
	}
}
