// Command renovate-dashboard-drift enforces one portfolio invariant: no mapped
// repository's Renovate configuration may resolve to an ENABLED Dependency
// Dashboard.
//
// The dashboard is an open, automation-owned issue that never closes. AGENTS.md
// has to carve it out of the oldest-actionable queue by author precisely because
// it otherwise heads that queue forever, which is the agent confusion behind the
// maintainer's standing direction to disable it (monorepo#2547). Closing one by
// hand does not help — Renovate recreates it while the setting resolves to true.
//
// The invariant was established once by a manual audit of every config. This
// check is what keeps it true without repeating that audit: a config that starts
// enabling the dashboard, or a repository that gains a config nobody looked at,
// fails CI instead of waiting for the next person to notice.
//
// # Why it reads configs rather than looking for dashboard issues
//
// The absence of an open dashboard issue proves nothing: Renovate is not enabled
// on several of these repositories yet, so the setting is latent and would only
// become a dashboard later. The issue's own acceptance criterion says to verify
// by reading each config, and that is what this does.
//
// # Failing closed
//
// A submodule that is not checked out looks exactly like a repository with no
// Renovate config — both are "no file on disk". Treating that as compliant would
// make the check silently vacuous the moment CI's checkout changed, which is the
// worst failure mode a guard can have: green while verifying nothing. So the set
// of roots known to carry a config is DECLARED below and enforced both ways:
//
//   - a declared root that is missing, empty, or has lost its config is an ERROR,
//     not a pass — the check could not verify what it claims to verify;
//   - a checked-out root that carries an UNDECLARED config is also an ERROR, so a
//     repository gaining a Renovate config forces someone to record it here and
//     decide, rather than being covered by nobody.
//
// Anything this cannot resolve offline — an unrecognised preset, ignorePresets,
// a Renovate config living under package.json's "renovate" key, a JSON5 feature
// beyond comments and trailing commas — is an error for the same reason. The
// check never guesses a config's meaning.
//
// # What a pass does NOT cover
//
// The undeclared-config half only sees repositories that are actually checked
// out, and most of the portfolio is not: CI clones the declared roots, and
// several mapped repositories are private and cannot be cloned there at all. So
// a pass is a statement about what was read, not about the portfolio — and it
// prints the mapped repositories it could not inspect, so the difference is
// visible in the log rather than implied away. Widening that coverage is
// tracked separately; it is a CI cost question, not a change to what this
// program can prove.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// declaredConfigRoots are the repository roots known to carry a Renovate config,
// as paths relative to the monorepo root ("." is the monorepo itself).
//
// Adding a Renovate config to any other mapped repository requires adding it
// here. That is deliberate: it is the step that makes a new config visible to
// this invariant instead of unmonitored.
var declaredConfigRoots = []string{
	".",
	"platform",
	"libraries/kyverno-policies",
	"libraries/provider-upjet-unifi",
	"templates/platform-template",
}

// configFileNames are the standalone config locations Renovate reads.
//
// package.json's "renovate" key is a location too, but it is not a standalone
// file: an ordinary package.json without that key is not a config at all. It is
// detected separately, by packageJSONConfig, so that "has no Renovate config"
// stays distinguishable from "has one this check does not look at".
var configFileNames = []string{
	"renovate.json",
	"renovate.json5",
	".github/renovate.json",
	".github/renovate.json5",
	".renovaterc",
	".renovaterc.json",
	".renovaterc.json5",
}

// dashboardState is what a config resolves to for the Dependency Dashboard.
type dashboardState int

const (
	dashboardDisabled dashboardState = iota
	dashboardEnabled
)

// presetEffect records what a known preset does to the Dependency Dashboard.
type presetEffect int

const (
	presetNeutral presetEffect = iota
	presetEnables
	presetDisables
)

