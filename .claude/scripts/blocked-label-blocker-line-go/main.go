// The blocker guard validates issue bodies as local data. Only the operator's
// validated --org argument selects a forge query; blocker identifiers never do.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
)

const help = `Verify open blocked-labelled issues carry a visible **Blocker:** record.

  **Blocker:** <identifier> | <blocker-kind> | last-verified <YYYY-MM-DD>: <result>
  **Blocker:** <what only the maintainer can do> | authority | last-verified <YYYY-MM-DD>: <result> | asked <pr|slack|session> <YYYY-MM-DD>

The blocker kind is upstream or authority. Explicit authority records may name
an account action, credential or permission in plain language. Legacy records
infer authority only from the literal identifier text "maintainer authority".
The independent provider outage cause belongs in the result, for example
"outage-cause=credentials/auth; access is still missing".
Ask channels: pr = draft PR; slack = the declared Slack channel; session = the
native ask tool in an interactive session. An issue comment alone is not an ask.

Sources (exactly one): --org <org> or --input <file>|-
Options: --today <YYYY-MM-DD> (default UTC today)
         --ask-max-age-days <n> (default 14)
         --quiet (findings only)
         --ask-digest (emit only the unasked authority blockers, oldest first,
                       as one consolidated sheet to deliver through a channel)
Exit: 0 conforms; 1 findings; 2 UNKNOWN (usage, unreadable or incomplete input).
`

var (
	orgRE          = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	dateRE         = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)
	identifierRE   = regexp.MustCompile(`#[0-9]+|maintainer authority|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+`)
	urlRE          = regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.-]*:[^\s]|//|www\.|[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.[A-Za-z]{2,}/)[^\s]*`)
	askRE          = regexp.MustCompile(`\| asked (pr|slack|session) ([0-9]{4}-[0-9]{2}-[0-9]{2})[\t ]*$`)
	verificationRE = regexp.MustCompile(`^([0-9]{4}-[0-9]{2}-[0-9]{2}): (.*)$`)
)

type options struct {
	org, input string
	today      time.Time
	maxAge     int64
	quiet      bool
	askDigest  bool
}

func civilDate(value string) (time.Time, error) {
	if !dateRE.MatchString(value) || strings.HasPrefix(value, "0000-") {
		return time.Time{}, errors.New("not a civil date")
	}
	return time.Parse("2006-01-02", value)
}

func arguments(args []string) (options, bool, error) {
	o := options{maxAge: 14}
	today := time.Now().UTC().Format("2006-01-02")
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--help", "-h":
			return o, true, nil
		case "--quiet":
			o.quiet = true
		case "--ask-digest":
			o.askDigest = true
		case "--org", "--input", "--today", "--ask-max-age-days":
			i++
			if i == len(args) {
				return o, false, fmt.Errorf("%s requires a value", arg)
			}
			value := args[i]
			switch arg {
			case "--org":
				o.org = value
			case "--input":
				o.input = value
			case "--today":
				today = value
			case "--ask-max-age-days":
				if len(value) > 9 {
					return o, false, errors.New("--ask-max-age-days must have at most 9 digits")
				}
				if value == "" || strings.IndexFunc(value, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
					return o, false, errors.New("--ask-max-age-days must be a non-negative integer")
				}
				o.maxAge, _ = strconv.ParseInt(value, 10, 64)
			}
		default:
			return o, false, fmt.Errorf("unknown argument %q", arg)
		}
	}
	if (o.org == "") == (o.input == "") {
		return o, false, errors.New("exactly one of --org or --input is required")
	}
	if o.org != "" && !orgRE.MatchString(o.org) {
		return o, false, errors.New("--org must match [A-Za-z0-9._-]+")
	}
	var err error
	o.today, err = civilDate(today)
	if err != nil {
		return o, false, errors.New("--today must be a real YYYY-MM-DD calendar date")
	}
	return o, false, nil
}

