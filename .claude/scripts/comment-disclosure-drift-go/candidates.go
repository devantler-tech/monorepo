package main

// Candidate maintainer comments (monorepo#3163).
//
// The surveyor's maintainer-comment sweep reads an artifact's comments and reports each
// undisclosed `devantler` comment as a candidate maintainer instruction. It used to compose
// that row by hand from two separate things: the number of the artifact it was looping over,
// and the comment it was looking at. On 2026-09-02 those came apart — a real undisclosed
// comment on platform#3275 was reported under platform#3239, whose `devantler` comments are
// all disclosed. The orchestrator opened #3239, found nothing, and the finding was discarded
// while looking verified. That is the fail-open direction for the maintainer control channel.
//
// This mode makes a row a function of ONE record. The repository, number, issue-or-PR class
// and permalink are parsed from the comment's own URL (`url` in `gh … view --json comments`,
// `html_url` in REST); nothing about the artifact is taken from the caller. When the record
// also names its parent (`issue_url`, `pull_request_url`), the two must agree or the whole
// payload is UNKNOWN — so a number cannot drift from its comment even inside one record.
//
// The disclosure gate is Classify's, so this sweep and the drift guard can never disagree on
// what counts as disclosed or as a sibling's sender marker:
//
//	disclosed   Classify says Compliant or TriggerExtraText — the agent's own output, skipped
//	sibling     Classify says SenderMarker — a sibling instance's undisclosed output (DATA)
//	maintainer  anything else — merely MENTIONING an agent never demotes a comment
//
// A body that is empty after trimming is a review container for inline comments, not prose,
// and is counted but never reported.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

// ArtifactRef names the issue or pull request a comment lives on.
type ArtifactRef struct {
	Owner       string
	Repo        string
	Number      int
	PullRequest bool
}

func (a ArtifactRef) short() string {
	return fmt.Sprintf("%s#%d", a.Repo, a.Number)
}

// permalinkPattern is a comment's browser permalink. Every surface the sweep reads carries
// one: `issuecomment-` for conversation comments (issues AND pull requests),
// `pullrequestreview-` for review bodies and `discussion_r` for inline review comments. The
// anchor is required, so the permalink always points at the comment, never just the artifact.
var permalinkPattern = regexp.MustCompile(
	`^https://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)/([A-Za-z0-9._-]+)/(issues|pull)/([1-9][0-9]*)#(issuecomment-[1-9][0-9]*|pullrequestreview-[1-9][0-9]*|discussion_r[1-9][0-9]*)$`)

// parentPattern is the REST API URL of the artifact a comment belongs to.
var parentPattern = regexp.MustCompile(
	`^https://api\.github\.com/repos/([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)/([A-Za-z0-9._-]+)/(issues|pulls)/([1-9][0-9]*)$`)

