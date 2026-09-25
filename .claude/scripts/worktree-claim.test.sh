#!/usr/bin/env bash
#
# Self-test for worktree-claim.sh (monorepo#2284).
# Hermetic: uses a throwaway git repo + worktrees; no network.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/worktree-claim.sh"
cleanup_script="$here/worktree-cleanup.sh"
shared_lib="$here/worktree-claim-lib.sh"
root_contract="$here/../../AGENTS.md"
maintenance_contract="$here/../skills/portfolio-maintenance/SKILL.md"
workflow_contract="$here/../../.github/workflows/ci.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

check() {
  local name="$1" want="$2" got="$3" hay="${4:-}" needle="${5:-}"
  if [ "$want" != "$got" ]; then
    printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$want" "$got" >&2
    fail=$((fail + 1)); return
  fi
  # Here-string, not `printf | grep -q`: under `pipefail` grep exits at the first match and the
  # writer dies with EPIPE, so a LONGER haystack makes the pipeline report failure on a needle it
  # actually found. That turns a passing assertion into a size-dependent flake.
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$hay"; then
    printf 'FAIL %s: output missing %q\n  got: %s\n' "$name" "$needle" "$hay" >&2
    fail=$((fail + 1)); return
  fi
  printf 'ok   %s\n' "$name"
  pass=$((pass + 1))
}

chmod +x "$script"

# Throwaway repo
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name "worktree-claim-test"
git -C "$repo" config user.email "worktree-claim-test@example.com"
git -C "$repo" commit --allow-empty -qm "init"

wt="$tmp/wt-a"

# ── add writes marker ──────────────────────────────────────────────────────
rc=0
out="$("$script" add "$repo" "$wt" "claim-branch-a" "session-alpha" 2>&1)" || rc=$?
check "add succeeds" 0 "$rc" "$out" "owner=session-alpha"
check "marker file exists" 0 "$([ -f "$wt/.claude-worktree-owner" ] && echo 0 || echo 1)"
owner_line="$(grep '^owner=' "$wt/.claude-worktree-owner")"
check "marker owner line" 0 0 "$owner_line" "owner=session-alpha"
created_line="$(grep '^created_at=' "$wt/.claude-worktree-owner")"
check "marker created_at present" 0 0 "$created_line" "created_at="
status_lines="$(git -C "$wt" status --porcelain --untracked-files=all)"
check "marker leaves worktree clean" "" "$status_lines"

# ── add resolves a relative worktree path from the repository ──────────────────────
relative_wt=".claim-relative-wt"
rc=0
out="$(cd "$tmp" && "$script" add "repo" "$relative_wt" "claim-branch-relative" "session-relative" 2>&1)" || rc=$?
check "relative add succeeds" 0 "$rc" "$out" "owner=session-relative"
check "relative marker is repo-relative" 0 "$([ -f "$repo/$relative_wt/.claude-worktree-owner" ] && echo 0 || echo 1)"

# ── add refuses a location the session write guard would block (monorepo#2755) ──
# Layout mirrors a harness session: <checkout>/.claude/worktrees/<slug>. The guard refuses Edit/Write
# into <checkout> outside <slug>, so a sibling maint-* tree must be refused at creation, not at the
# first edit. The fixture checkout is the throwaway repo itself, so the session dir is a real worktree.
sess="$repo/.claude/worktrees/sess-a"
mkdir -p "$repo/.claude/worktrees"
git -C "$repo" worktree add -q --detach "$sess"
rc=0
out="$(cd "$sess" && "$script" add "$repo" "$repo/.claude/worktrees/maint-sibling" "claim-branch-sibling" "session-sib" 2>&1)" || rc=$?
check "add refuses a sibling worktree of the session" 1 "$rc" "$out" "outside this session's worktree"
check "refusal names the writable location" 1 "$rc" "$out" "$sess/.claude/worktrees/maint-sibling"
check "refused add creates nothing" 1 "$([ -e "$repo/.claude/worktrees/maint-sibling" ] && echo 0 || echo 1)"
check "refused add creates no branch" 1 "$(git -C "$repo" show-ref --verify --quiet refs/heads/claim-branch-sibling && echo 0 || echo 1)"
# A not-yet-created tail can carry `..` that climbs back out of the session; containment must be
# judged on the collapsed path, or the string still starts with the session root and is admitted.
rc=0
out="$(cd "$sess" && "$script" add "$repo" "$sess/.claude/worktrees/not-yet/../../../../maint-escape" "claim-branch-escape" "session-esc" 2>&1)" || rc=$?
check "add refuses a not-yet-created tail that climbs out with .." 1 "$rc" "$out" "outside this session's worktree"
check "traversal refusal creates nothing" 1 "$([ -e "$repo/.claude/worktrees/maint-escape" ] && echo 0 || echo 1)"
rc=0
out="$(cd "$sess" && "$script" add "$sess" "$sess/.claude/worktrees/maint-nested" "claim-branch-nested" "session-nested" 2>&1)" || rc=$?
check "add admits a worktree nested under the session" 0 "$rc" "$out" "owner=session-nested"
rc=0
out="$(cd "$sess" && "$script" add "$repo" "$tmp/wt-outside-checkout" "claim-branch-outside" "session-out" 2>&1)" || rc=$?
check "add admits a target outside the session's checkout" 0 "$rc" "$out" "owner=session-out"

# ── add refuses a repo path that is not its own top level (uninitialized submodule) ──
mkdir -p "$repo/empty-submodule"
rc=0
out="$("$script" add "$repo/empty-submodule" "$tmp/wt-empty-sub" "claim-branch-empty" "session-empty" 2>&1)" || rc=$?
check "add refuses an uninitialized submodule path" 1 "$rc" "$out" "submodule-init.sh"
check "uninitialized refusal creates nothing" 1 "$([ -e "$tmp/wt-empty-sub" ] && echo 0 || echo 1)"

# ── add checks a populated submodule is the repository .gitmodules names (monorepo#3010) ──
# A real superproject with a real submodule, because the defect lives in how `git -C` resolves a
# submodule path: a standalone repository cannot show it.
upstream_sub="$tmp/upstream-sub"
git init -q -b main "$upstream_sub"
git -C "$upstream_sub" -c user.name=t -c user.email=t@example.com commit --allow-empty -qm "sub init"
other_sub="$tmp/other-sub"
git init -q -b main "$other_sub"
git -C "$other_sub" -c user.name=t -c user.email=t@example.com commit --allow-empty -qm "other init"
super="$tmp/super"
git init -q -b main "$super"
git -C "$super" -c protocol.file.allow=always submodule add -q "$upstream_sub" mod
git -C "$super" -c user.name=t -c user.email=t@example.com commit -qm "add submodule"

rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-ok" "claim-branch-sub-ok" "session-sub-ok" 2>&1)" || rc=$?
check "add succeeds on a correctly populated submodule" 0 "$rc" "$out" "owner=session-sub-ok"

# The submodule's own URL rewrite decides where git really fetches and pushes, so an origin
# configured with the registered URL is still refused when such a rewrite sends it elsewhere.
git -C "$super/mod" config url."$other_sub".insteadOf "$upstream_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-insteadof" "claim-branch-sub-insteadof" "session-sub-insteadof" 2>&1)" || rc=$?
check "add refuses an origin its own insteadOf rewrites to another repository" 1 "$rc" "$out" "redirected by:   URL rewrite"
git -C "$super/mod" config --unset url."$other_sub".insteadOf
git -C "$super/mod" config url."$other_sub".pushInsteadOf "$upstream_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-pushinsteadof" "claim-branch-sub-pushinsteadof" "session-sub-pushinsteadof" 2>&1)" || rc=$?
check "add refuses an origin its own pushInsteadOf rewrites to another repository" 1 "$rc" "$out" "redirected by:   URL rewrite"
git -C "$super/mod" config --unset url."$other_sub".pushInsteadOf

git -C "$super/mod" config remote.origin.url "$other_sub"
# The helper names the superproject by its physical path; on macOS $TMPDIR sits under a symlink.
super_phys="$(cd "$super" && pwd -P)"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-wrong" "claim-branch-sub-wrong" "session-sub-wrong" 2>&1)" || rc=$?
check "add refuses a submodule whose origin is not its .gitmodules URL" 1 "$rc" "$out" "git -C '$super_phys' submodule sync -- 'mod'"
check "origin refusal names both repositories" 1 "$rc" "$out" "$other_sub"
check "origin refusal creates no worktree" 1 "$([ -e "$tmp/wt-sub-wrong" ] && echo 0 || echo 1)"
check "origin refusal creates no branch" 1 "$(git -C "$super/mod" show-ref --verify --quiet refs/heads/claim-branch-sub-wrong && echo 0 || echo 1)"

# origin must be the registered URL itself. A spelling git may treat as the same repository is still
# refused, because whether it is depends on the server, and `submodule sync` restores the exact URL.
# GIT_ALLOW_PROTOCOL=file keeps the test offline: the advisory remote calls fail at once.
spelling=0
for pair in \
  "git@github.com:example/sub.git|https://github.com/example/sub" \
  "ssh://git@git.example.invalid:22/org/repo.git|git@git.example.invalid:org/repo" \
  "ssh://git@Git.Example.invalid/org/repo|ssh://git@git.example.invalid/org/repo" \
  "git@git.example.invalid:repos/app.git|ssh://git@git.example.invalid/repos/app.git" \
  "ssh://git@git.example.invalid/repos/app.git|ssh://git@git.example.invalid/repos/app" \
  "file://localhost$upstream_sub|$upstream_sub"; do
  git -C "$super" config -f .gitmodules submodule.mod.url "${pair%%|*}"
  git -C "$super/mod" config remote.origin.url "${pair#*|}"
  rc=0
  spelling=$((spelling + 1))
  out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-spelling-$spelling" "claim-branch-sub-spelling-$spelling" "session-sub-spelling" 2>&1)" || rc=$?
  check "add refuses origin ${pair#*|} for registered ${pair%%|*}" 1 "$rc" "$out" "submodule sync -- 'mod'"
done
git -C "$super/mod" config remote.origin.url "file://localhost$upstream_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-fileurl" "claim-branch-sub-fileurl" "session-sub-fileurl" 2>&1)" || rc=$?
check "add admits an origin that is exactly the registered file URL" 0 "$rc" "$out" "owner=session-sub-fileurl"

# Any other port can be a different server.
git -C "$super" config -f .gitmodules submodule.mod.url "ssh://git.example.invalid:2222/org/repo"
git -C "$super/mod" config remote.origin.url "ssh://git.example.invalid:3333/org/repo"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-port" "claim-branch-sub-port" "session-sub-port" 2>&1)" || rc=$?
check "add refuses an origin on another non-default port" 1 "$rc" "$out" "ssh://git.example.invalid:3333/org/repo"

# A server may treat repository paths case-sensitively.
git -C "$super" config -f .gitmodules submodule.mod.url "ssh://git@git.example.invalid/Org/Repo"
git -C "$super/mod" config remote.origin.url "ssh://git@git.example.invalid/org/repo"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-pathcase" "claim-branch-sub-pathcase" "session-sub-pathcase" 2>&1)" || rc=$?
check "add refuses an origin whose repository path differs only in case" 1 "$rc" "$out" "ssh://***@git.example.invalid/org/repo"

# An ssh user other than the conventional git decides whose account a relative path resolves under.
git -C "$super" config -f .gitmodules submodule.mod.url "alice@git.example.invalid:repo"
git -C "$super/mod" config remote.origin.url "mallory@git.example.invalid:repo"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-sshuser" "claim-branch-sub-sshuser" "session-sub-sshuser" 2>&1)" || rc=$?
check "add refuses an origin under another ssh user" 1 "$rc" "$out" "submodule sync"
git -C "$super/mod" config remote.origin.url "alice@git.example.invalid:repo"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-sshuser-ok" "claim-branch-sub-sshuser-ok" "session-sub-sshuser-ok" 2>&1)" || rc=$?
check "add admits an origin under the same ssh user" 0 "$rc" "$out" "owner=session-sub-sshuser-ok"

# ssh and https on one host can serve different repositories.
git -C "$super" config -f .gitmodules submodule.mod.url "ssh://git@git.example.invalid:22/org/repo"
git -C "$super/mod" config remote.origin.url "https://git.example.invalid:443/org/repo"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-transport" "claim-branch-sub-transport" "session-sub-transport" 2>&1)" || rc=$?
check "add refuses an origin that reaches the same path over another transport" 1 "$rc" "$out" "origin urls:     https://git.example.invalid:443/org/repo"

# `.git` is a suffix of a repository path; on a host name it names another host.
git -C "$super" config -f .gitmodules submodule.mod.url "ssh://forge.git/"
git -C "$super/mod" config remote.origin.url "ssh://forge/"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-hostgit" "claim-branch-sub-hostgit" "session-sub-hostgit" 2>&1)" || rc=$?
check "add refuses an origin whose host differs only by a .git suffix" 1 "$rc" "$out" "origin urls:     ssh://forge/"

# git reads `file://<host>/<path>` as /<path>, so a relative path that repeats the host is another
# repository.
git -C "$super" config -f .gitmodules submodule.mod.url "file://localhost$upstream_sub"
git -C "$super/mod" config remote.origin.url "localhost$upstream_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-filehost" "claim-branch-sub-filehost" "session-sub-filehost" 2>&1)" || rc=$?
check "add refuses a relative path that repeats a file URL's host" 1 "$rc" "$out" "origin urls:     localhost$upstream_sub"

# A query or fragment can carry a credential too.
git -C "$super" config -f .gitmodules submodule.mod.url "https://github.com/example/sub"
git -C "$super/mod" config remote.origin.url "https://github.com/example/other?access_token=q-s3cr3t#f-s3cr3t"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-query" "claim-branch-sub-query" "session-sub-query" 2>&1)" || rc=$?
check "add refuses an origin with a credential in its query" 1 "$rc" "$out" "origin urls:     https://github.com/example/other?***"
check "origin refusal redacts a query credential" 1 "$(grep -qE 's3cr3t' <<<"$out" && echo 0 || echo 1)"

# A refusal never echoes a credential carried in a remote URL.
git -C "$super" config -f .gitmodules submodule.mod.url "https://agent:gm-s3cr3t@github.com/example/sub"
git -C "$super/mod" config remote.origin.url "https://agent:s3cr3t-token@github.com/example/other"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-cred" "claim-branch-sub-cred" "session-sub-cred" 2>&1)" || rc=$?
check "add refuses a credential-bearing foreign origin" 1 "$rc" "$out" "origin urls:     https://***@github.com/example/other"
check "origin refusal prints the registered URL redacted" 1 "$rc" "$out" ".gitmodules url: https://***@github.com/example/sub"
check "origin refusal redacts both credentials" 1 "$(grep -qE 's3cr3t' <<<"$out" && echo 0 || echo 1)"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' bash -x "$script" add "$super/mod" "$tmp/wt-sub-cred-x" "claim-branch-sub-cred-x" "session-sub-cred-x" 2>&1)" || rc=$?
check "a traced refusal still refuses" 1 "$rc" "$out" "origin urls:     https://***@github.com/example/other"
check "xtrace never shows a remote credential" 1 "$(grep -qE 's3cr3t' <<<"$out" && echo 0 || echo 1)"
git -C "$super" config -f .gitmodules submodule.mod.url "https://github.com/example/sub"
git -C "$super/mod" config remote.origin.url "https://github.com/example/sub"

# The submodule's own ssh command is what fetch and push run. A global one applies to every
# repository, the superproject included, so it is not this check's concern.
git -C "$super/mod" config core.sshCommand "ssh -o ProxyCommand=true"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-sshcmd" "claim-branch-sub-sshcmd" "session-sub-sshcmd" 2>&1)" || rc=$?
check "add refuses a submodule whose own config sets core.sshCommand" 1 "$rc" "$out" "redirected by:   core.sshCommand"
git -C "$super/mod" config --unset core.sshCommand
printf '[core]\n\tsshCommand = ssh -v\n' >"$tmp/global-ssh.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-ssh.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-sshcmd-global" "claim-branch-sub-sshcmd-global" "session-sub-sshcmd-global" 2>&1)" || rc=$?
check "add admits a submodule when only global config sets core.sshCommand" 0 "$rc" "$out" "owner=session-sub-sshcmd-global"

# A global file can still apply a rewrite to this repository alone, through includeIf.
mod_gitdir="$(git -C "$super/mod" rev-parse --absolute-git-dir)"
printf '[url "https://github.com/example/other"]\n\tinsteadOf = https://github.com/example/sub\n' >"$tmp/only-mod.gitconfig"
printf '[includeIf "gitdir:%s"]\n\tpath = %s\n' "$mod_gitdir" "$tmp/only-mod.gitconfig" >"$tmp/global-include.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-include.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-includeif" "claim-branch-sub-includeif" "session-sub-includeif" 2>&1)" || rc=$?
check "add refuses an origin a global include rewrites for this repository alone" 1 "$rc" "$out" "redirected by:   URL rewrite"

# An include conditioned on the new branch applies only once the worktree is on it, so `add` checks the
# new worktree before claiming it, and takes back down what it created when that check refuses.
printf '[includeIf "onbranch:claim-branch-sub-onbranch"]\n\tpath = %s\n' "$tmp/only-mod.gitconfig" >"$tmp/global-onbranch.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-onbranch.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-onbranch" "claim-branch-sub-onbranch" "session-sub-onbranch" 2>&1)" || rc=$?
check "add refuses a new worktree its branch's include rewrites" 1 "$rc" "$out" "redirected by:   URL rewrite"
check "a refused new worktree is removed" 1 "$([ -e "$tmp/wt-sub-onbranch" ] && echo 0 || echo 1)"
check "a refused new worktree's new branch is removed" 1 "$(git -C "$super/mod" show-ref --verify --quiet refs/heads/claim-branch-sub-onbranch && echo 0 || echo 1)"
# A branch that existed before `add` is not add's to delete.
git -C "$super/mod" branch claim-branch-sub-onbranch-kept
printf '[includeIf "onbranch:claim-branch-sub-onbranch-kept"]\n\tpath = %s\n' "$tmp/only-mod.gitconfig" >"$tmp/global-onbranch-kept.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-onbranch-kept.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-onbranch-kept" "claim-branch-sub-onbranch-kept" "session-sub-onbranch-kept" 2>&1)" || rc=$?
check "add refuses an existing branch its include rewrites" 1 "$rc" "$out" "redirected by:   URL rewrite"
check "a refused worktree on an existing branch is removed" 1 "$([ -e "$tmp/wt-sub-onbranch-kept" ] && echo 0 || echo 1)"
check "a refused worktree keeps a branch that existed before add" 0 "$(git -C "$super/mod" show-ref --verify --quiet refs/heads/claim-branch-sub-onbranch-kept && echo 0 || echo 1)"
[ ! -e "$tmp/wt-sub-onbranch-kept" ] || git -C "$super/mod" worktree remove --force "$tmp/wt-sub-onbranch-kept"
git -C "$super/mod" branch -D -q claim-branch-sub-onbranch-kept

