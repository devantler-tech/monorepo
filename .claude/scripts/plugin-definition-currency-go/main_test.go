package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The pin source line is copied into reports, so it prints what names the repository and nothing
// else. These are the cases the shell suite asked of the Bash printable_url (monorepo#2851).
func TestPrintableURL(t *testing.T) {
	for _, tc := range []struct{ name, url, want string }{
		{"the pin source leaves out a URL's query", "https://host.example/org/repo.git?token=s3cr3t", "https://host.example/org/repo.git"},
		{"the pin source leaves out a URL's fragment", "https://host.example/org/repo.git#s3cr3t", "https://host.example/org/repo.git"},
		{"the pin source keeps scheme, host, port and path, and nothing else", "https://user:s3cr3t@host.example:8443/org/repo.git?access_token=s3cr3t#s3cr3t", "https://host.example:8443/org/repo.git"},
		{"the pin source leaves out a query that follows the host directly", "https://host.example?token=s3cr3t", "https://host.example"},
		{"the pin source leaves out the user of an scp-style location", "s3cr3t@host.example:org/repo.git", "host.example:org/repo.git"},
		{"the pin source prints a plain path whole", "/srv/git/a?b#c.git", "/srv/git/a?b#c.git"},
		{"the pin source prints only the transport of a command-line location", "ext::auth-proxy --token s3cr3t host.example org/repo", "ext::<address not shown>"},
		{"the pin source prints only the transport of a helper's own address", "vault::s3cr3t@host.example/org/repo", "vault::<address not shown>"},
		{"the pin source prints only the host and path of an scp-style location with an odd user", "s3cr3t token@host.example:org/repo.git", "host.example:org/repo.git"},
		{"the pin source prints nothing of a location it cannot read as one of the known forms", "host name with s3cr3t:org/repo.git", "<location not shown>"},
		{"the pin source prints a line break or an escape byte in a URL as a question mark", "https://host.example/org/repo.git\npin source      : forged\x1b[2K", "https://host.example/org/repo.git?pin source      : forged?[2K"},
		// Beyond the shell cases: the forms the remaining branches handle.
		{"a relative path is kept whole", "../sibling/repo.git", "../sibling/repo.git"},
		{"a scheme that is not a scheme prints nothing", "1http://host/path", "<location not shown>"},
		{"a bare word is kept whole", "origin-mirror", "origin-mirror"},
		{"an scp-style location whose head holds a slash is kept whole", "dir/name:path", "dir/name:path"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := printableURL(tc.url)
			if got != tc.want {
				t.Fatalf("printed %q, want %q", got, tc.want)
			}
			if strings.Contains(got, "s3cr3t") {
				t.Fatalf("the secret written into the URL was printed: %q", got)
			}
		})
	}
}

// Each filter is checked against the output jq 1.7 gives for the same document.
func TestRegistryPathsMatchJQ(t *testing.T) {
	const id = "p@m"
	for _, tc := range []struct {
		name, doc, want string
		fails           bool
	}{
		{"user scope record", `{"plugins":{"p@m":[{"scope":"user","installPath":"/u"}]}}`, "/u", false},
		{"no scope reads as user scope", `{"plugins":{"p@m":[{"installPath":"/u"}]}}`, "/u", false},
		{"a project record for this root outranks the user record", `{"plugins":{"p@m":[{"scope":"user","installPath":"/u"},{"scope":"project","projectPath":"/r/","installPath":"/p"}]}}`, "/p", false},
		{"a local record counts as project scope", `{"plugins":{"p@m":[{"scope":"local","projectPath":"/r","installPath":"/l"}]}}`, "/l", false},
		{"another root's project record does not apply", `{"plugins":{"p@m":[{"scope":"project","projectPath":"/other","installPath":"/p"}]}}`, "AMBIGUOUS 0", false},
		{"identical paths are one path", `{"plugins":{"p@m":[{"installPath":"/u"},{"scope":"user","installPath":"/u"}]}}`, "/u", false},
		{"two user paths are ambiguous", `{"plugins":{"p@m":[{"installPath":"/a"},{"installPath":"/b"}]}}`, "AMBIGUOUS 2", false},
		{"no usable record is not installed", `{"plugins":{"p@m":[{"installPath":""},5]}}`, "", true},
		{"a missing plugin is not installed", `{"plugins":{}}`, "", true},
		{"plugins that are not an object fail", `{"plugins":[]}`, "", true},
		{"a top-level string fails", `"x"`, "", true},
		{"a non-string project path fails", `{"plugins":{"p@m":[{"scope":"project","projectPath":5,"installPath":"/p"}]}}`, "", true},
		{"a false project path reads as empty", `{"plugins":{"p@m":[{"scope":"project","projectPath":false,"installPath":"/p"},{"installPath":"/u"}]}}`, "/u", false},
		{"malformed JSON fails", `{"plugins":`, "", true},
		{"records that cannot be iterated yield nothing", `{"plugins":{"p@m":5}}`, "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := registryPaths([]byte(tc.doc), id, "/r")
			if (err != nil) != tc.fails || got != tc.want {
				t.Fatalf("got %q, err %v; want %q, fails=%v", got, err, tc.want, tc.fails)
			}
		})
	}
}