// visibleRecord retains the existing Markdown contract: the first visible,
// column-zero marker continues until a blank line or a fence. Comments are
// stripped only outside fences; their literal contents cannot forge a close.
func visibleRecord(body string) string {
	var record string
	var fence byte
	var fenceLength int
	inComment := false
	for _, raw := range strings.Split(body, "\n") {
		line := strings.TrimSuffix(raw, "\r")
		if fence == 0 {
			var visible strings.Builder
			for line != "" {
				if inComment {
					end := strings.Index(line, "-->")
					if end < 0 {
						break
					}
					line = line[end+3:]
					inComment = false
				} else {
					start := strings.Index(line, "<!--")
					if start < 0 {
						visible.WriteString(line)
						break
					}
					visible.WriteString(line[:start])
					line = line[start+4:]
					inComment = true
				}
			}
			line = visible.String()
		}
		candidate := strings.TrimLeft(line, " \t")
		indent := len(line) - len(candidate)
		if indent <= 3 && len(candidate) >= 3 && (candidate[0] == '`' || candidate[0] == '~') {
			ch := candidate[0]
			n := 0
			for n < len(candidate) && candidate[n] == ch {
				n++
			}
			if n >= 3 {
				if fence == 0 {
					if record != "" {
						return record
					}
					fence = ch
					fenceLength = n
					continue
				}
				if ch == fence && n >= fenceLength && strings.Trim(candidate[n:], " \t") == "" {
					fence = 0
					continue
				}
			}
		}
		if fence != 0 {
			continue
		}
		if record != "" {
			if strings.Trim(line, " \t") == "" {
				return record
			}
			record += " " + strings.TrimLeft(line, " \t")
		} else if strings.HasPrefix(line, "**Blocker:**") {
			record = line
		}
	}
	return record
}

// classify separates blocker kind (who can clear it) from the result's outage
// cause (why a provider stopped serving). Delimiter cardinality is checked before
// reading the kind, so an extra segment cannot turn authority into upstream.
func classify(line string, today time.Time, maxAge int64) (string, bool) {
	if line == "" {
		return "MISSING", false
	}
	if !strings.HasPrefix(line, "**Blocker:** ") || strings.IndexFunc(line, func(r rune) bool { return unicode.IsControl(r) && r != '\t' }) >= 0 {
		return "MALFORMED", false
	}
	parts := strings.Split(line, " | last-verified ")
	if len(parts) != 2 {
		return "MALFORMED", false
	}
	head := strings.Split(strings.TrimPrefix(parts[0], "**Blocker:** "), " | ")
	if len(head) > 2 {
		return "MALFORMED", false
	}
	for _, segment := range head {
		if strings.Contains(segment, "|") {
			return "MALFORMED", false
		}
	}
	legacy := len(head) == 1
	kind := "upstream"
	if legacy {
		if strings.Contains(head[0], "maintainer authority") {
			kind = "authority"
		}
	} else {
		kind = head[1]
		if kind != "upstream" && kind != "authority" {
			return "MALFORMED", false
		}
	}
	identifier := strings.TrimSpace(urlRE.ReplaceAllString(head[0], ""))
	if !legacy && kind == "authority" {
		// An explicit authority kind makes plain descriptive text unambiguous.
		if !identifierRE.MatchString(identifier) && strings.IndexFunc(identifier, unicode.IsLetter) < 0 {
			return "MALFORMED", false
		}
	} else if !identifierRE.MatchString(identifier) {
		return "MALFORMED", false
	}
	verification := verificationRE.FindStringSubmatch(parts[1])
	if verification == nil {
		return "MALFORMED", false
	}
	if _, err := civilDate(verification[1]); err != nil {
		return "MALFORMED", false
	}
	result := strings.SplitN(verification[2], "| asked ", 2)[0]
	if strings.TrimSpace(result) == "" {
		return "MALFORMED", false
	}
	if kind == "upstream" {
		return "CONFORMS", legacy
	}
	ask := askRE.FindStringSubmatch(line)
	if ask == nil {
		return "NO-ASK", legacy
	}
	askDate, err := civilDate(ask[2])
	if err != nil || askDate.After(today) {
		return "MALFORMED", legacy
	}
	// Unix days avoid time.Duration's roughly 290-year subtraction limit.
	age := today.Unix()/86400 - askDate.Unix()/86400
	if age > maxAge {
		return "STALE-ASK", legacy
	}
	return "CONFORMS", legacy
}

// askRow is one unasked authority blocker, rendered for a maintainer rather
// than for a checker: what is being requested, and how long it has waited.
type askRow struct {
	repo     string
	number   int64
	created  string
	age      int64
	agedKnow bool
	request  string
}

