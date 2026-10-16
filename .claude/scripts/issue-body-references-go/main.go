// issue-body-references reads link destinations without executing or fetching body content.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	renderer "github.com/yuin/goldmark/renderer/html"
	"golang.org/x/net/html"
)

var repoName = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
var address = regexp.MustCompile(`(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.)[^\s<>"']+`)

// localIssue checks a complete destination, including relative links on a PR page.
func localIssue(destination, repo string, number int) bool {
	link, err := url.Parse(destination)
	if err != nil {
		return false
	}
	base := &url.URL{Scheme: "https", Host: "github.com", Path: "/" + repo + "/pull/"}
	link = base.ResolveReference(link)
	if link.User != nil || link.Port() != "" ||
		(!strings.EqualFold(link.Scheme, "https") && !strings.EqualFold(link.Scheme, "http")) ||
		(!strings.EqualFold(link.Hostname(), "github.com") && !strings.EqualFold(link.Hostname(), "redirect.github.com")) {
		return false
	}
	parts := strings.Split(strings.TrimSuffix(link.Path, "/"), "/")
	return len(parts) == 5 && strings.EqualFold(parts[1]+"/"+parts[2], repo) && parts[3] == "issues" && parts[4] == strconv.Itoa(number)
}

// bodyMentions uses Markdown/HTML structure so labels of foreign links never become bare refs.
// WithUnsafe preserves raw HTML as data for the HTML parser; it is never displayed or executed.
func bodyMentions(body, repo string, number int) (bool, error) {
	if !repoName.MatchString(repo) || number < 1 {
		return false, fmt.Errorf("invalid issue identity")
	}
	var rendered bytes.Buffer
	// GFM recognizes schemeless web/email links. Protocol URLs remain whole text tokens
	// for the punctuation handling below (including URLs in code spans).
	markdown := goldmark.New(
		goldmark.WithExtensions(extension.NewLinkify(extension.WithLinkifyURLRegexp(regexp.MustCompile(`^$`)))),
		goldmark.WithRendererOptions(renderer.WithUnsafe()),
	)
	if err := markdown.Convert([]byte(body), &rendered); err != nil {
		return false, err
	}
	document, err := html.Parse(&rendered)
	if err != nil {
		return false, err
	}
	bare := regexp.MustCompile(`(^|[^A-Za-z0-9_./#-])#` + strconv.Itoa(number) + `([^0-9]|$)`)
	var visit func(*html.Node) bool
	visit = func(node *html.Node) bool {
		if node.Type == html.ElementNode && node.Data == "a" {
			for _, attr := range node.Attr {
				if attr.Key == "href" {
					return localIssue(attr.Val, repo, number)
				}
			}
		}
		if node.Type == html.TextNode {
			// Literal/code URLs also name destinations. Compare each whole token, never a substring.
			for _, token := range address.FindAllString(node.Data, -1) {
				if localIssue(strings.TrimRight(token, ".,!?;:)]}"), repo, number) {
					return true
				}
			}
			if bare.MatchString(address.ReplaceAllString(node.Data, " ")) {
				return true
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			if visit(child) {
				return true
			}
		}
		return false
	}
	return visit(document), nil
}

type pullRequest struct {
	Repository string  `json:"repository_url"`
	Number     int     `json:"number"`
	State      string  `json:"state"`
	Body       *string `json:"body"`
	Pull       *struct {
		MergedAt *string `json:"merged_at"`
	} `json:"pull_request"`
}

type mention struct {
	Key     string `json:"k"`
	State   string `json:"s"`
	Closing bool   `json:"c"`
}

// run validates the complete observation before emitting any rows.
func run(args []string, in io.Reader, out io.Writer) error {
	if len(args) != 2 || !repoName.MatchString(args[0]) {
		return fmt.Errorf("usage: issue-body-references <owner/repo> <issue-number>")
	}
	number, err := strconv.Atoi(args[1])
	if err != nil || number < 1 {
		return fmt.Errorf("invalid issue number")
	}
	const maximum = 16 << 20
	data, err := io.ReadAll(io.LimitReader(in, maximum+1))
	if err != nil || len(data) > maximum {
		return fmt.Errorf("body-search read failed or exceeded its bound")
	}
	var search struct {
		Total      *int          `json:"total_count"`
		Incomplete *bool         `json:"incomplete_results"`
		Items      []pullRequest `json:"items"`
	}
	if err = json.Unmarshal(data, &search); err != nil {
		return fmt.Errorf("invalid body-search JSON")
	}
	if search.Total == nil || search.Incomplete == nil || *search.Incomplete || search.Items == nil || *search.Total != len(search.Items) || *search.Total > 100 {
		return fmt.Errorf("incomplete body-search observation")
	}
	rows := make([]mention, 0)
	for _, pr := range search.Items {
		const apiPrefix = "https://api.github.com/repos/"
		canonical := strings.TrimPrefix(pr.Repository, apiPrefix)
		if canonical == pr.Repository || !strings.EqualFold(canonical, args[0]) || pr.Number < 1 || pr.Pull == nil || (pr.State != "open" && pr.State != "closed") {
			return fmt.Errorf("invalid pull-request identity or state")
		}
		state := "CLOSED"
		if pr.State == "open" {
			state = "OPEN"
		}
		if pr.Pull.MergedAt != nil {
			if _, err = time.Parse(time.RFC3339, *pr.Pull.MergedAt); err != nil || pr.State != "closed" {
				return fmt.Errorf("invalid merge evidence")
			}
			state = "MERGED"
		}
		if pr.Body == nil {
			continue
		}
		matches, err := bodyMentions(*pr.Body, args[0], number)
		if err != nil {
			return fmt.Errorf("cannot parse body references: %w", err)
		}
		if matches {
			rows = append(rows, mention{Key: canonical + "#" + strconv.Itoa(pr.Number), State: state})
		}
	}
	return json.NewEncoder(out).Encode(rows)
}

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "issue-body-references: UNKNOWN:", err)
		os.Exit(2)
	}
}
