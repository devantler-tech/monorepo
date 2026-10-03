// The blocker guard validates issue bodies as local data. Only the operator's
// validated --org argument selects a forge query; blocker identifiers never do.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
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

const help = `Verify open blocked-labelled issues carry a visible **Blocker:** record, that
no open issue declares a blocker without carrying the blocked label, and that
no Security issue is left unstarted with no record of why.

  **Blocker:** <identifier> | <blocker-kind> | last-verified <YYYY-MM-DD>: <result>
  **Blocker:** <what only the maintainer can do> | authority | last-verified <YYYY-MM-DD>: <result> | asked <pr|slack|session> <YYYY-MM-DD>

The blocker kind is upstream or authority. Explicit authority records may name
an account action, credential or permission in plain language. Legacy records
infer authority only from the literal identifier text "maintainer authority".
The independent provider outage cause belongs in the result, for example
"outage-cause=credentials/auth; access is still missing".
Ask channels: pr = draft PR; slack = the declared Slack channel; session = the
native ask tool in an interactive session. An issue comment alone is not an ask.

An UNLABELLED row is an issue whose visible record declares a blocker while the
issue has no blocked label; "**Blocker:** none ..." declares none and is skipped.

An UNRECORDED row is a Security issue that nobody has started and that carries
no reason for it. Unstarted: opened longer ago than the bound, no assignee, no
open sub-issue, and no open pull request mentions it. No reason: no blocked
label, no **Blocker:** record of any kind, and no open native blocker. An issue
a dependency bot opened is the bot's own and is never reported. Only Security is
read this way: it outranks every other issue whatever its age, so an unstarted
one was passed over, while an older issue of another type may simply not have
been reached yet.

Sources (exactly one): --org <org> (every open issue, label or not, and every
                       open pull request, for the issues it mentions) or
         --input <file>|- (a JSON array; a record without a "labels" array is
                       read as blocked-labelled, the shape of earlier payloads,
                       and one with a "pull_request" key is a pull request)
Options: --today <YYYY-MM-DD> (default UTC today)
         --ask-max-age-days <n> (default 14)
         --verify-max-age-days <n> (default 7; an otherwise conforming record
                       whose last-verified date is older is reported STALE,
                       because skipping a blocked issue needs a live check)
         --unrecorded-max-age-days <n> (default 7; how long a Security issue
                       may stay unstarted before it needs a record)
         --quiet (findings only)
         --ask-digest (emit declared authority blockers with missing or stale
                       ask records, oldest first, for verification before
                       asking the maintainer)
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
	org, input       string
	today            time.Time
	maxAge           int64
	verifyMaxAge     int64
	unrecordedMaxAge int64
	quiet            bool
	askDigest        bool
}

func civilDate(value string) (time.Time, error) {
	if !dateRE.MatchString(value) || strings.HasPrefix(value, "0000-") {
		return time.Time{}, errors.New("not a civil date")
	}
	return time.Parse("2006-01-02", value)
}

func arguments(args []string) (options, bool, error) {
	o := options{maxAge: 14, verifyMaxAge: 7, unrecordedMaxAge: 7}
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
		case "--org", "--input", "--today", "--ask-max-age-days", "--verify-max-age-days", "--unrecorded-max-age-days":
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
			case "--ask-max-age-days", "--verify-max-age-days", "--unrecorded-max-age-days":
				if len(value) > 9 {
					return o, false, fmt.Errorf("%s must have at most 9 digits", arg)
				}
				if value == "" || strings.IndexFunc(value, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
					return o, false, fmt.Errorf("%s must be a non-negative integer", arg)
				}
				days, _ := strconv.ParseInt(value, 10, 64)
				switch arg {
				case "--ask-max-age-days":
					o.maxAge = days
				case "--verify-max-age-days":
					o.verifyMaxAge = days
				default:
					o.unrecordedMaxAge = days
				}
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
	// A future verification date cannot be fresh evidence, so it is never read as one.
	if verified, err := civilDate(verification[1]); err != nil || verified.After(today) {
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

// staleVerification reports whether an otherwise conforming record was last
// verified more than maxAge days before today. A blocker skip requires a live
// re-verification on every run, and a `blocked` label never expires, so a
// record nobody has re-checked can park an issue indefinitely while its shape
// still conforms (#3161). Callers apply it only to records classify accepted,
// which already rejects an unparseable or future date.
func staleVerification(line string, today time.Time, maxAge int64) bool {
	parts := strings.Split(line, " | last-verified ")
	if len(parts) != 2 {
		return false
	}
	verification := verificationRE.FindStringSubmatch(parts[1])
	if verification == nil {
		return false
	}
	verified, err := civilDate(verification[1])
	if err != nil {
		return false
	}
	return today.Unix()/86400-verified.Unix()/86400 > maxAge
}

// askRow is one declared authority blocker with a missing or stale ask record.
// The declaration still needs verification before asking the maintainer.
type askRow struct {
	repo     string
	number   int64
	created  string
	age      int64
	agedKnow bool
	request  string
	stale    bool // asked once, but the ask has since gone stale
	legacy   bool // authority inferred from prose, not an explicit class token
	opaque   bool // the record names an identifier but no concrete action
}

var ghReferenceRE = regexp.MustCompile(`(?i)gh-[0-9]+`)

// neutralize breaks GitHub's active syntax in untrusted text. The digest is
// built to be pasted into a PR, Slack or a session, and no Markdown construct
// hides a mention from a bot -- bots parse the raw text -- so the token itself
// must stop being a live mention, command or autolink. URL spans are omitted;
// zero-width spaces leave mention/reference/command text readable without live tokens.
func neutralize(s string) string {
	s = urlRE.ReplaceAllString(s, "[URL omitted]")
	s = ghReferenceRE.ReplaceAllStringFunc(s, func(reference string) string {
		return reference[:1] + "\u200b" + reference[1:]
	})
	var out strings.Builder
	for i, r := range s {
		out.WriteRune(r)
		if r != '@' && r != '#' && r != '/' {
			continue
		}
		rest := s[i+len(string(r)):]
		if next := []rune(rest); len(next) > 0 && (unicode.IsLetter(next[0]) || unicode.IsDigit(next[0])) {
			out.WriteRune('​')
		}
	}
	return out.String()
}

// identifierOnlyRE matches a record whose identifier names a thing but no
// action -- a bare issue reference, a repository reference, or the legacy
// phrase alone.
var identifierOnlyRE = regexp.MustCompile(`^(#[0-9]+|(?i:gh)-[0-9]+|[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?#[0-9]+|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+|maintainer authority)[.,;:]?$`)

// askRequest renders what the maintainer is actually being asked to do -- the
// identifier segment of the blocker line. The body stays untrusted data, so it
// is bounded and control-stripped exactly as the verdict report's snippet is.
func askRequest(line string) string {
	return digestText(strings.SplitN(strings.TrimPrefix(line, "**Blocker:** "), " | ", 2)[0])
}

// digestText bounds and renders every input-authored digest field as inert
// Markdown, including repository names supplied through --input.
func digestText(text string) string {
	// Decode before bounding and stripping controls so Markdown destinations
	// cannot hide schemes or introduce a newline after sanitization.
	text = html.UnescapeString(text)
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
	// Keep Markdown links and HTML inert, including nested entities and an
	// existing backslash that could otherwise unescape an opening bracket.
	return strings.NewReplacer(
		`\`, `\\`, "[", `\[`, "<", "&lt;", ">", "&gt;", "&", "&amp;",
	).Replace(neutralize(safe))
}

// requestIsOpaque reports a record that names an identifier but no action a
// maintainer could actually perform. Delivering such a row and recording it as
// asked would mark a non-actionable message as delivered.
func requestIsOpaque(line string) bool {
	text := strings.SplitN(strings.TrimPrefix(line, "**Blocker:** "), " | ", 2)[0]
	text = html.UnescapeString(text)
	return identifierOnlyRE.MatchString(strings.TrimSpace(text))
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

const digestDisclosure = "> 🤖 Generated by the Agentic Engineer\n\n"

// askDigestReport renders declarations oldest first for verification. Issue
// text and ask records do not establish that the maintainer must act.
func askDigestReport(rows []askRow) string {
	if len(rows) == 0 {
		return digestDisclosure + "ASK DIGEST -- no declared authority blocker has a missing or stale ask record.\n"
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
	seen := map[string]bool{}
	var repos []string
	for _, r := range rows {
		if !seen[r.repo] {
			seen[r.repo] = true
			repos = append(repos, digestText(r.repo))
		}
	}
	sort.Strings(repos)
	var out strings.Builder
	// The sheet is built to be delivered. Slack authenticates as the
	// maintainer's own account, so without a leading disclosure a pasted digest
	// reads as him writing to himself.
	_, _ = fmt.Fprint(&out, digestDisclosure)
	_, _ = fmt.Fprintf(&out, "ASK DIGEST -- %d declared authority blocker(s) to verify before asking for a maintainer action.\n", len(rows))
	_, _ = fmt.Fprint(&out, "Verify current capabilities and prerequisites; complete work the agent can perform.\n")
	_, _ = fmt.Fprint(&out, "Only for a remaining maintainer-only action, deliver an ask through a canonical channel\n")
	_, _ = fmt.Fprint(&out, "(pr | slack | session), then append `| asked <channel> <YYYY-MM-DD>` to that issue's **Blocker:** line.\n")
	// Repository visibility is not in the search payload, so this tool cannot
	// establish it. Say so rather than let a private row reach a public PR.
	_, _ = fmt.Fprint(&out, "CHECK BEFORE DELIVERY: this tool does not establish repository visibility.\n")
	_, _ = fmt.Fprintf(&out, "Treat these rows as private until each repository is confirmed public: %s\n", strings.Join(repos, ", "))
	_, _ = fmt.Fprint(&out, "Descriptions are quoted untrusted issue text with mentions broken and URLs omitted.\n\n")
	for _, r := range rows {
		age := "age unknown"
		if r.agedKnow {
			age = fmt.Sprintf("opened %s  %dd", r.created, r.age)
		}
		kind := "no ask recorded"
		if r.stale {
			kind = "ask record is stale -- verify before renewing"
		}
		notes := ""
		if r.legacy {
			notes += "  [legacy: no class token]"
		}
		if r.opaque {
			notes += "  [NO ACTION DESCRIBED -- reopen the issue before delivering]"
		}
		_, _ = fmt.Fprintf(&out, "  %s#\u200b%d  %s  (%s)%s\n  > %s\n", digestText(r.repo), r.number, age, kind, notes, r.request)
	}
	return out.String()
}

type issue struct {
	Repo          string `json:"repo"`
	Number        int64  `json:"number"`
	Body          string `json:"body"`
	RepositoryURL string `json:"repository_url"`
	CreatedAt     string `json:"created_at"`
	// Labels is nil when the record carries no "labels" array at all. Only an
	// --input record may omit it (see blocked); a forge record must carry one.
	Labels *[]struct {
		Name string `json:"name"`
	} `json:"labels"`
	// The rest decides whether an unlabelled issue with no record is being
	// skipped or is simply new, held or in flight (see unrecorded). Type stays
	// raw so a forge record without the key can be told from an untyped issue.
	Type      json.RawMessage   `json:"type"`
	Assignees []json.RawMessage `json:"assignees"`
	User      struct {
		Login string `json:"login"`
	} `json:"user"`
	Dependencies struct {
		BlockedBy int64 `json:"blocked_by"`
	} `json:"issue_dependencies_summary"`
	SubIssues struct {
		Total     int64 `json:"total"`
		Completed int64 `json:"completed"`
	} `json:"sub_issues_summary"`
	// PullRequest is the key search puts on a pull request and on nothing else.
	// A pull request is never judged as an issue: its body is read for the
	// issues it mentions. pull is set by the loaders, from that key or from the
	// read the record came from.
	PullRequest json.RawMessage `json:"pull_request"`
	pull        bool
}

// unrecordedType is the one issue type whose age proves it was passed over: a
// Security issue outranks every other issue regardless of age, so one still
// unstarted after the bound was passed over by every run that started anything
// else. An older issue of another type may be queued behind older ones in its
// own rung, so reading those the same way would report the backlog (#3415).
const unrecordedType = "Security"

// dependencyBots are the two dependency-automation authors as the search
// surface names them. An issue one of them opened is a control surface the bot
// owns: it is never agent work, so it is never one that was passed over.
var dependencyBots = map[string]bool{"renovate[bot]": true, "dependabot[bot]": true}

// typeName reads the issue type's name. An absent or null type is an untyped
// issue; anything else must be an object that names its type, so a shape this
// guard does not know is refused instead of read as "not Security".
func (i issue) typeName() (string, error) {
	if len(i.Type) == 0 || string(i.Type) == "null" {
		return "", nil
	}
	var named struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(i.Type, &named); err != nil || named.Name == "" {
		return "", errors.New("unreadable type")
	}
	return named.Name, nil
}

// mentioned reports whether an open pull request refers to the issue: a bare
// #N from its own repository, or <owner>/<repo>#N or .../<repo>/issues/N from
// anywhere. Any mention counts, not only a closing keyword, because a pull
// request that says "Part of #N" is work on the issue too. Bodies are
// untrusted, and are only matched against the issue's own name and number.
func mentioned(item issue, pulls []issue) bool {
	number := strconv.FormatInt(item.Number, 10)
	bare := regexp.MustCompile(`(^|[^A-Za-z0-9._/-])#` + number + `($|[^0-9])`)
	qualified := regexp.MustCompile(`(?i)(^|[^A-Za-z0-9._-])[A-Za-z0-9._-]+/` + regexp.QuoteMeta(item.Repo) + `(#|/issues/)` + number + `($|[^0-9])`)
	for _, pull := range pulls {
		if qualified.MatchString(pull.Body) || (strings.EqualFold(pull.Repo, item.Repo) && bare.MatchString(pull.Body)) {
			return true
		}
	}
	return false
}

// unrecorded reports whether an unlabelled issue with no record is plausibly
// being skipped, and how many days it has been open. What clears it is what
// the contract already treats as a visible reason not to start an issue: an
// open pull request and an open native blocker are live structured facts, an
// assignee holds it, and open sub-issues carry a decomposed one. A blocker of
// any other kind needs the label and record the caller has just found missing.
// An age that cannot be read is UNKNOWN: it is not shown to be within the bound.
func unrecorded(item issue, pulls []issue, today time.Time, maxAge int64) (int64, bool, error) {
	// run has already refused a record whose type cannot be read.
	name, _ := item.typeName()
	if !strings.EqualFold(name, unrecordedType) || dependencyBots[item.User.Login] || len(item.Assignees) > 0 ||
		item.Dependencies.BlockedBy > 0 || item.SubIssues.Total > item.SubIssues.Completed || mentioned(item, pulls) {
		return 0, false, nil
	}
	age, known := issueAge(item.CreatedAt, today)
	if !known {
		return 0, false, fmt.Errorf("%s#%d has no readable created_at, so its age is unproven -- UNKNOWN", item.Repo, item.Number)
	}
	return age, age > maxAge, nil
}

// blocked reports whether the issue carries the blocked label. An --input
// record without a labels array predates the label-independent enumeration,
// when every payload was the label:blocked search result, so it reads as
// labelled; searchIssues refuses a forge record without one.
func (i issue) blocked() bool {
	if i.Labels == nil {
		return true
	}
	for _, label := range *i.Labels {
		// Search matches labels case-insensitively, so the earlier label:blocked
		// read included a "Blocked" label; keep reading it as labelled.
		if strings.EqualFold(label.Name, "blocked") {
			return true
		}
	}
	return false
}

// "none" must be a whole word: followed by the end, whitespace, or prose
// punctuation that is itself followed by whitespace. An identifier that merely
// begins with none (none/repo#7, none.io/x, none-x) still declares a blocker.
var noBlockerRE = regexp.MustCompile(`(?i)^\*\*Blocker:\*\*[\t ]*none([\t ]|[—–]|[.,;:!]([\t ]|$)|$)`)

// declaresBlocker reports whether a visible record names a blocker. The
// "**Blocker:** none -- agent-actionable" form declares that there is none, and
// an issue carrying it is correctly unlabelled (#3142).
func declaresBlocker(line string) bool {
	return line != "" && !noBlockerRE.MatchString(line)
}

func inputIssues(raw []byte) ([]issue, error) {
	if !strings.HasPrefix(strings.TrimSpace(string(raw)), "[") {
		return nil, errors.New("payload is not a JSON array -- UNKNOWN")
	}
	var issues []issue
	if err := json.Unmarshal(raw, &issues); err != nil {
		return nil, errors.New("could not parse payload -- UNKNOWN")
	}
	for i := range issues {
		issues[i].pull = len(issues[i].PullRequest) > 0 && string(issues[i].PullRequest) != "null"
	}
	return issues, nil
}

// searchIssues decodes every concatenated page from gh --paginate. Count and
// completeness are independent requirements; partial results never mean zero.
// typed is set for the issue read, whose items must each carry a type key.
func searchIssues(raw []byte, typed bool) ([]issue, error) {
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
			// Without labels an unlabelled issue would read as labelled and its
			// declared blocker would never be compared against the label.
			if item.Labels == nil {
				return nil, errors.New("search item without labels -- UNKNOWN")
			}
			// The forge sends the key on every issue, null when untyped. Without
			// it every issue would read as untyped and none as unrecorded.
			if typed && len(item.Type) == 0 {
				return nil, errors.New("search item without type -- UNKNOWN")
			}
			item.pull = !typed
			item.Repo = item.RepositoryURL[strings.LastIndex(item.RepositoryURL, "/")+1:]
			issues = append(issues, item)
		}
	}
	if expected < 0 || len(issues) != expected {
		return nil, errors.New("truncated search read -- UNKNOWN")
	}
	return issues, nil
}

// searchEndpoint reads every open issue, not only label:blocked ones: a
// declared blocker without the label is invisible to a label-filtered read
// (#3142). Search serves at most 1000 results, so a larger org fails
// searchIssues' count check rather than reading as complete.
func searchEndpoint(org string) string {
	return "search/issues?q=org:" + org + "+is:issue+state:open+archived:false&per_page=100"
}

// pullEndpoint reads every open pull request, draft or not. Their bodies say
// which issues are in flight: without them an issue whose draft has waited a
// week for review would read as unstarted (#3415).
func pullEndpoint(org string) string {
	return "search/issues?q=org:" + org + "+is:pr+state:open+archived:false&per_page=100"
}

// forgeRead is the one place the guard reaches the forge; tests replace it.
var forgeRead = func(endpoint string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "gh", "api", endpoint, "--paginate").Output()
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
	// Two reads, each complete or the whole result UNKNOWN: the issues to
	// judge, then the pull requests that show which of them are in flight.
	var records []issue
	for _, read := range []struct {
		endpoint string
		typed    bool
	}{{searchEndpoint(o.org), true}, {pullEndpoint(o.org), false}} {
		raw, err := forgeRead(read.endpoint)
		if err != nil {
			return nil, errors.New("forge read failed -- UNKNOWN, never zero")
		}
		page, err := searchIssues(raw, read.typed)
		if err != nil {
			return nil, err
		}
		records = append(records, page...)
	}
	return records, nil
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
	records, err := load(o, stdin)
	if err != nil {
		return unknown(err)
	}
	// Validate all records before emitting a partial report.
	var issues, pulls []issue
	for i, item := range records {
		if item.Repo == "" || item.Number <= 0 || strings.IndexFunc(item.Repo, unicode.IsControl) >= 0 {
			return unknown(fmt.Errorf("record %d is missing or has invalid repo or number -- UNKNOWN", i))
		}
		if _, err := item.typeName(); err != nil {
			return unknown(fmt.Errorf("record %d has an unreadable type -- UNKNOWN", i))
		}
		if item.pull {
			pulls = append(pulls, item)
		} else {
			issues = append(issues, item)
		}
	}
	// Builder writes cannot fail. Check the external writer once the complete
	// report is ready, so an undelivered report never returns a valid verdict.
	var report strings.Builder
	var askRows []askRow
	bad, labelled, unlabelled, parked := 0, 0, 0, 0
	for _, item := range issues {
		line := visibleRecord(item.Body)
		if !item.blocked() {
			if declaresBlocker(line) {
				bad++
				unlabelled++
				_, _ = fmt.Fprintf(&report, "%-10s %s#%d  >>%s\n", "UNLABELLED", item.Repo, item.Number, snippet(line))
				continue
			}
			// "**Blocker:** none" is a record too: it says the issue is actionable.
			if line != "" {
				continue
			}
			// With no record, content cannot tell a skipped issue from ordinary
			// work (#3142). Its rung, its age and what is in flight can (#3415).
			age, finding, err := unrecorded(item, pulls, o.today, o.unrecordedMaxAge)
			if err != nil {
				return unknown(err)
			}
			if finding {
				bad++
				parked++
				_, _ = fmt.Fprintf(&report, "%-10s %s#%d  opened %s, unstarted for %d day(s) with no record\n", "UNRECORDED", item.Repo, item.Number, item.CreatedAt[:10], age)
			}
			continue
		}
		labelled++
		verdict, legacy := classify(line, o.today, o.maxAge)
		if verdict == "CONFORMS" && staleVerification(line, o.today, o.verifyMaxAge) {
			verdict = "STALE"
		}
		// Include stale ask records so their current need is verified alongside
		// missing records, without treating either as proof the maintainer must act.
		if verdict == "NO-ASK" || verdict == "STALE-ASK" {
			age, known := issueAge(item.CreatedAt, o.today)
			created := ""
			if known {
				created = item.CreatedAt[:10]
			}
			askRows = append(askRows, askRow{
				repo: item.Repo, number: item.Number, created: created,
				age: age, agedKnow: known, request: askRequest(line),
				stale: verdict == "STALE-ASK", legacy: legacy,
				opaque: requestIsOpaque(line),
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
				_, _ = fmt.Fprintf(&report, "  >>%s", snippet(line))
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
		digest := askDigestReport(askRows)
		if other := bad - len(askRows); other > 0 {
			digest += fmt.Sprintf("\n%d finding(s) outside this digest. Run without `--ask-digest` to inspect the verdict report.\n", other)
		}
		return emit(digest, code)
	}
	if bad > 0 {
		if !o.quiet {
			if labelledBad := bad - unlabelled - parked; labelledBad > 0 {
				_, _ = fmt.Fprintf(&report, "\nblocked-label-blocker-line.sh: %d of %d open blocked-labelled issue(s) need repair (missing, malformed, not re-verified recently, or an unraised authority blocker).\n", labelledBad, labelled)
			}
			if unlabelled > 0 {
				_, _ = fmt.Fprintf(&report, "\nblocked-label-blocker-line.sh: %d open issue(s) declare a blocker without the blocked label: re-verify each, then label it or unblock it.\n", unlabelled)
			}
			if parked > 0 {
				_, _ = fmt.Fprintf(&report, "\nblocked-label-blocker-line.sh: %d open %s issue(s) have gone unstarted for more than %d day(s) with no record: start each, or record what blocks it.\n", parked, unrecordedType, o.unrecordedMaxAge)
			}
		}
		return emit(report.String(), 1)
	}
	if !o.quiet {
		_, _ = fmt.Fprintf(&report, "\nblocked-label-blocker-line.sh: all %d open blocked-labelled issue(s) carry a conforming **Blocker:** line, no unlabelled issue declares a blocker, and no %s issue is unstarted without a record.\n", labelled, unrecordedType)
	}
	return emit(report.String(), 0)
}

// snippet bounds a reported record. Bodies are untrusted: reporting a rejected
// control must not execute it in the operator's terminal.
func snippet(line string) string {
	runes := []rune(line)
	if len(runes) > 100 {
		runes = runes[:100]
	}
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return unicode.ReplacementChar
		}
		return r
	}, string(runes))
}

func main() {
	// Let failed stdout/stderr writes reach run's UNKNOWN handling instead of
	// terminating the process before it can return the documented exit status.
	signal.Ignore(syscall.SIGPIPE)
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