// knownPresets is the closed set of presets this check can resolve offline.
//
// A preset is listed only once someone has established what it does to the
// dashboard. An unlisted preset is an ERROR rather than an assumed neutral,
// because assuming neutral is how an enabling preset would slip in: the whole
// point of the check is that nobody has to remember which presets matter.
//
// Parameterised presets are looked up with their argument list stripped, so
// `:semanticCommitTypeAll(fix)` resolves through `:semanticCommitTypeAll`.
var knownPresets = map[string]presetEffect{
	// config:recommended and the legacy config:base both include
	// :dependencyDashboard, which is why "enabled" is what a repository
	// inherits unless it opts out.
	"config:recommended":             presetEnables,
	"config:base":                    presetEnables,
	"config:best-practices":          presetEnables, // extends config:recommended
	":dependencyDashboard":           presetEnables,
	":disableDependencyDashboard":    presetDisables,
	":semanticCommitTypeAll":         presetNeutral,
	":semanticCommits":               presetNeutral,
	":semanticCommitsDisabled":       presetNeutral,
	":disableRateLimiting":           presetNeutral,
	":automergeMinor":                presetNeutral,
	":automergePatch":                presetNeutral,
	"config:semverAllMonthly":        presetNeutral,
	"security:only-security-updates": presetNeutral,
}

// renovateConfig is the fragment of a Renovate config this check needs.
//
// DependencyDashboard is a pointer so an ABSENT key is distinguishable from an
// explicit false — absent means the presets decide, explicit false means they do
// not.
type renovateConfig struct {
	DependencyDashboard *bool    `json:"dependencyDashboard"`
	Extends             []string `json:"extends"`

	// IgnorePresets cancels presets during resolution, including the opt-out
	// this check reads. Modelling it properly means resolving preset bodies —
	// ignorePresets applies to presets nested inside presets too — which is
	// exactly the offline resolution this check does not attempt. It is
	// captured only so its presence can be refused.
	IgnorePresets []string `json:"ignorePresets"`
}

type finding struct {
	root string
	path string
	msg  string
}

// errRootAbsent marks the one findConfigs failure that means "nothing was read
// here", as opposed to "something here could not be understood".
//
// The distinction decides the verdict for an UNDECLARED root: absent is the
// ordinary state of most of the portfolio and is reported as uninspected, while
// any other error is a real finding that must not be filed under it.
var errRootAbsent = errors.New("not checked out")

func main() {
	root := flag.String("root", ".", "path to the monorepo root")
	flag.Parse()

	code := run(*root, os.Stdout, os.Stderr)
	os.Exit(code)
}

