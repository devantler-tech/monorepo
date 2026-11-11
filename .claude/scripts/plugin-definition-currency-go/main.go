// Command plugin-definition-currency asks whether the definition the runtime LOADED is the one the
// consumer PINNED. It is the Go implementation behind plugin-definition-currency.sh (monorepo#2851);
// help.txt is its full usage and design note, and `--help` prints it.
//
// The port keeps the Bash implementation's contract statement for statement: the same flags, the
// same output lines and the same exit codes (0 CURRENT, 1 DRIFT, 2 UNKNOWN). Every repository read
// still goes through `git` on PATH, the forge read through `gh`, and the Codex state query through
// `codex`, with the arguments the Bash implementation used, so the shell suite's stubs drive both.
package main

import (
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

//go:embed help.txt
var helpText string

const (
	// recovery is named beside every UNKNOWN that a fresh worktree can actually hit.
	recovery = `
  To resolve: populate the pinned plugin submodule with .claude/scripts/submodule-init.sh
  libraries/agent-plugins, or make gh available so the pinned tree can be read from the forge.
  UNKNOWN means UNCHECKED: never read it as current, report it, and carry on against the reviewed
  definition at the pinned gitlink — it must never halt a run.`

	// adoptedRecovery names the one supported substitute for an unreadable adopted pin.
	adoptedRecovery = `
  To resolve: restore access to the remote and re-run. Or fetch the default branch yourself and
  name it, as ONE command, so the check runs only when the fetch succeeded:
    git fetch origin '+refs/heads/main:refs/remotes/origin/main' &&
      plugin-definition-currency.sh --adopted-ref refs/remotes/origin/main ...
  A failed fetch leaves the old ref in place. Naming that ref anyway measures against a pin the
  deployment may have moved off, and can report an install as up to date when it has drifted.
  The working tree's own gitlink is never used instead: on a branch that changes the pin it names a
  proposal, not what the deployment adopted. UNKNOWN means UNCHECKED: never read it as current,
  report it, and carry on against the reviewed definition — it must never halt a run.`
)

// unknown is a die(): the message goes to stderr and the exit status is 2.
type unknown struct{ msg string }

func (u *unknown) Error() string { return u.msg }

func die(format string, args ...any) error { return &unknown{msg: fmt.Sprintf(format, args...)} }

// exitStatus ends the run with a status whose explanation is already printed.
type exitStatus struct{ code int }

func (e *exitStatus) Error() string { return fmt.Sprintf("exit %d", e.code) }

var fullObjectID = regexp.MustCompile(`^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$`)

type options struct {
	repoRoot, pluginsRoot, codexHome           string
	gitlink, adoptedRef, remote, installed     string
	submodulePath, pluginID, pluginName        string
	runtime, loadedRef                         string
	adoptedRefSet, loadedRefSet, quiet, wanted bool
}

// envDefault is ${name:-fallback}: an empty value counts as unset.
func envDefault(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	c := &check{stdout: stdout, stderr: stderr}
	err := c.main(args)
	if err == nil {
		return c.status
	}
	var u *unknown
	if errors.As(err, &u) {
		fmt.Fprintf(stderr, "plugin-definition-currency: %s\n", u.msg)
		return 2
	}
	var e *exitStatus
	if errors.As(err, &e) {
		return e.code
	}
	fmt.Fprintf(stderr, "plugin-definition-currency: %v\n", err)
	return 2
}

func parseArgs(args []string) (options, bool, error) {
	home := os.Getenv("HOME")
	o := options{
		pluginsRoot:   envDefault("CLAUDE_CONFIG_DIR", home+"/.claude") + "/plugins",
		codexHome:     envDefault("CODEX_HOME", home+"/.codex"),
		remote:        "origin",
		submodulePath: "libraries/agent-plugins",
		pluginID:      "agentic-engineering@devantler-plugins",
		pluginName:    "agentic-engineering",
		runtime:       "claude",
	}
	values := map[string]*string{
		"--runtime": &o.runtime, "--repo-root": &o.repoRoot, "--plugins-root": &o.pluginsRoot,
		"--codex-home": &o.codexHome, "--gitlink": &o.gitlink, "--adopted-ref": &o.adoptedRef,
		"--remote": &o.remote, "--installed": &o.installed, "--submodule-path": &o.submodulePath,
		"--plugin-id": &o.pluginID, "--plugin-name": &o.pluginName, "--loaded-ref": &o.loadedRef,
	}
	for i := 0; i < len(args); {
		flag := args[i]
		if target, ok := values[flag]; ok {
			// A lone trailing flag is a usage error (UNKNOWN), never the DRIFT status.
			if len(args)-i < 2 {
				return o, false, die("missing value for %s", flag)
			}
			*target = args[i+1]
			switch flag {
			case "--adopted-ref":
				o.adoptedRefSet = true
			case "--loaded-ref":
				o.loadedRefSet = true
			}
			i += 2
			continue
		}
		switch flag {
		case "--quiet":
			o.quiet = true
			i++
		case "-h", "--help":
			return o, true, nil
		default:
			return o, false, die("unknown argument: %s", flag)
		}
	}
	return o, false, nil
}

// validate applies the Bash implementation's argument checks, in its order.
func (c *check) validate() error {
	o := &c.o
	if _, err := lookPath("git"); err != nil {
		return die("git is required")
	}
	switch o.runtime {
	case "claude", "codex", "git-ref":
	default:
		return die("unsupported runtime '%s' (expected claude, codex, or git-ref)", o.runtime)
	}
	if o.runtime != "claude" && o.installed != "" {
		return die("runtime '%s' does not accept --installed; resolve the copy that lane actually loaded", o.runtime)
	}
	if o.runtime == "git-ref" {
		if o.loadedRef == "" {
			return die("runtime git-ref requires --loaded-ref")
		}
		if strings.HasPrefix(o.loadedRef, "refs/") {
			if !gitOK("", "check-ref-format", o.loadedRef) {
				return die("--loaded-ref must be a fully qualified ref or full commit ID")
			}
		} else if !fullObjectID.MatchString(o.loadedRef) {
			return die("--loaded-ref must be a fully qualified ref or full commit ID")
		}
	} else if o.loadedRefSet {
		return die("--loaded-ref is only valid with --runtime git-ref")
	}
	if o.adoptedRefSet {
		// Two flags that each name the pin cannot both be honoured.
		if o.gitlink != "" {
			return die("--adopted-ref and --gitlink both name the pin; pass only one")
		}
		// A ref must be a REMOTE-TRACKING one: a local branch or tag is something this checkout
		// wrote itself, so on a rollout branch it names the proposal.
		switch {
		case strings.HasPrefix(o.adoptedRef, "refs/remotes/"):
			if !gitOK("", "check-ref-format", o.adoptedRef) {
				return die("--adopted-ref must be a remote-tracking ref (refs/remotes/...) or full commit ID")
			}
		case strings.HasPrefix(o.adoptedRef, "refs/"):
			return die("--adopted-ref '%s' is a local ref, which this checkout wrote itself and so cannot show what the deployment adopted — name a remote-tracking ref (refs/remotes/...) or a full commit ID", o.adoptedRef)
		case !fullObjectID.MatchString(o.adoptedRef):
			return die("--adopted-ref must be a remote-tracking ref (refs/remotes/...) or full commit ID")
		}
	}
	if o.remote == "" || strings.HasPrefix(o.remote, "-") {
		return die("--remote must name a git remote")
	}
	c.timeout = envDefault("PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS", "20")
	if !regexp.MustCompile(`^[1-9][0-9]{0,2}$`).MatchString(c.timeout) {
		return die("PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS must be a whole number of seconds from 1 to 999, got '%s'", c.timeout)
	}
	c.runtimeTimeout = envDefault("PLUGIN_CURRENCY_RUNTIME_TIMEOUT_SECS", "30")
	if !regexp.MustCompile(`^[1-9][0-9]{0,2}$`).MatchString(c.runtimeTimeout) {
		return die("PLUGIN_CURRENCY_RUNTIME_TIMEOUT_SECS must be a whole number of seconds from 1 to 999, got '%s'", c.runtimeTimeout)
	}
	return nil
}