# A post-checkout hook can leave files in the new worktree, which a plain `worktree remove` refuses.
mod_hooks="$(git -C "$super/mod" rev-parse --git-common-dir)/hooks"
mkdir -p "$mod_hooks"
printf '#!/bin/sh\ntouch hook-made-file\n' >"$mod_hooks/post-checkout"
chmod +x "$mod_hooks/post-checkout"
printf '[includeIf "onbranch:claim-branch-sub-onbranch-hook"]\n\tpath = %s\n' "$tmp/only-mod.gitconfig" >"$tmp/global-onbranch-hook.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-onbranch-hook.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-onbranch-hook" "claim-branch-sub-onbranch-hook" "session-sub-onbranch-hook" 2>&1)" || rc=$?
rm -f "$mod_hooks/post-checkout"
check "add refuses a new worktree its hook dirtied" 1 "$rc" "$out" "redirected by:   URL rewrite"
check "a refused new worktree a hook dirtied is removed" 1 "$([ -e "$tmp/wt-sub-onbranch-hook" ] && echo 0 || echo 1)"
check "a refused new worktree a hook dirtied loses its new branch" 1 "$(git -C "$super/mod" show-ref --verify --quiet refs/heads/claim-branch-sub-onbranch-hook && echo 0 || echo 1)"
[ ! -e "$tmp/wt-sub-onbranch-hook" ] || git -C "$super/mod" worktree remove --force "$tmp/wt-sub-onbranch-hook"
git -C "$super/mod" branch -D -q claim-branch-sub-onbranch-hook 2>/dev/null || true

# A signal that lands once the worktree exists, but before `add` has checked and claimed it, still takes
# back what `add` created. The shim holds the creation step open after the real `git worktree add`, and
# only the main process is signalled, so its handler runs as soon as that step returns.
mkdir -p "$tmp/git-slow-add"
cat >"$tmp/git-slow-add/git" <<SHIM
#!/usr/bin/env bash
rc=0
"$(command -v git)" "\$@" || rc=\$?
case " \$* " in
  *" worktree add "*"claim-branch-sig-window"*) : >"$tmp/sig-window-created"; sleep 3 ;;
esac
exit \$rc
SHIM
chmod +x "$tmp/git-slow-add/git"
PATH="$tmp/git-slow-add:$PATH" "$script" add "$repo" "$tmp/wt-sig-window" "claim-branch-sig-window" "session-sig-window" >/dev/null 2>&1 &
sig_window=$!
waited=0
until [ -e "$tmp/sig-window-created" ] || [ "$waited" -ge 100 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
kill -TERM "$sig_window" 2>/dev/null || true
wait "$sig_window" 2>/dev/null || true
check "a signal during creation arrived after the worktree existed" 0 "$([ -e "$tmp/sig-window-created" ] && echo 0 || echo 1)"
check "a signal after creation still removes the unclaimed worktree" 1 "$([ -e "$tmp/wt-sig-window" ] && echo 0 || echo 1)"
check "a signal after creation still removes the branch add created" 1 "$(git -C "$repo" show-ref --verify --quiet refs/heads/claim-branch-sig-window && echo 0 || echo 1)"

# git runs core.gitProxy for git:// connections, so a repository-local one decides what they reach.
git -C "$super/mod" config core.gitProxy "proxy-cmd for example.invalid"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-gitproxy" "claim-branch-sub-gitproxy" "session-sub-gitproxy" 2>&1)" || rc=$?
check "add refuses a submodule whose own config sets core.gitProxy" 1 "$rc" "$out" "redirected by:   core.gitProxy"
git -C "$super/mod" config --unset core.gitProxy
printf '[core]\n\tgitProxy = proxy-cmd\n' >"$tmp/global-gitproxy.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-gitproxy.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-gitproxy-global" "claim-branch-sub-gitproxy-global" "session-sub-gitproxy-global" 2>&1)" || rc=$?
check "add admits a submodule when only global config sets core.gitProxy" 0 "$rc" "$out" "owner=session-sub-gitproxy-global"

# A curl remote's proxy, or a pinned address for its host, decides which server answers.
for setting in "remote.origin.proxy=http://proxy.example.invalid:3128" "http.proxy=http://proxy.example.invalid:3128" "http.curloptResolve=github.com:443:192.0.2.1"; do
  key="${setting%%=*}"
  git -C "$super/mod" config "$key" "${setting#*=}"
  rc=0
  out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-$key" "claim-branch-sub-$key" "session-sub-$key" 2>&1)" || rc=$?
  check "add refuses a submodule whose own config sets $key" 1 "$rc" "$out" "redirected by:   $key"
  git -C "$super/mod" config --unset "$key"
done
printf '[http]\n\tproxy = http://proxy.example.invalid:3128\n' >"$tmp/global-proxy.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-proxy.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-proxy-global" "claim-branch-sub-proxy-global" "session-sub-proxy-global" 2>&1)" || rc=$?
check "add admits a submodule when only global config sets http.proxy" 0 "$rc" "$out" "owner=session-sub-proxy-global"
# git applies an http setting scoped to a URL to every remote that URL matches.
for setting in "http.https://github.com/.proxy=http://proxy.example.invalid:3128" "http.https://github.com/.curloptResolve=github.com:443:192.0.2.1"; do
  key="${setting%%=*}"
  name="${key##*.}"
  git -C "$super/mod" config "$key" "${setting#*=}"
  rc=0
  out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-scoped-$name" "claim-branch-sub-scoped-$name" "session-sub-scoped-$name" 2>&1)" || rc=$?
  check "add refuses a submodule whose own config sets $name for origin's URL" 1 "$rc" "$out" "redirected by:   http.$name"
  git -C "$super/mod" config --unset "$key"
done

# The probe repository is compared as neutral ground, so a user's init template must not reach it.
mkdir -p "$tmp/init-template"
printf '[core]\n\tsshCommand = ssh -o ProxyCommand=true\n' >"$tmp/init-template/config"
rc=0
out="$(GIT_TEMPLATE_DIR="$tmp/init-template" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-template" "claim-branch-sub-template" "session-sub-template" 2>&1)" || rc=$?
check "add admits a correct submodule when the user's init template sets core.sshCommand" 0 "$rc" "$out" "owner=session-sub-template"

# A Host header can make the registered URL reach another repository on the same server.
i=0
for key in "http.extraHeader" "http.https://github.com/.extraHeader"; do
  i=$((i + 1))
  git -C "$super/mod" config "$key" "Host: foreign.invalid"
  rc=0
  out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-header-$i" "claim-branch-sub-header-$i" "session-sub-header-$i" 2>&1)" || rc=$?
  check "add refuses a submodule whose own config sets $key" 1 "$rc" "$out" "redirected by:   http.extraHeader"
  git -C "$super/mod" config --unset "$key"
done
printf '[http]\n\textraHeader = X-Trace: on\n' >"$tmp/global-header.gitconfig"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-header.gitconfig" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-header-global" "claim-branch-sub-header-global" "session-sub-header-global" 2>&1)" || rc=$?
check "add admits a submodule when only global config sets http.extraHeader" 0 "$rc" "$out" "owner=session-sub-header-global"

# A plain push goes to the branch's push remote, which only defaults to origin.
git -C "$super/mod" config remote.pushDefault other
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-pushdefault" "claim-branch-sub-pushdefault" "session-sub-pushdefault" 2>&1)" || rc=$?
check "add refuses a submodule whose remote.pushDefault names another remote" 1 "$rc" "$out" "push remote:      other"
git -C "$super/mod" config branch.claim-branch-sub-pushremote-origin.pushRemote origin
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-pushremote-origin" "claim-branch-sub-pushremote-origin" "session-sub-pushremote-origin" 2>&1)" || rc=$?
check "add refuses remote.pushDefault in the main checkout even when the new branch pushes to origin" 1 "$rc" "$out" "push remote:      other"
git -C "$super/mod" config --unset remote.pushDefault
git -C "$super/mod" config --unset branch.claim-branch-sub-pushremote-origin.pushRemote
git -C "$super/mod" config branch.claim-branch-sub-pushremote.pushRemote other
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-pushremote" "claim-branch-sub-pushremote" "session-sub-pushremote" 2>&1)" || rc=$?
check "add refuses a new branch whose pushRemote names another remote" 1 "$rc" "$out" "push remote:      other"
check "a new branch set to push elsewhere loses its worktree" 1 "$([ -e "$tmp/wt-sub-pushremote" ] && echo 0 || echo 1)"
[ ! -e "$tmp/wt-sub-pushremote" ] || git -C "$super/mod" worktree remove --force "$tmp/wt-sub-pushremote"
git -C "$super/mod" config --unset branch.claim-branch-sub-pushremote.pushRemote
git -C "$super/mod" branch -D -q claim-branch-sub-pushremote 2>/dev/null || true
# A branch that tracks another remote pushes there too; "." keeps pushes in this repository.
git -C "$super/mod" branch claim-branch-sub-tracks-other
git -C "$super/mod" config branch.claim-branch-sub-tracks-other.remote other
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-tracks-other" "claim-branch-sub-tracks-other" "session-sub-tracks-other" 2>&1)" || rc=$?
check "add refuses a branch that tracks another remote" 1 "$rc" "$out" "push remote:      other"
check "a refused tracking branch loses its worktree" 1 "$([ -e "$tmp/wt-sub-tracks-other" ] && echo 0 || echo 1)"
[ ! -e "$tmp/wt-sub-tracks-other" ] || git -C "$super/mod" worktree remove --force "$tmp/wt-sub-tracks-other"
git -C "$super/mod" config branch.claim-branch-sub-tracks-other.remote .
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-tracks-local" "claim-branch-sub-tracks-other" "session-sub-tracks-local" 2>&1)" || rc=$?
check "add admits a branch that tracks this repository" 0 "$rc" "$out" "owner=session-sub-tracks-local"

# `submodule sync` writes a registered URL byte for byte, trailing newline included, so an origin
# without it is not that URL; a URL carrying a newline cannot be verified either way.
git -C "$super" config -f .gitmodules submodule.mod.url "https://github.com/example/sub"$'\n'
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-gmnewline" "claim-branch-sub-gmnewline" "session-sub-gmnewline" 2>&1)" || rc=$?
check "add refuses when the registered URL ends in a newline origin lacks" 1 "$rc" "$out" "contains a newline"
git -C "$super" config -f .gitmodules submodule.mod.url "https://github.com/example/sub"

# A completed check removes its probe repository as well.
mkdir -p "$tmp/probe-done"
rc=0
out="$(TMPDIR="$tmp/probe-done" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-probe-done" "claim-branch-sub-probe-done" "session-sub-probe-done" 2>&1)" || rc=$?
check "a completed origin check still claims" 0 "$rc" "$out" "owner=session-sub-probe-done"
check "a completed origin check leaves no probe repository behind" 1 "$(compgen -G "$tmp/probe-done/worktree-claim-probe.*" >/dev/null && echo 0 || echo 1)"

# The probe repository holds the registered URL, which can carry a credential, so an interrupted check
# must not leave it behind. The shim holds the check inside the probe until the job is signalled; it
# replaces itself with the sleep, so the process holding the check's pipe is one the signal reaches.
real_git="$(command -v git)"
mkdir -p "$tmp/git-slow-probe" "$tmp/probe-tmp"
cat >"$tmp/git-slow-probe/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get-url --all probe "*) : >"$tmp/probe-reached"; exec sleep 30 ;;
esac
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/git-slow-probe/git"
# Signal the run and every process under it, as a terminal or supervisor signals a process group.
# The tree is walked explicitly: job control, which would give the run its own group, needs a terminal
# that CI does not have.
process_tree() {
  local all queue=("$1") pid child parent tree=""
  all="$(ps -A -o pid= -o ppid=)"
  while [ "${#queue[@]}" -gt 0 ]; do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    tree="$tree $pid"
    while read -r child parent; do
      [ "$parent" != "$pid" ] || queue+=("$child")
    done <<<"$all"
  done
  printf '%s\n' "$tree"
}
PATH="$tmp/git-slow-probe:$PATH" TMPDIR="$tmp/probe-tmp" GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-interrupt" "claim-branch-sub-interrupt" "session-sub-interrupt" >/dev/null 2>&1 &
interrupted=$!
waited=0
until [ -e "$tmp/probe-reached" ] || [ "$waited" -ge 100 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
interrupted_tree="$(process_tree "$interrupted")"
# shellcheck disable=SC2086 # one pid per word
kill -TERM $interrupted_tree 2>/dev/null || true
wait "$interrupted" 2>/dev/null || true
waited=0
while compgen -G "$tmp/probe-tmp/worktree-claim-probe.*" >/dev/null && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
check "an interrupted origin check was inside its probe" 0 "$([ -e "$tmp/probe-reached" ] && echo 0 || echo 1)"
if compgen -G "$tmp/probe-tmp/worktree-claim-probe.*" >/dev/null; then
  # shellcheck disable=SC2086 # one pid per word
  ps -o pid= -o ppid= -o command= -p "$(echo $interrupted_tree | tr ' ' ',')" >&2 || true
fi
check "an interrupted origin check leaves no probe repository behind" 1 "$(compgen -G "$tmp/probe-tmp/worktree-claim-probe.*" >/dev/null && echo 0 || echo 1)"

# One configured value that repeats the registered URL across a newline is one URL to git, not two.
git -C "$super/mod" config remote.origin.url "$(printf '%s\n%s' "https://github.com/example/sub" "https://github.com/example/sub")"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-newline" "claim-branch-sub-newline" "session-sub-newline" 2>&1)" || rc=$?
check "add refuses an origin value that embeds a newline" 1 "$rc" "$out" "submodule sync -- 'mod'"
git -C "$super/mod" config remote.origin.url "https://github.com/example/sub"

# Stray content in a registered path that was never populated resolves to the superproject.
mkdir -p "$super/stray"
printf 'stray\n' >"$super/stray/leftover.txt"
git -C "$super" config -f .gitmodules submodule.stray.path stray
git -C "$super" config -f .gitmodules submodule.stray.url "$upstream_sub"
rc=0
out="$("$script" add "$super/stray" "$tmp/wt-stray" "claim-branch-stray" "session-stray" 2>&1)" || rc=$?
check "add refuses a registered path whose stray content resolves to the superproject" 1 "$rc" "$out" "submodule-init.sh"
check "stray refusal creates no branch in the superproject" 1 "$(git -C "$super" show-ref --verify --quiet refs/heads/claim-branch-stray && echo 0 || echo 1)"

# A push URL is where commits land, so a foreign pushurl is refused even when origin's fetch URL matches.
git -C "$super/mod" config remote.origin.pushurl "$other_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-pushurl" "claim-branch-sub-pushurl" "session-sub-pushurl" 2>&1)" || rc=$?
check "add refuses a submodule whose push URL is another repository" 1 "$rc" "$out" "$other_sub"
git -C "$super/mod" config --unset remote.origin.pushurl

# A custom pack command or remote helper is what fetch and push run, so it can reach another repository
# whatever the URL says.
for key in receivepack uploadpack vcs; do
  git -C "$super/mod" config "remote.origin.$key" "git-$key '$other_sub' #"
  rc=0
  out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-$key" "claim-branch-sub-$key" "session-sub-$key" 2>&1)" || rc=$?
  check "add refuses an origin with a custom $key setting" 1 "$rc" "$out" "custom transport: remote.origin.$key"
  git -C "$super/mod" config --unset "remote.origin.$key"
done

# A relative path shaped like host/owner/repo is a local repository, not the network URL it resembles.
git -C "$super/mod" config remote.origin.url "github.com/example/sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-localpath" "claim-branch-sub-localpath" "session-sub-localpath" 2>&1)" || rc=$?
check "add refuses a local path that merely looks like the registered URL" 1 "$rc" "$out" "origin urls:     github.com/example/sub"

# `.git` is a network spelling; on a local path it names a different directory.
git -C "$super" config -f .gitmodules submodule.mod.url "$upstream_sub.git"
git -C "$super/mod" config remote.origin.url "$upstream_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-dotgit" "claim-branch-sub-dotgit" "session-sub-dotgit" 2>&1)" || rc=$?
check "add refuses a local path that differs only by a .git suffix" 1 "$rc" "$out" ".gitmodules url: $upstream_sub.git"

# A relative .gitmodules URL resolves against the superproject's remote, as `git submodule init` does.
mkdir -p "$tmp/remote-root"
ln -s "$upstream_sub" "$tmp/remote-root/upstream-sub"
git -C "$super" config remote.origin.url "$tmp/remote-root/super"
git -C "$super" config -f .gitmodules submodule.mod.url "../upstream-sub"
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/upstream-sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-relative" "claim-branch-sub-relative" "session-sub-relative" 2>&1)" || rc=$?
check "add resolves a relative .gitmodules URL before comparing" 0 "$rc" "$out" "owner=session-sub-relative"

# git keeps a newline at the end of the superproject's remote URL inside the URL it resolves for `./x`,
# so an origin written without it is not what `submodule sync` writes.
git -C "$super" config remote.origin.url "$tmp/remote-root/super"$'\n'
git -C "$super" config -f .gitmodules submodule.mod.url "./child"
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/super/child"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-basenewline" "claim-branch-sub-basenewline" "session-sub-basenewline" 2>&1)" || rc=$?
check "add refuses a relative URL against a superproject remote that ends in a newline" 1 "$rc" "$out" "remote URL that contains a newline"
git -C "$super" config remote.origin.url "$tmp/remote-root/super"
git -C "$super" config -f .gitmodules submodule.mod.url "../upstream-sub"
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/upstream-sub"

