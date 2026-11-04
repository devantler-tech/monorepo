// Command board-add ensures an issue is on the 🌊 Project Board with a Status.
//
// `gh project item-add` has no Status option, so adding an issue to the board is two commands.
// The first exits 0 and prints an item id, so a half-completed add is indistinguishable from a
// successful one, and a status-less item is invisible in board layout and unsortable in triage.
// Measured 2026-07-19: 0 status-less items at 15:25Z, 9 at 19:2xZ, all created that day.
//
// So this command does both halves and then VERIFIES by reading the Status back. A success here
// means the status is on the board, not that a command exited 0.
//
// Usage (through the board-add.sh launcher):
//
//	board-add.sh <issue-url> [status-name]
//
// With no status argument, an existing Status is preserved and "📥 Backlog" is used only for a
// card with no Status. An explicit status deliberately updates it.
//
// Exit codes:
//
//	0  item has a Status; an explicit change is verified by read-back
//	1  usage error
//	2  add or set failed, or the read-back did not show the requested Status
//
// Every GitHub call goes through the `gh` CLI on PATH, with the same arguments the Bash
// implementation used, so the fixture harness (board-add.test.sh) drives both identically.
// This is a port of board-add.sh (monorepo#2510); the reasoning behind each rule is kept beside
// the code that implements it.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

const (
	projectNumber = "5"
	projectOwner  = "devantler-tech"
	defaultStatus = "📥 Backlog"

	// ind is the continuation indent every multi-line diagnostic has always used.
	ind = "\n          "

	// statusLadder is the CANONICAL ladder, as documented in the contract. It is deliberately a
	// local constant rather than the live option names: option names are editable by anyone with
	// project write access, so echoing them into this agent's transcript would put
	// board-controlled text in front of a high-authority reader. Untrusted input is never echoed
	// unbounded (AGENTS.md → Untrusted input / Egress).
	statusLadder = "✅ Done | 📊 Verifying | 🚀 Ready to Merge | 👀 In Review" + ind +
		"🏃🏻‍♂️ In Progress | 🫴 Ready | 📥 Backlog | 🧊 Icebox"

	// stateNothingWritten and stateItemOnBoard are the two states the board can be in when a call
	// fails. They are per call site on purpose: once item-add has succeeded, "nothing was
	// written" is false, and repeating it would hide a status-less item that needs repairing.
	stateNothingWritten = "Nothing was written: the board add did NOT happen. Retry after the reset."

	// Say only what is actually known. `item-add` is idempotent server-side and returns the
	// EXISTING item for an issue already on the board, so at this point the command cannot
	// distinguish a fresh add from a no-op, which means it cannot claim the Status is unset
	// either. Getting this wrong is harmful: the repair is to re-run, a re-run writes the DEFAULT
	// status, and an operator told the card has no Status would re-run and silently overwrite a
	// real one back to Backlog (the clobber measured in monorepo#2506).
	stateItemOnBoard = "The item is ON THE BOARD, but its Status was NOT written. item-add returns the" + ind +
		"existing item for an issue that was already there, so this cannot tell a" + ind +
		"fresh add from a no-op: the Status is either unset (new item) or still its" + ind +
		"previous value (already present). Re-run this script on the same URL after" + ind +
		"the reset; the default preserves an existing Status. An explicit status" + ind +
		"argument OVERWRITES whatever Status it currently has."
)

