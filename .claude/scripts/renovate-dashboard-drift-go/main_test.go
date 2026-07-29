package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withDeclaredRoots swaps the declared set for a test and restores it after, so
// each case can describe its own portfolio without the real one leaking in.
func withDeclaredRoots(t *testing.T, roots ...string) {
	t.Helper()

	original := declaredConfigRoots
	declaredConfigRoots = roots

	t.Cleanup(func() { declaredConfigRoots = original })
}

// writeFile creates a file and every directory above it.
func writeFile(t *testing.T, path, body string) {
	t.Helper()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// newRoot builds a throwaway monorepo root with a .gitmodules listing the given
// submodule paths.
func newRoot(t *testing.T, submodules ...string) string {
	t.Helper()

	root := t.TempDir()

	var b strings.Builder
	for _, p := range submodules {
		b.WriteString("[submodule \"" + p + "\"]\n\tpath = " + p + "\n\turl = git@github.com:devantler-tech/x.git\n")
	}

	writeFile(t, filepath.Join(root, ".gitmodules"), b.String())

	return root
}

// mustStrip strips a source that the caller asserts is well-formed, so the
// comment/comma tests stay about what survives the strip rather than about
// error plumbing.
func mustStrip(t *testing.T, src string) []byte {
	t.Helper()

	out, err := stripJSON5([]byte(src))
	if err != nil {
		t.Fatalf("stripJSON5: %v", err)
	}

	return out
}

func runIn(t *testing.T, root string) (int, string) {
	t.Helper()

	var stdout, stderr bytes.Buffer
	code := run(root, &stdout, &stderr)

	return code, stdout.String() + stderr.String()
}

// --- the JSON5 trap -------------------------------------------------------

// Every config in the portfolio carries a "$schema" URL containing "//". A
// comment stripper that is not string-aware cuts that URL in half, so this is the
// case that decides whether the whole approach is sound.
func TestStripJSON5PreservesURLsInsideStrings(t *testing.T) {
	src := `{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  // a real comment, which must go
  "extends": ["config:recommended", ":disableDependencyDashboard"]
}`

	var cfg struct {
		Schema  string   `json:"$schema"`
		Extends []string `json:"extends"`
	}

	stripped := mustStrip(t, src)
	if err := json.Unmarshal(stripped, &cfg); err != nil {
		t.Fatalf("stripped document did not parse: %v\n%s", err, stripped)
	}

	if cfg.Schema != "https://docs.renovatebot.com/renovate-schema.json" {
		t.Errorf("schema URL was corrupted by comment stripping: %q", cfg.Schema)
	}

	if len(cfg.Extends) != 2 {
		t.Errorf("extends = %v, want 2 entries", cfg.Extends)
	}
}

func TestStripJSON5HandlesBlockCommentsAndTrailingCommas(t *testing.T) {
	src := `{
  /* block
     comment */
  "extends": [
    "config:recommended",
  ],
  "dependencyDashboard": false,
}`

	var cfg renovateConfig
	if err := json.Unmarshal(mustStrip(t, src), &cfg); err != nil {
		t.Fatalf("did not parse: %v", err)
	}

	if cfg.DependencyDashboard == nil || *cfg.DependencyDashboard {
		t.Errorf("dependencyDashboard = %v, want explicit false", cfg.DependencyDashboard)
	}
}

// A comma inside a string value is data, not syntax.
func TestRemoveTrailingCommasLeavesStringsAlone(t *testing.T) {
	src := `{"description": "a, b, c", "extends": ["config:recommended",]}`

	var cfg struct {
		Description string   `json:"description"`
		Extends     []string `json:"extends"`
	}

	if err := json.Unmarshal(mustStrip(t, src), &cfg); err != nil {
		t.Fatalf("did not parse: %v", err)
	}

	if cfg.Description != "a, b, c" {
		t.Errorf("description = %q, want %q", cfg.Description, "a, b, c")
	}
}

// --- resolution -----------------------------------------------------------

func TestResolveDashboard(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		want    dashboardState
		wantErr bool
	}{
		{
			name: "config:recommended alone inherits the dashboard",
			body: `{"extends":["config:recommended"]}`,
			want: dashboardEnabled,
		},
		{
			name: "opt-out preset after recommended disables it",
			body: `{"extends":["config:recommended",":disableDependencyDashboard"]}`,
			want: dashboardDisabled,
		},
		{
			name: "explicit false overrides an enabling preset",
			body: `{"extends":["config:recommended"],"dependencyDashboard":false}`,
			want: dashboardDisabled,
		},
		{
			name: "explicit true overrides the opt-out preset",
			body: `{"extends":["config:recommended",":disableDependencyDashboard"],"dependencyDashboard":true}`,
			want: dashboardEnabled,
		},
		{
			name: "no extends and no key is Renovate's disabled default",
			body: `{"labels":["automated"]}`,
			want: dashboardDisabled,
		},
		{
			name: "later preset wins over an earlier one",
			body: `{"extends":[":disableDependencyDashboard","config:recommended"]}`,
			want: dashboardEnabled,
		},
		{
			name: "parameterised preset resolves through its base name",
			body: `{"extends":["config:recommended",":disableDependencyDashboard",":semanticCommitTypeAll(fix)"]}`,
			want: dashboardDisabled,
		},
		{
			name:    "an unknown preset is an error, never an assumed neutral",
			body:    `{"extends":["config:recommended","github>devantler-tech/renovate-config"]}`,
			wantErr: true,
		},
		{
			name:    "JSON5 beyond comments and trailing commas is an error",
			body:    `{extends: ['config:recommended']}`,
			wantErr: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			writeFile(t, filepath.Join(root, "renovate.json"), tc.body)

			got, err := resolveDashboard(root, "renovate.json")

			if tc.wantErr {
				if err == nil {
					t.Fatalf("want an error, got state %v", got)
				}

				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if got != tc.want {
				t.Errorf("state = %v, want %v", got, tc.want)
			}
		})
	}
}

