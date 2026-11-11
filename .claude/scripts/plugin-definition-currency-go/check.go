package main

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

type check struct {
	o              options
	stdout, stderr io.Writer
	status         int
	timeout        string

	pinSource     string // where the pin came from; printed with every verdict
	adoptedCommit string // the consumer commit whose gitlink is the adopted pin
	adoptedBranch string // the remote's default branch, when it advertises one
	adoptedURL    string // the location git contacted for it, with no credentials in it
	worktreeHead  string // this working tree's HEAD commit
	worktreePin   string // the gitlink recorded at that commit
	worktreeLine  string // the header line describing it
	worktreeNote  string // ROLLOUT, SUPERSEDED or UNADOPTED when it is not the adopted pin

	installedListing []string // every installed file and symlink under agents/ and skills/
	reviewed         string   // "<blob>\t<mode>\t<path>" per file of the loaded surface at a pin
	quiet            bool
}

// say prints one line unless --quiet.
func (c *check) say(s string) {
	if !c.quiet {
		fmt.Fprintln(c.stdout, s)
	}
}

func (c *check) main(args []string) error {
	o, help, err := parseArgs(args)
	if err != nil {
		return err
	}
	if help {
		fmt.Fprint(c.stdout, helpText)
		return nil
	}
	c.o, c.quiet = o, o.quiet
	if err := c.validate(); err != nil {
		return err
	}
	if c.o.repoRoot == "" {
		top, ok := gitOut("", "rev-parse", "--show-toplevel")
		if !ok {
			return die("not inside a git repository")
		}
		c.o.repoRoot = top
	}
	if info, err := os.Stat(c.o.repoRoot); err != nil || !info.IsDir() {
		return die("repo root does not exist: %s", c.o.repoRoot)
	}
	if err := c.resolvePin(); err != nil {
		return err
	}
	if c.o.runtime == "git-ref" {
		return c.gitRef()
	}
	if err := c.resolveInstalled(); err != nil {
		return err
	}
	return c.compare()
}

// worktreeNotice is printed after the verdict, never instead of it. sourceRelation says how the
// checked copy relates to the working tree's pin.
func (c *check) worktreeNotice(sourceRelation string) {
	if c.o.adoptedRefSet {
		// Printed with EVERY --adopted-ref verdict: a CURRENT measured against a stale ref is the
		// fail-open direction.
		c.say("")
		c.say("CALLER-NAMED PIN — this check did not ask the remote which pin is adopted. It measured")
		c.say("  against " + c.o.adoptedRef + " as it stands in this repository.")
		c.say("  The verdict above holds for the deployment only if that revision was fetched from the")
		c.say("  default branch just before this check, and that fetch succeeded. Otherwise it is")
		c.say("  UNCHECKED: never read it as current.")
	}
	if c.worktreeNote == "" {
		return
	}
	c.say("")
	switch c.worktreeNote {
	case "ROLLOUT":
		c.say("ROLLOUT — this working tree proposes a pin the deployment has not adopted. Its branch")
		c.say("  changes the gitlink, and that change is not adopted until it merges.")
	case "SUPERSEDED":
		c.say("SUPERSEDED — this working tree holds a pin the deployment no longer uses. The default")
		c.say("  branch moved the gitlink after this checkout was taken.")
	default:
		c.say("UNADOPTED — this working tree holds a pin that is not the adopted one, and no common")
		c.say("  history shows which side moved.")
	}
	c.say("    working tree : " + c.worktreePin)
	c.say("    adopted      : " + c.o.gitlink)
	c.say("  " + sourceRelation)
	c.say("  This describes the WORKING TREE, not the lane. The verdict above is measured against the")
	c.say("  adopted pin and is the only lane-drift signal: never open, update or close a lane-drift")
	c.say("  tracker on this notice, and never refresh an install onto a pin that is not adopted.")
}