// run returns 0 when every declared config resolves to a disabled dashboard, 1
// when at least one resolves to enabled, and 2 when the check could not verify
// what it claims to verify.
func run(root string, stdout, stderr io.Writer) int {
	declared := map[string]bool{}
	for _, r := range declaredConfigRoots {
		declared[r] = true
	}

	var (
		drift       []finding
		unusable    []finding
		checked     []string
		uninspected []string
	)

	// Every declared root must be present, checked out, and still carrying
	// exactly one config.
	for _, r := range declaredConfigRoots {
		paths, err := findConfigs(root, r)
		if err != nil {
			unusable = append(unusable, finding{root: r, msg: err.Error()})

			continue
		}

		if len(paths) == 0 {
			unusable = append(unusable, finding{
				root: r,
				msg: "declared as carrying a Renovate config, but none is present." +
					" If the submodule is simply not checked out, check it out — a" +
					" missing checkout and a deleted config are indistinguishable" +
					" here, so neither can be treated as compliant. If the config was" +
					" removed on purpose, drop this root from declaredConfigRoots.",
			})

			continue
		}

		state, err := resolveDashboard(root, paths[0])
		if err != nil {
			unusable = append(unusable, finding{root: r, path: paths[0], msg: err.Error()})

			continue
		}

		checked = append(checked, paths[0])

		if state == dashboardEnabled {
			drift = append(drift, finding{
				root: r,
				path: paths[0],
				msg: "resolves to dependencyDashboard: true. Opt out with the" +
					" `:disableDependencyDashboard` preset, or set" +
					" `\"dependencyDashboard\": false` explicitly.",
			})
		}
	}

	// Any OTHER checked-out mapped repository that has grown a config must be
	// declared, so it cannot sit unmonitored.
	subs, err := submodulePaths(root)
	if err != nil {
		fmt.Fprintf(stderr, "::error::renovate-dashboard-drift: %v\n", err)

		return 2
	}

	for _, r := range subs {
		if declared[r] {
			continue
		}

		paths, err := findConfigs(root, r)
		if errors.Is(err, errRootAbsent) {
			// Not checked out. That is NOT the same as having no config —
			// nothing was read — so it is reported alongside the pass rather
			// than counted as clean.
			uninspected = append(uninspected, r)

			continue
		}

		if err != nil {
			// Present but not understandable: a real finding, never filed
			// under "uninspected".
			unusable = append(unusable, finding{root: r, msg: err.Error()})

			continue
		}

		if len(paths) == 0 {
			// Checked out and genuinely config-less. A repository without a
			// Renovate config cannot enable a dashboard.
			continue
		}

		unusable = append(unusable, finding{
			root: r,
			path: paths[0],
			msg: "has a Renovate config that is not declared in declaredConfigRoots," +
				" so this invariant does not cover it. Add the root there.",
		})
	}

	for _, f := range unusable {
		fmt.Fprintf(stderr, "::error::%s: %s\n", f.label(), f.msg)
	}

	for _, f := range drift {
		fmt.Fprintf(stderr, "::error::%s: %s\n", f.label(), f.msg)
	}

	if len(unusable) > 0 {
		fmt.Fprintln(stderr, "::error::renovate-dashboard-drift: could not verify every declared config; treating that as a failure rather than a pass")

		return 2
	}

	if len(drift) > 0 {
		return 1
	}

	sort.Strings(checked)
	fmt.Fprintf(stdout, "renovate-dashboard-drift: %d config(s) checked, all resolve to a disabled Dependency Dashboard:\n", len(checked))

	for _, p := range checked {
		fmt.Fprintf(stdout, "  ok  %s\n", p)
	}

	// A pass covers what was read, and most of the portfolio is usually not
	// checked out. Saying so is the difference between "no undeclared config
	// exists" and "none was found where I looked" — only the second is true.
	if len(uninspected) > 0 {
		sort.Strings(uninspected)
		fmt.Fprintf(stdout, "%d mapped repositor%s NOT inspected (not checked out here), so an undeclared config in one would not have been seen:\n",
			len(uninspected), plural(len(uninspected), "y was", "ies were"))

		for _, r := range uninspected {
			fmt.Fprintf(stdout, "  --  %s\n", r)
		}
	}

	return 0
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}

	return many
}

func (f finding) label() string {
	if f.path != "" {
		return f.path
	}

	return f.root
}

// submodulePaths reads the mapped repository set from .gitmodules.
//
// This is a tracked file, so it is readable without checking out anything, which
// keeps the check network-free in the same way the Active Projects drift check
// is.
func submodulePaths(root string) ([]string, error) {
	raw, err := os.ReadFile(filepath.Join(root, ".gitmodules"))
	if err != nil {
		return nil, fmt.Errorf("could not read .gitmodules: %w", err)
	}

	var out []string

	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)

		rest, found := strings.CutPrefix(line, "path")
		if !found {
			continue
		}

		rest = strings.TrimSpace(rest)
		if value, isAssignment := strings.CutPrefix(rest, "="); isAssignment {
			out = append(out, strings.TrimSpace(value))
		}
	}

	return out, nil
}

