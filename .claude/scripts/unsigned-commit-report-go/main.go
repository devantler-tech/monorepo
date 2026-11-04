// Command unsigned-commit-report reports unsigned or unverifiable commits on agent-lane branches
// WITHOUT failing the pull request (monorepo#3212). It is the Go implementation behind
// unsigned-commit-report.sh (monorepo#3224); help.txt is its full usage and design note, and
// `--help` prints it.
//
// Every GitHub read goes through `gh` on PATH with the arguments the Bash implementation used,
// so the fixture harness (unsigned-commit-report.test.sh) drives both identically.
package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

//go:embed help.txt
var helpText string

const (
	prog = "unsigned-commit-report.sh"
	// prCommitCap: the endpoint lists AT MOST 250 commits per pull request whatever the
	// pagination, so a PR past that cap would be examined in part while `examined=` read as the
	// whole. Reaching the cap is UNKNOWN.
	prCommitCap = 250
	// lanePRLimit is explicit because gh defaults to 30 and would silently truncate; reaching it
	// is UNKNOWN, never a smaller number presented as the whole.
	lanePRLimit = 1000
	// defaultInstancesEnv carries the checked-in registry path from the launcher.
	defaultInstancesEnv = "UNSIGNED_COMMIT_REPORT_DEFAULT_INSTANCES"
)

var (
	sinceShape = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)
	repoChars  = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
)

type ghFunc func(stdin io.Reader, args ...string) (stdout string, err error)

// unknown is every exit-2 outcome: usage errors, unreadable input and failed reads alike.
type unknown struct{ msg string }

func (u *unknown) Error() string { return u.msg }

func die(format string, args ...any) error { return &unknown{msg: fmt.Sprintf(format, args...)} }

type options struct {
	pr, repo, input, headRef, since, lanes   string
	prAuthor, headOwner, headRepo, instances string
	help                                     bool
}

type env struct {
	gh       ghFunc
	lookPath func(string) (string, error)
	getenv   func(string) string
	readFile func(string) ([]byte, error)
	stdin    io.Reader
	stdout   io.Writer
	stderr   io.Writer
}

func main() {
	e := env{
		gh: func(stdin io.Reader, args ...string) (string, error) {
			var out bytes.Buffer
			cmd := exec.Command("gh", args...)
			cmd.Stdout = &out
			cmd.Stderr = os.Stderr
			err := cmd.Run()
			return out.String(), err
		},
		lookPath: exec.LookPath,
		getenv:   os.Getenv,
		readFile: os.ReadFile,
		stdin:    os.Stdin,
		stdout:   os.Stdout,
		stderr:   os.Stderr,
	}
	os.Exit(run(os.Args[1:], e))
}

func run(args []string, e env) int {
	opts, err := parseArgs(args, e.getenv(defaultInstancesEnv))
	if err == nil && opts.help {
		fmt.Fprint(e.stdout, helpText)
		return 0
	}
	if err == nil {
		err = report(opts, e)
	}
	var u *unknown
	if errors.As(err, &u) {
		fmt.Fprintf(e.stderr, "%s: %s\n", prog, u.msg)
		return 2
	}
	if err != nil {
		fmt.Fprintf(e.stderr, "%s: %s\n", prog, err)
		return 2
	}
	return 0
}

func parseArgs(args []string, defaultInstances string) (options, error) {
	opts := options{instances: defaultInstances}
	needs := map[string]string{
		"--pr": "a number", "--repo": "owner/repo", "--input": "a path", "--head-ref": "a ref",
		"--pr-author": "a login", "--head-owner": "a login", "--head-repo": "owner/repo",
		"--instances": "a path", "--merged-since": "YYYY-MM-DD", "--lanes": "a comma-separated list",
	}
	targets := map[string]*string{
		"--pr": &opts.pr, "--repo": &opts.repo, "--input": &opts.input, "--head-ref": &opts.headRef,
		"--pr-author": &opts.prAuthor, "--head-owner": &opts.headOwner, "--head-repo": &opts.headRepo,
		"--instances": &opts.instances, "--merged-since": &opts.since, "--lanes": &opts.lanes,
	}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "-h" || arg == "--help" {
			opts.help = true
			return opts, nil
		}
		target, known := targets[arg]
		if !known {
			return opts, die("unknown argument '%s'", arg)
		}
		if i+1 >= len(args) {
			return opts, die("%s needs %s", arg, needs[arg])
		}
		*target = args[i+1]
		i++
	}
	return opts, nil
}

// state is what the classification step needs to know about the run.
type state struct {
	opts    options
	reg     registry
	lanes   []string
	rows    string
	targets string
	skipped bool
	reason  string
}

