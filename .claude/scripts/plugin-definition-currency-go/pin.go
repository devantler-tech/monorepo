package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// gitlinkAt is the gitlink a consumer revision records for the plugin submodule. It returns
// nothing when the path is not a gitlink there, and fails only when the revision cannot be read.
// --no-replace-objects: a refs/replace entry makes `ls-tree` read the REPLACEMENT's tree while
// `rev-parse` still prints the expected commit.
func (c *check) gitlinkAt(rev string) (string, bool) {
	entry, ok := gitOut(c.o.repoRoot, "--no-replace-objects", "ls-tree", rev, "--", c.o.submodulePath)
	if !ok {
		return "", false
	}
	var pins []string
	for _, line := range strings.Split(entry, "\n") {
		if f := strings.Fields(line); len(f) >= 3 && f[0] == "160000" && f[1] == "commit" {
			pins = append(pins, f[2])
		}
	}
	return strings.Join(pins, "\n"), true
}

var (
	transportForm = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9+.-]*)::`)
	urlScheme     = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.-]*$`)
	scpHost       = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

// printableURL is where the remote is, and nothing else: the scheme, the host with its port, and
// the path. User, password, query and fragment are dropped; of an scp-style `user@host:path` it
// keeps the host and the path; a plain path is kept whole. A `<transport>::<address>` location is
// printed as its transport only. Any byte that is not printable ASCII is printed as `?`.
func printableURL(url string) string {
	shown := ""
	if m := transportForm.FindStringSubmatch(url); m != nil {
		shown = m[1] + "::<address not shown>"
	} else {
		switch {
		case strings.Contains(url, "://"):
			scheme, rest, _ := strings.Cut(url, "://")
			host := rest
			if i := strings.IndexAny(rest, "/?#"); i >= 0 {
				host = rest[:i]
			}
			path := rest[len(host):]
			if urlScheme.MatchString(scheme) {
				if i := strings.LastIndex(host, "@"); i >= 0 {
					host = host[i+1:]
				}
				if i := strings.IndexAny(path, "?#"); i >= 0 {
					path = path[:i]
				}
				shown = scheme + "://" + host + path
			}
		case strings.HasPrefix(url, "/") || strings.HasPrefix(url, "./") || strings.HasPrefix(url, "../"):
			shown = url
		case strings.Contains(url, ":"):
			first, after, _ := strings.Cut(url, ":")
			host := first
			if i := strings.LastIndex(first, "@"); i >= 0 {
				host = first[i+1:]
			}
			if strings.Contains(first, "/") {
				shown = url
			} else if scpHost.MatchString(host) {
				shown = host + ":" + after
			}
		default:
			shown = url
		}
	}
	if shown == "" {
		shown = "<location not shown>"
	}
	b := []byte(shown)
	for i, ch := range b {
		if ch < 0x20 || ch > 0x7e {
			b[i] = '?'
		}
	}
	return string(b)
}

// commonDir is `cd <dir> && cd "$(git rev-parse --git-common-dir)" && pwd -P`.
func commonDir(dir string) string {
	common, _ := gitOut(dir, "rev-parse", "--git-common-dir")
	target := dir
	if common != "" {
		if filepath.IsAbs(common) {
			target = common
		} else {
			target = filepath.Join(dir, common)
		}
	}
	if info, err := os.Stat(target); err != nil || !info.IsDir() {
		return ""
	}
	physical, err := filepath.EvalSymlinks(target)
	if err != nil {
		return ""
	}
	abs, err := filepath.Abs(physical)
	if err != nil {
		return ""
	}
	return abs
}