// gitRef compares only a declared source revision with the consumer pin. A declared source ref does
// not identify what a native harness loaded, so it never substitutes another runtime's cache.
func (c *check) gitRef() error {
	o := &c.o
	sourceSub := o.repoRoot + "/" + o.submodulePath
	if _, err := os.Stat(sourceSub + "/.git"); err != nil {
		return die("plugin source submodule is not initialised: %s", sourceSub)
	}
	// A plain `git show <ref>:<path>` resolves THROUGH refs/replace, and the replacement namespace
	// is configurable (GIT_REPLACE_REF_BASE). Follow the namespace git honours, and keep scanning
	// the default too, so neither placement can hide a replacement.
	replaceBase := strings.TrimSuffix(envDefault("GIT_REPLACE_REF_BASE", "refs/replace/"), "/")
	patterns := []string{"refs/replace/*"}
	if replaceBase != "refs/replace" {
		patterns = append(patterns, replaceBase+"/*")
	}
	replaced, ok := gitOut(sourceSub, append([]string{"for-each-ref", "--format=%(refname)"}, patterns...)...)
	if !ok {
		return die("cannot enumerate replacement refs in %s", sourceSub)
	}
	if replaced != "" {
		// UNKNOWN reasons survive --quiet: this explanation goes to stderr.
		var b strings.Builder
		fmt.Fprintf(&b, "pinned revision        : %s\n\n", o.gitlink)
		b.WriteString("UNKNOWN — the plugin submodule carries replacement ref(s):\n")
		for _, r := range strings.Split(replaced, "\n") {
			if r != "" {
				fmt.Fprintf(&b, "  %s\n", r)
			}
		}
		b.WriteString("\nA source reader using plain 'git show' resolves through refs/replace, so comparing\n")
		b.WriteString("revisions cannot establish the source bytes it reads. Remove the\n")
		b.WriteString("replacement ref, or verify the loaded blobs against the pinned tree directly.\n")
		fmt.Fprint(c.stderr, b.String())
		return &exitStatus{code: 2}
	}
	loaded, ok := gitOut(sourceSub, "--no-replace-objects", "rev-parse", "--verify", "--end-of-options", o.loadedRef+"^{commit}")
	if !ok {
		return die("cannot resolve source revision '%s' in %s", o.loadedRef, sourceSub)
	}
	c.say("pinned revision        : " + o.gitlink)
	c.say("pin source             : " + c.pinSource)
	if c.worktreeLine != "" {
		c.say("worktree pin           : " + c.worktreeLine)
	}
	c.say("declared source revision: " + loaded + " (" + o.loadedRef + ")")
	c.say("")
	relation := "The declared source revision is not the working tree's pin."
	if loaded == c.worktreePin {
		relation = "The declared source revision is the working tree's pin."
	}
	if loaded == o.gitlink {
		c.say("CURRENT — declared source revision matches the pinned gitlink.")
		c.say("Evidence: source parity only; this does not attest the loaded session.")
		c.worktreeNotice(relation)
		return nil
	}
	c.say("DRIFT — declared source revision " + loaded + " differs from pinned gitlink " + o.gitlink + ".")
	c.worktreeNotice(relation)
	c.say("")
	c.say("Do not inspect another runtime's cache. Follow the reviewed definition at " + o.gitlink + " and")
	c.say("report that the declared source " + o.loadedRef + " must be reconciled with the consumer pin.")
	c.status = 1
	return nil
}