func report(opts options, e env) error {
	s := &state{opts: opts}
	data, err := e.readFile(opts.instances)
	reg, ok := loadRegistry(data)
	if err != nil || !ok {
		return die("instance registry is unreadable or malformed -- UNKNOWN")
	}
	s.reg = reg
	if s.opts.lanes == "" {
		names := make([]string, 0, len(reg.instances))
		for _, inst := range reg.instances {
			names = append(names, inst.namespace)
		}
		s.opts.lanes = strings.Join(names, ",")
	}
	s.lanes = splitLanes(s.opts.lanes)
	seen := map[string]bool{}
	for _, lane := range s.lanes {
		if lane == "" {
			return die("--lanes has an empty namespace -- UNKNOWN")
		}
		if seen[lane] {
			return die("--lanes repeats '%s' -- UNKNOWN", lane)
		}
		seen[lane] = true
		if !reg.has(lane) {
			return die("--lanes names an unregistered namespace -- UNKNOWN")
		}
	}

	modes := 0
	for _, mode := range []string{opts.pr, opts.input, opts.since} {
		if mode != "" {
			modes++
		}
	}
	if modes != 1 {
		return die("exactly one of --pr, --input or --merged-since is required")
	}
	if opts.pr != "" && !allDigits(opts.pr) {
		return die("--pr must be a number (got '%s')", opts.pr)
	}
	if opts.since != "" && !sinceShape.MatchString(opts.since) {
		return die("--merged-since must be YYYY-MM-DD (got '%s')", opts.since)
	}
	if opts.pr != "" || opts.since != "" {
		if !strings.Contains(opts.repo, "/") {
			return die("--repo owner/repo is required with --pr or --merged-since")
		}
		if !repoChars.MatchString(opts.repo) {
			return die("--repo must match [A-Za-z0-9._/-]+ (got '%s')", opts.repo)
		}
		if _, err := e.lookPath("gh"); err != nil {
			return die("gh is required")
		}
	}

	switch {
	case opts.input != "":
		err = s.payloadMode(e)
	case opts.pr != "":
		err = s.prMode(e)
	default:
		err = s.sweepMode(e)
	}
	if err != nil {
		return err
	}
	return s.classify(e)
}