// The GraphQL documents are byte-for-byte the ones the Bash implementation sent, so the call log
// a fixture records is unchanged by the port.
const (
	// Project metadata in ONE query: the project id, plus the Status field and its options asked
	// for BY NAME. `gh project field-list --limit 100` returned the same ids but cost ~101 GraphQL
	// points per call, enough for a board sweep to drain the shared hourly budget, while this
	// query costs ~1 (measured 2026-09-15, monorepo#2507). Asking by name also cannot miss Status
	// on a later page, because there is no page. Resolved live rather than hardcoded: option ids
	// change whenever the maintainer edits the column set, and a stale id sets the WRONG column.
	metadataQuery = `
  query($owner: String!, $number: Int!) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField { id options { id name } }
        }
      }
    }
  }`

	// Membership is read from the issue, never by walking the board. Absence requires every
	// page, while a hit must match the project ID (project numbers are owner-local).
	membershipQuery = `
    query($owner: String!, $repo: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) {
          projectItems(first: 100, after: $after, includeArchived: false) {
            nodes { id project { id } fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            } }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }`

	addedStatusQuery = `
    query AddedStatus($id: ID!) {
      node(id: $id) { ... on ProjectV2Item { id
        fieldValueByName(name: "Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name }
        }
      } }
    }`

	// Fetch the ONE item by node id. `gh project item-list` walks all ~4,300 board items over
	// the shared 5k/hr GraphQL budget and has already died on that here.
	readBackQuery = `
  query($id: ID!) {
    node(id: $id) {
      ... on ProjectV2Item {
        fieldValueByName(name: "Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name }
        }
      }
    }
  }`

	rateLimitQuery = `query { rateLimit { remaining limit resetAt } }`
)

var (
	issueURLShape = regexp.MustCompile(`(?s)^https://github\.com/.*/.*/issues/.*$`)
	// A SECONDARY limit is a short-term burst guard, reported separately because neither
	// primary counter reflects it.
	secondaryLimit = regexp.MustCompile(`(?i)secondary rate limit|submitted too quickly`)
	primaryLimit   = regexp.MustCompile(`(?i)rate.limit|RATE_LIMITED`)
)

// ghFunc runs `gh` with args and returns its stdout and stderr. A non-nil error means gh did not
// exit 0 (or could not be started).
type ghFunc func(args ...string) (stdout, stderr string, err error)

// exit carries a verdict out of the call chain: the message goes to stderr, the code to the OS.
type exit struct {
	code int
	msg  string
}

func (e *exit) Error() string { return e.msg }

// die is an operational failure (exit 2); usageDie is a usage error or refused input (exit 1).
func die(msg string) *exit      { return &exit{code: 2, msg: msg} }
func usageDie(msg string) *exit { return &exit{code: 1, msg: msg} }

// errUsage asks run to print the usage text, unprefixed, and exit 1.
var errUsage = errors.New("usage")

type adder struct {
	gh ghFunc
	// lastErr is the stderr of the most recent call whose stderr the Bash implementation sent to
	// its GH_ERR file. That stderr is the only place GitHub says *why* it refused, so it is kept
	// rather than discarded; each such call replaces it, so it never holds a stale failure. The
	// budget probes keep their stderr to themselves, exactly as before.
	lastErr string
	stdout  io.Writer
}

// call runs gh, records its stderr as the latest failure evidence, and trims trailing newlines
// from stdout the way a shell command substitution does.
func (a *adder) call(args ...string) (string, error) {
	out, errText, err := a.gh(args...)
	a.lastErr = errText
	return strings.TrimRight(out, "\n"), err
}

func main() {
	code := run(os.Args[1:], execGH, exec.LookPath, os.Stdout, os.Stderr)
	os.Exit(code)
}

func execGH(args ...string) (string, string, error) {
	var out, errBuf bytes.Buffer
	cmd := exec.Command("gh", args...)
	cmd.Stdin = nil
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	err := cmd.Run()
	return out.String(), errBuf.String(), err
}

func run(args []string, gh ghFunc, lookPath func(string) (string, error), stdout, stderr io.Writer) int {
	a := &adder{gh: gh, stdout: stdout}
	if err := a.main(args, lookPath); err != nil {
		if errors.Is(err, errUsage) {
			fmt.Fprint(stderr, usageText())
			return 1
		}
		var e *exit
		if errors.As(err, &e) {
			fmt.Fprintf(stderr, "board-add: %s\n", e.msg)
			return e.code
		}
		fmt.Fprintf(stderr, "board-add: %s\n", err)
		return 2
	}
	return 0
}