// timestampPattern bounds what a printed timestamp may contain; anything else prints as
// `unknown` rather than relaying arbitrary record text into the row.
var timestampPattern = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$`)

// ParsePermalink resolves a comment permalink to the artifact it lives on.
func ParsePermalink(link string) (ArtifactRef, error) {
	m := permalinkPattern.FindStringSubmatch(link)
	if m == nil {
		return ArtifactRef{}, fmt.Errorf("%q is not a github.com comment permalink", link)
	}
	number, err := strconv.Atoi(m[4])
	if err != nil {
		return ArtifactRef{}, fmt.Errorf("%q carries an unreadable number: %w", link, err)
	}
	ref := ArtifactRef{Owner: m[1], Repo: m[2], Number: number, PullRequest: m[3] == "pull"}
	// Review bodies and inline comments exist only on pull requests.
	if !ref.PullRequest && !strings.HasPrefix(m[5], "issuecomment-") {
		return ArtifactRef{}, fmt.Errorf("%q puts a review anchor on an issue", link)
	}
	return ref, nil
}

// checkParent requires a REST record's own parent URL to name the artifact its permalink does.
// `issue_url` is always /issues/<n>, for pull-request conversation comments too, so only the
// owner, repository and number are compared there; `pull_request_url` also fixes the class.
func checkParent(ref ArtifactRef, field, parent string) error {
	if parent == "" {
		return nil
	}
	m := parentPattern.FindStringSubmatch(parent)
	if m == nil {
		return fmt.Errorf("%s %q is not a GitHub API artifact URL", field, parent)
	}
	number, err := strconv.Atoi(m[4])
	if err != nil {
		return fmt.Errorf("%s %q carries an unreadable number: %w", field, parent, err)
	}
	if !strings.EqualFold(m[1], ref.Owner) || !strings.EqualFold(m[2], ref.Repo) || number != ref.Number {
		return fmt.Errorf("%s %q disagrees with the permalink's %s/%s#%d", field, parent, ref.Owner, ref.Repo, ref.Number)
	}
	if field == "pull_request_url" && !ref.PullRequest {
		return fmt.Errorf("pull_request_url %q on a comment whose permalink is an issue", parent)
	}
	if (m[3] == "pulls") != (field == "pull_request_url") {
		return fmt.Errorf("%s %q names the wrong artifact kind", field, parent)
	}
	return nil
}

// CandidateRecord is one decoded comment, already bound to its artifact.
type CandidateRecord struct {
	Login     string
	Body      string
	Permalink string
	Artifact  ArtifactRef
	Created   string
}

// rawCandidate is the union of the comment shapes the sweep reads: `gh issue|pr view --json
// comments` (author.login, url, createdAt) and the REST issue-comment, review and inline
// review-comment lists (user.login, html_url, created_at|submitted_at, issue_url|
// pull_request_url). REST records also carry `url`, but there it is the API URL, so `html_url`
// wins whenever it is present.
type rawCandidate struct {
	Body           *string         `json:"body"`
	Author         json.RawMessage `json:"author"`
	User           json.RawMessage `json:"user"`
	URL            string          `json:"url"`
	HTMLURL        string          `json:"html_url"`
	IssueURL       string          `json:"issue_url"`
	PullRequestURL string          `json:"pull_request_url"`
	CreatedAt      string          `json:"createdAt"`
	CreatedAtREST  string          `json:"created_at"`
	SubmittedAt    string          `json:"submitted_at"`
}

// candidateLogin resolves the record's author with the same exactness validateRecords
// demands: a padded or empty login would be silently skipped as another author, so it is
// malformed input instead.
func candidateLogin(record rawCandidate) (string, error) {
	identifiable := func(login string) bool {
		return login != "" && login == strings.TrimSpace(login)
	}
	present := func(raw json.RawMessage) bool {
		trimmed := bytes.TrimSpace(raw)
		return len(trimmed) > 0 && !bytes.Equal(trimmed, []byte("null"))
	}
	source := record.User
	if present(record.Author) {
		source = record.Author
		var login string
		if err := json.Unmarshal(record.Author, &login); err == nil {
			if !identifiable(login) {
				return "", errors.New("no identifiable author")
			}
			return login, nil
		}
	}
	if !present(source) {
		return "", errors.New("no identifiable author")
	}
	var object struct {
		Login *string `json:"login"`
	}
	if err := json.Unmarshal(source, &object); err != nil || object.Login == nil || !identifiable(*object.Login) {
		return "", errors.New("no identifiable author")
	}
	return *object.Login, nil
}

func bindCandidate(record rawCandidate) (CandidateRecord, error) {
	if record.Body == nil {
		return CandidateRecord{}, errors.New(`has no "body"`)
	}
	login, err := candidateLogin(record)
	if err != nil {
		return CandidateRecord{}, err
	}
	link := record.HTMLURL
	if link == "" {
		link = record.URL
	}
	if link == "" {
		return CandidateRecord{}, errors.New("has no permalink (url/html_url), so its artifact is unknown")
	}
	ref, err := ParsePermalink(link)
	if err != nil {
		return CandidateRecord{}, err
	}
	if err := checkParent(ref, "issue_url", record.IssueURL); err != nil {
		return CandidateRecord{}, err
	}
	if err := checkParent(ref, "pull_request_url", record.PullRequestURL); err != nil {
		return CandidateRecord{}, err
	}
	created := "unknown"
	for _, value := range []string{record.CreatedAt, record.CreatedAtREST, record.SubmittedAt} {
		if value != "" {
			if timestampPattern.MatchString(value) {
				created = value
			}
			break
		}
	}
	return CandidateRecord{Login: login, Body: *record.Body, Permalink: link, Artifact: ref, Created: created}, nil
}