// splitLanes is `IFS=, read -r -a` on the lane list: a single trailing comma ends the list
// rather than naming an empty lane.
func splitLanes(list string) []string {
	if list == "" {
		return nil
	}
	parts := strings.Split(list, ",")
	if parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// laneOf reads the lane from the head ref's first path segment; "" means no registered match.
func (s *state) laneOf(ref string) string {
	lane, _, found := strings.Cut(ref, "/")
	if !found {
		return ""
	}
	for _, l := range s.lanes {
		if l == lane {
			return lane
		}
	}
	return ""
}

// nonLaneReason applies the sweep's provenance rule to one pull request: lane work only when its
// head lives in the base repository AND its author is that lane's exact writer identity.
// Absent provenance is not trusted; the caller states it or the report says it could not check.
func (s *state) nonLaneReason(lane string) string {
	o := s.opts
	if lane == "" {
		return "non-agent-head"
	}
	if o.headOwner != "" && o.repo != "" && o.headOwner != firstSegment(o.repo) {
		return "foreign-head"
	}
	if o.headRepo != "" && o.repo != "" && o.headRepo != o.repo {
		return "foreign-head"
	}
	if o.prAuthor != "" && !s.reg.writerOK(lane, o.prAuthor, "rest") {
		return "foreign-author"
	}
	return ""
}

func firstSegment(s string) string {
	segment, _, _ := strings.Cut(s, "/")
	return segment
}

func (s *state) payloadMode(e env) error {
	var data []byte
	var err error
	if s.opts.input == "-" {
		if data, err = io.ReadAll(e.stdin); err != nil {
			return die("could not read payload from stdin")
		}
	} else if data, err = e.readFile(s.opts.input); err != nil {
		return die("cannot read payload: %s", s.opts.input)
	}
	commits, ok := decodeStream(data)
	if !ok || len(commits) != 1 {
		return die("payload is not a JSON array (exactly one document required) -- UNKNOWN")
	}
	list, isArray := commits[0].([]any)
	if !isArray {
		return die("payload is not a JSON array (exactly one document required) -- UNKNOWN")
	}
	rows, err := commitRows(list, s.opts.headRef, true)
	if err != nil {
		return die("could not parse payload -- UNKNOWN")
	}
	s.rows = rows
	// Identity/repository claims turn this into an authoritative PR report: bind the branch and
	// every required provenance field before any skip or count. The raw classification seam
	// makes no identity/repository claims at all.
	o := s.opts
	if o.repo+o.headOwner+o.headRepo+o.prAuthor != "" &&
		(o.headRef == "" || o.repo == "" || o.headRepo == "" || o.prAuthor == "") {
		return die("payload has incomplete branch/repository/author provenance -- UNKNOWN")
	}
	if o.headRef != "" {
		if reason := s.nonLaneReason(s.laneOf(o.headRef)); reason != "" {
			s.skipped, s.reason, s.rows = true, reason, ""
			return nil
		}
	}
	// CI feeds this mode the raw endpoint payload, so the 250-commit cap applies here as well.
	if count := countNonEmpty(s.rows); count >= prCommitCap {
		return die("payload has %d commits, at the %d-commit endpoint cap: the report would be TRUNCATED -- UNKNOWN", count, prCommitCap)
	}
	return nil
}

func (s *state) prMode(e env) error {
	o := &s.opts
	// Provenance is fetched even when a caller supplies the branch name: direct mode must
	// describe the pull request the endpoint actually returned.
	text, err := e.gh(nil, "api", "repos/"+o.repo+"/pulls/"+o.pr)
	if err != nil {
		return die("could not read %s#%s metadata -- UNKNOWN", o.repo, o.pr)
	}
	docs, ok := decodeStream([]byte(text))
	var fields []string
	if ok && len(docs) == 1 {
		for _, keys := range [][]string{{"head", "ref"}, {"head", "repo", "owner", "login"}, {"head", "repo", "full_name"}, {"user", "login"}} {
			value, pathErr := path(docs[0], keys...)
			str, isString := value.(string)
			if pathErr != nil || !isString || str == "" {
				ok = false
				break
			}
			fields = append(fields, str)
		}
	}
	if _, isObject := firstOrNil(docs).(map[string]any); !ok || !isObject || len(fields) != 4 {
		return die("%s#%s has missing or malformed provenance -- UNKNOWN", o.repo, o.pr)
	}
	if o.headRef != "" && o.headRef != fields[0] {
		return die("supplied head ref differs from %s#%s -- UNKNOWN", o.repo, o.pr)
	}
	o.headRef, o.headOwner, o.headRepo, o.prAuthor = fields[0], fields[1], fields[2], fields[3]
	if reason := s.nonLaneReason(s.laneOf(o.headRef)); reason != "" {
		s.skipped, s.reason = true, reason
		return nil
	}
	rows, err := s.prCommits(e, o.repo, o.pr, o.headRef)
	if err != nil {
		return err
	}
	s.rows = rows
	return nil
}

func firstOrNil(docs []any) any {
	if len(docs) == 0 {
		return nil
	}
	return docs[0]
}

// prCommits reads one pull request's commits as TSV rows: sha, verified, reason, branch.
func (s *state) prCommits(e env, repo, pr, branch string) (string, error) {
	text, err := e.gh(nil, "api", "repos/"+repo+"/pulls/"+pr+"/commits", "--paginate")
	if err != nil {
		return "", die("could not read %s#%s commits -- UNKNOWN", repo, pr)
	}
	// `--paginate` emits one array per page; every page is walked.
	pages, ok := decodeStream([]byte(text))
	if !ok {
		return "", die("could not read %s#%s commits -- UNKNOWN", repo, pr)
	}
	var all strings.Builder
	for _, page := range pages {
		list, isArray := page.([]any)
		if !isArray {
			return "", die("could not read %s#%s commits -- UNKNOWN", repo, pr)
		}
		rows, err := commitRows(list, branch, false)
		if err != nil {
			return "", die("could not read %s#%s commits -- UNKNOWN", repo, pr)
		}
		all.WriteString(rows)
	}
	out := strings.TrimRight(all.String(), "\n")
	if count := countNonEmpty(out); count >= prCommitCap {
		return "", die("%s#%s has %d commits, at the %d-commit endpoint cap: the report would be TRUNCATED -- UNKNOWN", repo, pr, count, prCommitCap)
	}
	return out, nil
}

// commitRows renders commits as the TSV rows the Bash filters produced. Payload mode defaults a
// missing sha to "missing" and a missing verified flag to false; the endpoint path does not.
func commitRows(list []any, branch string, payload bool) (string, error) {
	var b strings.Builder
	for _, item := range list {
		sha, err := path(item, "sha")
		if err != nil {
			return "", err
		}
		verified, err := path(item, "commit", "verification", "verified")
		if err != nil {
			return "", err
		}
		reason, err := path(item, "commit", "verification", "reason")
		if err != nil {
			return "", err
		}
		if payload && !truthy(sha) {
			sha = "missing"
		}
		if payload && !truthy(verified) {
			verified = false
		}
		if !truthy(reason) {
			reason = "missing"
		}
		cells := []any{sha, toString(verified), reason, branch}
		for i, cell := range cells {
			field, err := tsvField(cell)
			if err != nil {
				return "", err
			}
			if i > 0 {
				b.WriteByte('\t')
			}
			b.WriteString(field)
		}
		b.WriteByte('\n')
	}
	return b.String(), nil
}

// sweepMode is measurement mode: every lane's merged pull requests since the date, each one
// examined only when it is that lane's own work.
func (s *state) sweepMode(e env) error {
	o := &s.opts
	var prs []string
	foreign := 0
	for _, lane := range s.lanes {
		if lane == "" {
			continue
		}
		chunk, err := e.gh(nil, "pr", "list", "--repo", o.repo, "--state", "merged",
			"--limit", fmt.Sprint(lanePRLimit), "--search", "merged:>="+o.since+" head:"+lane+"/",
			"--json", "number,headRefName,author,isCrossRepository",
			"--jq", `.[] | [.number, .headRefName, (.author.login // ""), (.isCrossRepository | tostring)] | @tsv`)
		if err != nil {
			return die("could not list merged %s/* PRs in %s -- UNKNOWN", lane, o.repo)
		}
		chunk = strings.TrimRight(chunk, "\n")
		// Foreign-provenance results consume the same search limit, so the raw listing is checked
		// before filtering, or a capped search with even one foreign result could look complete.
		if count := countNonEmpty(chunk); count >= lanePRLimit {
			return die("lane %s/* has %d merged PRs since %s, at the %d-PR cap: the sweep would be TRUNCATED -- UNKNOWN; narrow --merged-since or --lanes", lane, count, o.since, lanePRLimit)
		}
		// `head:<lane>/` matches branch NAMES, and names are not owned across forks: lane work is
		// the lane's exact writer identity on a head that lives in this repository.
		for _, line := range lines(chunk) {
			f := readFields(line, 4)
			if f[0] == "" {
				continue
			}
			if f[2] == "" || (f[3] != "true" && f[3] != "false") {
				return die("merged PR has missing or malformed provenance -- UNKNOWN")
			}
			if f[3] == "false" && s.laneOf(f[1]) == lane && s.reg.writerOK(lane, f[2], "cli") {
				prs = append(prs, f[0]+"\t"+f[1])
			} else {
				foreign++
			}
		}
	}
	count := 0
	var rows, targets strings.Builder
	for _, entry := range prs {
		f := readFields(entry, 2)
		if f[0] == "" {
			continue
		}
		chunk, err := s.prCommits(e, o.repo, f[0], f[1])
		if err != nil {
			return err
		}
		rows.WriteString(chunk + "\n")
		count++
		var shas []string
		for _, line := range strings.Split(chunk, "\n") {
			if line == "" {
				continue
			}
			sha, _, _ := strings.Cut(line, "\t")
			shas = append(shas, prefix(sha, 10))
		}
		fmt.Fprintf(&targets, "T  %s#%s  %s  commits=%d  %s\n", o.repo, f[0], f[1], countNonEmpty(chunk), strings.Join(shas, " "))
	}
	s.rows, s.targets = rows.String(), targets.String()
	o.headRef = fmt.Sprintf("merged-since:%s prs=%d foreign=%d lanes=%s", o.since, count, foreign, o.lanes)
	return nil
}

// classOf maps `verification.reason` to git's %G? letter. Only the reason is consulted: GitHub
// sets `verified` true exactly when the reason is `valid`. Anything not named here is class E:
// a reason the report has not seen is still "GitHub could not verify it", never a pass.
func classOf(reason string) string {
	switch reason {
	case "valid":
		return "G"
	case "unsigned":
		return "N"
	case "invalid", "malformed_signature", "bad_cert", "unknown_signature_type", "malformed_ssh_signature":
		return "B"
	default:
		return "E"
	}
}

func (s *state) classify(e env) error {
	o := s.opts
	actions := e.getenv("GITHUB_ACTIONS") != ""
	examined, g, n, b, x := 0, 0, 0, 0, 0
	var findings strings.Builder
	for _, line := range lines(s.rows) {
		f := readFields(line, 4)
		sha, reason, branch := f[0], f[2], f[3]
		if sha == "" {
			continue
		}
		examined++
		class := classOf(reason)
		switch class {
		case "G":
			g++
			continue
		case "N":
			n++
		case "B":
			b++
		default:
			x++
		}
		fmt.Fprintf(&findings, "%s  %s  %s  %s\n", class, sha, reason, branch)
		if actions {
			fmt.Fprintf(e.stdout, "::warning title=Unsigned or unverifiable commit (%s)::%s %s on %s\n", class, prefix(sha, 10), reason, branch)
		}
	}
	fmt.Fprint(e.stdout, s.targets)
	fmt.Fprint(e.stdout, findings.String())
	lane := "sweep"
	if o.since == "" {
		if lane = s.laneOf(o.headRef); lane == "" {
			lane = "none"
		}
	}
	skipNote := ""
	reason := s.reason
	if reason == "" {
		reason = "non-agent-head"
	}
	if s.skipped {
		skipNote = " skipped=" + reason
	}
	head := o.headRef
	if head == "" {
		head = "unknown"
	}
	summary := fmt.Sprintf("examined=%d signed=%d unsigned=%d bad=%d unverifiable=%d head=%s lane=%s%s", examined, g, n, b, x, head, lane, skipNote)
	fmt.Fprintln(e.stdout, summary)
	if path := e.getenv("GITHUB_STEP_SUMMARY"); path != "" {
		if err := appendStepSummary(path, s, summary, findings.String(), reason, examined); err != nil {
			return err
		}
	}
	return nil
}

func appendStepSummary(path string, s *state, summary, findings, reason string, examined int) error {
	o := s.opts
	var b strings.Builder
	b.WriteString("### Unsigned-commit report (non-blocking, monorepo#3212)\n\n")
	fmt.Fprintf(&b, "`%s`\n\n", summary)
	switch {
	case findings != "":
		b.WriteString("| class | sha | reason | branch |\n|---|---|---|---|\n")
		for _, line := range lines(findings) {
			f := awkFields(line, 4)
			fmt.Fprintf(&b, "| %s | `%s` | %s | %s |\n", f[0], prefix(f[1], 10), f[2], f[3])
		}
	case s.skipped:
		switch reason {
		case "foreign-head":
			fmt.Fprintf(&b, "Skipped: the head of this pull request lives outside `%s`, so its commits are not agent-lane work and nothing was classified.\n", o.repo)
		case "foreign-author":
			fmt.Fprintf(&b, "Skipped: `%s` is not the writer identity of the `%s` lane, so nothing was classified.\n", o.prAuthor, s.laneOf(o.headRef))
		default:
			fmt.Fprintf(&b, "Skipped: `%s` is not an agent-lane head (%s), so nothing was classified.\n", o.headRef, o.lanes)
		}
	default:
		fmt.Fprintf(&b, "No unsigned or unverifiable commits among the %d examined.\n", examined)
	}
	if s.targets != "" {
		b.WriteString("\n| target | branch | commits | examined |\n|---|---|---|---|\n")
		for _, line := range lines(s.targets) {
			f := strings.Fields(line)
			field := func(i int) string {
				if i < len(f) {
					return f[i]
				}
				return ""
			}
			rest := ""
			if len(f) > 4 {
				rest = strings.Join(f[4:], " ")
			}
			fmt.Fprintf(&b, "| %s | %s | %s | `%s` |\n", field(1), field(2), strings.TrimPrefix(field(3), "commits="), rest)
		}
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return die("could not write the step summary")
	}
	// A write or a close that fails means the summary may be incomplete, so both are reported
	// rather than dropped.
	_, writeErr := file.WriteString(b.String())
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		return die("could not write the step summary")
	}
	return nil
}

// awkFields is awk's default field split, padded to n.
func awkFields(line string, n int) []string {
	f := strings.Fields(line)
	for len(f) < n {
		f = append(f, "")
	}
	return f
}

// prefix is the shell's ${s:0:n} in a UTF-8 locale.
func prefix(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// decodeStream parses a sequence of JSON values, as jq reads its input.
func decodeStream(data []byte) ([]any, bool) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var values []any
	for {
		var value any
		err := decoder.Decode(&value)
		if errors.Is(err, io.EOF) {
			return values, true
		}
		if err != nil {
			return nil, false
		}
		values = append(values, value)
	}
}

// path follows object keys like jq's `.a.b`: null propagates, a non-object is an error.
func path(value any, keys ...string) (any, error) {
	for _, key := range keys {
		switch typed := value.(type) {
		case nil:
			return nil, nil
		case map[string]any:
			value = typed[key]
		default:
			return nil, errors.New("cannot index a non-object")
		}
	}
	return value, nil
}