func usageText() string {
	return "usage: board-add.sh <issue-url> [status-name]\n\n" +
		"  <issue-url>    full https://github.com/<owner>/<repo>/issues/<n> URL\n" +
		"  [status-name]  explicitly set Status; omitted preserves it, or uses \"" + defaultStatus + "\" if unset\n\n" +
		"Statuses: " + statusLadder + "\n"
}

func (a *adder) main(args []string, lookPath func(string) (string, error)) error {
	if len(args) < 1 || len(args) > 2 {
		return errUsage
	}
	issueURL := args[0]
	statusName := defaultStatus
	explicit := false
	if len(args) == 2 {
		statusName = args[1]
		explicit = true
	}

	if !issueURLShape.MatchString(issueURL) {
		return usageDie(fmt.Sprintf("not an issue URL: %s (expected https://github.com/<owner>/<repo>/issues/<n>)", issueURL))
	}
	owner, repo, number, ok := parseIssueURL(issueURL)
	if !ok {
		return usageDie("not an issue URL: " + issueURL)
	}

	if _, err := lookPath("gh"); err != nil {
		return die("gh CLI not found")
	}

	// ORG SCOPE, checked before the repo is even inspected. Cross-repo scope is closed by
	// default (AGENTS.md → Merge policy), so an arbitrary external issue URL must not cause this
	// command to probe that repository, let alone put it on the org board.
	if owner != projectOwner {
		return usageDie(fmt.Sprintf("refusing %s/%s: only %s issues belong on this board", owner, repo, projectOwner))
	}

	// FAIL CLOSED on visibility: project 5 is public, so a private repo's issue must never be
	// swept onto it by an agent. An unreadable repo is treated as private. The probe is on the
	// REST budget (`core`), which is metered separately from GraphQL.
	isPrivate, err := a.call("api", "repos/"+owner+"/"+repo, "--jq", ".private")
	if err != nil {
		isPrivate = "unknown"
	}
	switch isPrivate {
	case "false":
	case "true":
		return die(fmt.Sprintf("%s/%s is PRIVATE; project 5 is public — adding it is a maintainer decision, not an agent default", owner, repo))
	default:
		return a.dieGH("core", fmt.Sprintf("could not determine visibility of %s/%s", owner, repo),
			stateNothingWritten,
			fmt.Sprintf("could not determine visibility of %s/%s; refusing (fail-closed)", owner, repo))
	}

	metadataText, err := a.call("api", "graphql", "-f", "owner="+projectOwner, "-F", "number="+projectNumber, "-f", "query="+metadataQuery)
	if err != nil {
		return a.dieGH("graphql", "could not reach the Projects API for "+projectOwner+"/"+projectNumber,
			stateNothingWritten,
			"could not reach the Projects API for "+projectOwner+"/"+projectNumber+" (auth, network, or scope)")
	}
	metadata, metadataOK := decodeJSON(metadataText)
	projectID := ""
	if metadataOK {
		if v, err := path(metadata, "data", "organization", "projectV2", "id"); err == nil {
			projectID = rawOrEmpty(v)
		}
	}
	if projectID == "" {
		return die("could not resolve project " + projectOwner + "/" + projectNumber)
	}

	itemID, currentStatus, err := a.membership(issueURL, owner, repo, number, projectID)
	if err != nil {
		return err
	}

	if !explicit && currentStatus != "" {
		fmt.Fprintf(a.stdout, "board-add: %s already-present (status untouched) (item %s) [verified]\n", issueURL, itemID)
		return nil
	}

	// The Status field came back with the project metadata, so writing a status needs no further
	// lookup. A missing field, or one that is not a single-select, has no id and is refused
	// before any board write.
	field, _ := path(metadata, "data", "organization", "projectV2", "field")
	fieldObj, _ := field.(map[string]any)
	fieldID := ""
	if fieldObj != nil {
		fieldID = rawOrEmpty(fieldObj["id"])
	}
	if fieldID == "" {
		return die("could not resolve the Status field on project " + projectNumber)
	}

	optionID := ""
	for _, option := range iterate(fieldObj["options"]) {
		o, isObject := option.(map[string]any)
		if !isObject {
			if option == nil {
				continue
			}
			return die("could not resolve the Status field on project " + projectNumber)
		}
		if name, isString := o["name"].(string); isString && name == statusName {
			if optionID = rawOrEmpty(o["id"]); optionID != "" {
				break
			}
		}
	}
	if optionID == "" {
		// Report the CANONICAL ladder, never the live option names: those come from the board
		// and may be instruction-shaped. Only the count of live options is reported, which
		// carries no attacker text.
		liveCount := len(iterate(fieldObj["options"]))
		return usageDie(fmt.Sprintf("unknown status \"%s\" — expected one of: %s"+ind+
			"(the board currently defines %d options; if the ladder was\n"+
			"           renamed on the board, reconcile it in the UI rather than guessing)",
			statusName, statusLadder, liveCount))
	}

	// Add. `item-add` is idempotent server-side (an existing item is returned, not duplicated),
	// and prints nothing useful off-TTY, so ask for the id explicitly.
	outcome := "already-present (status set)"
	if itemID == "" {
		addText, addErr := a.call("project", "item-add", projectNumber, "--owner", projectOwner,
			"--url", issueURL, "--format", "json")
		// An empty answer carries no id (reported below); an answer that is not one JSON value,
		// or whose id cannot be read, is a failed add, exactly as the jq stage of the old pipe.
		addedOK := true
		if strings.TrimSpace(addText) != "" {
			added, decoded := decodeJSON(addText)
			idValue, pathErr := path(added, "id")
			if !decoded || pathErr != nil {
				addedOK = false
			} else {
				itemID = rawOrEmpty(idValue)
			}
		}
		if addErr != nil || !addedOK {
			return a.dieGH("graphql", "item-add failed for "+issueURL, stateNothingWritten,
				"item-add failed for "+issueURL+" (auth, network, or scope)")
		}
		if itemID == "" {
			return die("item-add returned no item id for " + issueURL)
		}
		outcome = "added (absent at lookup)"
	}

	// item-add can return a card created by another writer after the lookup. Read its Status
	// before applying the default, so a concurrent add is not flattened.
	if !explicit {
		addedText, err := a.call("api", "graphql", "-f", "id="+itemID, "-f", "query="+addedStatusQuery)
		if err != nil {
			return a.dieGH("graphql", "could not read the existing Status for "+issueURL, stateItemOnBoard,
				"could not read the existing Status; item is on the board, no Status was written")
		}
		addedStatus, valid := addedStatusValue(addedText, itemID)
		if !valid {
			return die("invalid existing Status response; no Status was written")
		}
		if addedStatus != "" {
			fmt.Fprintf(a.stdout, "board-add: %s already-present (status untouched) (item %s) [verified]\n", issueURL, itemID)
			return nil
		}
	}

	// DELIBERATELY NO ROLLBACK-BY-DELETE. Telling a newly-created item from a pre-existing one
	// depends on a lookup that can fail, paginate, or match another owner's project #5, and every
	// one of those misreadings would end in DELETING a board card the maintainer already had.
	// Failure leaves the item on the board with its Status unwritten; a default retry preserves
	// a populated Status and fills an unset one.
	if _, err := a.call("project", "item-edit", "--id", itemID, "--project-id", projectID,
		"--field-id", fieldID, "--single-select-option-id", optionID); err != nil {
		// item-add has ALREADY succeeded here, so "nothing was written" would be false. It does
		// NOT follow that the item is new or status-less, so no message may promise an unset
		// Status.
		return a.dieGH("graphql", fmt.Sprintf("could not set the Status for %s (item %s)", issueURL, itemID),
			stateItemOnBoard,
			fmt.Sprintf("could not set the Status for %s (item %s).", issueURL, itemID)+ind+
				"The item is on the board and its Status was not written — it is either"+ind+
				"unset, or unchanged if the issue was already there."+ind+
				"To set it, re-run this script on the same URL. The default preserves a"+ind+
				"Status; an explicit status argument OVERWRITES whatever it currently has.")
	}

	// VERIFY BY READ-BACK — the whole point. An exit-0 from item-edit is not evidence the status
	// landed; only reading it back off the board is. The read-back must distinguish "the board
	// says something else" from "the query never ran": an unrun query is reported as a failed
	// verification, never as a statement about a board this command did not manage to read.
	actual, err := a.call("api", "graphql", "-f", "id="+itemID, "-f", "query="+readBackQuery,
		"--jq", ".data.node.fieldValueByName.name // empty")
	if err != nil {
		return a.dieGH("graphql", fmt.Sprintf("could not read the Status back for %s (item %s)", issueURL, itemID),
			"The item is on the board. The Status write command returned success, but"+ind+
				"that is not evidence it persisted — only this read-back establishes that,"+ind+
				"and the read-back is what failed. The Status is therefore UNVERIFIED: it"+ind+
				"may or may not be set. To confirm it, re-run this script on the same URL"+ind+
				"after the reset. The default preserves a Status; an explicit status"+ind+
				"argument OVERWRITES whatever Status it currently has.",
			fmt.Sprintf("could not read the Status back for %s (item %s) (auth, network, or scope).", issueURL, itemID)+ind+
				"This is a failed VERIFICATION rather than a failed write — but the write is"+ind+
				"not confirmed either: the command returned success, and only this read-back"+ind+
				"could establish that it persisted. The Status is UNVERIFIED. To confirm it,"+ind+
				"re-run this script on the same URL. The default preserves a Status;"+ind+
				"an explicit status argument OVERWRITES whatever it currently has.")
	}

	if actual != statusName {
		// Do NOT echo the actual value: it is board-controlled text, the same untrusted class as
		// the option names. Reporting only whether a value was present says everything the
		// operator needs to act.
		observed := "a different Status"
		if actual == "" {
			observed = "no Status at all"
		}
		return die(fmt.Sprintf("read-back MISMATCH for %s: wanted \"%s\", board shows %s.", issueURL, statusName, observed) + ind +
			"Re-run to retry; if it persists, inspect the board in the UI (the live" + ind +
			"value is not printed here because board text is not trusted input).")
	}

	fmt.Fprintf(a.stdout, "board-add: %s %s → %s (item %s) [verified]\n", issueURL, outcome, statusName, itemID)
	return nil
}