// findConfigs returns the Renovate config files present under a root.
//
// More than one is reported as an error rather than resolved by precedence:
// Renovate itself errors on multiple config files, so a repository in that state
// has a problem this check should surface rather than paper over.
func findConfigs(root, rel string) ([]string, error) {
	dir := filepath.Join(root, rel)

	info, err := os.Stat(dir)
	if err != nil {
		// Only a genuinely missing directory is the ordinary "not checked out"
		// state. A permission error, an I/O error, or a path whose parent is not
		// a directory means the root is there and could not be read — reporting
		// that as merely uninspected would let a real failure pass.
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w (%v)", errRootAbsent, err)
		}

		return nil, fmt.Errorf("could not be inspected (%v)", err)
	}

	if !info.IsDir() {
		return nil, errors.New("is not a directory")
	}

	var found []string

	for _, name := range configFileNames {
		p := filepath.Join(dir, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			found = append(found, filepath.ToSlash(filepath.Join(rel, name)))
		}
	}

	hasPackageConfig, err := packageJSONConfig(filepath.Join(dir, "package.json"))
	if err != nil {
		return nil, err
	}

	if hasPackageConfig {
		found = append(found, filepath.ToSlash(filepath.Join(rel, "package.json")))
	}

	if len(found) > 1 {
		return nil, fmt.Errorf("has %d Renovate config files (%s); Renovate errors on more than one", len(found), strings.Join(found, ", "))
	}

	return found, nil
}

// packageJSONConfig reports whether a package.json carries a "renovate" key,
// which Renovate reads as a config location.
//
// A missing package.json is simply not a config. An UNPARSEABLE one is an error:
// it cannot be ruled out as a config location, and "I could not tell" must never
// resolve to "there is nothing here" in a check whose whole value is that a
// config nobody looked at fails loudly.
func packageJSONConfig(path string) (bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}

		return false, fmt.Errorf("has a package.json that could not be read (%v)", err)
	}

	var pkg map[string]json.RawMessage
	if err := json.Unmarshal(raw, &pkg); err != nil {
		return false, fmt.Errorf(
			"has a package.json that could not be parsed (%v), so it cannot be ruled out as"+
				" a Renovate config location. Renovate reads a top-level \"renovate\" key there", err)
	}

	_, ok := pkg["renovate"]

	return ok, nil
}

// resolveDashboard reports what a config file resolves to for the dashboard.
//
// rel is relative to root, so the two are joined here rather than relying on the
// process working directory — a check invoked with --root elsewhere must read the
// configs under THAT root, not whatever happens to sit beside the caller.
func resolveDashboard(root, rel string) (dashboardState, error) {
	if filepath.Base(rel) == "package.json" {
		return dashboardDisabled, errors.New(
			"carries its Renovate config under package.json's \"renovate\" key, which this" +
				" check does not resolve. Move the config to a renovate.json so this" +
				" invariant covers it, or teach this check to read the key")
	}

	raw, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		return dashboardDisabled, fmt.Errorf("could not read: %w", err)
	}

	stripped, err := stripJSON5(raw)
	if err != nil {
		return dashboardDisabled, err
	}

	var cfg renovateConfig
	if err := json.Unmarshal(stripped, &cfg); err != nil {
		return dashboardDisabled, fmt.Errorf(
			"could not parse after removing JSON5 comments and trailing commas (%v)."+
				" This check supports JSON plus those two JSON5 features; a config using"+
				" more of JSON5 needs a real JSON5 parser here before it can be verified", err)
	}

	// An explicit top-level key wins over every preset, so it is decided first —
	// and deciding it first is also what keeps the ignorePresets refusal below
	// from rejecting a config whose verdict presets cannot affect at all.
	if cfg.DependencyDashboard != nil {
		if *cfg.DependencyDashboard {
			return dashboardEnabled, nil
		}

		return dashboardDisabled, nil
	}

	// From here the presets decide the verdict, so ignorePresets — which can
	// cancel the very `:disableDependencyDashboard` opt-out this check reads —
	// makes the config unresolvable by preset names alone.
	if len(cfg.IgnorePresets) > 0 {
		return dashboardDisabled, fmt.Errorf(
			"sets ignorePresets (%s) with no explicit dependencyDashboard key, so the"+
				" verdict rests on presets that ignorePresets can cancel — including"+
				" `:disableDependencyDashboard` itself. Resolving that needs the preset"+
				" bodies, which this offline check does not have, so the config is"+
				" reported as unverifiable rather than assumed compliant."+
				" Setting `\"dependencyDashboard\": false` explicitly settles it",
			strings.Join(cfg.IgnorePresets, ", "))
	}

	// A later preset overrides an earlier one.
	state := dashboardDisabled

	for _, preset := range cfg.Extends {
		effect, known := knownPresets[presetKey(preset)]
		if !known {
			return dashboardDisabled, fmt.Errorf(
				"extends the preset %q, which this check does not know how to resolve"+
					" offline. Add it to knownPresets once its effect on the Dependency"+
					" Dashboard is established — guessing it is neutral is how an"+
					" enabling preset would slip in unnoticed", preset)
		}

		switch effect {
		case presetEnables:
			state = dashboardEnabled
		case presetDisables:
			state = dashboardDisabled
		case presetNeutral:
		}
	}

	return state, nil
}