# An explicitly empty branch remote names no remote, so git resolves against the superproject's own
# path, not origin.
git -C "$super" config branch.main.remote ""
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-emptyremote" "claim-branch-sub-emptyremote" "session-sub-emptyremote" 2>&1)" || rc=$?
check "add refuses an origin resolved against origin when the branch remote is empty" 1 "$rc" "$out" ".gitmodules url: ${super_phys%/*}/upstream-sub"
git -C "$super/mod" config remote.origin.url "${super_phys%/*}/upstream-sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-emptyremote-ok" "claim-branch-sub-emptyremote-ok" "session-sub-emptyremote-ok" 2>&1)" || rc=$?
check "add admits the origin sync writes when the branch remote is empty" 0 "$rc" "$out" "owner=session-sub-emptyremote-ok"
git -C "$super" config --unset branch.main.remote
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/upstream-sub"

# A ':' inside the superproject's path is data: git drops the last component at the last '/'.
git -C "$super" config remote.origin.url "https://git.example.invalid/org/super:variant.git"
git -C "$super" config -f .gitmodules submodule.mod.url "../sub.git"
git -C "$super/mod" config remote.origin.url "https://git.example.invalid/org/sub.git"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-relcolon" "claim-branch-sub-relcolon" "session-sub-relcolon" 2>&1)" || rc=$?
check "add resolves a relative URL past a ':' in the superproject's path as git does" 0 "$rc" "$out" "owner=session-sub-relcolon"
git -C "$super/mod" config remote.origin.url "https://git.example.invalid/org/super:sub.git"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-relcolon-wrong" "claim-branch-sub-relcolon-wrong" "session-sub-relcolon-wrong" 2>&1)" || rc=$?
check "add refuses the origin a ':' split would resolve to" 1 "$rc" "$out" "https://git.example.invalid/org/super:sub.git"

# A `..` that climbs past an scp-like remote's host leaves `.` in its place, as git does; one more
# `..` is an error git cannot resolve.
git -C "$super" config remote.origin.url "git@git.example.invalid:org/super.git"
git -C "$super" config -f .gitmodules submodule.mod.url "../../../sub.git"
git -C "$super/mod" config remote.origin.url ".:sub.git"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-relroot" "claim-branch-sub-relroot" "session-sub-relroot" 2>&1)" || rc=$?
check "add resolves a relative URL that climbs past an scp host as git does" 0 "$rc" "$out" "owner=session-sub-relroot"
git -C "$super/mod" config remote.origin.url "git@git.example.invalid:sub.git"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-relroot-wrong" "claim-branch-sub-relroot-wrong" "session-sub-relroot-wrong" 2>&1)" || rc=$?
check "add refuses the origin a relative URL would reach if it stopped at the host" 1 "$rc" "$out" "origin urls:     ***@git.example.invalid:sub.git"
git -C "$super" config -f .gitmodules submodule.mod.url "../../../../sub.git"
rc=0
out="$(GIT_ALLOW_PROTOCOL='file' "$script" add "$super/mod" "$tmp/wt-sub-relroot-over" "claim-branch-sub-relroot-over" "session-sub-relroot-over" 2>&1)" || rc=$?
check "add refuses a relative URL that climbs further than git can resolve" 1 "$rc" "$out" "climbs past the root of the superproject's remote"

# A global rewrite applies to every repository, so an origin written exactly as `submodule sync`
# resolves the relative URL is admitted even though the rewrite changes where it fetches.
mkdir -p "$tmp/mirror"
ln -s "$upstream_sub" "$tmp/mirror/sub.git"
printf '[url "%s/"]\n\tinsteadOf = alias:\n' "$tmp/mirror" >"$tmp/global-mirror.gitconfig"
git -C "$super" config remote.origin.url "alias:super.git"
git -C "$super" config -f .gitmodules submodule.mod.url "../sub.git"
git -C "$super/mod" config remote.origin.url "alias:sub.git"
rc=0
out="$(GIT_CONFIG_GLOBAL="$tmp/global-mirror.gitconfig" "$script" add "$super/mod" "$tmp/wt-sub-mirror" "claim-branch-sub-mirror" "session-sub-mirror" 2>&1)" || rc=$?
check "add admits an origin a global rewrite sends to a mirror" 0 "$rc" "$out" "owner=session-sub-mirror"

# A relative superproject remote resolves relative to the submodule's own directory, as sync writes it.
mkdir -p "$super/foo"
ln -s "$upstream_sub" "$super/foo/sub.git"
git -C "$super" config remote.origin.url "foo/super.git"
git -C "$super/mod" config remote.origin.url "../foo/sub.git"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-relremote" "claim-branch-sub-relremote" "session-sub-relremote" 2>&1)" || rc=$?
check "add admits the origin sync writes for a relative superproject remote" 0 "$rc" "$out" "owner=session-sub-relremote"
rm -rf "$super/foo"
git -C "$super" config remote.origin.url "$tmp/remote-root/super"
git -C "$super" config -f .gitmodules submodule.mod.url "../upstream-sub"
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/upstream-sub"

# A linked worktree of the submodule outside the superproject shares origin, so it is checked too.
git -C "$super/mod" worktree add -q --detach "$tmp/linked-mod"
git -C "$super/mod" config remote.origin.url "$other_sub"
rc=0
out="$("$script" add "$tmp/linked-mod" "$tmp/wt-linked-wrong" "claim-branch-linked-wrong" "session-linked-wrong" 2>&1)" || rc=$?
check "add refuses a linked submodule worktree whose origin is another repository" 1 "$rc" "$out" "$other_sub"
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/upstream-sub"
rc=0
out="$("$script" add "$tmp/linked-mod" "$tmp/wt-linked-ok" "claim-branch-linked-ok" "session-linked-ok" 2>&1)" || rc=$?
check "add admits a linked submodule worktree whose origin is registered" 0 "$rc" "$out" "owner=session-linked-ok"

# acquire applies the same check to an existing submodule worktree.
git -C "$super/mod" config remote.origin.url "$other_sub"
rc=0
out="$("$script" acquire "$tmp/wt-linked-ok" "session-linked-ok" 2>&1)" || rc=$?
check "acquire refuses a submodule worktree whose origin is another repository" 1 "$rc" "$out" "$other_sub"
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/upstream-sub"
rc=0
out="$("$script" acquire "$tmp/wt-linked-ok" "session-linked-ok" 2>&1)" || rc=$?
check "acquire renews a submodule worktree whose origin is registered" 0 "$rc" "$out" "renewed"

# A submodule name may contain a space; the registration must still be found.
git -C "$super" -c protocol.file.allow=always submodule add -q "$upstream_sub" "mod space"
rc=0
out="$("$script" add "$super/mod space" "$tmp/wt-sub-space" "claim-branch-sub-space" "session-sub-space" 2>&1)" || rc=$?
check "add finds a submodule whose name contains a space" 0 "$rc" "$out" "owner=session-sub-space"

# A linked worktree of a NESTED submodule is registered by its immediate parent, not the top level.
outer_sub="$tmp/outer-sub"
git init -q -b main "$outer_sub"
git -C "$outer_sub" -c protocol.file.allow=always submodule add -q "$upstream_sub" inner
git -C "$outer_sub" -c user.name=t -c user.email=t@example.com commit -qm "add inner"
nest_super="$tmp/nest-super"
git init -q -b main "$nest_super"
git -C "$nest_super" -c protocol.file.allow=always submodule add -q "$outer_sub" outer
git -C "$nest_super" -c protocol.file.allow=always submodule update -q --init --recursive
git -C "$nest_super/outer/inner" worktree add -q --detach "$tmp/linked-inner"
rc=0
out="$("$script" add "$tmp/linked-inner" "$tmp/wt-linked-inner" "claim-branch-linked-inner" "session-linked-inner" 2>&1)" || rc=$?
check "add admits a linked worktree of a nested submodule" 0 "$rc" "$out" "owner=session-linked-inner"
git -C "$nest_super/outer/inner" config remote.origin.url "$other_sub"
rc=0
out="$("$script" add "$tmp/linked-inner" "$tmp/wt-linked-inner-wrong" "claim-branch-linked-inner-wrong" "session-linked-inner-wrong" 2>&1)" || rc=$?
check "add refuses a nested linked worktree whose origin is another repository" 1 "$rc" "$out" "submodule sync -- 'inner'"

# A submodule of a linked superproject worktree keeps its git directory under
# <super>/.git/worktrees/<id>/modules/, which is how a session worktree's submodules are laid out.
session="$tmp/session-super"
git -C "$super" worktree add -q --detach "$session"
git -C "$session" -c protocol.file.allow=always submodule update -q --init mod
git -C "$session/mod" worktree add -q --detach "$session/per-run"
rc=0
out="$("$script" add "$session/per-run" "$tmp/wt-session-ok" "claim-branch-session-ok" "session-session-ok" 2>&1)" || rc=$?
check "add admits a worktree of a linked superproject's submodule" 0 "$rc" "$out" "owner=session-session-ok"
git -C "$session/mod" config remote.origin.url "$other_sub"
rc=0
out="$("$script" add "$session/per-run" "$tmp/wt-session-wrong" "claim-branch-session-wrong" "session-session-wrong" 2>&1)" || rc=$?
check "add refuses a linked superproject's submodule whose origin is another repository" 1 "$rc" "$out" "submodule sync -- 'mod'"

# A superproject created with --separate-git-dir keeps its submodules' git directories there too, so
# their location never names the superproject; the submodule's main checkout still does.
mkdir -p "$tmp/sep-admin" "$tmp/sep-work"
sep_super="$tmp/sep-work/super"
git init -q -b main --separate-git-dir "$tmp/sep-admin/super" "$sep_super"
git -C "$sep_super" -c protocol.file.allow=always submodule add -q "$upstream_sub" mod
git -C "$sep_super" -c user.name=t -c user.email=t@example.com commit -qm "add submodule"
git -C "$sep_super/mod" worktree add -q --detach "$tmp/sep-linked"
rc=0
out="$("$script" add "$tmp/sep-linked" "$tmp/wt-sep-ok" "claim-branch-sep-ok" "session-sep-ok" 2>&1)" || rc=$?
check "add admits a linked worktree of a separate-git-dir superproject's submodule" 0 "$rc" "$out" "owner=session-sep-ok"
git -C "$sep_super/mod" config remote.origin.url "$other_sub"
rc=0
out="$("$script" add "$tmp/sep-linked" "$tmp/wt-sep-wrong" "claim-branch-sep-wrong" "session-sep-wrong" 2>&1)" || rc=$?
check "add refuses a separate-git-dir superproject's linked submodule with a foreign origin" 1 "$rc" "$out" "submodule sync -- 'mod'"
# With extensions.worktreeConfig, core.worktree can live in config.worktree instead of config.
sep_common="$(git -C "$sep_super/mod" rev-parse --path-format=absolute --git-common-dir)"
sep_worktree="$(git --git-dir="$sep_common" config --get core.worktree)"
git --git-dir="$sep_common" config extensions.worktreeConfig true
git --git-dir="$sep_common" config --unset core.worktree
git --git-dir="$sep_common" config --worktree core.worktree "$sep_worktree"
rc=0
out="$("$script" add "$tmp/sep-linked" "$tmp/wt-sep-wtconfig" "claim-branch-sep-wtconfig" "session-sep-wtconfig" 2>&1)" || rc=$?
check "add refuses a foreign origin when core.worktree lives in config.worktree" 1 "$rc" "$out" "submodule sync -- 'mod'"
# Without its main checkout nothing leads to the superproject, so the worktree is refused, not waved through.
mv "$sep_super/mod" "$tmp/sep-mod-away"
rc=0
out="$("$script" add "$tmp/sep-linked" "$tmp/wt-sep-orphan" "claim-branch-sep-orphan" "session-sep-orphan" 2>&1)" || rc=$?
check "add refuses a submodule worktree whose superproject cannot be found" 1 "$rc" "$out" "no superproject registers it"
mv "$tmp/sep-mod-away" "$sep_super/mod"

# A standalone repository may keep its git directory elsewhere, with core.worktree pointing back at its
# checkout; nothing registers it, so it is not refused.
mkdir -p "$tmp/standalone-admin"
git init -q -b main --separate-git-dir "$tmp/standalone-admin/repo" "$tmp/standalone"
git --git-dir="$tmp/standalone-admin/repo" config core.worktree "$tmp/standalone"
git -C "$tmp/standalone" -c user.name=t -c user.email=t@example.com commit --allow-empty -qm init
rc=0
out="$("$script" add "$tmp/standalone" "$tmp/wt-standalone" "claim-branch-standalone" "session-standalone" 2>&1)" || rc=$?
check "add admits a standalone repository whose core.worktree points back at its checkout" 0 "$rc" "$out" "owner=session-standalone"
# A submodule's git directory stays a submodule's even when its core.worktree points at a standalone checkout.
git --git-dir="$sep_common" config --worktree core.worktree "$tmp/standalone"
rc=0
out="$("$script" add "$tmp/sep-linked" "$tmp/wt-sep-repointed" "claim-branch-sep-repointed" "session-sep-repointed" 2>&1)" || rc=$?
check "add refuses a submodule worktree whose core.worktree points at a standalone checkout" 1 "$rc" "$out" "no superproject registers it"
git --git-dir="$sep_common" config --worktree core.worktree "$sep_worktree"

# A submodule cloned in place keeps its git directory at <checkout>/.git with no core.worktree, so its
# main checkout is that directory's parent, and a linked worktree of it is still that submodule's.
inplace_super="$tmp/inplace-super"
git init -q -b main "$inplace_super"
git clone -q "$upstream_sub" "$inplace_super/indep"
git -C "$inplace_super" -c protocol.file.allow=always submodule add -q "$upstream_sub" indep
git -C "$inplace_super" -c user.name=t -c user.email=t@example.com commit -qm "add in-place submodule"
git -C "$inplace_super/indep" worktree add -q --detach "$tmp/linked-indep"
rc=0
out="$("$script" add "$tmp/linked-indep" "$tmp/wt-indep-ok" "claim-branch-indep-ok" "session-indep-ok" 2>&1)" || rc=$?
check "add admits a linked worktree of an in-place submodule clone" 0 "$rc" "$out" "owner=session-indep-ok"
git -C "$inplace_super/indep" config remote.origin.url "$other_sub"
rc=0
out="$("$script" add "$tmp/linked-indep" "$tmp/wt-indep-wrong" "claim-branch-indep-wrong" "session-indep-wrong" 2>&1)" || rc=$?
check "add refuses a linked worktree of an in-place submodule clone with a foreign origin" 1 "$rc" "$out" "submodule sync -- 'indep'"
# Repointing the in-place clone's core.worktree at a standalone checkout does not move where it lives.
git config -f "$inplace_super/indep/.git/config" core.worktree "$tmp/standalone"
rc=0
out="$("$script" acquire "$tmp/linked-indep" "session-indep-repointed" 2>&1)" || rc=$?
check "acquire refuses an in-place clone whose core.worktree points at a standalone checkout" 1 "$rc" "$out" "submodule sync -- 'indep'"
git config -f "$inplace_super/indep/.git/config" --unset core.worktree
rm -f "$tmp/linked-indep/.claude-worktree-owner"
git -C "$inplace_super/indep" config remote.origin.url "$upstream_sub"

# When two .gitmodules sections claim one path, git initializes it from the later one.
git -C "$super" config -f .gitmodules submodule.dup.path mod
git -C "$super" config -f .gitmodules submodule.dup.url "$other_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-dup-first" "claim-branch-sub-dup-first" "session-sub-dup-first" 2>&1)" || rc=$?
check "add refuses an origin that only an earlier duplicate section registers" 1 "$rc" "$out" ".gitmodules url: $other_sub"
git -C "$super/mod" config remote.origin.url "$other_sub"
rc=0
out="$("$script" add "$super/mod" "$tmp/wt-sub-dup-last" "claim-branch-sub-dup-last" "session-sub-dup-last" 2>&1)" || rc=$?
check "add admits the origin the later duplicate section registers" 0 "$rc" "$out" "owner=session-sub-dup-last"
git -C "$super/mod" config remote.origin.url "$tmp/remote-root/upstream-sub"
git -C "$super" config -f .gitmodules --remove-section submodule.dup

# ── check: mine ────────────────────────────────────────────────────────────
rc=0
out="$("$script" check "$wt" "session-alpha" 2>&1)" || rc=$?
check "check mine" 0 "$rc" "$out" "mine"

# ── check: live foreign ────────────────────────────────────────────────────
rc=0
out="$("$script" check "$wt" "session-beta" 2>&1)" || rc=$?
check "check live foreign" 3 "$rc" "$out" "LIVE foreign claim"

# ── check: expired foreign ─────────────────────────────────────────────────
# Rewrite marker with an old timestamp (3h ago).
old="$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")"
printf 'owner=session-alpha\ncreated_at=%s\n' "$old" >"$wt/.claude-worktree-owner"
rc=0
out="$("$script" check "$wt" "session-beta" 2>&1)" || rc=$?
check "check expired foreign" 0 "$rc" "$out" "expired"

# ── acquire: expired ownership transfers atomically ──────────────────────────
rc=0
out="$("$script" acquire "$wt" "session-beta" 2>&1)" || rc=$?
check "acquire transfers expired claim" 0 "$rc" "$out" "owner=session-beta"
owner_line="$(grep '^owner=' "$wt/.claude-worktree-owner")"
check "transferred marker owner" 0 0 "$owner_line" "owner=session-beta"

# ── acquire: current owner renews its lease ───────────────────────────────
printf 'owner=session-beta\ncreated_at=%s\n' "$old" >"$wt/.claude-worktree-owner"
rc=0
out="$("$script" acquire "$wt" "session-beta" 2>&1)" || rc=$?
check "acquire renews own claim" 0 "$rc" "$out" "renewed"
renewed_at="$(sed -n 's/^created_at=//p' "$wt/.claude-worktree-owner")"
check "renewal refreshes timestamp" 0 "$([ "$renewed_at" != "$old" ] && echo 0 || echo 1)"