// resolveInstalled finds the installed copy the runtime serves.
func (c *check) resolveInstalled() error {
	o := &c.o
	// jq is no longer what parses these documents, but a host without it was UNKNOWN in the Bash
	// implementation, and the port keeps every UNKNOWN it had (monorepo#2851).
	_, jqErr := lookPath("jq")
	switch {
	case o.installed == "" && o.runtime == "codex":
		// Enablement is an EFFECTIVE-STATE question that only the runtime can answer; never infer it
		// from line-oriented config text.
		if _, err := lookPath("codex"); err != nil {
			return die("codex is required to establish effective plugin state for %s", o.codexHome)
		}
		if jqErr != nil {
			return die("jq is required to parse Codex runtime state for %s", o.codexHome)
		}
		raw, err := command("", []string{"CODEX_HOME=" + o.codexHome}, "codex", "plugin", "list", "--json")
		if err != nil {
			return die("Codex runtime state query failed for %s — cannot establish effective plugin state", o.codexHome)
		}
		if strings.TrimRight(string(raw), "\n") == "" {
			return die("Codex runtime state query returned no data for %s", o.codexHome)
		}
		enabled, err := codexEnabled([]byte(strings.TrimRight(string(raw), "\n")), o.pluginID)
		if err != nil {
			return die("Codex runtime state query returned malformed JSON for %s", o.codexHome)
		}
		if enabled == "unparseable" {
			return die("Codex runtime state query returned an unexpected shape for %s", o.codexHome)
		}
		if enabled != "true" {
			return die("plugin '%s' is not enabled according to the Codex runtime state query", o.pluginID)
		}
		_, marketplace, found := strings.Cut(o.pluginID, "@")
		if !found {
			return die("Codex plugin id '%s' has no marketplace suffix", o.pluginID)
		}
		cache := o.codexHome + "/plugins/cache/" + marketplace + "/" + o.pluginName
		if info, err := os.Stat(cache); err != nil || !info.IsDir() {
			return die("Codex plugin cache does not exist: %s", cache)
		}
		entries, err := os.ReadDir(cache)
		if err != nil {
			return die("could not enumerate the Codex plugin cache: %s", cache)
		}
		var copies []string
		for _, entry := range entries {
			if entry.Type()&fs.ModeType == fs.ModeDir {
				copies = append(copies, cache+"/"+entry.Name())
			}
		}
		if len(copies) == 0 {
			return die("Codex plugin '%s' has no cached copy in %s", o.pluginID, cache)
		}
		if len(copies) != 1 {
			return die("Codex plugin '%s' has %d cached copies; cannot identify the loaded one", o.pluginID, len(copies))
		}
		o.installed = copies[0]
	case o.installed == "":
		// Claude resolves from the runtime's own record: its cache can hold several versions at once
		// and only this registry says which one is served.
		if jqErr != nil {
			return die("jq is required to read the runtime plugin registry")
		}
		registry := o.pluginsRoot + "/installed_plugins.json"
		if f, err := os.Open(registry); err != nil {
			return die("cannot read the runtime plugin registry: %s", registry)
		} else {
			_ = f.Close()
		}
		// A readable path that is not a file fails as an unparseable registry, as it did for jq.
		raw, _ := os.ReadFile(registry)
		// Only the records that apply to THIS checkout count: a project- or local-scope record for
		// the repository root, the more specific scope, else the user-scope record (monorepo#4835).
		paths, err := registryPaths(raw, o.pluginID, o.repoRoot)
		if info, statErr := os.Stat(registry); statErr == nil && info.IsDir() {
			err = errJQ
		}
		if err != nil {
			return die("plugin '%s' is not installed, or the runtime plugin registry could not be parsed: %s", o.pluginID, registry)
		}
		switch {
		case paths == "AMBIGUOUS 0":
			return die("plugin '%s' has no user-scope or project-scope record for %s in %s; pass --installed", o.pluginID, o.repoRoot, registry)
		case strings.HasPrefix(paths, "AMBIGUOUS "):
			return die("plugin '%s' has %s distinct install paths that apply to %s; pass --installed to pick one", o.pluginID, strings.TrimPrefix(paths, "AMBIGUOUS "), o.repoRoot)
		}
		o.installed = paths
	}
	if info, err := os.Stat(o.installed); err != nil || !info.IsDir() {
		return die("installed plugin path does not exist: %s", o.installed)
	}

	// The installed tree is enumerated ONCE, WITHOUT a filename filter, and classified by the same
	// rule as the pinned tree, so an installed path in an unexpected shape is reported rather than
	// skipped. An unreadable subtree is UNKNOWN, never an empty one.
	for _, d := range []string{"agents", "skills"} {
		root := o.installed + "/" + d
		if info, err := os.Stat(root); err != nil || !info.IsDir() {
			continue
		}
		listed, err := findFilesAndLinks(root)
		if err != nil {
			return die("could not enumerate the installed definitions under %s%s", root, recovery)
		}
		c.installedListing = append(c.installedListing, listed...)
	}
	sort.Strings(c.installedListing)
	return nil
}