// The five configs actually in the portfolio, so a refactor that breaks real
// input fails here rather than in CI against the submodules.
func TestResolvesTheRealPortfolioConfigs(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{
			name: "monorepo",
			body: `{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended", ":disableDependencyDashboard", ":semanticCommitTypeAll(fix)"],
  "github-actions": {"enabled": false}
}`,
		},
		{
			name: "platform (explicit false beside config:recommended)",
			body: `{"$schema":"https://docs.renovatebot.com/renovate-schema.json","extends":["config:recommended"],"dependencyDashboard":false}`,
		},
		{
			name: "kyverno-policies (explicit false)",
			body: `{"$schema":"https://docs.renovatebot.com/renovate-schema.json","extends":["config:recommended"],"dependencyDashboard":false}`,
		},
		{
			name: "platform-template",
			body: `{"$schema":"https://docs.renovatebot.com/renovate-schema.json","extends":["config:recommended",":disableDependencyDashboard",":semanticCommitTypeAll(fix)"]}`,
		},
		{
			name: "provider-upjet-unifi (JSON5 with comments)",
			body: `{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended", ":disableDependencyDashboard"],
  // The maximum number of PRs to be created in parallel
  "prConcurrentLimit": 5,
  // The branches renovate should target
  "baseBranches": ["main"],
  "semanticCommits": "disabled",
  "labels": ["automated"]
}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			writeFile(t, filepath.Join(root, "renovate.json5"), tc.body)

			got, err := resolveDashboard(root, "renovate.json5")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if got != dashboardDisabled {
				t.Errorf("state = %v, want disabled — this config is live in the portfolio", got)
			}
		})
	}
}

// --- end-to-end -----------------------------------------------------------

func TestPassesWhenEveryDeclaredConfigOptsOut(t *testing.T) {
	root := newRoot(t, "platform")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":["config:recommended",":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "platform/.github/renovate.json"), `{"extends":["config:recommended"],"dependencyDashboard":false}`)

	code, out := runIn(t, root)
	if code != 0 {
		t.Fatalf("exit = %d, want 0\n%s", code, out)
	}

	if !strings.Contains(out, "2 config(s) checked") {
		t.Errorf("expected a count of what was checked, got:\n%s", out)
	}
}

func TestFailsWhenAConfigEnablesTheDashboard(t *testing.T) {
	root := newRoot(t, "platform")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":["config:recommended",":disableDependencyDashboard"]}`)
	// Inherits the dashboard by not opting out — the exact drift this guards.
	writeFile(t, filepath.Join(root, "platform/.github/renovate.json"), `{"extends":["config:recommended"]}`)

	code, out := runIn(t, root)
	if code != 1 {
		t.Fatalf("exit = %d, want 1\n%s", code, out)
	}

	if !strings.Contains(out, "resolves to dependencyDashboard: true") {
		t.Errorf("expected the drift to be named, got:\n%s", out)
	}
}