# ── malformed foreign marker fails closed ───────────────────────────────────
printf 'owner=session-beta\ncreated_at=not-a-timestamp\n' >"$wt/.claude-worktree-owner"
rc=0
out="$("$script" acquire "$wt" "session-other" 2>&1)" || rc=$?
check "malformed foreign marker fails closed" 2 "$rc" "$out" "unparseable"

# ── acquire recovers a lock whose owner process is gone ────────────────────────────
stale="$tmp/stale-lock-wt"
git -C "$repo" worktree add -q -b "claim-branch-stale-lock" "$stale"
stale_real="$(cd "$stale" && pwd -P)"
stale_hash="$(printf '%s' "$stale_real" | git -C "$stale" hash-object --stdin)"
stale_ref="refs/worktree/claim-locks/$stale_hash"
stale_blob="$(printf 'pid=999999999\ncreated_at=%s\n' "$old" | git -C "$stale" hash-object -w --stdin)"
git -C "$stale" update-ref "$stale_ref" "$stale_blob"
rc=0
out="$("$script" acquire "$stale" "session-after-crash" 2>&1)" || rc=$?
check "acquire recovers stale process lock" 0 "$rc" "$out" "owner=session-after-crash"
check "recovered lock ref is released" 1 "$(git -C "$stale" rev-parse -q --verify "$stale_ref" >/dev/null 2>&1; echo $?)"

# ── concurrent stale-lock recovery is compare-and-swap safe ────────────────────────
stale_race="$tmp/stale-race-wt"
git -C "$repo" worktree add -q -b "claim-branch-stale-race" "$stale_race"
stale_race_real="$(cd "$stale_race" && pwd -P)"
stale_race_hash="$(printf '%s' "$stale_race_real" | git -C "$stale_race" hash-object --stdin)"
stale_race_ref="refs/worktree/claim-locks/$stale_race_hash"
stale_race_blob="$(printf 'pid=999999999\ncreated_at=%s\n' "$old" | git -C "$stale_race" hash-object -w --stdin)"
git -C "$stale_race" update-ref "$stale_race_ref" "$stale_race_blob"
"$script" acquire "$stale_race" "session-stale-racer-a" >"$tmp/stale-racer-a.out" 2>&1 &
stale_pid_a=$!
"$script" acquire "$stale_race" "session-stale-racer-b" >"$tmp/stale-racer-b.out" 2>&1 &
stale_pid_b=$!
stale_rc_a=0
wait "$stale_pid_a" || stale_rc_a=$?
stale_rc_b=0
wait "$stale_pid_b" || stale_rc_b=$?
stale_race_result=1
if { [ "$stale_rc_a" -eq 0 ] && [ "$stale_rc_b" -eq 3 ]; } ||
  { [ "$stale_rc_a" -eq 3 ] && [ "$stale_rc_b" -eq 0 ]; }; then
  stale_race_result=0
fi
check "concurrent stale recovery has one winner" 0 "$stale_race_result"

# ── acquire: concurrent claimants have exactly one winner ────────────────────────
race="$tmp/race-wt"
git -C "$repo" worktree add -q -b "claim-branch-race" "$race"
"$script" acquire "$race" "session-racer-a" >"$tmp/racer-a.out" 2>&1 &
pid_a=$!
"$script" acquire "$race" "session-racer-b" >"$tmp/racer-b.out" 2>&1 &
pid_b=$!
rc_a=0
wait "$pid_a" || rc_a=$?
rc_b=0
wait "$pid_b" || rc_b=$?
race_result=1
if { [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 3 ]; } ||
  { [ "$rc_a" -eq 3 ] && [ "$rc_b" -eq 0 ]; }; then
  race_result=0
fi
check "concurrent acquire has one winner" 0 "$race_result"
race_owner="$(sed -n 's/^owner=//p' "$race/.claude-worktree-owner")"
winner="session-racer-a"
[ "$rc_b" -eq 0 ] && winner="session-racer-b"
check "concurrent winner owns marker" "$winner" "$race_owner"

# ── check: absent path is free ─────────────────────────────────────────────
rc=0
out="$("$script" check "$tmp/no-such-wt" "session-beta" 2>&1)" || rc=$?
check "check absent path" 0 "$rc" "$out" "path absent"

# ── mark on existing tree ──────────────────────────────────────────────────
bare="$tmp/bare-wt"
git -C "$repo" worktree add -q -b "claim-branch-b" "$bare"
# A pre-existing exclude file need not end with a newline. The marker rule must
# still become a distinct pattern rather than concatenate with the last one.
exclude_path="$(git -C "$bare" rev-parse --git-path info/exclude)"
printf 'existing-rule' >"$exclude_path"
rc=0
out="$("$script" mark "$bare" "session-gamma" 2>&1)" || rc=$?
check "mark succeeds" 0 "$rc" "$out" "owner=session-gamma"
bare_status="$(git -C "$bare" status --porcelain --untracked-files=all)"
check "newline-less exclude still ignores marker" "" "$bare_status"
rc=0
out="$("$script" check "$bare" "session-other" 2>&1)" || rc=$?
check "mark then foreign check" 3 "$rc" "$out" "LIVE foreign claim"

# ── an unmarked worktree someone is working in is never "free" (monorepo#2724) ──
# The marker is a claim a cooperating writer opts into, and a harness session never writes one, so an
# unmarked tree must be checked for a live process before it reads as free. lsof is stubbed so each
# arm is deterministic; the last arm uses the real tool to prove the parse against its actual output.
shim="$tmp/lsof-shim"
mkdir -p "$shim"
cat >"$shim/lsof" <<'SHIM'
#!/usr/bin/env bash
printf '%b' "${LSOF_STUB_OUT-}"
exit "${LSOF_STUB_RC:-0}"
SHIM
chmod +x "$shim/lsof"
occupied="$tmp/occupied-wt"
git -C "$repo" worktree add -q -b "claim-branch-occupied" "$occupied"
occupied_real="$(cd "$occupied" && pwd -P)"
idle_out='p1\nn/\n'

run_stubbed() {
  local stub_out=$1 stub_rc=$2
  shift 2
  PATH="$shim:$PATH" LSOF_STUB_OUT="$stub_out" LSOF_STUB_RC="$stub_rc" "$script" "$@"
}

rc=0
out="$(run_stubbed "${idle_out}p999999\nn${occupied_real}\n" 0 check "$occupied" "session-delta" 2>&1)" || rc=$?
check "check unmarked tree with a live process" 3 "$rc" "$out" "pid=999999"
rc=0
out="$(run_stubbed "${idle_out}p999999\nn${occupied_real}/sub/dir\n" 0 check "$occupied" "session-delta" 2>&1)" || rc=$?
check "check unmarked tree with a live process below it" 3 "$rc" "$out" "LIVE"
rc=0
out="$(run_stubbed "${idle_out}p999999\nn${occupied_real}\n" 0 acquire "$occupied" "session-delta" 2>&1)" || rc=$?
check "acquire unmarked tree with a live process" 3 "$rc" "$out" "stand down"
check "occupied acquire writes no marker" 1 "$([ -e "$occupied/.claude-worktree-owner" ] && echo 0 || echo 1)"

# Negative controls: a sibling path sharing the prefix, the caller's own process chain, and an idle
# system must all read free, or the check would make every worktree unclaimable.
rc=0
out="$(run_stubbed "${idle_out}p999999\nn${occupied_real}-sibling\n" 0 check "$occupied" "session-delta" 2>&1)" || rc=$?
check "a sibling path sharing the prefix is not an occupant" 0 "$rc" "$out" "free"
rc=0
out="$(run_stubbed "${idle_out}p$$\nn${occupied_real}\n" 0 check "$occupied" "session-delta" 2>&1)" || rc=$?
check "the caller's own process chain is not an occupant" 0 "$rc" "$out" "free"
rc=0
out="$(run_stubbed "${idle_out}p999999\nn/proc/999999/cwd (readlink: Permission denied)\n" 0 check "$occupied" "session-delta" 2>&1)" || rc=$?
check "an unreadable cwd is not an occupant" 0 "$rc" "$out" "free"

# lsof failure fails closed: a partial or empty process list cannot prove the tree is idle.
rc=0
out="$(run_stubbed "$idle_out" 1 check "$occupied" "session-delta" 2>&1)" || rc=$?
check "check fails closed when lsof fails" 2 "$rc" "$out" "cannot tell"
rc=0
out="$(run_stubbed "" 0 check "$occupied" "session-delta" 2>&1)" || rc=$?
check "check fails closed when lsof lists nothing" 2 "$rc" "$out" "cannot tell"
rc=0
out="$(run_stubbed "$idle_out" 1 acquire "$occupied" "session-delta" 2>&1)" || rc=$?
check "acquire fails closed when lsof fails" 2 "$rc" "$out" "cannot tell"
check "failed acquire writes no marker" 1 "$([ -e "$occupied/.claude-worktree-owner" ] && echo 0 || echo 1)"

rc=0
out="$(run_stubbed "$idle_out" 0 acquire "$occupied" "session-delta" 2>&1)" || rc=$?
check "acquire an idle unmarked tree" 0 "$rc" "$out" "acquired"
# Once marked, the marker decides exactly as before: the owner renews whatever lsof reports.
rc=0
out="$(run_stubbed "${idle_out}p999999\nn${occupied_real}\n" 0 acquire "$occupied" "session-delta" 2>&1)" || rc=$?
check "a marked tree keeps its marker semantics" 0 "$rc" "$out" "renewed"

# `add` creates the tree itself, so nothing can be inside it yet and lsof is never consulted.
rc=0
out="$(run_stubbed "" 1 add "$repo" "$tmp/wt-fresh" "claim-branch-fresh" "session-fresh" 2>&1)" || rc=$?
check "add does not depend on lsof" 0 "$rc" "$out" "owner=session-fresh"

# Real lsof: a process working in an unmarked tree blocks the claim, and its exit frees it.
if command -v lsof >/dev/null 2>&1; then
  live="$tmp/live-wt"
  git -C "$repo" worktree add -q -b "claim-branch-live" "$live"
  live_real="$(cd "$live" && pwd -P)"
  (cd "$live" && exec sleep 60) &
  occupant=$!
  # Wait for the background process to be inside the tree, or the arm races its own fixture.
  for _ in $(seq 1 50); do
    seen="$(lsof -a -p "$occupant" -d cwd -F n 2>/dev/null || true)"
    grep -qxF "n$live_real" <<<"$seen" && break
    sleep 0.1
  done
  rc=0
  out="$("$script" check "$live" "session-epsilon" 2>&1)" || rc=$?
  check "real lsof sees a process in an unmarked tree" 3 "$rc" "$out" "pid=$occupant"
  kill "$occupant" 2>/dev/null || true
  wait "$occupant" 2>/dev/null || true
  rc=0
  out="$("$script" check "$live" "session-epsilon" 2>&1)" || rc=$?
  check "real lsof frees the tree once the process exits" 0 "$rc" "$out" "free"
else
  printf 'FAIL real lsof arm: lsof is not installed\n' >&2
  fail=$((fail + 1))
fi

# ── usage error ────────────────────────────────────────────────────────────
rc=0
out="$("$script" 2>&1)" || rc=$?
check "usage no args" 1 "$rc"

# ── caller contract requires a per-run unique renewal token ────────────────────────
contract_rc=0
grep -qF 'unique to one runtime invocation' "$root_contract" || contract_rc=1
grep -qF 'unique to one runtime invocation' "$maintenance_contract" || contract_rc=1
check "contracts require a per-run unique owner token" 0 "$contract_rc"

# ── the claim and cleanup commands must share one mutex protocol ──────────────────
shared_rc=0
[ -f "$shared_lib" ] || shared_rc=1
grep -qF 'worktree-claim-lib.sh' "$script" || shared_rc=1
grep -qF 'worktree-claim-lib.sh' "$cleanup_script" || shared_rc=1
grep -qF 'WORKTREE_CLAIM_LOCK_REF_PREFIX' "$shared_lib" 2>/dev/null || shared_rc=1
grep -qF 'worktree_claim_lock_acquire()' "$shared_lib" 2>/dev/null || shared_rc=1
check "claim and cleanup source one mutex protocol" 0 "$shared_rc"