// findFilesAndLinks is `find <root> \( -type f -o -type l \)`: it never follows a symlink, and an
// unreadable directory fails the enumeration.
func findFilesAndLinks(root string) ([]string, error) {
	var found []string
	failed := false
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			failed = true
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if t := d.Type(); t.IsRegular() || t&fs.ModeSymlink != 0 {
			found = append(found, p)
		}
		return nil
	})
	if err != nil || failed {
		return found, fmt.Errorf("could not enumerate %s", root)
	}
	return found, nil
}

const desiredStateRel = ".claude/plugin-consumption/agentic-engineering.desired-state.json"

// loadReviewed builds c.reviewed: one "<blob>\t<mode>\t<path>" record per file of the loaded
// surface at pin. declaration is the consumer commit whose desired state declares the runtime
// assets, or empty for the working-tree file; forge says whether a pin absent from the local object
// database may be read from the forge.
func (c *check) loadReviewed(pin, declaration string, forge bool) error {
	o := &c.o
	// Agents and skills are implicit runtime entrypoints. Other executable dependencies are explicit
	// in the provider-neutral desired state.
	if _, err := lookPath("jq"); err != nil {
		return die("jq is required to read the provider-neutral runtime assets")
	}
	var desiredState, assets string
	if declaration != "" {
		// The declaration and the pin come from ONE consumer revision.
		desiredState = desiredStateRel + " at " + declaration
		raw, err := command("", nil, "git", "-C", o.repoRoot, "--no-replace-objects", "cat-file", "blob", declaration+":"+desiredStateRel)
		if err == nil {
			assets, err = runtimeAssets(raw)
		}
		if err != nil {
			return die("provider-neutral requiredRuntimeAssets are missing or malformed in %s", desiredState)
		}
	} else {
		desiredState = o.repoRoot + "/" + desiredStateRel
		raw, err := os.ReadFile(desiredState)
		if err != nil {
			return die("cannot read the provider-neutral desired state: %s", desiredState)
		}
		if assets, err = runtimeAssets(raw); err != nil {
			return die("provider-neutral requiredRuntimeAssets are missing or malformed in %s", desiredState)
		}
	}
	if assets == "" {
		return die("provider-neutral requiredRuntimeAssets are empty in %s", desiredState)
	}

	// The pinned revision's definition tree: the local submodule object database first (offline, no
	// API budget), the forge only when the pinned commit is not present locally. --no-replace-objects
	// on both reads, so a replacement cannot rewrite the REVIEWED side. `<sub>/.git`, not `<sub>`: an
	// empty submodule directory would answer from the consumer repository around it.
	prefix := "plugins/" + o.pluginName + "/"
	sub := o.repoRoot + "/" + o.submodulePath
	tree := ""
	_, gitErr := os.Stat(sub + "/.git")
	if gitErr == nil && gitOK(sub, "--no-replace-objects", "cat-file", "-e", pin+"^{commit}") {
		listing, ok := gitOut(sub, "--no-replace-objects", "ls-tree", "-r", pin, "--", prefix)
		if !ok {
			return die("could not read the pinned tree %s from %s%s", pin, sub, recovery)
		}
		// Split the leading "<mode> <type> <sha>" on spaces but the PATH on the tab only.
		var records []string
		for _, line := range strings.Split(listing, "\n") {
			fields := strings.Split(line, "\t")
			meta := strings.Fields(fields[0])
			if len(meta) >= 3 && meta[1] == "blob" {
				p := ""
				if len(fields) > 1 {
					p = fields[1]
				}
				records = append(records, meta[2]+"\t"+meta[0]+"\t"+p)
			}
		}
		tree = joinLines(records)
	} else {
		if !forge {
			return die("commit %s is not in the local object database", pin)
		}
		if _, err := lookPath("gh"); err != nil {
			return die("commit %s is not in the local object database and gh is unavailable%s", pin, recovery)
		}
		if _, err := lookPath("jq"); err != nil {
			return die("jq is required to read the pinned tree from the forge")
		}
		// Derived, never hard-coded: --submodule-path is a flag.
		url, ok := gitOut(o.repoRoot, "config", "-f", ".gitmodules", "--get", "submodule."+o.submodulePath+".url")
		if !ok {
			return die("no .gitmodules url for '%s' — cannot resolve %s from the forge%s", o.submodulePath, pin, recovery)
		}
		slug := url
		if i := strings.LastIndex(slug, ":"); i >= 0 {
			slug = slug[i+1:]
		}
		if i := strings.LastIndex(slug, "/github.com/"); i >= 0 {
			slug = slug[i+len("/github.com/"):]
		}
		slug = strings.TrimSuffix(slug, ".git")
		if !strings.Contains(slug, "/") {
			return die("could not derive an owner/repo slug from '%s'", url)
		}
		raw, err := command("", nil, "gh", "api", "repos/"+slug+"/git/trees/"+pin+"?recursive=1")
		if err != nil {
			return die("could not read the pinned tree %s from %s%s", pin, slug, recovery)
		}
		raw = []byte(strings.TrimRight(string(raw), "\n"))
		// A truncated response is a PARTIAL tree; comparing it as if complete is a fail-open.
		if forgeTruncated(raw) == "true" {
			return die("the forge returned a TRUNCATED tree for %s — cannot verify completeness%s", pin, recovery)
		}
		safety, err := forgePathSafety(raw)
		if err != nil {
			return die("could not validate pinned forge paths for %s from %s", pin, slug)
		}
		if safety != "safe" {
			return die("the forge tree contains an unsafe path (tab, newline, carriage return or backslash) — cannot serialize it losslessly%s", recovery)
		}
		if tree, err = forgeTree(raw); err != nil {
			return die("could not parse the pinned tree %s from %s", pin, slug)
		}
	}
	if tree == "" {
		return die("pinned revision %s yielded no tree entries", pin)
	}

	// README, the manifest and resources/ stay outside the surface. Runtime assets are an explicit
	// allow-list, never all of scripts/.
	required := map[string]bool{}
	for _, asset := range strings.Split(assets, "\n") {
		required[asset] = true
	}
	var reviewed []string
	quoted := false
	for _, line := range strings.Split(tree, "\n") {
		fields := strings.Split(line, "\t")
		for len(fields) < 3 {
			fields = append(fields, "")
		}
		if strings.HasPrefix(fields[2], `"`) {
			quoted = true
			continue
		}
		if strings.HasPrefix(fields[2], prefix) {
			rel := fields[2][len(prefix):]
			if strings.HasPrefix(rel, "agents/") || strings.HasPrefix(rel, "skills/") || required[rel] {
				reviewed = append(reviewed, fields[0]+"\t"+fields[1]+"\t"+rel)
			}
		}
	}
	if quoted {
		return die("the pinned tree contains a path git had to quote (tab, newline or backslash) — cannot verify it%s", recovery)
	}
	if len(reviewed) == 0 {
		return die("pinned revision %s contains no definition files under %s", pin, prefix)
	}
	sort.SliceStable(reviewed, func(i, j int) bool {
		return strings.Split(reviewed[i], "\t")[2] < strings.Split(reviewed[j], "\t")[2]
	})
	c.reviewed = strings.Join(reviewed, "\n")

	// A declaration absent from the pinned tree is UNKNOWN, not silently omitted from both sides,
	// and executability is part of the provider-neutral contract.
	for _, asset := range strings.Split(assets, "\n") {
		if asset == "" {
			continue
		}
		var record []string
		for _, line := range reviewed {
			if f := strings.Split(line, "\t"); f[2] == asset {
				record = append(record, f[1]+"\t"+f[2])
			}
		}
		if len(record) == 0 {
			return die("required runtime asset '%s' is absent from pinned revision %s", asset, pin)
		}
		if mode, _, _ := strings.Cut(strings.Join(record, "\n"), "\t"); mode != "100755" {
			return die("required runtime asset '%s' is not executable at pinned revision %s", asset, pin)
		}
	}
	return nil
}