// A declared root that is not checked out must NOT read as compliant.
func TestFailsClosedWhenADeclaredRootIsNotCheckedOut(t *testing.T) {
	root := newRoot(t, "platform")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	// platform/ deliberately absent, exactly like an uninitialised submodule.

	code, out := runIn(t, root)
	if code != 2 {
		t.Fatalf("exit = %d, want 2 — an unverifiable root must never pass\n%s", code, out)
	}

	if !strings.Contains(out, "could not verify") {
		t.Errorf("expected the reason to be stated, got:\n%s", out)
	}
}

// A repository that grows a config nobody declared must force a decision.
func TestFailsWhenAnUndeclaredRepoHasAConfig(t *testing.T) {
	root := newRoot(t, "platform", "applications/ksail")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "platform/.github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	// ksail is checked out and has gained a config, but is not declared.
	writeFile(t, filepath.Join(root, "applications/ksail/renovate.json"), `{"extends":["config:recommended"]}`)

	code, out := runIn(t, root)
	if code != 2 {
		t.Fatalf("exit = %d, want 2\n%s", code, out)
	}

	if !strings.Contains(out, "not declared") {
		t.Errorf("expected the undeclared config to be named, got:\n%s", out)
	}
}

// An undeclared repo with NO config is fine — most of the portfolio is in that
// state, and a repo without a config cannot enable a dashboard.
func TestIgnoresUndeclaredRepoWithoutAConfig(t *testing.T) {
	root := newRoot(t, "platform", "applications/ksail")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "platform/.github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "applications/ksail/README.md"), "no renovate config here\n")

	if code, out := runIn(t, root); code != 0 {
		t.Fatalf("exit = %d, want 0\n%s", code, out)
	}
}

// Renovate itself errors on more than one config file; so does this.
func TestFailsWhenARootHasTwoConfigFiles(t *testing.T) {
	root := newRoot(t)
	withDeclaredRoots(t, ".")

	writeFile(t, filepath.Join(root, "renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)

	code, out := runIn(t, root)
	if code != 2 {
		t.Fatalf("exit = %d, want 2\n%s", code, out)
	}

	if !strings.Contains(out, "more than one") {
		t.Errorf("expected the duplicate configs to be named, got:\n%s", out)
	}
}

func TestErrorsWhenGitmodulesIsMissing(t *testing.T) {
	root := t.TempDir()
	withDeclaredRoots(t)

	if code, out := runIn(t, root); code != 2 {
		t.Fatalf("exit = %d, want 2\n%s", code, out)
	}
}

// --- the ways a config can outrun this check ------------------------------
//
// Each case below is a config Renovate reads differently from the reduced model
// here. The check's stated contract is that anything it cannot resolve offline
// is an error, so every one of them must fail closed rather than resolve to a
// comfortable "disabled".

// An unterminated /* swallows the rest of the document. Renovate cannot parse
// such a file at all, so a green verdict here would be about a document that
// does not exist.
func TestUnterminatedBlockCommentIsAnError(t *testing.T) {
	root := t.TempDir()
	// Complete, opt-out JSON followed by a comment that never closes. Dropping
	// the malformed suffix leaves a document that parses and reads as disabled.
	writeFile(t, filepath.Join(root, "renovate.json"), `{"extends":[":disableDependencyDashboard"]} /* oops`)

	if _, err := resolveDashboard(root, "renovate.json"); err == nil {
		t.Fatal("want an error: an unterminated block comment makes the file unparseable to Renovate," +
			" so silently discarding it certifies a document Renovate never sees")
	}
}

// A terminated block comment at the very end of the file is valid JSON5 and must
// keep working — the guard above must reject the malformed case without
// rejecting this one.
func TestTerminatedTrailingBlockCommentStillResolves(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "renovate.json"), `{"extends":[":disableDependencyDashboard"]} /* fine */`)

	got, err := resolveDashboard(root, "renovate.json")
	if err != nil {
		t.Fatalf("unexpected error on a well-formed trailing comment: %v", err)
	}

	if got != dashboardDisabled {
		t.Errorf("state = %v, want disabled", got)
	}
}