claim_filter=$(awk '
  /^            worktree-claim:/ { inside=1; next }
  inside && /^            [a-zA-Z0-9_-]+:/ { exit }
  inside { print }
' "$workflow_contract")
filter_rc=0
grep -qF ".claude/scripts/worktree-cleanup.sh" <<< "$claim_filter" || filter_rc=1
check "claim contract runs when cleanup consumer changes" 0 "$filter_rc"

# ── caller contracts fail closed on every acquisition error ─────────────────────
fail_closed_rc=0
grep -qiF 'only exit 0 authorizes' "$root_contract" || fail_closed_rc=1
grep -qiF 'only exit 0 authorizes' "$maintenance_contract" || fail_closed_rc=1
grep -qF 'every non-zero status' "$root_contract" || fail_closed_rc=1
grep -qF 'every non-zero status' "$maintenance_contract" || fail_closed_rc=1
check "contracts fail closed on every acquisition error" 0 "$fail_closed_rc"

# ── stale-base warning (the pinned-gitlink trap) ───────────────────────────────
# A submodule worktree is created at the pinned gitlink, not at the remote default branch. git is
# silent about the gap, so a tree tens of commits behind reads exactly like a current one. Both arms
# below are required: the control is what proves the warning is discriminating rather than
# unconditional, since a script that always warned would pass the positive arm alone.
origin_repo="$tmp/origin.git"
git init -q --bare -b main "$origin_repo"

seed="$tmp/seed"
git init -q -b main "$seed"
git -C "$seed" config user.name "worktree-claim-test"
git -C "$seed" config user.email "worktree-claim-test@example.com"
git -C "$seed" commit --allow-empty -qm "base"
git -C "$seed" remote add origin "$origin_repo"
git -C "$seed" push -q origin main

consumer="$tmp/consumer"
git clone -q "$origin_repo" "$consumer"
git -C "$consumer" config user.name "worktree-claim-test"
git -C "$consumer" config user.email "worktree-claim-test@example.com"

# Upstream advances by exactly two commits; the consumer stays pinned at base.
git -C "$seed" commit --allow-empty -qm "ahead-1"
git -C "$seed" commit --allow-empty -qm "ahead-2"
git -C "$seed" push -q origin main

# `|| rc=$?`, not a bare assignment: under `set -Eeuo pipefail` a non-zero command substitution
# terminates the suite on the assignment itself, so a regression here would abort before the arm
# below could report it — no FAIL line, no summary, just a bare shell exit. The guard keeps the
# regression a reported failure. Same shape as the malformed-count arm at lines 429-431.
stale_rc=0
stale_out="$("$script" add "$consumer" "$tmp/wt-stale" "claim-stale" "session-stale" 2>&1)" || stale_rc=$?
check "stale base still claims successfully (advisory, not fatal)" 0 "$stale_rc" \
  "$stale_out" "owner=session-stale"
check "stale base warns" 0 "$stale_rc" "$stale_out" "WARNING base is 2 commit(s) behind"
# The hint must not name refs/remotes/origin/*: nothing in the claim updates it, so it is absent on a
# moved default and frozen under a narrowed refspec. It names the fetch that was actually measured.
check "stale-base warning names the rebase fix" 0 "$stale_rc" "$stale_out" "rebase FETCH_HEAD"
stale_hint_rc=0
grep -qF -- "rebase 'origin/main'" <<<"$stale_out" && stale_hint_rc=1
check "stale-base hint does NOT send the user to the tracking ref" 0 "$stale_hint_rc"

# Control: same script, same repo, base now current — the warning MUST disappear. If this arm also
# warned, the positive arm above would prove nothing about staleness detection.
git -C "$consumer" fetch -q origin main
git -C "$consumer" reset -q --hard origin/main
current_rc=0
current_out="$("$script" add "$consumer" "$tmp/wt-current" "claim-current" "session-current" 2>&1)" || current_rc=$?
check "current base still claims successfully" 0 "$current_rc" "$current_out" "owner=session-current"
current_warn_rc=0
grep -qF -- "WARNING base is" <<<"$current_out" && current_warn_rc=1
check "current base does NOT warn (control)" 0 "$current_warn_rc"

# The remote's default branch MOVED after the clone. refs/remotes/origin/HEAD is written once, at
# clone time, and no fetch refreshes it — so a check that trusts it keeps comparing against the old
# default and reports "not behind" while the tree is arbitrarily stale against the real one. That is
# the silent-wrong-answer case, strictly worse than the UNKNOWN below, because it looks like a pass.
moved_origin="$tmp/moved-origin.git"
git init -q --bare -b main "$moved_origin"
moved_seed="$tmp/moved-seed"
git init -q -b main "$moved_seed"
git -C "$moved_seed" config user.name "worktree-claim-test"
git -C "$moved_seed" config user.email "worktree-claim-test@example.com"
git -C "$moved_seed" commit --allow-empty -qm "base"
git -C "$moved_seed" remote add origin "$moved_origin"
git -C "$moved_seed" push -q origin main

moved_consumer="$tmp/moved-consumer"
git clone -q "$moved_origin" "$moved_consumer"
git -C "$moved_consumer" config user.name "worktree-claim-test"
git -C "$moved_consumer" config user.email "worktree-claim-test@example.com"

# Default moves main → trunk, and trunk advances by two commits. The consumer's origin/HEAD still
# names main, and main itself never moves — so comparing against the stale pointer yields behind=0.
git -C "$moved_seed" checkout -q -b trunk
git -C "$moved_seed" commit --allow-empty -qm "trunk-ahead-1"
git -C "$moved_seed" commit --allow-empty -qm "trunk-ahead-2"
git -C "$moved_seed" push -q origin trunk
git -C "$moved_origin" symbolic-ref HEAD refs/heads/trunk

moved_stale="$(git -C "$moved_consumer" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "")"
check "clone-time origin/HEAD still names the OLD default (precondition)" "origin/main" "$moved_stale"

moved_rc=0
moved_out="$("$script" add "$moved_consumer" "$tmp/wt-moved" "claim-moved" "session-moved" 2>&1)" || moved_rc=$?
check "moved default still claims successfully" 0 "$moved_rc" "$moved_out" "owner=session-moved"
check "moved default is measured against the CURRENT remote default" 0 "$moved_rc" \
  "$moved_out" "WARNING base is 2 commit(s) behind origin/trunk"

# A moved default does NOT break the old tracking-ref hint, and asserting that it did would pin a
# claim this suite can disprove: `git fetch origin +refs/heads/trunk:<private>` also applies the
# repository's CONFIGURED refspec, so an ordinary consumer gains origin/trunk as a side effect of the
# claim itself. Pinned as a precondition so the narrowed-refspec arms below are not later "tidied up"
# into covering this case too.
moved_tracking_ref="$(git -C "$moved_consumer" rev-parse --verify --quiet origin/trunk >/dev/null 2>&1 && echo present || echo absent)"
check "a moved default leaves the tracking ref PRESENT, so it is not the broken-hint case" \
  "present" "$moved_tracking_ref"

# The configured fetch refspec does not map the default branch into refs/remotes/origin/*. `git fetch
# origin main` still SUCCEEDS and still retrieves the new tip — but it lands in FETCH_HEAD only,
# because the command-line refspec controls what is fetched while the CONFIGURED mapping controls
# which remote-tracking refs get updated. So a pre-existing origin/main stays frozen at its old value,
# rev-parse resolves it happily, and the comparison is made against a ref that no longer tracks
# anything. Same silent false-current as the moved-default case above, reached one layer down: every
# guard in this function fires correctly and the ANSWER is still wrong, because the ref being compared
# is not the tip that was just fetched.
narrowed_origin="$tmp/narrowed-origin.git"
git init -q --bare -b main "$narrowed_origin"
narrowed_seed="$tmp/narrowed-seed"
git init -q -b main "$narrowed_seed"
git -C "$narrowed_seed" config user.name "worktree-claim-test"
git -C "$narrowed_seed" config user.email "worktree-claim-test@example.com"
git -C "$narrowed_seed" commit --allow-empty -qm "base"
git -C "$narrowed_seed" remote add origin "$narrowed_origin"
git -C "$narrowed_seed" push -q origin main

narrowed_consumer="$tmp/narrowed-consumer"
git clone -q "$narrowed_origin" "$narrowed_consumer"
git -C "$narrowed_consumer" config user.name "worktree-claim-test"
git -C "$narrowed_consumer" config user.email "worktree-claim-test@example.com"
# Narrow the mapping so main is no longer covered. origin/main SURVIVES at the clone-time value,
# which is what makes this the silent case rather than the UNKNOWN one.
git -C "$narrowed_consumer" config remote.origin.fetch "+refs/heads/release/*:refs/remotes/origin/release/*"

git -C "$narrowed_seed" commit --allow-empty -qm "ahead-1"
git -C "$narrowed_seed" commit --allow-empty -qm "ahead-2"
git -C "$narrowed_seed" commit --allow-empty -qm "ahead-3"
git -C "$narrowed_seed" push -q origin main

narrowed_pre="$(git -C "$narrowed_consumer" rev-parse origin/main)"
narrowed_tip="$(git -C "$narrowed_seed" rev-parse main)"
check "origin/main is present but STALE before the claim (precondition)" 0 \
  "$([ "$narrowed_pre" != "$narrowed_tip" ] && echo 0 || echo 1)"

narrowed_rc=0
narrowed_out="$("$script" add "$narrowed_consumer" "$tmp/wt-narrowed" "claim-narrowed" "session-narrowed" 2>&1)" || narrowed_rc=$?
check "narrowed refspec still claims successfully" 0 "$narrowed_rc" "$narrowed_out" "owner=session-narrowed"
# The whole point: three commits behind must be REPORTED, not swallowed by a tracking ref the fetch
# never updated. A silent pass here is the exact failure this function exists to remove.
check "narrowed refspec is measured against the tip actually FETCHED" 0 "$narrowed_rc" \
  "$narrowed_out" "WARNING base is 3 commit(s) behind"
narrowed_silent_rc=0
grep -qF -- "WARNING base is" <<<"$narrowed_out" || narrowed_silent_rc=1
check "narrowed refspec never reports a silent 'current' base" 0 "$narrowed_silent_rc"

# The arms below execute the two commands literally, so this pins that the script actually EMITS
# them — without it the execution arms would keep passing even if the hint reverted, and they would
# be proving git's behaviour rather than this script's advice. Both halves are asserted: the rebase
# target alone would leave the fetch, which is what makes FETCH_HEAD correct, unpinned.
check "the emitted hint names the fetch that makes FETCH_HEAD correct" 0 "$narrowed_rc" \
  "$narrowed_out" "fetch origin 'main' &&"
check "the emitted hint rebases onto FETCH_HEAD" 0 "$narrowed_rc" "$narrowed_out" "rebase FETCH_HEAD"

# A hint is only advice if it RUNS, so both forms are EXECUTED here rather than pattern-matched.
# This is the fixture where they differ: the claim's fetch does not update origin/main (the
# configured mapping does not cover it), so the tracking ref is frozen while the tree is 3 behind.
#
# NEGATIVE CONTROL, and it carries the whole argument: the OLD hint does not fail loudly here — it
# SUCCEEDS, says "up to date", and leaves the tree exactly as stale as the warning just reported.
# That is the silent false-current this function exists to remove, reappearing inside its remedy.
narrowed_old_hint_rc=0
git -C "$tmp/wt-narrowed" rebase 'origin/main' >/dev/null 2>&1 || narrowed_old_hint_rc=$?
check "the tracking-ref hint SUCCEEDS while changing nothing (negative control)" 0 "$narrowed_old_hint_rc"
narrowed_behind_after_old="$(git -C "$tmp/wt-narrowed" rev-list --count "HEAD..$narrowed_tip" 2>/dev/null)"
check "the tracking-ref hint leaves the tree just as stale" 3 "$narrowed_behind_after_old"

# The emitted hint, run exactly as written. It must close the gap the warning reported.
narrowed_new_hint_rc=0
{ git -C "$tmp/wt-narrowed" fetch origin main >/dev/null 2>&1 &&
  git -C "$tmp/wt-narrowed" rebase FETCH_HEAD >/dev/null 2>&1; } || narrowed_new_hint_rc=$?
check "the emitted hint RUNS under a narrowed refspec" 0 "$narrowed_new_hint_rc"
narrowed_behind_after_new="$(git -C "$tmp/wt-narrowed" rev-list --count "HEAD..$narrowed_tip" 2>/dev/null)"
check "the emitted hint actually closes the gap it reported" 0 "$narrowed_behind_after_new"

# Unresolvable remote: the comparison cannot be made, and the required outcome is an explicit UNKNOWN
# rather than silence — silence is indistinguishable from "base is current", the confusion this whole
# check exists to remove. Repointing origin at an absent bare repository is hermetic: ls-remote and
# fetch both fail locally, no network is touched. Claiming must still succeed (advisory, never fatal).
git -C "$consumer" remote set-url origin "$tmp/absent-origin.git"
unknown_rc=0
unknown_out="$("$script" add "$consumer" "$tmp/wt-unknown" "claim-unknown" "session-unknown" 2>&1)" || unknown_rc=$?
check "unavailable remote still claims successfully" 0 "$unknown_rc" \
  "$unknown_out" "owner=session-unknown"
check "unavailable remote writes the ownership marker" 0 \
  "$([ -e "$tmp/wt-unknown/.claude-worktree-owner" ] && echo 0 || echo 1)"
check "unavailable remote reports base freshness UNKNOWN" 0 "$unknown_rc" \
  "$unknown_out" "base freshness UNKNOWN"
git -C "$consumer" remote set-url origin "$origin_repo"

# The numeric guard must be present: an unnormalised count would make the -gt test fail OPEN inside
# an if, silently skipping the warning on exactly the malformed input it should be loudest about.
#
# ⚠️ This arm is a SOURCE-COUPLED guard, not a behavioural one — reaching the malformed-count path
# needs `git rev-list --count` to emit a non-integer, which cannot be provoked hermetically. It is
# therefore matched on the two semantic tokens rather than a whole literal line: an exact-line match
# breaks on a harmless reformat and passes on the same text sitting in a comment, which fails in both
# directions. Replace this with a behavioural arm if the count ever moves behind an injectable seam.
normalise_rc=0
normalise_src="$(sed -n '/^warn_if_base_is_stale()/,/^}/p' "$script")"
# Comment lines are stripped first. The function DOCUMENTS the numeric test verbatim ("would make
# `[ "$behind" -gt 0 ]` fail OPEN…"), so matching the raw text finds the prose two lines above the
# code and reports the order backwards — the same match-a-comment defect this arm exists to catch.
normalise_code="$(grep -vE '^[[:space:]]*#' <<<"$normalise_src")"
grep -qF -- '[!0-9]' <<<"$normalise_code" || normalise_rc=1
# Presence alone is not the property. Both tokens would still be found if a later edit moved the
# normalisation BELOW the numeric test, which reinstates the fail-open path this arm guards. So
# compare their positions: the normalisation must precede the comparison that depends on it.
# awk with `exit` (not `grep -n | head`) — the pipe would EPIPE the writer under pipefail, exactly
# the flake fixed in check() above. index() keeps both needles literal.
# The malformed case must take the UNKNOWN path, not fold to `behind=0`: normalising to 0 also
# stopped the fail-open, but rendered an unestablished comparison identically to a current base.
# So the anchor is the `[!0-9]` case itself, and the arm below additionally requires that the
# diagnostic — not a silent assignment — is what follows it.
norm_line="$(awk 'index($0,"[!0-9]"){print NR; exit}' <<<"$normalise_code")"
test_line="$(awk 'index($0,"\"$behind\" -gt 0"){print NR; exit}' <<<"$normalise_code")"
# ...and the malformed branch must EMIT the UNKNOWN notice rather than silently choosing a value.
# `if`, not `cmd && assign`: under `set -e` a non-final `&&` operand that fails makes the LIST's
# status non-zero, which is the fail-open/abort ambiguity this file keeps pinning elsewhere.
malformed_branch="$(awk -v n="$norm_line" \
  'NR>n && NR<=n+3 && index($0,"base_freshness_unknown")' <<<"$normalise_code")"
if [ -z "$malformed_branch" ]; then normalise_rc=1; fi
# And the retired normalisation must be gone, or both spellings could coexist with the silent one winning.
if grep -qF -- 'behind=0' <<<"$normalise_code"; then normalise_rc=1; fi
# Guard both operands before the numeric comparison: `[ "" -lt 3 ]` errors rather than returning
# false, and an unguarded `&&` chain would swallow that as "arm satisfied" — the same fail-open
# shape this test exists to pin.
case "$norm_line" in '' | *[!0-9]*) norm_line=0 ;; esac
case "$test_line" in '' | *[!0-9]*) test_line=0 ;; esac
[ "$norm_line" -gt 0 ] && [ "$test_line" -gt 0 ] && [ "$norm_line" -lt "$test_line" ] || normalise_rc=1
check "behind-count is normalised BEFORE the numeric test" 0 "$normalise_rc"

# ...and the same property BEHAVIOURALLY, which is what the arm above says it cannot be. It can:
# `git` is resolved from PATH, so a stub forwarding every other subcommand to the real binary and
# returning a non-integer on `rev-list --count` is the injectable seam the comment asked for. Worth
# both arms — the source-coupled one pins that the retired `behind=0` spelling is gone, this one
# pins the OUTPUT, so a reformat cannot break it and a matching comment cannot satisfy it.
stub_dir="$tmp/stub-bin"
mkdir -p "$stub_dir"
real_git="$(command -v git)"
cat >"$stub_dir/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "rev-list" ]; then
    for inner in "\$@"; do
      [ "\$inner" = "--count" ] && { printf 'fatal: not a valid object name\n'; exit 0; }
    done
  fi
done
exec "$real_git" "\$@"
STUB
chmod +x "$stub_dir/git"
malformed_consumer="$tmp/malformed-consumer"
git clone -q "$origin_repo" "$malformed_consumer"
malformed_rc=0
malformed_out="$(PATH="$stub_dir:$PATH" "$script" add \
  "$malformed_consumer" "$tmp/wt-malformed" "claim-malformed" "session-malformed" 2>&1)" || malformed_rc=$?
check "a malformed behind-count still claims successfully (advisory, not fatal)" 0 "$malformed_rc" \
  "$malformed_out" "owner=session-malformed"
check "a malformed behind-count reports UNKNOWN rather than a silent 'current'" 0 "$malformed_rc" \
  "$malformed_out" "base freshness UNKNOWN"
# The NEGATIVE half. It must not emit a behind-count WARNING at all: the count is unusable, so the
# only honest outputs are the UNKNOWN notice (asserted above) and silence about a distance. Matched on
# the `WARNING base is` PREFIX, not on `WARNING base is 0 commit(s)` -- the retired `behind=0` folding
# never printed that string either (0 is not > 0, so it warned about nothing), which made the old
# assertion unfireable. The prefix form does fire, on a garbage count rendered into the message.
malformed_quiet_rc=0
grep -qF -- "WARNING base is" <<<"$malformed_out" && malformed_quiet_rc=1
check "a malformed behind-count never renders a distance" 0 "$malformed_quiet_rc"

# A FAILED rev-list must report UNKNOWN, not fold into behind=0 — otherwise an unavailable comparison
# renders identically to a current base, the exact silence this whole check removes.
#
# ⚠️ SOURCE-COUPLED for the same reason as the arm above: `warn_if_base_is_stale` runs immediately
# after a successful `git worktree add`, so a failing `rev-list` in that window cannot be provoked
# hermetically. Asserted on structure — the assignment is guarded by `if !`, and the guard body calls
# base_freshness_unknown — with comments stripped so prose cannot satisfy it. Replace with a
# behavioural arm if the count ever moves behind an injectable seam.
revfail_rc=0
revlist_line="$(awk 'index($0,"rev-list --count"){print NR; exit}' <<<"$normalise_code")"
case "$revlist_line" in '' | *[!0-9]*) revlist_line=0 ;; esac
[ "$revlist_line" -gt 0 ] &&
  grep -qF -- 'if ! behind="$(git -C "$wt" rev-list --count' <<<"$normalise_code" || revfail_rc=1
# The guard body must actually emit the notice, not merely return. Captured output + an emptiness
# test, NOT `awk | grep -q`: `grep -q` exits at the first match, the awk writer can then die of
# EPIPE, and under `pipefail` the pipeline reports failure for a needle it actually found — the
# size-dependent flake `check()` documents at lines 26-28. Same shape as lines 394-396.
revfail_branch="$(awk -v n="$revlist_line" \
  'NR>n && NR<=n+2 && index($0,"base_freshness_unknown")' <<<"$normalise_code")"
if [ -z "$revfail_branch" ]; then revfail_rc=1; fi
check "a FAILED rev-list reports UNKNOWN rather than behind=0" 0 "$revfail_rc"

# A remote that never answers must not hold the claim open. `ext::` runs an arbitrary command as the
# transport, so this hangs git deterministically with no network and no unreachable-address guesswork.
# The bound is asserted by WALL CLOCK: a run that merely "succeeds" would also succeed if the timer
# never fired and git sat there for the full sleep, so elapsed time is the only thing that separates
# a working bound from an absent one.
#
# `protocol.ext.allow` is REQUIRED and is not decoration: it defaults to `never`, so without it git
# rejects the transport in 0s with "transport 'ext' not allowed" and the fixture exercises the
# fast-FAILURE path instead of the hang. That version of this test passed with the bound removed —
# it was vacuous, and only the ablation exposed it.
hang_consumer="$tmp/hang-consumer"
git clone -q "$origin_repo" "$hang_consumer"
git -C "$hang_consumer" remote set-url origin "ext::sleep 60"
git -C "$hang_consumer" config protocol.ext.allow always
hang_start="$(date +%s)"
hang_rc=0
hang_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=3 "$script" add \
  "$hang_consumer" "$tmp/wt-hang" "claim-hang" "session-hang" 2>&1)" || hang_rc=$?
hang_elapsed=$(($(date +%s) - hang_start))
check "an unresponsive remote still claims successfully (advisory, not fatal)" 0 "$hang_rc" \
  "$hang_out" "owner=session-hang"
# Two calls are bounded, so allow both plus slack -- but far below the 60s the transport would take.
hang_bounded_rc=0
[ "$hang_elapsed" -lt 30 ] || hang_bounded_rc=1
check "an unresponsive remote is abandoned at the bound, not waited out" 0 "$hang_bounded_rc"
hang_unknown_rc=0
grep -qF -- "base freshness UNKNOWN" <<<"$hang_out" || hang_unknown_rc=1
check "an unresponsive remote reports UNKNOWN rather than silence" 0 "$hang_unknown_rc"

# shquote must survive a TERMINAL NEWLINE. `$(…)` strips trailing newlines, so the previous
# command-substitution form emitted a rebase hint naming a DIFFERENT path than the one it operated
# on — and that hint is written to be pasted and run.
# The SHIPPED function is extracted and evaluated, not reimplemented here: a local copy would only
# prove that the copy works, which is the vacuous shape this file guards against elsewhere.
shquote_rc=0
shquote_fn="$(sed -n '/^shquote()/,/^}/p' "$script")"
# `printf %s` then measure: capturing with $() here would strip the very newline under test.
shquote_len="$(bash -c 'eval "$1"; out="$(shquote "$2"; printf X)"; out=${out%X}; printf %s "${#out}"' \
  _ "$shquote_fn" $'wt\n')"
