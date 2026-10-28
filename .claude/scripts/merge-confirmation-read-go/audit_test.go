package mergeconfirmation

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func repositoryRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "../../.."))
}
func read(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(repositoryRoot(), name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestRepositoryAudit(t *testing.T) {
	if err := verifyFixtures(extract); err != nil {
		t.Fatal(err)
	}
	result, err := auditRepository(repositoryRoot(), gitCommand)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("no invalid fields in %d lists across %d surfaces (%d plugin definitions)", result.lists, result.surfaces, result.pluginSurfaces)
}

func TestEveryProsePrescriptionGatesItsOwnSection(t *testing.T) {
	text := read(t, ".claude/guides/merge-policy.md")
	if err := auditPolicy(text); err != nil {
		t.Fatal(err)
	}
	for i, rule := range proseRules {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			flat := space.ReplaceAllString(text, " ")
			changed := strings.ReplaceAll(flat, rule.needle, "REMOVED")
			if changed == flat {
				t.Fatal("vacuous ablation")
			}
			// Removing a complete command also removes its shorter valid-field
			// substring. Restore earlier independent requirements so each case
			// proves the selected rule rather than a collateral earlier failure.
			for _, earlier := range proseRules[:i] {
				if !strings.Contains(earlier.needle, rule.needle) {
					changed += " " + earlier.needle
				}
			}
			changed = "## Merge policy\n" + changed
			// A surviving copy outside the section must not satisfy the rule.
			changed += "\n## Unrelated\n" + rule.needle
			if err := auditPolicy(changed); err == nil || !strings.Contains(err.Error(), rule.diagnostic) {
				t.Fatalf("missing prescription passed or failed for wrong reason: %v", err)
			}
		})
	}
	if err := auditPolicy("## Different\n" + strings.Repeat("text ", 200)); err == nil || !strings.Contains(err.Error(), "vacuous") {
		t.Fatal("missing section was accepted")
	}
}

func TestEveryWiringPointAndTrigger(t *testing.T) {
	text := read(t, ".github/workflows/ci.yaml")
	if err := auditWiring(text); err != nil {
		t.Fatal(err)
	}
	for i, rule := range wiringRules {
		t.Run(fmt.Sprintf("point-%d", i), func(t *testing.T) {
			if strings.Count(text, rule.needle+"\n") != 1 {
				t.Fatal("vacuous/ambiguous wiring fixture")
			}
			for _, replacement := range []string{"", rule.needle + "\n" + rule.needle + "\n"} {
				changed := strings.Replace(text, rule.needle+"\n", replacement, 1)
				if err := auditWiring(changed); err == nil || !strings.Contains(err.Error(), rule.diagnostic) {
					t.Fatalf("missing/duplicate wiring accepted: %v", err)
				}
			}
		})
	}
	for i, trigger := range triggers {
		t.Run(fmt.Sprintf("trigger-%d", i), func(t *testing.T) {
			block, err := indentedBlock(text, "            merge-confirmation-read:", 12)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(block, trigger+"\n") {
				t.Fatal("missing positive trigger")
			}
			changed := strings.Replace(text, block, strings.Replace(block, trigger+"\n", "", 1), 1)
			// Identical triggers in other filters deliberately remain present.
			if err := auditWiring(changed); err == nil || !strings.Contains(err.Error(), "filter is missing") {
				t.Fatalf("disconnected trigger accepted: %v", err)
			}
		})
	}
	block, err := indentedBlock(text, "  test-merge-confirmation-read:", 2)
	if err != nil {
		t.Fatal(err)
	}
	changed := strings.Replace(text, block, strings.ReplaceAll(block, "submodule update --init libraries/agent-plugins", "REMOVED"), 1)
	if err := auditWiring(changed); err == nil || !strings.Contains(err.Error(), "does not initialise") {
		t.Fatal("initialization elsewhere satisfied missing local init")
	}
	if err := auditWiring(""); err == nil {
		t.Fatal("missing workflow accepted")
	}
}