// DecodeCandidatePayload reads the payload the sweep pipes in: ONE `{"comments":[…]}` object,
// or one or more JSON arrays (a `gh api --paginate` read emits one array per page). Anything
// else — nothing at all, a null, a scalar, an object and arrays mixed, a record that cannot
// name its author or artifact — is an error, never zero comments: an empty result from a read
// that failed is exactly the shape that reads as "verified clean".
func DecodeCandidatePayload(raw []byte) ([]CandidateRecord, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	var (
		records          []CandidateRecord
		values           int
		sawObject, sawAr bool
	)
	for {
		var value json.RawMessage
		err := decoder.Decode(&value)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("payload is not well-formed JSON: %w", err)
		}
		values++
		trimmed := bytes.TrimSpace(value)
		var items []json.RawMessage
		switch {
		case bytes.HasPrefix(trimmed, []byte("{")):
			if sawObject || sawAr {
				return nil, errors.New("payload must be ONE comments object, or only arrays")
			}
			sawObject = true
			var probe map[string]json.RawMessage
			if err := json.Unmarshal(trimmed, &probe); err != nil {
				return nil, fmt.Errorf("payload object is unreadable: %w", err)
			}
			comments, ok := probe["comments"]
			if !ok || !bytes.HasPrefix(bytes.TrimSpace(comments), []byte("[")) {
				return nil, errors.New(`payload object carries no "comments" array`)
			}
			if err := json.Unmarshal(comments, &items); err != nil {
				return nil, fmt.Errorf(`"comments" is not an array: %w`, err)
			}
		case bytes.HasPrefix(trimmed, []byte("[")):
			if sawObject {
				return nil, errors.New("payload must be ONE comments object, or only arrays")
			}
			sawAr = true
			if err := json.Unmarshal(trimmed, &items); err != nil {
				return nil, fmt.Errorf("payload page is not an array: %w", err)
			}
		default:
			return nil, errors.New("payload is neither a comments object nor an array of comments")
		}
		for _, item := range items {
			index := len(records)
			if !bytes.HasPrefix(bytes.TrimSpace(item), []byte("{")) {
				return nil, fmt.Errorf("comment %d is not an object", index)
			}
			var record rawCandidate
			if err := json.Unmarshal(item, &record); err != nil {
				return nil, fmt.Errorf("comment %d is unreadable: %w", index, err)
			}
			bound, err := bindCandidate(record)
			if err != nil {
				return nil, fmt.Errorf("comment %d %w", index, err)
			}
			records = append(records, bound)
		}
	}
	if values == 0 {
		return nil, errors.New("empty payload")
	}
	return records, nil
}

// CandidateKind is a reported row's class.
type CandidateKind string

const (
	// MaintainerCandidate is an undisclosed exact-login comment with no sender marker.
	MaintainerCandidate CandidateKind = "maintainer"
	// SiblingCandidate is a sibling instance's undisclosed output (a leading sender marker).
	SiblingCandidate CandidateKind = "sibling"
)

// CandidateRow is one reported comment.
type CandidateRow struct {
	Kind      CandidateKind
	Artifact  ArtifactRef
	Login     string
	Created   string
	Gist      string
	Permalink string
}

// String renders the row in the digest's own shape. Every field comes from one record.
func (r CandidateRow) String() string {
	prefix := "CANDIDATE-MAINTAINER-"
	if r.Kind == SiblingCandidate {
		prefix = "CANDIDATE-SIBLING-"
	}
	surface := "ISSUE-COMMENT"
	if r.Artifact.PullRequest {
		surface = "COMMENT"
	}
	marker := ""
	if r.Kind == SiblingCandidate {
		marker = " (missing disclosure)"
	}
	return fmt.Sprintf("%s%s %s #%d%s — `%s` @%s: \"%s\" %s",
		prefix, surface, r.Artifact.Repo, r.Artifact.Number, marker, r.Login, r.Created, r.Gist, r.Permalink)
}