# "'" + w + t + newline + "'" = 5 characters. A stripped newline yields 4.
[ "$shquote_len" = "5" ] || shquote_rc=1
check "shipped shquote preserves a terminal newline" 0 "$shquote_rc"
# Source-coupled arm: the shipped shquote must not use command substitution at all, which is the
# only way the strip can reappear.
shquote_src="$(sed -n '/^shquote()/,/^}/p' "$script" | grep -vE '^[[:space:]]*#')"
shquote_impl_rc=0
if grep -qF -- '$(' <<<"$shquote_src"; then shquote_impl_rc=1; fi
check "shquote uses no command substitution (cannot strip a trailing newline)" 0 "$shquote_impl_rc"
# The POSITIVE half, and it is not decoration: both arms above would still pass if the newline fix
# had broken quote escaping outright, since neither input contains a quote. Escaping IS the job this
# helper exists to do, so it needs an arm of its own — compared byte-exactly against the expected
# `'it'\''s'`, because a length check cannot tell a correct escape from a differently-wrong one.
shquote_esc_rc=0
bash -c 'eval "$1"; shquote "$2" >"$3"' _ "$shquote_fn" "it's" "$tmp/shq.esc"
printf "%s" "'it'\\''s'" >"$tmp/shq.esc.expected"
cmp -s "$tmp/shq.esc" "$tmp/shq.esc.expected" || shquote_esc_rc=1
check "shquote still escapes an embedded single quote" 0 "$shquote_esc_rc"

# `add` must CLAIM before it runs the advisory freshness check. That check makes up to two bounded
# remote calls, so running it first leaves the new tree unclaimed for both timeouts — long enough for
# a concurrent run to take the marker, which would leave this invocation exiting 3 on a worktree and
# branch it just created. Asserted on OUTPUT ORDER against the unresponsive-remote fixture, which is
# the case where the window is widest: the acquire line must precede the freshness NOTE.
#
# The transport is a script under this run's own `mktemp -d`, NOT a bare `sleep`: the orphan check
# below greps the process table, and a bare `sleep 97` matches a leftover from any earlier run of
# this suite — which made the assertion fail on a tree that was actually correct. The temp path is
# unique per run, so the grep can only ever match this run's descendants.
#
# NO `exec`, for the same reason spelled out for `ignore_transport` below — but the failure it
# prevents here is narrower than "the arm never fires", and the difference was measured rather than
# assumed. `exec sleep 97` replaces the process image, so the transport's own argv becomes "sleep 97"
# and this run's unique path is gone from it. The arm still went red, because `git remote-ext origin
# <path>` carries the path as an ARGUMENT and is itself orphaned by the same regression — so what the
# assertion actually observed was the git helper, a PROXY, never the transport the comment names.
# Ablating group signalling to pid-only signalling made that concrete: with `exec` a bare `sleep 97`
# was left running and `pgrep -f "$slow_transport"` could not see it (1 leaked, 0 of them matched);
# without `exec` the transport is matched directly (2 matches, 0 leaked). A regression that reaped
# the helper but not the transport — exactly the TERM-ignoring case the next arm covers — would
# therefore have read clean here. Looping over short sleeps keeps the script itself resident, so the
# arm observes the process it claims to.
slow_transport="$tmp/slow-transport"
printf '#!/usr/bin/env bash\nfor _ in $(seq 97); do sleep 1; done\n' >"$slow_transport"
chmod +x "$slow_transport"
order_consumer="$tmp/order-consumer"
git clone -q "$origin_repo" "$order_consumer"
git -C "$order_consumer" remote set-url origin "ext::$slow_transport"
git -C "$order_consumer" config protocol.ext.allow always
order_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=2 "$script" add \
  "$order_consumer" "$tmp/wt-order" "claim-order" "session-order" 2>&1)" || true
acquire_at="$(awk '/owner=session-order/{print NR; exit}' <<<"$order_out")"
note_at="$(awk '/base freshness UNKNOWN/{print NR; exit}' <<<"$order_out")"
case "$acquire_at" in '' | *[!0-9]*) acquire_at=0 ;; esac
case "$note_at" in '' | *[!0-9]*) note_at=0 ;; esac
order_rc=0
[ "$acquire_at" -gt 0 ] && [ "$note_at" -gt 0 ] && [ "$acquire_at" -lt "$note_at" ] || order_rc=1
check "add claims the worktree BEFORE the advisory remote check" 0 "$order_rc"

# A timed-out git must not leave its TRANSPORT child running. git delegates to a helper process, and
# killing only the git pid leaves that helper reparented, running to its own native timeout — twice
# per `add`, so an unresponsive remote accumulates them. Matched on this run's unique transport path.
sleep 1
orphan_rc=0
if pgrep -f "$slow_transport" >/dev/null 2>&1; then orphan_rc=1; fi
check "a timed-out remote leaves no orphaned transport process" 0 "$orphan_rc"
# Mirror the `ignore_transport` cleanup below: if the arm above just FAILED there is a live process
# holding this run's temp dir, and the EXIT trap's `rm -rf` would otherwise race it.
pkill -KILL -f "$slow_transport" >/dev/null 2>&1 || true

# SIGTERM is a REQUEST -- catchable and ignorable -- so the timer's TERM does not stop a transport
# that ignores it. The WAITED-ON process is `git`, which honours TERM and dies, so `add` still
# returns at the bound; what survives is the transport helper, reparented and running to its own
# native timeout. `add` reports success while leaving a process behind, twice per call. SIGKILL
# cannot be trapped, so escalating to it after a grace period is what actually reaps the tree.
#
# Fixture shape is load-bearing in two ways, both learned by ablation:
#   * NO `exec`. `exec sleep 97` replaces the process image, so its argv becomes "sleep 97" and
#     `pgrep -f "$ignore_transport"` can never match -- the assertion would pass on a broken tree.
#     Looping over short sleeps keeps the script itself resident, so its path stays greppable.
#   * The loop is what makes ignoring TERM observable: the group TERM kills the current `sleep 1`
#     child, but the script traps nothing and continues, which is exactly the surviving helper.
# Elapsed time is deliberately NOT asserted here: `git` dies on TERM either way, so a wall-clock
# assertion passes in both arms and would only look like proof.
ignore_transport="$tmp/ignore-term-transport"
printf '#!/usr/bin/env bash\ntrap "" TERM\nfor _ in $(seq 97); do sleep 1; done\n' >"$ignore_transport"
chmod +x "$ignore_transport"
ignore_consumer="$tmp/ignore-consumer"
git clone -q "$origin_repo" "$ignore_consumer"
git -C "$ignore_consumer" remote set-url origin "ext::$ignore_transport"
git -C "$ignore_consumer" config protocol.ext.allow always
ignore_rc=0
ignore_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=2 "$script" add \
  "$ignore_consumer" "$tmp/wt-ignore" "claim-ignore" "session-ignore" 2>&1)" || ignore_rc=$?
sleep 2
# An absence assertion alone is vacuous: if a regression made `add` fail BEFORE bounded_remote ever
# ran, no transport would be spawned and the arm below would report success on a broken tree. So
# establish first that the bounded call actually happened — this transport swallows TERM, so the
# remote is abandoned and the freshness verdict degrades to UNKNOWN, which is the observable proof
# that the timeout path executed rather than being skipped.
check "the SIGTERM-ignoring transport was actually reached (guards the arm below)" 0 "$ignore_rc" \
  "$ignore_out" "base freshness UNKNOWN"
ignore_orphan_rc=0
if pgrep -f "$ignore_transport" >/dev/null 2>&1; then ignore_orphan_rc=1; fi
check "a SIGTERM-IGNORING transport is SIGKILLed, not left orphaned" 0 "$ignore_orphan_rc"
pkill -KILL -f "$ignore_transport" >/dev/null 2>&1 || true

# The TIMER must not outlive the call it bounds. The killer subshell sleeps in a separate child
# process, so signalling the subshell's pid alone leaves that `sleep` running to its full duration --
# on the FAST path, where the remote answers immediately, every `add` leaked one or two of them.
# Bounding both is the same tree-kill problem as the transport, one level up.
#
# The timeout value is deliberately absurd and unique: a real leak is then unmistakable in the
# process table, and the assertion cannot collide with an unrelated `sleep` from this suite, another
# suite, or a developer's shell. A round number like 60 would match half the machine.
timer_consumer="$tmp/timer-consumer"
git clone -q "$origin_repo" "$timer_consumer"
timer_rc=0
timer_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=9871 "$script" add \
  "$timer_consumer" "$tmp/wt-timer" "claim-timer" "session-timer" 2>&1)" || timer_rc=$?
sleep 1
# Same vacuity guard as the transport arm above: an `add` that failed before arming the timer would
# leave no `sleep 9871` and the leak assertion would pass for the wrong reason. A successful claim is
# the marker that the fast path — the one that used to leak a timer per call — actually ran.
check "the fast path was actually reached (guards the arm below)" 0 "$timer_rc" \
  "$timer_out" "owner=session-timer"
timer_leak_rc=0
if pgrep -f 'sleep 9871' >/dev/null 2>&1; then timer_leak_rc=1; fi
check "a fast remote leaves no timer process behind" 0 "$timer_leak_rc"
pkill -KILL -f 'sleep 9871' >/dev/null 2>&1 || true

# The bound is read from the environment and handed straight to `sleep`, so a malformed value makes
# that `sleep` fail instantly and collapses the bound to roughly zero: the remote is abandoned before
# it can answer, and a REACHABLE remote is then reported UNKNOWN for a reason nothing states. The
# guard rejects the value, says so, and falls back to the default.
#
# Asserted on the NOTICE rather than on elapsed time, deliberately. Both the guarded and unguarded
# arms finish quickly here -- the unguarded one because the bound collapsed, the guarded one because
# the fixture answers immediately -- so a wall-clock assertion would pass either way and prove
# nothing. The distinguishing observable is that the rejection is reported.
badtimeout_consumer="$tmp/badtimeout-consumer"
git clone -q "$origin_repo" "$badtimeout_consumer"
badtimeout_rc=0
badtimeout_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=invalid "$script" add \
  "$badtimeout_consumer" "$tmp/wt-badtimeout" "claim-badtimeout" "session-badtimeout" 2>&1)" || badtimeout_rc=$?
check "a non-integer timeout is rejected and reported" 0 "$badtimeout_rc" \
  "$badtimeout_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="
check "a rejected timeout still claims the worktree" 0 "$badtimeout_rc" \
  "$badtimeout_out" "owner=session-badtimeout"

# `0` parses as an integer but is not a bound -- it abandons every remote call immediately, which is
# the same invisible-UNKNOWN failure wearing a well-formed value.
zerotimeout_consumer="$tmp/zerotimeout-consumer"
git clone -q "$origin_repo" "$zerotimeout_consumer"
zerotimeout_rc=0
zerotimeout_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=0 "$script" add \
  "$zerotimeout_consumer" "$tmp/wt-zerotimeout" "claim-zerotimeout" "session-zerotimeout" 2>&1)" || zerotimeout_rc=$?
check "a zero timeout is rejected as not-a-bound" 0 "$zerotimeout_rc" \
  "$zerotimeout_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="

# Zero has more than one spelling. `00` and `000` are digit-only and are not the literal `0`, and
# `sleep` returns from each immediately -- so a guard written against the SPELLING `0` leaves exactly
# the same collapsed bound reachable. An earlier round of this PR did precisely that.
for zero_spelling in 00 000; do
  zs_consumer="$tmp/zs-$zero_spelling-consumer"
  git clone -q "$origin_repo" "$zs_consumer"
  zs_rc=0
  zs_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="$zero_spelling" "$script" add \
    "$zs_consumer" "$tmp/wt-zs-$zero_spelling" "claim-zs-$zero_spelling" "session-zs" 2>&1)" || zs_rc=$?
  check "an all-zero timeout spelling '$zero_spelling' is rejected" 0 "$zs_rc" \
    "$zs_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="
done

# POSITIVE CONTROL: `0001` has leading zeros but is a genuine 1-second bound and must NOT be
# rejected. Without this, a guard that simply refused any value containing a zero would satisfy every
# assertion above while quietly refusing legitimate configuration -- strict-looking and wrong.
leadzero_consumer="$tmp/leadzero-consumer"
git clone -q "$origin_repo" "$leadzero_consumer"
leadzero_add_rc=0
leadzero_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=0001 "$script" add \
  "$leadzero_consumer" "$tmp/wt-leadzero" "claim-leadzero" "session-leadzero" 2>&1)" || leadzero_add_rc=$?
check "a leading-zero timeout still claims successfully" 0 "$leadzero_add_rc" \
  "$leadzero_out" "owner=session-leadzero"
leadzero_rc=0
grep -qF "ignoring unusable" <<<"$leadzero_out" && leadzero_rc=1
check "a leading-zero but NON-zero timeout is accepted" 0 "$leadzero_rc"

# RANGE, not just spelling. `sleep` enforces the bound, and both ends defeat it: BSD sleep (the
# primary host) rejects a value at/above ~2^31 with a usage error and returns INSTANTLY, so the killer
# fires at once and TERMs a reachable remote -- the bound collapses to ~0 and every claim reports
# UNKNOWN; GNU sleep accepts the same value and waits ~317 years, i.e. no bound at all. `600000` is
# unbounded on both and is the plausible "someone meant milliseconds" value. Measured on this PR's own
# previous head: both were ACCEPTED.
for bad_range in 600000 10000000000; do
  br_consumer="$tmp/br-$bad_range-consumer"
  git clone -q "$origin_repo" "$br_consumer"
  br_rc=0
  br_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="$bad_range" "$script" add \
    "$br_consumer" "$tmp/wt-br-$bad_range" "claim-br-$bad_range" "session-br" 2>&1)" || br_rc=$?
  check "an out-of-range timeout '$bad_range' is rejected" 0 "$br_rc" \
    "$br_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="
done

# POSITIVE CONTROL for the range guard: the maximum must still be ACCEPTED, or a guard that simply
# refused anything long would satisfy both arms above while rejecting legitimate configuration.
maxtimeout_consumer="$tmp/maxtimeout-consumer"
git clone -q "$origin_repo" "$maxtimeout_consumer"
maxtimeout_rc=0
maxtimeout_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=3600 "$script" add \
  "$maxtimeout_consumer" "$tmp/wt-maxtimeout" "claim-maxtimeout" "session-maxtimeout" 2>&1)" || maxtimeout_rc=$?
maxtimeout_rejected=0
grep -qF "ignoring unusable" <<<"$maxtimeout_out" && maxtimeout_rejected=1
check "the maximum in-range timeout is accepted (control)" 0 "$maxtimeout_rejected"
check "the maximum in-range timeout still claims" 0 "$maxtimeout_rc" \
  "$maxtimeout_out" "owner=session-maxtimeout"

# ── a hostile remote default-branch name must never reach git as an OPTION ──────
# The name is REMOTE-supplied and fed to `git fetch`. Passed positionally, a name beginning with `-`
# is parsed as an option: a remote whose HEAD symrefs to refs/heads/--upload-pack=<cmd> made git RUN
# <cmd>. Reproduced against this PR's own previous head -- the sentinel file was created -- so this is
# a demonstrated arbitrary-command primitive on the creation path of every worktree, not a theory.
# Note the ref really does live under refs/heads/, so requiring that prefix does NOT close it; the
# name itself has to be rejected.
inj_origin="$tmp/inj-origin.git"
git init -q --bare -b main "$inj_origin"
git -C "$seed" push -q "$inj_origin" main
inj_pwn="$tmp/inj-pwn"
inj_sentinel="$tmp/inj-executed"
printf '#!/usr/bin/env bash\n: >"%s"\nexit 1\n' "$inj_sentinel" >"$inj_pwn"
chmod +x "$inj_pwn"
git -C "$inj_origin" update-ref "refs/heads/--upload-pack=$inj_pwn" refs/heads/main
git -C "$inj_origin" symbolic-ref HEAD "refs/heads/--upload-pack=$inj_pwn"
inj_consumer="$tmp/inj-consumer"
git clone -q "$origin_repo" "$inj_consumer"
git -C "$inj_consumer" remote set-url origin "$inj_origin"
inj_rc=0
inj_out="$("$script" add "$inj_consumer" "$tmp/wt-inj" "claim-inj" "session-inj" 2>&1)" || inj_rc=$?
check "a hostile default-branch name still claims (advisory, not fatal)" 0 "$inj_rc" \
  "$inj_out" "owner=session-inj"
check "a hostile default-branch name reports UNKNOWN" 0 "$inj_rc" \
  "$inj_out" "base freshness UNKNOWN"
# The arm that matters: the attacker-chosen command must not have run.
inj_exec_rc=0
[ -e "$inj_sentinel" ] && inj_exec_rc=1
check "a hostile default-branch name is NEVER executed" 0 "$inj_exec_rc"

# Remote-default DISCOVERY failure must report UNKNOWN, not fall back to the clone-time pointer.
# The fallback trusted `refs/remotes/origin/HEAD` — written once at clone time and never refreshed —
# which is the stale source this whole check exists to stop trusting: if the default moved, the old
# branch usually still fetches, so the comparison yields behind=0 and reports a CURRENT base for an
# arbitrarily stale tree. The git stub makes only the symref discovery fail, so the branch fetch
# still succeeds and the old fallback path would have been taken.
symref_stub="$tmp/symref-stub"
mkdir -p "$symref_stub"
cat >"$symref_stub/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = "--symref" ] && exit 0
done
exec "$real_git" "\$@"
STUB
chmod +x "$symref_stub/git"
symref_consumer="$tmp/symref-consumer"
git clone -q "$origin_repo" "$symref_consumer"
symref_rc=0
symref_out="$(PATH="$symref_stub:$PATH" "$script" add \
  "$symref_consumer" "$tmp/wt-symref" "claim-symref" "session-symref" 2>&1)" || symref_rc=$?
check "failed default discovery still claims successfully" 0 "$symref_rc" \
  "$symref_out" "owner=session-symref"
check "failed default discovery reports UNKNOWN, not a stale-pointer comparison" 0 "$symref_rc" \
  "$symref_out" "base freshness UNKNOWN"