// membership pages through the issue's project items until it finds this project's item or
// proves absence. Any unreadable or malformed page refuses before any write.
func (a *adder) membership(issueURL, owner, repo, number, projectID string) (itemID, status string, err error) {
	after := ""
	for {
		cursor := []string{"-F", "after=null"}
		if after != "" {
			cursor = []string{"-f", "after=" + after}
		}
		args := append([]string{"api", "graphql", "-f", "owner=" + owner, "-f", "repo=" + repo,
			"-F", "number=" + number}, cursor...)
		args = append(args, "-f", "query="+membershipQuery)
		pageText, callErr := a.call(args...)
		if callErr != nil {
			return "", "", a.dieGH("graphql", "could not read project membership for "+issueURL,
				stateNothingWritten, "could not read project membership; refusing before any write")
		}
		page, ok := parseMembershipPage(pageText)
		if !ok {
			return "", "", die("invalid project membership response; refusing before any write")
		}
		for _, node := range page.nodes {
			if node.projectID == projectID {
				return node.id, node.status, nil
			}
		}
		if !page.hasNext {
			return "", "", nil
		}
		if page.endCursor == "" || page.endCursor == after {
			return "", "", die("invalid project membership cursor; refusing before any write")
		}
		after = page.endCursor
	}
}

type membershipNode struct {
	id, projectID, status string
}