func TestCodexEnabledMatchesJQ(t *testing.T) {
	for _, tc := range []struct {
		name, doc, want string
		fails           bool
	}{
		{"enabled", `{"installed":[{"pluginId":"p@m","enabled":true}]}`, "true", false},
		{"disabled", `{"installed":[{"pluginId":"p@m","enabled":false}]}`, "false", false},
		{"absent", `{"installed":[]}`, "false", false},
		{"any enabled record enables it", `{"installed":[{"pluginId":"p@m","enabled":false},{"pluginId":"p@m","enabled":true}]}`, "true", false},
		{"no installed array", `{"available":[]}`, "unparseable", false},
		{"null document", `null`, "unparseable", false},
		{"an array document fails", `[]`, "", true},
		{"a scalar record fails", `{"installed":[1]}`, "", true},
		{"a null record is skipped", `{"installed":[null,{"pluginId":"p@m","enabled":true}]}`, "true", false},
		{"two documents give two answers", `{"installed":[]} {"installed":[{"pluginId":"p@m","enabled":true}]}`, "false\ntrue", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := codexEnabled([]byte(tc.doc), "p@m")
			if (err != nil) != tc.fails || got != tc.want {
				t.Fatalf("got %q, err %v; want %q, fails=%v", got, err, tc.want, tc.fails)
			}
		})
	}
}

func TestRuntimeAssetsMatchJQ(t *testing.T) {
	sum := strings.Repeat("a", 64)
	asset := func(path string) string {
		return `{"path":"` + path + `","sha256":"` + sum + `","executable":true}`
	}
	doc := func(assets ...string) string {
		return `{"spec":{"source":{"requiredRuntimeAssets":[` + strings.Join(assets, ",") + `]}}}`
	}
	for _, tc := range []struct {
		name, doc, want string
		fails           bool
	}{
		{"one asset", doc(asset("scripts/a.sh")), "scripts/a.sh", false},
		{"two assets", doc(asset("scripts/a.sh"), asset("scripts/b.sh")), "scripts/a.sh\nscripts/b.sh", false},
		{"a repeated path is refused", doc(asset("scripts/a.sh"), asset("scripts/a.sh")), "", true},
		{"an empty list is refused", doc(), "", true},
		{"a dot-dot segment passes the filter, as it did in jq", doc(asset("../a.sh")), "../a.sh", false},
		{"a non-executable asset is refused", `{"spec":{"source":{"requiredRuntimeAssets":[{"path":"a","sha256":"` + sum + `","executable":false}]}}}`, "", true},
		{"a short digest is refused", `{"spec":{"source":{"requiredRuntimeAssets":[{"path":"a","sha256":"abc","executable":true}]}}}`, "", true},
		{"a missing declaration is refused", `{"spec":{}}`, "", true},
		{"a spec that is not an object fails", `{"spec":[]}`, "", true},
		// jq's `$` also matches before a final newline, so this path passed the Bash filter.
		{"a path ending in a newline passed jq's test(), and the read drops the newline", doc(asset(`a.sh\n`)), "a.sh", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := runtimeAssets([]byte(tc.doc))
			if (err != nil) != tc.fails || got != tc.want {
				t.Fatalf("got %q, err %v; want %q, fails=%v", got, err, tc.want, tc.fails)
			}
		})
	}
}

func TestForgeFiltersMatchJQ(t *testing.T) {
	if got := forgeTruncated([]byte(`{"truncated":true}`)); got != "true" {
		t.Fatalf("truncated true read as %q", got)
	}
	if got := forgeTruncated([]byte(`{"truncated":"true"}`)); got != "true" {
		t.Fatalf("jq -r prints the string \"true\" as true too; read as %q", got)
	}
	if got := forgeTruncated([]byte(`{"tree":[]}`)); got != "false" {
		t.Fatalf("an absent flag read as %q", got)
	}
	tree := `{"tree":[{"type":"tree","path":"d"},{"type":"blob","sha":"s1","mode":"100644","path":"d/a"},{"type":"blob","sha":"s2","mode":"100755","path":"d/b c"}]}`
	if got, err := forgeTree([]byte(tree)); err != nil || got != "s1\t100644\td/a\ns2\t100755\td/b c" {
		t.Fatalf("tree read as %q, %v", got, err)
	}
	for _, tc := range []struct{ name, doc, want string }{
		{"safe", tree, "safe"},
		{"a tab is unsafe", `{"tree":[{"type":"blob","path":"a\tb"}]}`, "unsafe"},
		{"a backslash is unsafe", `{"tree":[{"type":"blob","path":"a\\b"}]}`, "unsafe"},
		{"a carriage return is unsafe", `{"tree":[{"type":"blob","path":"a\rb"}]}`, "unsafe"},
		{"an unsafe tree entry that is not a blob is ignored", `{"tree":[{"type":"tree","path":"a\nb"}]}`, "safe"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got, err := forgePathSafety([]byte(tc.doc)); err != nil || got != tc.want {
				t.Fatalf("got %q, %v; want %q", got, err, tc.want)
			}
		})
	}
	for _, doc := range []string{`{"tree":null}`, `{"tree":[{"type":"blob","path":5}]}`, `{}`} {
		if _, err := forgePathSafety([]byte(doc)); err == nil {
			t.Fatalf("%s: jq fails on this document, the port accepted it", doc)
		}
	}
}