// askRequest renders what the maintainer is actually being asked to do -- the
// identifier segment of the blocker line. The body stays untrusted data, so it
// is bounded and control-stripped exactly as the verdict report's snippet is.
func askRequest(line string) string {
	text := strings.SplitN(strings.TrimPrefix(line, "**Blocker:** "), " | ", 2)[0]
	runes := []rune(strings.TrimSpace(text))
	if len(runes) > 100 {
		runes = runes[:100]
	}
	safe := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return unicode.ReplacementChar
		}
		return r
	}, string(runes))
	if safe == "" {
		return "(no description in record)"
	}
	return safe
}

// issueAge reports whole days open. A missing or unparseable creation date is
// not fatal: the ask is still owed, so the row is kept and marked unknown.
func issueAge(createdAt string, today time.Time) (int64, bool) {
	if len(createdAt) < 10 {
		return 0, false
	}
	created, err := civilDate(createdAt[:10])
	if err != nil {
		return 0, false
	}
	return today.Unix()/86400 - created.Unix()/86400, true
}

// askDigestReport renders the consolidated sheet. Oldest first, because the
// age is the argument: a blocker nobody can clear without the maintainer only
// gets worse by being re-verified.
func askDigestReport(rows []askRow) string {
	if len(rows) == 0 {
		return "ASK DIGEST -- no authority blocker is awaiting an ask.\n"
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.agedKnow != b.agedKnow {
			return a.agedKnow // undated rows sort last
		}
		if a.agedKnow && a.age != b.age {
			return a.age > b.age
		}
		if a.repo != b.repo {
			return a.repo < b.repo
		}
		return a.number < b.number
	})
	var out strings.Builder
	_, _ = fmt.Fprintf(&out, "ASK DIGEST -- %d authority blocker(s) awaiting a maintainer decision.\n", len(rows))
	_, _ = fmt.Fprint(&out, "Deliver one ask through a canonical channel (pr | slack | session), then append\n")
	_, _ = fmt.Fprint(&out, "\"| asked <channel> <YYYY-MM-DD>\" to each **Blocker:** line below.\n\n")
	for _, r := range rows {
		age := "age unknown"
		if r.agedKnow {
			age = fmt.Sprintf("opened %s  %dd", r.created, r.age)
		}
		_, _ = fmt.Fprintf(&out, "  %s#%d  %s\n    %s\n", r.repo, r.number, age, r.request)
	}
	return out.String()
}

type issue struct {
	Repo          string `json:"repo"`
	Number        int64  `json:"number"`
	Body          string `json:"body"`
	RepositoryURL string `json:"repository_url"`
	CreatedAt     string `json:"created_at"`
}

func inputIssues(raw []byte) ([]issue, error) {
	if !strings.HasPrefix(strings.TrimSpace(string(raw)), "[") {
		return nil, errors.New("payload is not a JSON array -- UNKNOWN")
	}
	var issues []issue
	if err := json.Unmarshal(raw, &issues); err != nil {
		return nil, errors.New("could not parse payload -- UNKNOWN")
	}
	return issues, nil
}

// searchIssues decodes every concatenated page from gh --paginate. Count and
// completeness are independent requirements; partial results never mean zero.
func searchIssues(raw []byte) ([]issue, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	expected := -1
	var issues []issue
	for {
		var page struct {
			Total      *int    `json:"total_count"`
			Incomplete *bool   `json:"incomplete_results"`
			Items      []issue `json:"items"`
		}
		err := decoder.Decode(&page)
		if err == io.EOF {
			break
		}
		if err != nil || page.Total == nil || page.Incomplete == nil || page.Items == nil || *page.Total < 0 {
			return nil, errors.New("unreadable search page -- UNKNOWN")
		}
		if *page.Incomplete {
			return nil, errors.New("search reported incomplete_results -- UNKNOWN")
		}
		if expected >= 0 && expected != *page.Total {
			return nil, errors.New("search total_count changed -- UNKNOWN")
		}
		expected = *page.Total
		for _, item := range page.Items {
			item.Repo = item.RepositoryURL[strings.LastIndex(item.RepositoryURL, "/")+1:]
			issues = append(issues, item)
		}
	}
	if expected < 0 || len(issues) != expected {
		return nil, errors.New("truncated search read -- UNKNOWN")
	}
	return issues, nil
}

