package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

var lookPath = exec.LookPath

// command runs name with args in dir (the process's own directory when empty) and returns its
// standard output. Standard error is discarded, as `2>/dev/null` discards it.
func command(dir string, env []string, name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if env != nil {
		cmd.Env = append(os.Environ(), env...)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.Bytes(), err
}

// gitOut is `$(git ...)`: the output with its trailing newlines removed, and whether git succeeded.
func gitOut(dir string, args ...string) (string, bool) {
	out, err := command(dir, nil, "git", args...)
	return strings.TrimRight(string(out), "\n"), err == nil
}

func gitOK(dir string, args ...string) bool {
	_, err := command(dir, nil, "git", args...)
	return err == nil
}

// boundedRemote runs a remote git call that can never hang the check: the command gets its own
// process group and the whole group is signalled when the bound passes, because git hands the
// transport to a helper (ssh, git-remote-https) that outlives a kill aimed at git alone. It is the
// Bash implementation's bounded_remote, the same function as worktree-claim.sh's (monorepo#3824).
// GIT_TERMINAL_PROMPT=0 and BatchMode: an unattended run must get a failure, never a credential or
// passphrase prompt it cannot answer.
func boundedRemote(secs string, args ...string) ([]byte, error) {
	seconds, err := strconv.Atoi(secs)
	if err != nil {
		return nil, err
	}
	// GIT_SSH_COMMAND outranks core.sshCommand and GIT_SSH, so start from whichever of the three git
	// itself would have used. Every caller bounds `git -C <repository> ...`, which is how that
	// repository's own setting is found.
	baseSSH := os.Getenv("GIT_SSH_COMMAND")
	repo := ""
	if len(args) >= 3 && args[0] == "git" && args[1] == "-C" {
		repo = args[2]
	}
	if baseSSH == "" && repo != "" {
		baseSSH, _ = gitOut(repo, "config", "--get", "core.sshCommand")
	}
	if baseSSH == "" {
		baseSSH = envDefault("GIT_SSH", "ssh")
	}
	// The two options added below are OpenSSH's, so they go only to a command git itself treats as
	// OpenSSH: one declared so, or, undeclared, one named `ssh`. Any other runs exactly as
	// configured, and the watchdog is what bounds it.
	variant := os.Getenv("GIT_SSH_VARIANT")
	if variant == "" && repo != "" {
		variant, _ = gitOut(repo, "config", "--get", "ssh.variant")
	}
	if variant == "" || variant == "auto" {
		program, _, _ := strings.Cut(baseSSH, " ")
		if filepath.Base(program) == "ssh" && !strings.HasSuffix(program, "/") {
			variant = "ssh"
		} else {
			variant = "other"
		}
	}
	env := []string{"GIT_TERMINAL_PROMPT=0"}
	if variant == "ssh" {
		env = append(env, "GIT_SSH_COMMAND="+baseSSH+" -o BatchMode=yes -o ConnectTimeout="+secs)
	}
	return bounded(seconds, env, args[0], args[1:]...)
}