// The remote bound kills the whole process group, so a helper that outlives git cannot hold the
// check past it, and its exit is a failure the caller reads as UNKNOWN.
func TestBoundedRemoteKillsTheProcessGroup(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "child-survived")
	script := filepath.Join(dir, "slow")
	// The child sleeps in the background and would write the marker if it were not killed.
	body := "#!/bin/sh\n(sleep 3; : >\"" + marker + "\") &\nsleep 30\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	_, err := boundedRemote("1", script)
	if err == nil {
		t.Fatal("a call killed at the bound reported success")
	}
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Fatalf("the bound did not hold: %v", elapsed)
	}
	time.Sleep(4 * time.Second)
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a process in the command's group outlived the bound")
	}
}

// OpenSSH options go only to a command git treats as OpenSSH.
func TestBoundedRemoteAddsSSHOptionsOnlyToOpenSSH(t *testing.T) {
	dir := t.TempDir()
	probe := filepath.Join(dir, "probe")
	if err := os.WriteFile(probe, []byte("#!/bin/sh\nprintf '%s' \"${GIT_SSH_COMMAND-unset}\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, sshCommand, variant, want string }{
		{"plain ssh", "ssh", "", "ssh -o BatchMode=yes -o ConnectTimeout=7"},
		{"a configured ssh command keeps its own options", "/usr/bin/ssh -i key", "", "/usr/bin/ssh -i key -o BatchMode=yes -o ConnectTimeout=7"},
		{"plink is left as configured", "plink", "", "plink"},
		{"a declared OpenSSH variant gets the options", "wrapper", "ssh", "wrapper -o BatchMode=yes -o ConnectTimeout=7"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("GIT_SSH_COMMAND", tc.sshCommand)
			t.Setenv("GIT_SSH_VARIANT", tc.variant)
			out, err := boundedRemote("7", probe)
			if err != nil || string(out) != tc.want {
				t.Fatalf("got %q, %v; want %q", out, err, tc.want)
			}
		})
	}
}

// Only 0 and 1 are verdicts. A usage error is UNKNOWN, never the DRIFT status.
func TestUsageErrorsAreUnknown(t *testing.T) {
	for _, args := range [][]string{
		{"--runtime"},
		{"--bogus"},
		{"--runtime", "other"},
		{"--runtime", "codex", "--installed", "/x"},
		{"--runtime", "git-ref"},
		{"--runtime", "git-ref", "--loaded-ref", "main"},
		{"--loaded-ref", "refs/heads/main"},
		{"--adopted-ref", "refs/heads/main"},
		{"--adopted-ref", "abc"},
		{"--adopted-ref", "refs/remotes/origin/main", "--gitlink", "x"},
		{"--remote", "-x"},
	} {
		var stdout, stderr bytes.Buffer
		if code := run(args, &stdout, &stderr); code != 2 || !strings.HasPrefix(stderr.String(), "plugin-definition-currency: ") {
			t.Fatalf("%v: code=%d stderr=%q, want UNKNOWN", args, code, stderr.String())
		}
	}
}

func TestHelpPrintsTheDesignNote(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--help"}, &stdout, &stderr); code != 0 || stdout.String() != helpText || !strings.Contains(helpText, "Exit 2 is deliberately NOT exit 0") {
		t.Fatalf("code=%d help=%.200q", code, stdout.String())
	}
}

// The entrypoint forwards arguments, output and status, and its own failure is UNKNOWN.
func TestEntrypointForwardsStatus(t *testing.T) {
	launcher, err := filepath.Abs(filepath.Join("..", "plugin-definition-currency.sh"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(launcher, "--runtime", "other")
	out, err := cmd.CombinedOutput()
	var exitErr *exec.ExitError
	if !asExit(err, &exitErr) || exitErr.ExitCode() != 2 || !strings.Contains(string(out), "unsupported runtime 'other'") {
		t.Fatalf("err=%v out=%s", err, out)
	}
}

func asExit(err error, target **exec.ExitError) bool {
	e, ok := err.(*exec.ExitError)
	if ok {
		*target = e
	}
	return ok
}