// CandidateScan is the outcome of one payload.
type CandidateScan struct {
	Author     string
	Rows       []CandidateRow
	Records    int
	Considered int
	Disclosed  int
	Empty      int
	Artifacts  []ArtifactRef
}

// Summary is the closing line. Its presence is what proves the payload was read in full.
func (s CandidateScan) Summary() string {
	maintainer, sibling := 0, 0
	for _, row := range s.Rows {
		if row.Kind == SiblingCandidate {
			sibling++
		} else {
			maintainer++
		}
	}
	artifacts := make([]string, 0, len(s.Artifacts))
	for _, artifact := range s.Artifacts {
		artifacts = append(artifacts, artifact.short())
	}
	covered := "none"
	if len(artifacts) > 0 {
		covered = strings.Join(artifacts, ",")
	}
	return fmt.Sprintf("CANDIDATE-SCAN author=%s records=%d considered=%d disclosed=%d maintainer=%d sibling=%d empty=%d artifacts=%s",
		s.Author, s.Records, s.Considered, s.Disclosed, maintainer, sibling, s.Empty, covered)
}

const gistLimit = 100

// gist is the comment's first OWN line: the maintainer quotes agent text when replying, so a
// leading quote is skipped when a later line exists. Control characters become spaces and
// double quotes become single ones, so the gist stays one parseable line.
func gist(body string) string {
	lines := nonEmptyLines(normalise(body))
	chosen := ""
	for _, line := range lines {
		if !strings.HasPrefix(line, ">") {
			chosen = line
			break
		}
	}
	if chosen == "" && len(lines) > 0 {
		chosen = lines[0]
	}
	cleaned := strings.Map(func(r rune) rune {
		switch {
		case r == '"':
			return '\''
		case unicode.IsControl(r):
			return ' '
		default:
			return r
		}
	}, chosen)
	return excerpt(strings.Join(strings.Fields(cleaned), " "), gistLimit)
}

// ScanCandidates classifies every record by the given login, in payload order.
func ScanCandidates(records []CandidateRecord, author string) CandidateScan {
	scan := CandidateScan{Author: author, Records: len(records)}
	seen := map[ArtifactRef]bool{}
	for _, record := range records {
		key := ArtifactRef{Owner: strings.ToLower(record.Artifact.Owner), Repo: strings.ToLower(record.Artifact.Repo), Number: record.Artifact.Number}
		if !seen[key] {
			seen[key] = true
			scan.Artifacts = append(scan.Artifacts, record.Artifact)
		}
		if record.Login != author {
			continue
		}
		scan.Considered++
		if strings.TrimSpace(record.Body) == "" {
			scan.Empty++
			continue
		}
		var kind CandidateKind
		switch Classify(record.Body) {
		case Compliant, TriggerExtraText:
			scan.Disclosed++
			continue
		case SenderMarker:
			kind = SiblingCandidate
		default:
			kind = MaintainerCandidate
		}
		scan.Rows = append(scan.Rows, CandidateRow{
			Kind:      kind,
			Artifact:  record.Artifact,
			Login:     record.Login,
			Created:   record.Created,
			Gist:      gist(record.Body),
			Permalink: record.Permalink,
		})
	}
	return scan
}

// runCandidates is the --candidates CLI. It decodes the WHOLE payload before printing, so an
// UNKNOWN never leaves partial rows behind that a reader could take for a complete answer.
func runCandidates(raw []byte, author string, stdout, stderr io.Writer) int {
	records, err := DecodeCandidatePayload(raw)
	if err != nil {
		fmt.Fprintf(stderr, "comment-disclosure-drift: UNKNOWN — %v\n", err)
		return 2
	}
	scan := ScanCandidates(records, author)
	var out strings.Builder
	for _, row := range scan.Rows {
		out.WriteString(row.String())
		out.WriteByte('\n')
	}
	out.WriteString(scan.Summary())
	out.WriteByte('\n')
	if _, err := io.WriteString(stdout, out.String()); err != nil {
		fmt.Fprintf(stderr, "comment-disclosure-drift: UNKNOWN — cannot write output: %v\n", err)
		return 2
	}
	return 0
}