func TestDiscoveryPrunesOnlyNestedWorktrees(t *testing.T) {
	root := t.TempDir()
	for _, path := range []string{".claude/guides/kept.md", ".claude/settings.json", ".claude/worktrees/other/.claude/nested.md"} {
		p := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	paths, err := discoverDefinitions(filepath.Join(root, ".claude"), true)
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 2 || !strings.HasSuffix(paths[0], "guides/kept.md") || !strings.HasSuffix(paths[1], "settings.json") {
		t.Fatalf("wrong discovery: %v", paths)
	}
	if _, err := discoverDefinitions(filepath.Join(root, "missing"), true); err == nil {
		t.Fatal("unreadable discovery accepted")
	}
}

func TestPinnedBytesAndReadFailures(t *testing.T) {
	const root = "/fixture"
	const plugin = "/fixture/libraries/agent-plugins"
	key := func(dir string, args ...string) string { return dir + "|" + strings.Join(args, " ") }
	valid := map[string]string{
		key(root, "--no-replace-objects", "rev-parse", "HEAD:libraries/agent-plugins"): "pin\n",
		key(plugin, "rev-parse", "HEAD"):                                               "pin\n",
		key(plugin, "status", "--porcelain"):                                           "",
		key(plugin, "ls-files", "-v"):                                                  "H plugins/agentic-engineering/a.md\n",
		key(plugin, "--no-replace-objects", "ls-tree", "-r", "--name-only", "HEAD", "--", "plugins/agentic-engineering"): "plugins/agentic-engineering/a.md\nplugins/agentic-engineering/last.json\n",
	}
	for _, p := range []string{"plugins/agentic-engineering/a.md", "plugins/agentic-engineering/last.json"} {
		valid[key(plugin, "--no-replace-objects", "rev-parse", "HEAD:"+p)] = "blob\n"
		valid[key(plugin, "hash-object", "--no-filters", "--", p)] = "blob\n"
	}
	runner := func(override map[string]string, fail string) commandRunner {
		return func(dir string, args ...string) (string, error) {
			k := key(dir, args...)
			if k == fail {
				return "", errors.New("injected read failure")
			}
			if v, ok := override[k]; ok {
				return v, nil
			}
			if v, ok := valid[k]; ok {
				return v, nil
			}
			return "", fmt.Errorf("unapproved command: %s", k)
		}
	}
	if err := verifyPinned(root, runner(nil, "")); err != nil {
		t.Fatal(err)
	}
	for k := range valid {
		t.Run("unreadable-"+k, func(t *testing.T) {
			if err := verifyPinned(root, runner(nil, k)); err == nil {
				t.Fatal("failed read accepted")
			}
		})
	}
	for _, tc := range []struct{ name, key, value, diagnostic string }{
		{"empty-pin", key(root, "--no-replace-objects", "rev-parse", "HEAD:libraries/agent-plugins"), "", "gitlink"},
		{"wrong-revision", key(plugin, "rev-parse", "HEAD"), "other", "pins"},
		{"dirty", key(plugin, "status", "--porcelain"), " M altered.md", "uncommitted"},
		{"assume-unchanged", key(plugin, "ls-files", "-v"), "h hidden.md", "hide"},
		{"skip-worktree", key(plugin, "ls-files", "-v"), "S hidden.md", "hide"},
		{"empty-enumeration", key(plugin, "--no-replace-objects", "ls-tree", "-r", "--name-only", "HEAD", "--", "plugins/agentic-engineering"), "", "enumeration"},
		{"different-last-blob", key(plugin, "hash-object", "--no-filters", "--", "plugins/agentic-engineering/last.json"), "altered", "BYTES-DIFFER"},
		{"empty-last-hash", key(plugin, "hash-object", "--no-filters", "--", "plugins/agentic-engineering/last.json"), "", "BYTES-UNKNOWN"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := verifyPinned(root, runner(map[string]string{tc.key: tc.value}, ""))
			if err == nil || !strings.Contains(err.Error(), tc.diagnostic) {
				t.Fatalf("wrong refusal: %v", err)
			}
		})
	}
}

func TestLauncherDoesNotCacheExternalSourceReads(t *testing.T) {
	text := read(t, ".claude/scripts/merge-confirmation-read.test.sh")
	if !strings.Contains(text, "exec go -C") || !strings.Contains(text, "test -count=1 ./...") {
		t.Fatal("launcher could cache a repository audit whose inputs live outside its module")
	}
}