func load(o options, stdin io.Reader) ([]issue, error) {
	if o.input != "" {
		var raw []byte
		var err error
		if o.input == "-" {
			raw, err = io.ReadAll(stdin)
		} else {
			raw, err = os.ReadFile(o.input)
		}
		if err != nil {
			return nil, errors.New("could not read payload -- UNKNOWN")
		}
		return inputIssues(raw)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	endpoint := "search/issues?q=org:" + o.org + "+is:issue+state:open+label:blocked+archived:false&per_page=100"
	raw, err := exec.CommandContext(ctx, "gh", "api", endpoint, "--paginate").Output()
	if err != nil {
		return nil, errors.New("forge read failed -- UNKNOWN, never zero")
	}
	return searchIssues(raw)
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	unknown := func(err error) int {
		// A failed diagnostic write cannot change the UNKNOWN exit status.
		_, _ = fmt.Fprintln(stderr, "blocked-label-blocker-line.sh:", err)
		return 2
	}
	emit := func(report string, code int) int {
		if report != "" {
			if _, err := io.WriteString(stdout, report); err != nil {
				return unknown(fmt.Errorf("could not write report -- UNKNOWN: %w", err))
			}
		}
		return code
	}
	o, wantsHelp, err := arguments(args)
	if err != nil {
		return unknown(err)
	}
	if wantsHelp {
		return emit(help, 0)
	}
	issues, err := load(o, stdin)
	if err != nil {
		return unknown(err)
	}
	// Validate all records before emitting a partial report.
	for i, item := range issues {
		if item.Repo == "" || item.Number <= 0 || strings.IndexFunc(item.Repo, unicode.IsControl) >= 0 {
			return unknown(fmt.Errorf("record %d is missing or has invalid repo or number -- UNKNOWN", i))
		}
	}
	// Builder writes cannot fail. Check the external writer once the complete
	// report is ready, so an undelivered report never returns a valid verdict.
	var report strings.Builder
	var askRows []askRow
	bad := 0
	for _, item := range issues {
		line := visibleRecord(item.Body)
		verdict, legacy := classify(line, o.today, o.maxAge)
		if verdict == "NO-ASK" {
			age, known := issueAge(item.CreatedAt, o.today)
			created := ""
			if known {
				created = item.CreatedAt[:10]
			}
			askRows = append(askRows, askRow{
				repo: item.Repo, number: item.Number, created: created,
				age: age, agedKnow: known, request: askRequest(line),
			})
		}
		if verdict == "CONFORMS" && o.quiet {
			continue
		}
		_, _ = fmt.Fprintf(&report, "%-10s %s#%d", verdict, item.Repo, item.Number)
		if legacy {
			_, _ = fmt.Fprint(&report, "  [legacy: no class token]")
		}
		if verdict != "CONFORMS" {
			bad++
			if line != "" {
				snippet := []rune(line)
				if len(snippet) > 100 {
					snippet = snippet[:100]
				}
				// Malformed bodies are still untrusted: reporting a rejected control
				// must not execute it in the operator's terminal.
				safe := strings.Map(func(r rune) rune {
					if unicode.IsControl(r) {
						return unicode.ReplacementChar
					}
					return r
				}, string(snippet))
				_, _ = fmt.Fprintf(&report, "  >>%s", safe)
			}
		}
		_, _ = fmt.Fprintln(&report)
	}
	// The digest replaces the verdict report for its own consumer, but never
	// the verdict: a malformed record is still a finding when no ask is owed.
	if o.askDigest {
		code := 0
		if bad > 0 {
			code = 1
		}
		return emit(askDigestReport(askRows), code)
	}
	if bad > 0 {
		if !o.quiet {
			_, _ = fmt.Fprintf(&report, "\nblocked-label-blocker-line.sh: %d of %d open blocked-labelled issue(s) need repair (missing, malformed, or an unraised authority blocker).\n", bad, len(issues))
		}
		return emit(report.String(), 1)
	}
	if !o.quiet {
		_, _ = fmt.Fprintf(&report, "\nblocked-label-blocker-line.sh: all %d open blocked-labelled issue(s) carry a conforming **Blocker:** line.\n", len(issues))
	}
	return emit(report.String(), 0)
}

func main() {
	// Let failed stdout/stderr writes reach run's UNKNOWN handling instead of
	// terminating the process before it can return the documented exit status.
	signal.Ignore(syscall.SIGPIPE)
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