# ── add attaches to a branch that already exists (monorepo#2776) ───────────────────
# Rung 1 of the work-selection ladder is "finish an open PR", and that branch exists before the
# worktree does. `add` hardcoded `-b`, so the mandated helper could only ever create a NEW branch:
# resuming an open PR fell out of the claim protocol entirely, because the one command that writes
# the ownership marker refused to run.
existing_repo="$tmp/existing-repo"
mkdir -p "$existing_repo"
git -C "$existing_repo" init -q -b main
git -C "$existing_repo" config user.name "worktree-claim-test"
git -C "$existing_repo" config user.email "worktree-claim-test@example.com"
git -C "$existing_repo" commit --allow-empty -qm "init"
git -C "$existing_repo" branch "claim-existing-local"
git -C "$existing_repo" commit --allow-empty -qm "main moves on"
existing_tip="$(git -C "$existing_repo" rev-parse "claim-existing-local")"

local_rc=0
local_out="$("$script" add \
  "$existing_repo" "$tmp/wt-existing-local" "claim-existing-local" "session-existing" 2>&1)" || local_rc=$?
check "add attaches to an existing local branch" 0 "$local_rc" "$local_out" "owner=session-existing"
check "existing-branch add writes the marker" 0 \
  "$([ -f "$tmp/wt-existing-local/.claude-worktree-owner" ] && echo 0 || echo 1)"
# The point of attaching is landing on THAT branch's commit. Creating a fresh branch from HEAD would
# also exit 0 and also write a marker, so the exit code alone cannot tell the two apart — assert the
# checked-out commit, which is the only thing that distinguishes a resumed PR from a silent fork.
check "existing-branch add lands on that branch's tip, not the repo HEAD" 0 0 \
  "$(git -C "$tmp/wt-existing-local" rev-parse HEAD)" "$existing_tip"
check "existing-branch add checks out the branch itself" 0 0 \
  "$(git -C "$tmp/wt-existing-local" rev-parse --abbrev-ref HEAD)" "claim-existing-local"

# A branch that exists only on the REMOTE is the actual open-PR case: a fresh checkout has no local
# ref for it. Creating it from the consumer's HEAD would silently fork the PR — the worktree would
# look plausible and carry none of the PR's commits.
remote_seed="$tmp/remote-seed"
mkdir -p "$remote_seed"
git -C "$remote_seed" init -q -b main
git -C "$remote_seed" config user.name "worktree-claim-test"
git -C "$remote_seed" config user.email "worktree-claim-test@example.com"
git -C "$remote_seed" commit --allow-empty -qm "init"
git -C "$remote_seed" checkout -q -b "claim-existing-remote"
git -C "$remote_seed" commit --allow-empty -qm "work that only exists on the PR branch"
remote_tip="$(git -C "$remote_seed" rev-parse "claim-existing-remote")"
git -C "$remote_seed" checkout -q main
remote_origin="$tmp/remote-origin.git"
git clone -q --bare "$remote_seed" "$remote_origin"
remote_consumer="$tmp/remote-consumer"
git clone -q "$remote_origin" "$remote_consumer"
git -C "$remote_consumer" branch -D "claim-existing-remote" >/dev/null 2>&1 || true
# Drop the tracking ref too. `git clone` creates one for every remote branch, so leaving it would let
# this case pass without the fetch ever running — the assertion would hold while the code path it is
# meant to cover was dead. Clearing it is what makes the fetch load-bearing: ablate the fetch and this
# block goes RED.
git -C "$remote_consumer" update-ref -d "refs/remotes/origin/claim-existing-remote"
check "remote-branch fixture starts with no local and no tracking ref" 0 0 \
  "$(git -C "$remote_consumer" for-each-ref --format='%(refname)' \
      'refs/heads/claim-existing-remote' 'refs/remotes/origin/claim-existing-remote' | wc -l | tr -d ' ')" "0"

remote_rc=0
remote_out="$("$script" add \
  "$remote_consumer" "$tmp/wt-existing-remote" "claim-existing-remote" "session-remote-existing" 2>&1)" || remote_rc=$?
check "add attaches to a branch that exists only on the remote" 0 "$remote_rc" \
  "$remote_out" "owner=session-remote-existing"
check "remote-branch add lands on the remote tip, not the consumer HEAD" 0 0 \
  "$(git -C "$tmp/wt-existing-remote" rev-parse HEAD)" "$remote_tip"

# Fail-closed regression: attaching must not defeat git's own single-checkout rule. A branch already
# checked out elsewhere stays refused, so two worktrees can never share one branch.
dup_rc=0
dup_out="$("$script" add \
  "$existing_repo" "$tmp/wt-existing-dup" "claim-existing-local" "session-dup" 2>&1)" || dup_rc=$?
check "a branch already checked out elsewhere is still refused" 2 "$dup_rc" \
  "$dup_out" "git worktree add failed"

# ── an unresolvable remote must not become a silent fork (CodeRabbit, #2810) ────────
# A fetch failure leaves refs/remotes/origin/<branch> untouched, so "no tracking ref" cannot be read
# as "the branch does not exist on origin" — it also means "we could not ask". Creating the branch
# from HEAD there reintroduces exactly the silent fork the remote arm exists to prevent, and the
# bounded remote call makes it reachable on a mere TIMEOUT, where the network is fine seconds later
# and the run does go on to push.
unreach_seed="$tmp/unreach-repo"
mkdir -p "$unreach_seed"
git -C "$unreach_seed" init -q -b main
git -C "$unreach_seed" config user.name "worktree-claim-test"
git -C "$unreach_seed" config user.email "worktree-claim-test@example.com"
git -C "$unreach_seed" commit --allow-empty -qm "init"
git -C "$unreach_seed" remote add origin "$tmp/definitely-not-a-repo.git"
# Remote state must never decide whether `add` succeeds — a pinned property of this helper, with
# four "advisory, not fatal" assertions behind it — so this still claims. What it must NOT do is stay
# silent: the ambiguity is announced, and the claim protocol's own remote-tip SHA comparison before
# pushing is what actually catches a fork.
unreach_rc=0
unreach_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=5 "$script" add \
  "$unreach_seed" "$tmp/wt-unreach" "claim-unreachable" "session-unreach" 2>&1)" || unreach_rc=$?
check "an unresolvable remote still claims (advisory, not fatal)" 0 "$unreach_rc" \
  "$unreach_out" "owner=session-unreach"
check "an unresolvable remote ANNOUNCES that it could not check for an existing branch" 0 \
  "$unreach_rc" "$unreach_out" "could not reach origin to check whether"
check "the announcement names the verification the caller must do" 0 \
  "$unreach_rc" "$unreach_out" "VERIFY the remote tip before pushing"

# The reachable-remote counterpart MUST still create: `ls-remote --exit-code` answers 2 for "branch
# absent" and 128 for "could not ask", and only the first is proof the branch is new. Without this
# the fix above would block every genuinely-new branch.
absent_seed="$tmp/absent-repo"
mkdir -p "$absent_seed"
git -C "$absent_seed" init -q -b main
git -C "$absent_seed" config user.name "worktree-claim-test"
git -C "$absent_seed" config user.email "worktree-claim-test@example.com"
git -C "$absent_seed" commit --allow-empty -qm "init"
git init -q --bare "$tmp/absent-origin.git"
git -C "$absent_seed" remote add origin "$tmp/absent-origin.git"
absent_rc=0
absent_out="$("$script" add \
  "$absent_seed" "$tmp/wt-absent" "claim-genuinely-new" "session-absent" 2>&1)" || absent_rc=$?
check "a branch absent from a REACHABLE remote is still created" 0 "$absent_rc" \
  "$absent_out" "owner=session-absent"

# A repo with no origin at all is not an unreachable remote — nothing can host the branch, so
# creating it is correct. `ls-remote` cannot tell these apart (both exit 128), which is why origin's
# presence is checked separately rather than inferred from the exit code.
noremote_rc=0
noremote_out="$("$script" add \
  "$repo" "$tmp/wt-noremote" "claim-no-remote" "session-noremote" 2>&1)" || noremote_rc=$?
check "a repo with no origin still creates the branch" 0 "$noremote_rc" \
  "$noremote_out" "owner=session-noremote"

# ── a STALE local branch must not attach silently (Codex P2, #2810) ────────────────
# The local arm returned before any remote check, so a local ref left behind by an earlier run
# attached at its old SHA while origin had moved on. Work then targets an obsolete head and only the
# eventual push reveals it — the same shape that once produced a worktree 56 commits behind its PR,
# where a plausible-looking diff would have reverted the PR's own commits.
stale_seed="$tmp/stale-seed"
mkdir -p "$stale_seed"
git -C "$stale_seed" init -q -b main
git -C "$stale_seed" config user.name "worktree-claim-test"
git -C "$stale_seed" config user.email "worktree-claim-test@example.com"
git -C "$stale_seed" commit --allow-empty -qm "init"
git -C "$stale_seed" checkout -q -b "claim-stale-local"
git -C "$stale_seed" commit --allow-empty -qm "the commit the local ref will sit at"
stale_old="$(git -C "$stale_seed" rev-parse HEAD)"
git -C "$stale_seed" checkout -q main
stale_origin="$tmp/stale-origin.git"
git clone -q --bare "$stale_seed" "$stale_origin"
stale_consumer="$tmp/stale-consumer"
git clone -q "$stale_origin" "$stale_consumer"
git -C "$stale_consumer" branch -f "claim-stale-local" "$stale_old"
# origin advances past the local ref, exactly as a sibling push or review follow-up would.
git -C "$stale_seed" checkout -q "claim-stale-local"
git -C "$stale_seed" commit --allow-empty -qm "origin moves ahead"
git -C "$stale_seed" push -q "$stale_origin" "claim-stale-local"
git -C "$stale_seed" checkout -q main

stalelocal_rc=0
stalelocal_out="$("$script" add \
  "$stale_consumer" "$tmp/wt-stale-local" "claim-stale-local" "session-stalelocal" 2>&1)" || stalelocal_rc=$?
check "a stale local branch still claims (advisory, not fatal)" 0 "$stalelocal_rc" \
  "$stalelocal_out" "owner=session-stalelocal"
check "a stale local branch is ANNOUNCED rather than attached silently" 0 "$stalelocal_rc" \
  "$stalelocal_out" "behind origin"
check "the staleness announcement names the branch" 0 "$stalelocal_rc" \
  "$stalelocal_out" "claim-stale-local"

# A local branch that is already current must stay quiet — otherwise the warning fires on every
# ordinary attach and is trained away as noise.
current_consumer="$tmp/current-consumer"
git clone -q "$stale_origin" "$current_consumer"
git -C "$current_consumer" branch -f "claim-current-local" "$(git -C "$current_consumer" rev-parse origin/main)"
currentlocal_rc=0
currentlocal_out="$("$script" add \
  "$current_consumer" "$tmp/wt-current-local" "claim-current-local" "session-currentlocal" 2>&1)" || currentlocal_rc=$?
check "a current local branch claims without a staleness warning" 0 "$currentlocal_rc" \
  "$currentlocal_out" "owner=session-currentlocal"
check "no false staleness warning on a branch origin does not have" 0 \
  "$(grep -qF 'behind origin' <<<"$currentlocal_out" && echo 1 || echo 0)"

# ── ls-remote SUCCEEDS but the fetch fails, with no cached tracking ref ────────────────────────
# The remote arm attaches with `--track … origin/$branch`. That ref only exists if the fetch landed,
# so when `ls-remote` says the branch exists and the fetch then fails on a checkout that has never
# fetched it, `worktree add` dies on `invalid reference` and `add` FAILS — remote state deciding
# whether `add` succeeds, which every "advisory, not fatal" assertion above exists to prevent. The
# combination is not exotic: `bounded_remote` gives the fetch a short timeout, so a merely SLOW
# remote trips it while `ls-remote` already succeeded, and resuming an open PR is exactly the case
# with no cached ref. The stub fails ONLY `fetch`, so `ls-remote` still answers 0 — without that
# asymmetry the run would take the `*)` arm and this case would never be exercised.
fetchfail_origin="$tmp/fetchfail-origin.git"
git init -q --bare "$fetchfail_origin"
fetchfail_seed="$tmp/fetchfail-seed"
# Initialize directly rather than clone-or-init: the fallback made the seed's layout depend on which
# arm ran, and both suppressions hid a real setup failure — a fixture that fails to build is
# indistinguishable from one that built, so the checks below would pass for the wrong reason.
git init -q -b main "$fetchfail_seed"
git -C "$fetchfail_seed" config user.name "worktree-claim-test"
git -C "$fetchfail_seed" config user.email "worktree-claim-test@example.com"
git -C "$fetchfail_seed" commit --allow-empty -qm "init"
git -C "$fetchfail_seed" checkout -qb "claim-fetchfail"
git -C "$fetchfail_seed" commit --allow-empty -qm "work that only exists on origin"
git -C "$fetchfail_seed" remote add origin "$fetchfail_origin"
git -C "$fetchfail_seed" push -q origin main claim-fetchfail

# Clone WITHOUT the branch's tracking ref, but keep the normal wildcard refspec — a narrowed
# refspec would fail `--track` for an unrelated reason and mask what this fixture measures.
fetchfail_consumer="$tmp/fetchfail-consumer"
git clone -q --single-branch --branch main "$fetchfail_origin" "$fetchfail_consumer"
git -C "$fetchfail_consumer" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
check "precondition: the branch has NO cached tracking ref" 0 \
  "$(git -C "$fetchfail_consumer" show-ref --verify --quiet refs/remotes/origin/claim-fetchfail && echo 1 || echo 0)"

fetchfail_stub="$tmp/fetchfail-stub"
mkdir -p "$fetchfail_stub"
cat >"$fetchfail_stub/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = "fetch" ] && exit 1
done
exec "$real_git" "\$@"
STUB
chmod +x "$fetchfail_stub/git"

fetchfail_rc=0
fetchfail_out="$(PATH="$fetchfail_stub:$PATH" "$script" add \
  "$fetchfail_consumer" "$tmp/wt-fetchfail" "claim-fetchfail" "session-fetchfail" 2>&1)" || fetchfail_rc=$?
check "an unfetchable existing branch still claims (advisory, not fatal)" 0 "$fetchfail_rc" \
  "$fetchfail_out" "owner=session-fetchfail"
check "the unfetchable-branch claim actually creates the worktree" 0 \
  "$([ -d "$tmp/wt-fetchfail" ] && echo 0 || echo 1)"
# Silence here would be the dangerous outcome: origin POSITIVELY has this branch, so creating it
# locally forks a real PR rather than resuming it. The warning is what sends the operator to
# re-fetch before pushing, and it must say which of the two situations this is.
check "an unfetchable existing branch is announced as a FORK, not a resume" 0 "$fetchfail_rc" \
  "$fetchfail_out" "FORK, not a resume"
check "the fork warning states the branch exists on origin" 0 "$fetchfail_rc" \
  "$fetchfail_out" "EXISTS on origin"

# ── a CACHED tracking ref that is STALE, when the refresh fails ────────────────────────────────
# The guard above proves a cached ref EXISTS; existence is not freshness. With the fetch failing,
# that ref is whatever the last successful fetch left, so attaching resumes the PR at an obsolete
# head — the same silent staleness the fork branch warns about, arriving through the fallback
# instead. `ls-remote` already returned origin's tip, so this is checkable rather than unknowable.
stalecache_origin="$tmp/stalecache-origin.git"
git init -q --bare "$stalecache_origin"
stalecache_seed="$tmp/stalecache-seed"
git init -q "$stalecache_seed"
git -C "$stalecache_seed" config user.name "worktree-claim-test"
git -C "$stalecache_seed" config user.email "worktree-claim-test@example.com"
git -C "$stalecache_seed" commit --allow-empty -qm "init"
git -C "$stalecache_seed" branch -M main
git -C "$stalecache_seed" checkout -qb "claim-stalecache"
git -C "$stalecache_seed" commit --allow-empty -qm "v1"
git -C "$stalecache_seed" remote add origin "$stalecache_origin"
git -C "$stalecache_seed" push -q origin main claim-stalecache

# Clone WHILE the branch is at v1, so the tracking ref is cached and genuinely current...
stalecache_consumer="$tmp/stalecache-consumer"
git clone -q "$stalecache_origin" "$stalecache_consumer"
stalecache_cached="$(git -C "$stalecache_consumer" rev-parse refs/remotes/origin/claim-stalecache)"
# ...then advance origin, which is what makes the cache stale without touching the consumer.
git -C "$stalecache_seed" commit --allow-empty -qm "v2"
git -C "$stalecache_seed" push -q origin claim-stalecache
stalecache_tip="$(git -C "$stalecache_origin" rev-parse claim-stalecache)"
check "precondition: the cached ref and origin's tip actually differ" 0 \
  "$([ "$stalecache_cached" != "$stalecache_tip" ] && echo 0 || echo 1)"

stalecache_rc=0
stalecache_out="$(PATH="$fetchfail_stub:$PATH" "$script" add \
  "$stalecache_consumer" "$tmp/wt-stalecache" "claim-stalecache" "session-stalecache" 2>&1)" || stalecache_rc=$?
check "a stale cached ref still claims (advisory, not fatal)" 0 "$stalecache_rc" \
  "$stalecache_out" "owner=session-stalecache"
check "an unrefreshable cached ref is announced as STALE" 0 "$stalecache_rc" \
  "$stalecache_out" "is STALE"
# Naming both SHAs is what makes the warning actionable rather than vague: the operator can see
# which head they are on and which one they wanted.
check "the stale-cache warning names the cached AND the origin sha" 0 "$stalecache_rc" \
  "$stalecache_out" "${stalecache_cached:0:10}"
# BOTH halves, or the check does not test what its name claims: with only the cached prefix asserted,
# dropping the origin prefix from the message leaves this green — and the origin sha is the half that
# tells the operator which head they wanted.
check "the stale-cache warning names the ORIGIN sha too" 0 "$stalecache_rc" \
  "$stalecache_out" "${stalecache_tip:0:10}"

# The complement, and the reason this cannot just always warn: when the fetch SUCCEEDS the cached
# ref is current, so the warning must stay silent or it fires on every ordinary attach.
freshcache_consumer="$tmp/freshcache-consumer"
git clone -q "$stalecache_origin" "$freshcache_consumer"
freshcache_rc=0
freshcache_out="$("$script" add \
  "$freshcache_consumer" "$tmp/wt-freshcache" "claim-stalecache" "session-freshcache" 2>&1)" || freshcache_rc=$?
