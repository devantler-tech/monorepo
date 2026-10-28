package mergeconfirmation

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type rule struct{ needle, diagnostic string }

var proseRules = []rule{
	{"Confirming the merge landed", "does not name the post-merge confirmation read"},
	{"--json state,mergedAt", "does not prescribe a valid post-merge read"},
	{"adding `mergedAt` or `mergeCommit` only when you need the timestamp or the squash sha", "does not give the mergeCommit/mergedAt optional-field guidance"},
	{"gh pr view <n> --repo devantler-tech/<repo> --json state,mergedAt", "prescribes a bare field list"},
	{"gh api graphql -f query='{repository(owner:\"devantler-tech\",name:\"<repo>\"){pullRequest(number:<n>){state mergedAt isInMergeQueue mergeQueueEntry{state position}}}}'", "does not prescribe the merge-queue membership read"},
	{"no `gh pr view` or `gh pr list` field reports merge-queue membership", "does not state that isInMergeQueue is unavailable"},
	{"there is NO `merged` field", "does not state that merged is not a field"},
	{"rejects the **whole** `--json` request when any single field is unknown", "does not state that one unknown field voids the entire --json read"},
}
var wiringRules = []rule{
	{"            merge-confirmation-read:", "paths-filter entry"},
	{"      merge-confirmation-read: ${{ steps.filter.outputs.merge-confirmation-read }}", "changes-job outputs declaration"},
	{"  test-merge-confirmation-read:", "job definition"},
	{"      - test-merge-confirmation-read", "status job needs: entry"},
	{"            ${{ needs.test-merge-confirmation-read.result }}", "status job job-results entry"},
}
var triggers = []string{
	"              - 'AGENTS.md'",
	"              - '.claude/**/*.md'",
	"              - '.claude/**/*.json'",
	"              - '.claude/scripts/merge-confirmation-read.test.sh'",
	"              - '.claude/scripts/merge-confirmation-read-go/**'",
	"              - 'libraries/agent-plugins'",
	"              - '.github/workflows/ci.yaml'",
}

func auditPolicy(text string) error {
	var lines []string
	inside := false
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "## Merge policy") {
			inside = true
			lines = append(lines, line)
			continue
		}
		if inside && strings.HasPrefix(line, "## ") {
			break
		}
		if inside {
			lines = append(lines, line)
		}
	}
	section := strings.Join(lines, "\n")
	if len(section) <= 500 {
		return fmt.Errorf("could not locate a '## Merge policy' section — assertions would be vacuous")
	}
	flat := space.ReplaceAllString(section, " ")
	for _, rule := range proseRules {
		if !strings.Contains(flat, rule.needle) {
			return fmt.Errorf("Merge policy %s", rule.diagnostic)
		}
	}
	return nil
}

func indentedBlock(text, heading string, indentation int) (string, error) {
	var block []string
	inside := false
	for _, line := range strings.Split(text, "\n") {
		if line == heading {
			inside = true
			continue
		}
		if !inside {
			continue
		}
		// The original job extractor ends at the next job key, not at a
		// two-space comment; the paths-filter extractor uses indentation.
		endsBlock := strings.TrimSpace(line) != "" && len(line)-len(strings.TrimLeft(line, " ")) <= indentation
		if indentation == 2 {
			endsBlock = regexp.MustCompile(`^  [A-Za-z0-9_-]+:$`).MatchString(line)
		}
		if endsBlock {
			break
		}
		block = append(block, line)
	}
	if len(block) == 0 {
		return "", fmt.Errorf("could not locate %s block", strings.TrimSpace(heading))
	}
	return strings.Join(block, "\n") + "\n", nil
}

func auditWiring(text string) error {
	for _, rule := range wiringRules {
		hits := 0
		for _, line := range strings.Split(text, "\n") {
			if line == rule.needle {
				hits++
			}
		}
		if hits != 1 {
			return fmt.Errorf("ci.yaml carries this job's %s %d times — the guard would not gate", rule.diagnostic, hits)
		}
	}
	block, err := indentedBlock(text, wiringRules[0].needle, 12)
	if err != nil {
		return err
	}
	for _, trigger := range triggers {
		if !strings.Contains(block, trigger+"\n") {
			return fmt.Errorf("ci.yaml filter is missing %s", strings.TrimSpace(trigger))
		}
	}
	job, err := indentedBlock(text, wiringRules[2].needle, 2)
	if err != nil {
		return err
	}
	if !strings.Contains(job, "submodule update --init libraries/agent-plugins") {
		return fmt.Errorf("ci.yaml's test-merge-confirmation-read job does not initialise libraries/agent-plugins")
	}
	if !strings.Contains(job, "go-version-file: .claude/scripts/merge-confirmation-read-go/go.mod") {
		return fmt.Errorf("ci.yaml's test-merge-confirmation-read job does not set up the module's Go version")
	}
	if !strings.Contains(job, "run: bash .claude/scripts/merge-confirmation-read.test.sh") {
		return fmt.Errorf("ci.yaml does not invoke the uncached guard launcher")
	}
	return nil
}

type commandRunner func(dir string, args ...string) (string, error)

func gitCommand(dir string, args ...string) (string, error) {
	command := exec.Command("git", append([]string{"-C", dir}, args...)...)
	output, err := command.Output()
	return strings.TrimRight(string(output), "\n"), err
}