// Renovate's ignorePresets removes a preset from resolution, including the
// opt-out this check relies on. Silently discarding the key turns a config that
// really does inherit the dashboard into a green result.
func TestIgnorePresetsIsAnError(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "renovate.json"),
		`{"extends":["config:recommended",":disableDependencyDashboard"],"ignorePresets":[":disableDependencyDashboard"]}`)

	if _, err := resolveDashboard(root, "renovate.json"); err == nil {
		t.Fatal("want an error: ignorePresets can cancel the very opt-out this check reads," +
			" so a config carrying it cannot be resolved by this reduced model")
	}
}

// Renovate reads a "renovate" key in package.json as a config location. The file
// comment promises this check fails closed on it; without that, such a config is
// invisible and the repository reads as config-less.
func TestPackageJSONRenovateKeyIsAnError(t *testing.T) {
	root := newRoot(t, "platform")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "platform/package.json"),
		`{"name":"platform","renovate":{"extends":["config:recommended"]}}`)

	code, out := runIn(t, root)
	if code != 2 {
		t.Fatalf("exit = %d, want 2 — a package.json Renovate config must not read as no config\n%s", code, out)
	}

	if !strings.Contains(out, "package.json") {
		t.Errorf("expected the package.json config to be named, got:\n%s", out)
	}
}

// The same key in an UNDECLARED repository is the case that matters most: it is
// exactly "a repository grew a config nobody looked at", and treating it as
// config-less is how it would stay unmonitored.
func TestPackageJSONRenovateKeyInAnUndeclaredRepoIsAnError(t *testing.T) {
	root := newRoot(t, "platform", "applications/ksail")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "platform/.github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "applications/ksail/package.json"),
		`{"name":"ksail","renovate":{"extends":["config:recommended"]}}`)

	code, out := runIn(t, root)
	if code != 2 {
		t.Fatalf("exit = %d, want 2\n%s", code, out)
	}

	if !strings.Contains(out, "not declared") {
		t.Errorf("expected the undeclared config to be named, got:\n%s", out)
	}
}

// A package.json with no "renovate" key is not a config location, and must not
// be mistaken for one — most repositories in the portfolio have one.
func TestPackageJSONWithoutARenovateKeyIsNotAConfig(t *testing.T) {
	root := newRoot(t, "applications/ksail")
	withDeclaredRoots(t, ".")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "applications/ksail/package.json"), `{"name":"ksail","devDependencies":{}}`)

	if code, out := runIn(t, root); code != 0 {
		t.Fatalf("exit = %d, want 0 — an ordinary package.json is not a Renovate config\n%s", code, out)
	}
}

// A package.json that cannot be parsed cannot be ruled out as a config location
// either, so it fails closed like every other unreadable input.
func TestUnparseablePackageJSONIsAnError(t *testing.T) {
	root := newRoot(t, "applications/ksail")
	withDeclaredRoots(t, ".")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "applications/ksail/package.json"), `{"name": broken`)

	code, out := runIn(t, root)
	if code != 2 {
		t.Fatalf("exit = %d, want 2\n%s", code, out)
	}

	if !strings.Contains(out, "package.json") {
		t.Errorf("expected the unreadable package.json to be named, got:\n%s", out)
	}
}

// --- saying what the green result actually covers --------------------------

// Most mapped repositories are not checked out when this runs, and an
// uninspected repository is not the same as one verified to have no config. A
// pass must say which is which, or it reads as portfolio-wide coverage it does
// not have.
func TestSuccessOutputNamesTheRepositoriesItCouldNotInspect(t *testing.T) {
	root := newRoot(t, "platform", "applications/ksail", "applications/wedding-app")
	withDeclaredRoots(t, ".", "platform")

	writeFile(t, filepath.Join(root, ".github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	writeFile(t, filepath.Join(root, "platform/.github/renovate.json"), `{"extends":[":disableDependencyDashboard"]}`)
	// ksail is checked out and clean; wedding-app is absent, like a submodule
	// CI cannot clone.
	writeFile(t, filepath.Join(root, "applications/ksail/README.md"), "no renovate config here\n")

	code, out := runIn(t, root)
	if code != 0 {
		t.Fatalf("exit = %d, want 0\n%s", code, out)
	}

	if !strings.Contains(out, "applications/wedding-app") {
		t.Errorf("expected the uninspected repository to be named, got:\n%s", out)
	}

	if strings.Contains(out, "applications/ksail") {
		t.Errorf("applications/ksail WAS inspected and has no config; it must not be reported as uninspected:\n%s", out)
	}
}