// throughSymlink reports whether any component of rel under the install is a symlink: -f, `git
// hash-object` and -x all FOLLOW one, so a definition replaced by a link to an identical file, or a
// scripts/ link redirecting a required asset, would otherwise pass.
func (c *check) throughSymlink(rel string) bool {
	probe := c.o.installed
	for rel != "" {
		segment := rel
		if i := strings.Index(rel, "/"); i >= 0 {
			segment, rel = rel[:i], rel[i+1:]
		} else {
			rel = ""
		}
		probe += "/" + segment
		if info, err := os.Lstat(probe); err == nil && info.Mode()&fs.ModeSymlink != 0 {
			return true
		}
	}
	return false
}

func executable(p string) bool { return syscall.Access(p, 1) == nil }

// compareReviewed compares the installed copy against c.reviewed, one line per file, and returns
// the findings and the number of pinned files compared.
func (c *check) compareReviewed() (int, int, error) {
	drift, checked := 0, 0
	inReviewed := map[string]bool{}
	for _, line := range strings.Split(c.reviewed, "\n") {
		if parts := strings.Split(line, "\t"); len(parts) >= 3 {
			inReviewed[parts[2]] = true
		}
	}
	for _, line := range strings.Split(c.reviewed, "\n") {
		// `read -r sha mode rel` with IFS=tab: runs of tabs are one separator, and the last field
		// takes the rest of the line.
		fields := strings.FieldsFunc(line, func(r rune) bool { return r == '\t' })
		if len(fields) < 3 {
			continue
		}
		revSHA, revMode := fields[0], fields[1]
		rel := strings.Join(fields[2:], "\t")
		checked++
		installedPath := c.o.installed + "/" + rel
		if c.throughSymlink(rel) {
			c.say("DRIFT    " + rel + "  installed through a SYMLINK where the pinned revision has a regular path")
			drift++
			continue
		}
		if info, err := os.Stat(installedPath); err != nil || !info.Mode().IsRegular() {
			c.say("MISSING  " + rel + "  (reviewed " + revSHA + " — the installed copy does not have this definition at all)")
			drift++
			continue
		}
		// --no-filters: a clean filter would normalise the content first, so a CRLF copy and its LF
		// twin would hash identically.
		own, ok := gitOut("", "hash-object", "--no-filters", installedPath)
		if !ok {
			return 0, 0, die("cannot hash the installed definition %s", installedPath)
		}
		// Mode matters as much as content: a helper that loses its executable bit still hashes
		// identically.
		var wantExec string
		switch revMode {
		case "100644":
			wantExec = "no"
		case "100755":
			wantExec = "yes"
		default:
			return 0, 0, die("pinned %s has unsupported mode %s — cannot verify it", rel, revMode)
		}
		haveExec := "no"
		if executable(installedPath) {
			haveExec = "yes"
		}
		switch {
		case own == revSHA && wantExec == haveExec:
			c.say("match    " + rel)
		case own == revSHA:
			c.say("DRIFT    " + rel + "  content matches but mode differs (reviewed executable=" + wantExec + ", installed executable=" + haveExec + ")")
			drift++
		default:
			c.say("DRIFT    " + rel + "  installed=" + first(own, 12) + " reviewed=" + first(revSHA, 12))
			drift++
		}
	}
	for _, p := range c.installedListing {
		if p == "" {
			continue
		}
		rel := strings.TrimPrefix(p, c.o.installed+"/")
		if !inReviewed[rel] {
			c.say("EXTRA    " + rel + "  (installed but absent from the pinned revision)")
			drift++
		}
	}
	return drift, checked, nil
}