// presetKey normalises a preset reference for lookup by dropping any argument
// list, so `:semanticCommitTypeAll(fix)` and `:semanticCommitTypeAll` are the
// same preset.
func presetKey(preset string) string {
	if i := strings.Index(preset, "("); i >= 0 {
		return preset[:i]
	}

	return preset
}

// stripJSON5 removes // and /* */ comments and trailing commas, leaving string
// literals untouched.
//
// String-awareness is the whole point. Every config in this portfolio carries
// `"$schema": "https://docs.renovatebot.com/renovate-schema.json"`, and a naive
// comment strip would cut that URL in half at the `//` and produce a document
// that either fails to parse or, worse, parses into something else. The same
// applies to a `//` inside any other string value.
func stripJSON5(src []byte) ([]byte, error) {
	out := make([]byte, 0, len(src))

	var (
		inString bool
		quote    byte
		escaped  bool
	)

	for i := 0; i < len(src); i++ {
		c := src[i]

		if inString {
			out = append(out, c)

			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == quote:
				inString = false
			}

			continue
		}

		if c == '"' || c == '\'' {
			inString, quote = true, c

			out = append(out, c)

			continue
		}

		if c == '/' && i+1 < len(src) {
			if src[i+1] == '/' {
				for i < len(src) && src[i] != '\n' {
					i++
				}

				// Keep the newline so line-oriented structure survives.
				if i < len(src) {
					out = append(out, src[i])
				}

				continue
			}

			if src[i+1] == '*' {
				i += 2
				for i+1 < len(src) && !(src[i] == '*' && src[i+1] == '/') {
					i++
				}

				// Running off the end means the comment never closed. Dropping
				// the remainder would leave a document that parses cleanly and
				// says nothing about the file Renovate would choke on, so this
				// is an error rather than a silent truncation.
				if i+1 >= len(src) || src[i] != '*' || src[i+1] != '/' {
					return nil, errors.New(
						"has an unterminated /* block comment, so it is not valid JSON5 and" +
							" Renovate cannot parse it. Close the comment; this check will not" +
							" verify a document it had to repair first")
				}

				i++ // land on the '/' so the loop's i++ moves past it

				continue
			}
		}

		out = append(out, c)
	}

	return removeTrailingCommas(out), nil
}

// removeTrailingCommas drops a comma that is followed only by whitespace and a
// closing brace or bracket. It is string-aware for the same reason stripJSON5
// is: a comma inside a string value is data, not syntax.
func removeTrailingCommas(src []byte) []byte {
	out := make([]byte, 0, len(src))

	var (
		inString bool
		escaped  bool
	)

	for i := 0; i < len(src); i++ {
		c := src[i]

		if inString {
			out = append(out, c)

			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == '"':
				inString = false
			}

			continue
		}

		if c == '"' {
			inString = true

			out = append(out, c)

			continue
		}

		if c == ',' {
			j := i + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r') {
				j++
			}

			if j < len(src) && (src[j] == '}' || src[j] == ']') {
				continue
			}
		}

		out = append(out, c)
	}

	return out
}