// resolveAdoptedFromRemote reads the tip of the remote's default branch from the remote itself. A
// local remote-tracking ref is only as fresh as the last fetch, and a stale one fails in BOTH
// directions.
func (c *check) resolveAdoptedFromRemote() error {
	o := &c.o
	// The remote must be one this repository has CONFIGURED: a path or URL could answer with the
	// working tree's own HEAD.
	if !gitOK(o.repoRoot, "config", "--get", "remote."+o.remote+".url") {
		return die("'%s' is not a configured remote of %s — the adopted pin is unknown. --remote takes a remote NAME, never a path or URL%s", o.remote, o.repoRoot, adoptedRecovery)
	}
	// Compare the location git will actually contact, after any url.<base>.insteadOf rewrite.
	remoteURL, ok := gitOut(o.repoRoot, "ls-remote", "--get-url", "--", o.remote)
	if !ok {
		remoteURL, _ = gitOut(o.repoRoot, "config", "--get", "remote."+o.remote+".url")
	}
	c.adoptedURL = printableURL(remoteURL)
	remoteDir := remoteURL
	switch {
	case strings.HasPrefix(remoteDir, "file://localhost/"):
		remoteDir = strings.TrimPrefix(remoteDir, "file://localhost")
	case strings.HasPrefix(remoteDir, "file:///"):
		remoteDir = strings.TrimPrefix(remoteDir, "file://")
	}
	switch {
	case strings.HasPrefix(remoteDir, "/"):
	case strings.Contains(remoteDir, "://") || regexp.MustCompile(`@.*:`).MatchString(remoteDir):
		remoteDir = ""
	default:
		remoteDir = o.repoRoot + "/" + remoteDir
	}
	if remoteDir != "" {
		if info, err := os.Stat(remoteDir); err == nil && info.IsDir() {
			remoteCommon := commonDir(remoteDir)
			ownCommon := commonDir(o.repoRoot)
			if remoteCommon != "" && remoteCommon == ownCommon {
				return die("remote '%s' points back at this repository, so it cannot show what the deployment adopted — the adopted pin is unknown%s", o.remote, adoptedRecovery)
			}
		}
	}
	// git follows a redirect of its first request by default, and the pin would then come from a
	// location the pin source line does not name. Ask git which value it will use for this URL.
	for _, scheme := range []string{"http://", "https://", "ftp://", "ftps://"} {
		if strings.HasPrefix(remoteURL, scheme) {
			follow, _ := gitOut(o.repoRoot, "-c", "http.followRedirects=false", "config", "--get-urlmatch", "http.followRedirects", remoteURL)
			if follow != "false" {
				return die("the configuration of %s lets a read of remote '%s' follow an HTTP redirect (an http.<url>.followRedirects setting), so the location the pin would come from cannot be named — the adopted pin is unknown%s", o.repoRoot, o.remote, adoptedRecovery)
			}
			break
		}
	}
	raw, err := boundedRemote(c.timeout, "git", "-C", o.repoRoot,
		"-c", "http.followRedirects=false",
		"-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime="+c.timeout,
		"ls-remote", "--symref", "--", o.remote, "HEAD")
	if err != nil {
		return die("cannot read the default branch of remote '%s' from %s within %ss — the adopted pin is unknown%s", o.remote, o.repoRoot, c.timeout, adoptedRecovery)
	}
	advertised := strings.TrimRight(string(raw), "\n")
	// Two records for HEAD: "ref: refs/heads/<branch>\tHEAD" and "<sha>\tHEAD".
	branchSeen, commitSeen := false, false
	for _, line := range strings.Split(advertised, "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) < 2 || fields[1] != "HEAD" {
			continue
		}
		if !branchSeen && strings.HasPrefix(fields[0], "ref: refs/heads/") {
			c.adoptedBranch = fields[0][5:]
			branchSeen = true
		}
		if !commitSeen && !strings.HasPrefix(fields[0], "ref: ") {
			c.adoptedCommit = fields[0]
			commitSeen = true
		}
	}
	if !fullObjectID.MatchString(c.adoptedCommit) {
		return die("remote '%s' advertised no default-branch commit — the adopted pin is unknown%s", o.remote, adoptedRecovery)
	}
	if !gitOK(o.repoRoot, "--no-replace-objects", "cat-file", "-e", c.adoptedCommit+"^{commit}") {
		// Fetch that one commit and nothing else: the empty --refmap and the bare object id mean no
		// remote-tracking ref moves and FETCH_HEAD is not written. The object being readable
		// afterwards is the evidence, not the fetch's own status.
		_, _ = boundedRemote(c.timeout, "git", "-C", o.repoRoot,
			"-c", "http.followRedirects=false",
			"-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime="+c.timeout,
			"fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--no-auto-maintenance",
			"--no-write-fetch-head", "--refmap=", "--", o.remote, c.adoptedCommit)
		if !gitOK(o.repoRoot, "--no-replace-objects", "cat-file", "-e", c.adoptedCommit+"^{commit}") {
			return die("the default-branch tip %s of remote '%s' is not in the local object database and could not be fetched — the adopted pin is unknown%s", c.adoptedCommit, o.remote, adoptedRecovery)
		}
	}
	return nil
}