type membershipPage struct {
	nodes     []membershipNode
	hasNext   bool
	endCursor string
}

// parseMembershipPage accepts a page only when GraphQL reported no errors, the node list is an
// array, hasNextPage is a boolean, and every node carries a non-empty item id, a non-empty
// project id and a Status that is either null or a non-empty name.
func parseMembershipPage(text string) (membershipPage, bool) {
	var page membershipPage
	root, ok := decodeJSON(text)
	if !ok || !noGraphQLErrors(root) {
		return page, false
	}
	items, err := path(root, "data", "repository", "issue", "projectItems")
	if err != nil {
		return page, false
	}
	nodesValue, err := path(items, "nodes")
	if err != nil {
		return page, false
	}
	nodes, isArray := nodesValue.([]any)
	if !isArray {
		return page, false
	}
	hasNext, err := path(items, "pageInfo", "hasNextPage")
	if err != nil {
		return page, false
	}
	next, isBool := hasNext.(bool)
	if !isBool {
		return page, false
	}
	for _, n := range nodes {
		node, isObject := n.(map[string]any)
		if !isObject {
			return page, false
		}
		id, _ := node["id"].(string)
		project, _ := node["project"].(map[string]any)
		if id == "" || project == nil {
			return page, false
		}
		projectID, _ := project["id"].(string)
		if projectID == "" {
			return page, false
		}
		fieldValue, present := node["fieldValueByName"]
		if !present {
			return page, false
		}
		status := ""
		if fieldValue != nil {
			value, isObject := fieldValue.(map[string]any)
			if !isObject {
				return page, false
			}
			name, isString := value["name"].(string)
			if !isString || name == "" {
				return page, false
			}
			status = name
		}
		page.nodes = append(page.nodes, membershipNode{id: id, projectID: projectID, status: status})
	}
	page.hasNext = next
	if next {
		cursor, err := path(items, "pageInfo", "endCursor")
		if err != nil {
			return page, false
		}
		page.endCursor = rawOrEmpty(cursor)
	}
	return page, true
}