# Assert the claim SUCCEEDED first. Absence-of-warning is satisfied by a fixture that never got far
# enough to warn, so without this the check passes precisely when `add` is broken.
check "the fresh-cache claim succeeds" 0 "$freshcache_rc" \
  "$freshcache_out" "owner=session-freshcache"
check "no false STALE warning when the refresh succeeds" 0 \
  "$(grep -qF 'is STALE' <<<"$freshcache_out" && echo 1 || echo 0)"

# ── the stale-LOCAL remediation must move something ────────────────────────────────────────────
# It used to print `git fetch origin <branch>` — a command this function has already run, and which
# only updates refs/remotes/origin/<branch>. Following it leaves the worktree exactly as stale, so
# the operator learns the warning is noise. The hint must name the fast-forward in the WORKTREE.
check "the stale-local hint names a merge, not another fetch" 0 "$stalelocal_rc" \
  "$stalelocal_out" "merge --ff-only"
# Assert against the HINT LINE, not the whole transcript. `git worktree add` echoes the worktree path
# itself ("Preparing worktree ..."), so a whole-output match for that path passes no matter what the
# hint targets — verified: repointing the hint at $repo left the suite fully green. Isolating the line
# is what makes this assertion capable of failing for the reason it exists.
stalelocal_hint="$(grep 'Reconcile before working' <<<"$stalelocal_out" || true)"
check "a reconcile hint was actually emitted (guards the two checks below)" 0 \
  "$([ -n "$stalelocal_hint" ] && echo 0 || echo 1)"
check "the stale-local hint targets the WORKTREE" 0 0 \
  "$stalelocal_hint" "wt-stale-local"
check "the stale-local hint does NOT target the repo checkout" 0 \
  "$(grep -qF 'stale-consumer' <<<"$stalelocal_hint" && echo 1 || echo 0)"

# ── resuming a remote branch in a NARROW-REFSPEC clone ─────────────────────────────────────────
# `worktree add --track <start>` does not ask whether the ref EXISTS; it asks whether git considers
# it a trackable remote branch, and that answer comes from `remote.origin.fetch`. In a single-branch
# clone the explicit refspec fetch above still creates refs/remotes/origin/<branch>, and the add is
# still refused with `cannot set up tracking information` — leaving NO worktree at all. Resuming an
# open PR is rung-1 work, so this arm failing is the helper being unusable for its commonest case.
narrowfetch_origin="$tmp/narrowfetch-origin.git"
git init -q --bare -b main "$narrowfetch_origin"
narrowfetch_seed="$tmp/narrowfetch-seed"
git init -q -b main "$narrowfetch_seed"
git -C "$narrowfetch_seed" config user.name "worktree-claim-test"
git -C "$narrowfetch_seed" config user.email "worktree-claim-test@example.com"
git -C "$narrowfetch_seed" commit --allow-empty -qm "base"
git -C "$narrowfetch_seed" remote add origin "$narrowfetch_origin"
git -C "$narrowfetch_seed" push -q origin main
git -C "$narrowfetch_seed" checkout -qb "claim-narrowfetch"
git -C "$narrowfetch_seed" commit --allow-empty -qm "pr-work"
git -C "$narrowfetch_seed" push -q origin "claim-narrowfetch"
narrowfetch_tip="$(git -C "$narrowfetch_origin" rev-parse "claim-narrowfetch")"

# --single-branch is what a shallow CI checkout and `gh repo clone -- --depth` both produce.
narrowfetch_consumer="$tmp/narrowfetch-consumer"
git clone -q --single-branch --branch main "$narrowfetch_origin" "$narrowfetch_consumer"
# Guards the arm below: without a narrowed refspec this fixture proves nothing, and a later "tidy-up"
# of the clone flags would silently make every assertion here vacuous.
# Here-string, not a pipe: `grep -q` exits at the first match, the writer dies with EPIPE, and under
# `pipefail` the pipeline reports non-zero — so the guard would print 0 and the precondition would
# pass even when the refspec DOES map the PR branch, i.e. vacuous in the one direction it must catch.
check "precondition: the consumer's refspec does NOT map the PR branch" 0 \
  "$(grep -qF 'refs/heads/*' \
     <<<"$(git -C "$narrowfetch_consumer" config remote.origin.fetch)" && echo 1 || echo 0)"

narrowfetch_rc=0
narrowfetch_out="$("$script" add \
  "$narrowfetch_consumer" "$tmp/wt-narrowfetch" "claim-narrowfetch" "session-narrowfetch" 2>&1)" || narrowfetch_rc=$?
check "a narrow-refspec clone still resumes an existing remote branch" 0 "$narrowfetch_rc" \
  "$narrowfetch_out" "owner=session-narrowfetch"
check "the narrow-refspec claim actually creates the worktree" 0 \
  "$([ -d "$tmp/wt-narrowfetch" ] && echo 0 || echo 1)"
# The whole point of resuming: land on the PR's commit, not a fork from local HEAD.
check "the narrow-refspec worktree lands on the remote tip" 0 0 \
  "$(git -C "$tmp/wt-narrowfetch" rev-parse HEAD 2>/dev/null || echo none)" "$narrowfetch_tip"

# ── a failed refresh must not let behind=0 read as "current" ────────────────────────────────────
# The local-branch arm counts `behind` against refs/remotes/origin/<branch>. When the fetch fails,
# that ref is whatever the last successful fetch left — so a local branch equal to that obsolete
# cache counts 0 and the arm stays silent, which is indistinguishable from a genuinely current
# branch. A zero measured against an unrefreshed ref is not evidence; it is the absence of evidence.
behindfail_origin="$tmp/behindfail-origin.git"
git init -q --bare -b main "$behindfail_origin"
behindfail_seed="$tmp/behindfail-seed"
git init -q -b main "$behindfail_seed"
git -C "$behindfail_seed" config user.name "worktree-claim-test"
git -C "$behindfail_seed" config user.email "worktree-claim-test@example.com"
git -C "$behindfail_seed" commit --allow-empty -qm "init"
git -C "$behindfail_seed" remote add origin "$behindfail_origin"
git -C "$behindfail_seed" push -q origin main
git -C "$behindfail_seed" checkout -qb "claim-behindfail"
git -C "$behindfail_seed" commit --allow-empty -qm "v1"
git -C "$behindfail_seed" push -q origin "claim-behindfail"

# Clone at v1 so the LOCAL branch and the CACHED tracking ref agree...
behindfail_consumer="$tmp/behindfail-consumer"
git clone -q "$behindfail_origin" "$behindfail_consumer"
git -C "$behindfail_consumer" branch "claim-behindfail" "origin/claim-behindfail"
# ...then advance origin. The consumer is never told, so a failed fetch leaves behind=0 against a
# ref that is now one commit stale.
git -C "$behindfail_seed" commit --allow-empty -qm "v2"
git -C "$behindfail_seed" push -q origin "claim-behindfail"
check "precondition: local and cached agree while origin has moved on" 0 \
  "$([ "$(git -C "$behindfail_consumer" rev-parse claim-behindfail)" \
     = "$(git -C "$behindfail_consumer" rev-parse refs/remotes/origin/claim-behindfail)" ] &&
     [ "$(git -C "$behindfail_consumer" rev-parse claim-behindfail)" \
     != "$(git -C "$behindfail_origin" rev-parse claim-behindfail)" ] && echo 0 || echo 1)"

behindfail_rc=0
behindfail_out="$(PATH="$fetchfail_stub:$PATH" "$script" add \
  "$behindfail_consumer" "$tmp/wt-behindfail" "claim-behindfail" "session-behindfail" 2>&1)" || behindfail_rc=$?
check "an unrefreshable local branch still claims (advisory, not fatal)" 0 "$behindfail_rc" \
  "$behindfail_out" "owner=session-behindfail"
# Assert on the branch-specific line. `warn_if_base_is_stale` also emits an UNKNOWN for origin/HEAD
# under the same stub, so a whole-transcript match for "UNKNOWN" passes even with this fix reverted —
# verified by reverting it and watching the unisolated form stay green.
behindfail_line="$(grep 'origin/claim-behindfail' <<<"$behindfail_out" || true)"
check "a behind=0 measured against an unrefreshed ref reports UNKNOWN, not silence" 0 \
  "$([ -n "$behindfail_line" ] && echo 0 || echo 1)"
check "the UNKNOWN names the failed refresh as the reason" 0 0 \
  "$behindfail_line" "refresh failed"

# ── a local branch with NO tracking ref at all, when the refresh fails ─────────────────────────
# The case above has a cached ref, so `behind` is measurable and the zero answer is what needed
# reporting. Here there is no `refs/remotes/origin/<branch>` to measure against — the state a fresh
# `--single-branch` checkout is in for exactly the branch an open PR lives on. A failed refresh then
# leaves nothing to compare, and returning silently is indistinguishable from "verified current",
# which is the very condition the cached-ref arm rejects. Same reasoning, the other branch of the
# same function; it went untested, so the silent return survived a fix that named it.
nocache_origin="$tmp/nocache-origin.git"
git init -q --bare -b main "$nocache_origin"
nocache_seed="$tmp/nocache-seed"
git init -q -b main "$nocache_seed"
git -C "$nocache_seed" config user.name "worktree-claim-test"
git -C "$nocache_seed" config user.email "worktree-claim-test@example.com"
git -C "$nocache_seed" commit --allow-empty -qm "init"
git -C "$nocache_seed" remote add origin "$nocache_origin"
git -C "$nocache_seed" push -q origin main
git -C "$nocache_seed" checkout -qb "claim-nocache"
git -C "$nocache_seed" commit --allow-empty -qm "pr work"
git -C "$nocache_seed" push -q origin "claim-nocache"

# --single-branch leaves no tracking ref for the PR branch; the wildcard refspec is restored so the
# absent ref is what this measures rather than a narrowed fetch config.
nocache_consumer="$tmp/nocache-consumer"
git clone -q --single-branch --branch main "$nocache_origin" "$nocache_consumer"
git -C "$nocache_consumer" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
# A LOCAL branch of that name, so the attach path runs the freshness check at all.
git -C "$nocache_consumer" branch "claim-nocache" main
check "precondition: a local branch exists with no tracking ref" 0 \
  "$(git -C "$nocache_consumer" show-ref --verify --quiet refs/heads/claim-nocache &&
     ! git -C "$nocache_consumer" show-ref --verify --quiet refs/remotes/origin/claim-nocache &&
     echo 0 || echo 1)"

nocache_rc=0
nocache_out="$(PATH="$fetchfail_stub:$PATH" "$script" add \
  "$nocache_consumer" "$tmp/wt-nocache" "claim-nocache" "session-nocache" 2>&1)" || nocache_rc=$?
check "a missing tracking ref still claims (advisory, not fatal)" 0 "$nocache_rc" \
  "$nocache_out" "owner=session-nocache"
# Branch-specific line for the same reason the case above needs one: `warn_if_base_is_stale` emits
# its own UNKNOWN for origin/HEAD under this stub, so a whole-transcript "UNKNOWN" match stays green
# with the fix reverted.
nocache_line="$(grep 'origin/claim-nocache' <<<"$nocache_out" || true)"
check "an absent tracking ref after a failed refresh reports UNKNOWN, not silence" 0 \
  "$([ -n "$nocache_line" ] && echo 0 || echo 1)"
check "that UNKNOWN also names the failed refresh as the reason" 0 0 \
  "$nocache_line" "refresh failed"

# ── a NON-ZERO behind measured against an unrefreshed ref is not origin's state ────────────────
# The behind=0 case above is handled. The non-zero one was argued safe because "origin demonstrably
# has those commits" — but the count is measured against the CACHED ref, which a failed fetch leaves
# at whatever the last successful fetch wrote. If the branch was since deleted or force-pushed on
# origin, those commits are not on origin at all, and the emitted hint tells the operator to
# `merge --ff-only origin/<branch>` — resurrecting work that no longer exists there. A count is only
# origin's state when the ref it was measured against was actually refreshed.
behindstale_origin="$tmp/behindstale-origin.git"
git init -q --bare -b main "$behindstale_origin"
behindstale_seed="$tmp/behindstale-seed"
git init -q -b main "$behindstale_seed"
git -C "$behindstale_seed" config user.name "worktree-claim-test"
git -C "$behindstale_seed" config user.email "worktree-claim-test@example.com"
git -C "$behindstale_seed" commit --allow-empty -qm "init"
git -C "$behindstale_seed" remote add origin "$behindstale_origin"
git -C "$behindstale_seed" push -q origin main
git -C "$behindstale_seed" checkout -qb "claim-behindstale"
git -C "$behindstale_seed" commit --allow-empty -qm "v1"
behindstale_v1="$(git -C "$behindstale_seed" rev-parse HEAD)"
git -C "$behindstale_seed" commit --allow-empty -qm "v2"
git -C "$behindstale_seed" push -q origin "claim-behindstale"

# The consumer caches origin at v2 while its local branch stays at v1, so behind=1 is measurable...
behindstale_consumer="$tmp/behindstale-consumer"
git clone -q "$behindstale_origin" "$behindstale_consumer"
git -C "$behindstale_consumer" branch "claim-behindstale" "$behindstale_v1"
# ...and then the branch is DELETED on origin. The cached ref survives that, which is exactly why
# the count keeps reading 1 while origin no longer carries the branch at all.
git -C "$behindstale_origin" update-ref -d refs/heads/claim-behindstale
check "precondition: behind is measurable while origin no longer has the branch" 0 \
  "$([ "$(git -C "$behindstale_consumer" rev-list --count \
       claim-behindstale..refs/remotes/origin/claim-behindstale)" = "1" ] &&
     ! git -C "$behindstale_origin" show-ref --verify --quiet refs/heads/claim-behindstale &&
     echo 0 || echo 1)"

behindstale_rc=0
behindstale_out="$(PATH="$fetchfail_stub:$PATH" "$script" add \
  "$behindstale_consumer" "$tmp/wt-behindstale" "claim-behindstale" "session-behindstale" 2>&1)" ||
  behindstale_rc=$?
check "an unverifiable behind-count still claims (advisory, not fatal)" 0 "$behindstale_rc" \
  "$behindstale_out" "owner=session-behindstale"
# Isolate the branch's own NOTE line. `warn_if_base_is_stale` emits its own UNKNOWN for origin/HEAD
# under this stub, so a whole-transcript match for "UNVERIFIED" would pass with the fix reverted.
behindstale_line="$(grep 'behind the CACHED' <<<"$behindstale_out" || true)"
check "a behind-count from a failed refresh is announced against the CACHED ref" 0 \
  "$([ -n "$behindstale_line" ] && echo 0 || echo 1)"
check "that announcement marks the count UNVERIFIED" 0 0 \
  "$behindstale_line" "UNVERIFIED"
# The hint is the actionable half, and the ff-merge is what would resurrect deleted work. It must not
# be offered when the refresh that would have proven origin's state failed.
check "no authoritative ff-merge hint is offered on an unverified count" 0 \
  "$(grep -qF 'merge --ff-only' <<<"$behindstale_out" && echo 1 || echo 0)"

# ── a FAILED pinned worktree creation must not report success ──────────────────────────────────
# `add_worktree_on` is invoked as `if ! add_worktree_on ...`, which suppresses errexit for its whole
# body. On the pinned path the creation's status is therefore not fatal, and the advisory
# `branch --set-upstream-to ... || true` that follows it returns 0 — so the function's status is the
# TRACKING call's, and a worktree git refused is announced as claimed. A post-checkout hook that
# rejects the checkout is the real, unstubbed shape of this: git exits non-zero having already
# created the directory, so the directory's existence proves nothing about success.
pinfail_origin="$tmp/pinfail-origin.git"
git init -q --bare -b main "$pinfail_origin"
pinfail_seed="$tmp/pinfail-seed"
git init -q -b main "$pinfail_seed"
git -C "$pinfail_seed" config user.name "worktree-claim-test"
git -C "$pinfail_seed" config user.email "worktree-claim-test@example.com"
git -C "$pinfail_seed" commit --allow-empty -qm "init"
git -C "$pinfail_seed" remote add origin "$pinfail_origin"
git -C "$pinfail_seed" push -q origin main
git -C "$pinfail_seed" checkout -qb "claim-pinfail"
git -C "$pinfail_seed" commit --allow-empty -qm "work that lives on origin"
git -C "$pinfail_seed" push -q origin "claim-pinfail"

# A plain clone caches origin/claim-pinfail with no local branch — the state that takes the remote
# arm, resolves a pinned tip, and reaches the pinned creation.
pinfail_consumer="$tmp/pinfail-consumer"
git clone -q "$pinfail_origin" "$pinfail_consumer"
check "precondition: cached tracking ref present and no local branch (pinned path)" 0 \
  "$(git -C "$pinfail_consumer" show-ref --verify --quiet refs/remotes/origin/claim-pinfail &&
     ! git -C "$pinfail_consumer" show-ref --verify --quiet refs/heads/claim-pinfail &&
     echo 0 || echo 1)"
cat >"$pinfail_consumer/.git/hooks/post-checkout" <<'HOOK'
#!/bin/sh
echo "post-checkout refuses this checkout" >&2
exit 7
HOOK
chmod +x "$pinfail_consumer/.git/hooks/post-checkout"

pinfail_rc=0
pinfail_out="$("$script" add \
  "$pinfail_consumer" "$tmp/wt-pinfail" "claim-pinfail" "session-pinfail" 2>&1)" || pinfail_rc=$?
check "a refused pinned creation does NOT exit 0" 1 \
  "$([ "$pinfail_rc" -ne 0 ] && echo 1 || echo 0)"
# The success line is what a caller and the run report read as "the lane is mine". Emitting it over a
# refused checkout is the actual harm — the exit code alone could be lost in a pipeline.
check "a refused pinned creation does not announce ownership" 0 \
  "$(grep -qF 'owner=session-pinfail' <<<"$pinfail_out" && echo 1 || echo 0)"
check "a refused pinned creation says the worktree add failed" 0 0 \
  "$pinfail_out" "git worktree add failed"

printf '\nworktree-claim: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