// resolvePin establishes the pin the verdict is measured against, and the working tree's own pin
// beside it as a separate fact that never changes the verdict.
func (c *check) resolvePin() error {
	o := &c.o
	if o.gitlink != "" {
		c.pinSource = "named by --gitlink; neither the adopted nor the working-tree pin was resolved"
		return nil
	}
	if !gitOK(o.repoRoot, "rev-parse", "--git-dir") {
		return die("cannot read %s as a git repository — the adopted pin is unknown", o.repoRoot)
	}
	if o.adoptedRefSet {
		commit, ok := gitOut(o.repoRoot, "--no-replace-objects", "rev-parse", "--verify", "--quiet", "--end-of-options", o.adoptedRef+"^{commit}")
		if !ok {
			return die("cannot resolve the adopted revision '%s' in %s — the adopted pin is unknown%s", o.adoptedRef, o.repoRoot, adoptedRecovery)
		}
		c.adoptedCommit = commit
		c.pinSource = "caller-named — the gitlink at " + o.adoptedRef + " (" + commit + "), named by --adopted-ref and NOT refreshed by this check"
	} else {
		if err := c.resolveAdoptedFromRemote(); err != nil {
			return err
		}
		branch := c.adoptedBranch
		if branch == "" {
			branch = "HEAD"
		}
		c.pinSource = "adopted — the gitlink at " + o.remote + " " + branch + " (" + c.adoptedCommit + "), read from the remote by this check at " + c.adoptedURL
	}
	pin, ok := c.gitlinkAt(c.adoptedCommit)
	if !ok {
		return die("cannot read the tree of the adopted revision %s in %s — the adopted pin is unknown%s", c.adoptedCommit, o.repoRoot, adoptedRecovery)
	}
	if pin == "" {
		return die("no gitlink for '%s' at the adopted revision %s — cannot establish the pinned revision", o.submodulePath, c.adoptedCommit)
	}
	o.gitlink = pin

	// The working tree's own pin is a second FACT, never a second basis: failing to read or classify
	// it falls back to "not established" instead of dying.
	if head, ok := gitOut(o.repoRoot, "rev-parse", "--verify", "--quiet", "HEAD"); ok {
		c.worktreeHead = head
	}
	if c.worktreeHead != "" {
		if pin, ok := c.gitlinkAt(c.worktreeHead); ok {
			c.worktreePin = pin
		}
	}
	switch {
	case c.worktreePin == "":
		c.worktreeLine = "no gitlink readable at HEAD — only the adopted pin was compared"
	case c.worktreePin == o.gitlink:
		if o.adoptedRefSet {
			c.worktreeLine = c.worktreePin + " at HEAD " + c.worktreeHead + " — the caller-named pin"
		} else {
			c.worktreeLine = c.worktreePin + " at HEAD " + c.worktreeHead + " — the adopted pin"
		}
	default:
		// Which side moved is read from the fork point, not from ancestry alone.
		forkPin := ""
		if forkPoint, ok := gitOut(o.repoRoot, "--no-replace-objects", "merge-base", c.adoptedCommit, c.worktreeHead); ok && forkPoint != "" {
			if pin, ok := c.gitlinkAt(forkPoint); ok {
				forkPin = pin
			}
		}
		switch {
		case forkPin == "":
			c.worktreeNote = "UNADOPTED"
		case forkPin == c.worktreePin:
			c.worktreeNote = "SUPERSEDED"
		default:
			c.worktreeNote = "ROLLOUT"
		}
		c.worktreeLine = c.worktreePin + " at HEAD " + c.worktreeHead + " — NOT the adopted pin (" + c.worktreeNote + ", explained below)"
	}
	return nil
}