// addedStatusValue validates the post-add Status read: no GraphQL errors, the node is the item
// that was added, and its Status is either null or a non-empty name.
func addedStatusValue(text, itemID string) (string, bool) {
	root, ok := decodeJSON(text)
	if !ok || !noGraphQLErrors(root) {
		return "", false
	}
	nodeValue, err := path(root, "data", "node")
	if err != nil {
		return "", false
	}
	node, isObject := nodeValue.(map[string]any)
	if !isObject {
		return "", false
	}
	if id, isString := node["id"].(string); !isString || id != itemID {
		return "", false
	}
	fieldValue, present := node["fieldValueByName"]
	if !present {
		return "", false
	}
	if fieldValue == nil {
		return "", true
	}
	value, isObject := fieldValue.(map[string]any)
	if !isObject {
		return "", false
	}
	name, isString := value["name"].(string)
	if !isString || name == "" {
		return "", false
	}
	return name, true
}

// parseIssueURL splits https://github.com/<owner>/<repo>/issues/<n> exactly as the shell
// parameter expansions did: owner is everything before the first slash, repo everything before
// the next one, and the number everything after the first "/issues/" that follows the owner.
func parseIssueURL(raw string) (owner, repo, number string, ok bool) {
	if !issueURLShape.MatchString(raw) {
		return "", "", "", false
	}
	rest := strings.TrimPrefix(raw, "https://github.com/")
	owner, afterOwner, found := strings.Cut(rest, "/")
	if !found {
		afterOwner = rest
	}
	repo, _, _ = strings.Cut(afterOwner, "/")
	number = afterOwner
	if _, n, found := strings.Cut(afterOwner, "/issues/"); found {
		number = n
	}
	if !allDigits(number) {
		return owner, repo, number, false
	}
	return owner, repo, number, true
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