func first(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

var counts = regexp.MustCompile(`^([0-9]+) ([0-9]+)$`)

func (c *check) compare() error {
	o := &c.o
	if err := c.loadReviewed(o.gitlink, c.adoptedCommit, true); err != nil {
		return err
	}
	c.say("pinned revision : " + o.gitlink)
	c.say("pin source      : " + c.pinSource)
	if c.worktreeLine != "" {
		c.say("worktree pin    : " + c.worktreeLine)
	}
	c.say("installed copy  : " + o.installed)
	c.say("")
	drift, checked, err := c.compareReviewed()
	if err != nil {
		return err
	}

	// The same comparison against the pin the working tree holds, reported as a count only. Nothing
	// it does, including failing on a tree it cannot read, reaches the verdict. The forge is not
	// consulted for it.
	worktreeComparison := ""
	if c.worktreeNote != "" {
		worktreeComparison = "Against the working tree's pin the installed copy was not compared: the pin's tree or its runtime-asset declaration is not readable locally."
		side := &check{o: c.o, stdout: io.Discard, stderr: io.Discard, quiet: true, installedListing: c.installedListing}
		if side.loadReviewed(c.worktreePin, c.worktreeHead, false) == nil {
			if d, n, err := side.compareReviewed(); err == nil {
				if m := counts.FindStringSubmatch(strconv.Itoa(d) + " " + strconv.Itoa(n)); m != nil {
					if d == 0 {
						worktreeComparison = "Against the working tree's pin the installed copy matches all " + m[2] + " file(s)."
					} else {
						worktreeComparison = "Against the working tree's pin the installed copy shows " + m[1] + " finding(s) across " + m[2] + " file(s)."
					}
				}
			}
		}
	}

	c.say("")
	if drift == 0 {
		c.say("CURRENT — " + strconv.Itoa(checked) + " pinned loaded file(s) match the installed copy.")
		// This compares the INSTALLED copy on disk; the running process executes whatever it loaded
		// at startup.
		c.say("Scope: this describes the INSTALLED copy on disk, not the definition this process booted.")
		c.say("An install becomes live on the next dispatch, so a run whose install changed mid-flight is")
		c.say("still executing what it booted; only a LATER run's check establishes that the pin is live.")
		c.worktreeNotice(worktreeComparison)
		return nil
	}
	// `drift` counts EXTRA files too, which are not among the `checked` pinned definitions.
	c.say("DRIFT — " + strconv.Itoa(drift) + " finding(s) across " + strconv.Itoa(checked) + " pinned loaded file(s).")
	c.worktreeNotice(worktreeComparison)
	c.say("")
	c.say("What to do, in this order:")
	c.say("  1. Do NOT proceed as if the loaded definition were current. Read the reviewed definition at")
	c.say("     " + o.gitlink + " and follow that, then report the drift in the run report.")
	// The control plane is per-runtime: `codex plugin` has no update command.
	c.say("  2. Refresh through the runtime's own control plane. Never edit the plugin cache: it is")
	c.say("     read-only evidence.")
	if o.runtime == "codex" {
		for _, line := range codexRemediation(o.gitlink, o.pluginID, o.codexHome) {
			c.say(line)
		}
	} else {
		c.say("     For Claude: the /plugin marketplace update flow.")
		if c.adoptedCommit != "" {
			c.say("     Bind the refresh and its runtime file list to this consumer revision:")
			c.say("       plugin-definition-refresh.sh --adopted-ref " + c.adoptedCommit)
		} else {
			c.say("     Bind the refresh to the named plugin pin: plugin-definition-refresh.sh --gitlink " + o.gitlink)
		}
	}
	c.say("  3. If the refresh needs an interactive session this run cannot open, surface it to the")
	c.say("     maintainer on a declared channel rather than leaving it unreported.")
	c.status = 1
	return nil
}

func codexRemediation(gitlink, pluginID, codexHome string) []string {
	return []string{
		"     For Codex: `codex plugin add` installs the marketplace snapshot's LATEST, so the only",
		"     safe sequence is one that never advances the snapshot. Check the snapshot's revision",
		"     against " + gitlink + " first — and the revision ALONE does not establish the content, because",
		"     a dirty file, a clean/smudge filter, or a replacement object each leave the revision",
		"     reading correct while the bytes on disk differ. In the snapshot checkout <snapshot>,",
		"     all four must pass before any install:",
		"         git -C <snapshot> --no-replace-objects rev-parse HEAD   # must equal " + gitlink,
		"         git -C <snapshot> status --porcelain                    # must print NOTHING",
		"         git -C <snapshot> ls-files --others --ignored --exclude-standard -- \\",
		"           <prefix>/agents <prefix>/skills <runtime-asset>        # must print NOTHING",
		"         # repeat <runtime-asset> for every declared requiredRuntimeAsset; ignored untracked",
		"         # files are hidden from status but the marketplace installer can still copy them",
		"         and EVERY definition file must equal its pinned blob — one file proves only itself,",
		"         so a filter or index flag altering any OTHER file survives a single-file check:",
		"           git -C <snapshot> --no-replace-objects ls-tree -r --name-only HEAD -- <prefix>",
		"           # for each: --no-replace-objects rev-parse HEAD:<f> must equal",
		"           # hash-object --no-filters -- <f>",
		"         and EVERY executable requiredRuntimeAsset must retain its pinned mode:",
		"           git -C <snapshot> --no-replace-objects ls-tree HEAD -- <runtime-asset>",
		"           # must start '100755 blob'; test -x <snapshot>/<runtime-asset> must succeed",
		"       * snapshot AT the pin and all of the above clean -> reinstall WITHOUT upgrading.",
		"         `codex plugin remove` deletes the plugin from local config AND cache, so an 'add'",
		"         that then fails — bad snapshot, disk error, interrupted run — leaves this lane with",
		"         no definition to load. Do NOT rely on 'add' overwriting an existing install; the",
		"         CLI does not document that. There is no safe local rollback of the cache: it is",
		"         read-only evidence, so restoring a copy of it by hand is itself a violation, and a",
		"         cache copy would not restore the deleted config entry in any case. Save the config",
		"         entry first so registration can be rebuilt through the control plane:",
		"           # copy the [plugins.\"" + pluginID + "\"] table out of " + codexHome + "/config.toml",
		"           codex plugin remove " + pluginID + " && codex plugin add " + pluginID,
		"         If the 'add' fails, restore that config entry and re-run 'add'. If it still fails,",
		"         this lane can neither load a definition nor repair itself: surface it to the",
		"         maintainer on a declared channel as an outage, rather than editing the cache.",
		"       * snapshot NOT at the pin -> do NOT reinstall, and do NOT run",
		"         'codex plugin marketplace upgrade': it moves the snapshot to the upstream tip, so a",
		"         following 'add' installs a revision nobody here has reviewed. Reconcile the consumer",
		"         gitlink with the revision you intend to run through the reviewed rollout instead.",
	}
}