func verifyPinned(root string, run commandRunner) error {
	plugin := filepath.Join(root, "libraries/agent-plugins")
	pin, err := run(root, "--no-replace-objects", "rev-parse", "HEAD:libraries/agent-plugins")
	if err != nil || strings.TrimSpace(pin) == "" {
		return fmt.Errorf("could not resolve this commit's libraries/agent-plugins gitlink: %v", err)
	}
	actual, err := run(plugin, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("could not read populated plugin revision: %w", err)
	}
	if actual != pin {
		return fmt.Errorf("libraries/agent-plugins is at %s but this commit pins %s", actual, pin)
	}
	status, err := run(plugin, "status", "--porcelain")
	if err != nil {
		return fmt.Errorf("could not read plugin worktree status: %w", err)
	}
	if status != "" {
		return fmt.Errorf("libraries/agent-plugins has uncommitted changes")
	}
	flags, err := run(plugin, "ls-files", "-v")
	if err != nil {
		return fmt.Errorf("could not read plugin index flags: %w", err)
	}
	for _, line := range strings.Split(flags, "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && (fields[0] == "S" || len(fields[0]) == 1 && fields[0][0] >= 'a' && fields[0][0] <= 'z') {
			return fmt.Errorf("plugin carries assume-unchanged/skip-worktree entries, which hide a modification")
		}
	}
	files, err := run(plugin, "--no-replace-objects", "ls-tree", "-r", "--name-only", "HEAD", "--", "plugins/agentic-engineering")
	if err != nil || strings.TrimSpace(files) == "" {
		return fmt.Errorf("pinned plugin definition enumeration failed or came back empty: %v", err)
	}
	var mismatch []string
	for _, file := range strings.Split(strings.TrimRight(files, "\n"), "\n") {
		if file == "" {
			continue
		}
		want, wantErr := run(plugin, "--no-replace-objects", "rev-parse", "HEAD:"+file)
		got, gotErr := run(plugin, "hash-object", "--no-filters", "--", file)
		if wantErr != nil || gotErr != nil || strings.TrimSpace(want) == "" || strings.TrimSpace(got) == "" {
			mismatch = append(mismatch, "BYTES-UNKNOWN "+file)
		} else if want != got {
			mismatch = append(mismatch, "BYTES-DIFFER "+file)
		}
	}
	if len(mismatch) > 0 {
		return fmt.Errorf("plugin definition worktree bytes are not pinned blobs: %s", strings.Join(mismatch, "\n"))
	}
	return nil
}

func discoverDefinitions(dir string, pruneWorktrees bool) ([]string, error) {
	var paths []string
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if pruneWorktrees && entry.IsDir() && path == filepath.Join(dir, "worktrees") {
			return filepath.SkipDir
		}
		if entry.Type().IsRegular() && (filepath.Ext(path) == ".md" || filepath.Ext(path) == ".json") {
			paths = append(paths, path)
		}
		return nil
	})
	sort.Strings(paths)
	return paths, err
}

func discoverSurfaces(root string) ([]string, error) {
	claude, err := discoverDefinitions(filepath.Join(root, ".claude"), true)
	if err != nil {
		return nil, err
	}
	plugin, err := discoverDefinitions(filepath.Join(root, "libraries/agent-plugins/plugins/agentic-engineering"), false)
	if err != nil {
		return nil, fmt.Errorf("plugin is not initialised: %w", err)
	}
	markdown := false
	for _, path := range plugin {
		if filepath.Ext(path) == ".md" {
			markdown = true
			break
		}
	}
	if !markdown {
		return nil, fmt.Errorf("plugin is not initialised or has no Markdown definition surfaces")
	}
	return append(append([]string{filepath.Join(root, "AGENTS.md")}, claude...), plugin...), nil
}

type auditResult struct{ surfaces, pluginSurfaces, lists int }

func auditRepository(root string, run commandRunner) (auditResult, error) {
	var result auditResult
	policy, err := os.ReadFile(filepath.Join(root, ".claude/guides/merge-policy.md"))
	if err != nil {
		return result, err
	}
	if err := auditPolicy(string(policy)); err != nil {
		return result, err
	}
	if err := verifyPinned(root, run); err != nil {
		return result, err
	}
	paths, err := discoverSurfaces(root)
	if err != nil {
		return result, err
	}
	var offenders []string
	for _, path := range paths {
		if strings.HasPrefix(path, filepath.Join(root, "libraries/agent-plugins/plugins/agentic-engineering")+string(os.PathSeparator)) {
			result.pluginSurfaces++
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		} // Same optional-surface rule as the original guard.
		result.surfaces++
		lists, err := extract(data, filepath.Ext(path) == ".json")
		if err != nil {
			return result, fmt.Errorf("%s: %w", path, err)
		}
		result.lists += len(lists)
		for _, bad := range badLists(lists) {
			relative, _ := filepath.Rel(root, path)
			offenders = append(offenders, relative+": "+bad)
		}
	}
	if result.surfaces < 5 || result.pluginSurfaces < 5 || result.lists < 5 {
		return result, fmt.Errorf("vacuous scan: %d surfaces, %d plugin definitions, %d lists", result.surfaces, result.pluginSurfaces, result.lists)
	}
	workflow, err := os.ReadFile(filepath.Join(root, ".github/workflows/ci.yaml"))
	if err != nil {
		return result, fmt.Errorf("ci.yaml is missing or unreadable: %w", err)
	}
	if err := auditWiring(string(workflow)); err != nil {
		return result, err
	}
	if len(offenders) > 0 {
		return result, fmt.Errorf("invalid merged or isInMergeQueue field is prescribed:\n%s", strings.Join(offenders, "\n"))
	}
	return result, nil
}
