#!/usr/bin/env bash
# pr-worktree-holder.test.sh — behavioural proof for pr-worktree-holder.sh (monorepo#3067).
#
# monorepo#3053 read idle on every published-event signal while two live sessions worked in its
# worktree. The helper answers from the host's processes instead, so this test pins, against real
# git checkouts and a scripted process table:
#   - a process holds its own checkout, that checkout's populated submodules and, for a per-session
#     worktree only, the product worktrees nested in those submodules;
#   - a main checkout never claims the per-session worktrees nested inside it;
#   - the asking session is `self`, while another session in the same worktree and a sibling in a
#     different worktree stay `live`;
#   - a failed or empty `lsof`, or a failed `ps`, is `unknown:` and exit 2, never `none`.
# `lsof` and `ps` are shims driven by FIXTURE_* variables; the helper itself reads no environment.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/pr-worktree-holder.sh"
checks=0
failures=0
finished=0
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/pr-worktree-holder-test.XXXXXX")"
trap 'rm -rf -- "${sandbox}"; if [ "${finished}" != 1 ]; then echo "pr-worktree-holder.test.sh: aborted before finishing" >&2; exit 1; fi' EXIT
sandbox="$(cd "${sandbox}" && /bin/pwd -P)"

[ -x "${tool}" ] || { echo "FAIL cannot execute ${tool}" >&2; exit 1; }

# Fixture repositories only: never the caller's global or system git configuration.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() {
  git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    -c init.defaultBranch=main -c protocol.file.allow=always "$@"
}

# ── Checkouts ───────────────────────────────────────────────────────────────────────────────────
main="${sandbox}/main"
w1="${main}/.claude/worktrees/w1"
w2="${main}/.claude/worktrees/w2"
g init -q "${sandbox}/product-origin"
g -C "${sandbox}/product-origin" commit -q --allow-empty -m init
g init -q "${main}"
g -C "${main}" commit -q --allow-empty -m init
g -C "${main}" submodule --quiet add "${sandbox}/product-origin" product
g -C "${main}" commit -q -m 'add product'
g -C "${main}" config remote.origin.url git@github.com:devantler-tech/demo.git
g -C "${main}/product" config remote.origin.url https://github.com/devantler-tech/product.git
# The main checkout's own submodule registers a worktree inside itself. A main checkout never claims
# what is nested in it, so a process at the main checkout must not hold this branch.
g -C "${main}/product" worktree add -q -b claude/product-main-nested "${main}/product/.claude/worktrees/nested"
# Two per-session worktrees, nested in the main checkout exactly as the harness creates them.
g -C "${main}" worktree add -q -b claude/feature-1 "${w1}"
g -C "${main}" worktree add -q -b claude/feature-2 "${w2}"
# Session w1 populates the product submodule, works on a branch there, and keeps a per-run product
# worktree inside it, as the git-and-worktrees guide prescribes.
g -C "${w1}" submodule --quiet update --init product
g -C "${w1}/product" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${w1}/product" switch -q -c claude/product-7
g -C "${w1}/product" worktree add -q -b claude/product-8 "${w1}/product/.claude/worktrees/maint-1"
# Session w3 is mid-rebase on its branch: HEAD is detached and the branch is named only in the
# rebase state (the shape `git rebase` leaves while it stops on a conflict).
w3="${main}/.claude/worktrees/w3"
g -C "${main}" worktree add -q -b claude/rebasing-10 "${w3}"
w3_gitdir="$(g -C "${w3}" rev-parse --path-format=absolute --git-dir)"
g -C "${w3}" switch -q --detach
mkdir -p "${w3_gitdir}/rebase-merge"
# Written without a trailing newline: the branch must still be read.
printf 'refs/heads/claude/rebasing-10' >"${w3_gitdir}/rebase-merge/head-name"
# A standalone clone elsewhere on the host whose remote is not called `origin`.
elsewhere="${sandbox}/elsewhere"
g init -q "${elsewhere}"
g -C "${elsewhere}" commit -q --allow-empty -m init
g -C "${elsewhere}" remote add upstream https://github.com/devantler-tech/tool
g -C "${elsewhere}" switch -q -c claude/tool-11

# Guard the fixture itself: w1's submodule must be its own checkout, not a path inside w1, and w3
# must really be detached.
[ "$(g -C "${w1}/product" rev-parse --show-toplevel)" = "${w1}/product" ] ||
  { echo "FAIL fixture: w1/product is not a populated submodule checkout" >&2; exit 1; }
if g -C "${w3}" symbolic-ref -q HEAD >/dev/null; then
  echo "FAIL fixture: w3 is not detached" >&2
  exit 1
fi

# ── Shims ───────────────────────────────────────────────────────────────────────────────────────
shims="${sandbox}/shims"
mkdir -p "${shims}"
cat >"${shims}/lsof" <<'SHIM'
#!/usr/bin/env bash
cat "${FIXTURE_LSOF:?}"
exit "${FIXTURE_LSOF_RC:-0}"
SHIM
# The real process table (so the helper's own ancestry is real), with one row replaced and the
# scripted holder rows appended.
cat >"${shims}/ps" <<'SHIM'
#!/usr/bin/env bash
if [ "${FIXTURE_PS_FAIL:-0}" = 1 ]; then exit 1; fi
/bin/ps "$@" | awk -v row="${FIXTURE_SELF_ROW:-}" '
  BEGIN { split(row, r, " ") }
  row != "" && $1 == r[1] { print row; next }
  { print }'
cat "${FIXTURE_PS_EXTRA:?}"
SHIM
chmod +x "${shims}/lsof" "${shims}/ps"

me="$$"
lsof_full="${sandbox}/lsof-full"
cat >"${lsof_full}" <<LSOF
p${me}
fcwd
n${w1}
p9000001
fcwd
n${w1}
p9000002
fcwd
n${w1}
p9000003
fcwd
n${w2}
p9000004
fcwd
n${w2}
p9000005
fcwd
n${main}
p9000006
fcwd
n${w1}/product
p9000007
fcwd
n/
p9000008
fcwd
n${w2}
p9000009
fcwd
n${w3}
p9000010
fcwd
n${elsewhere}
p9000013
fcwd
n${w2}
p9000014
fcwd
n${w2}
p9000016
fcwd
n${w2}
p9000017
fcwd
n${w2}
LSOF
# 9000008 is in the lsof output but not in the process table: it exited before ps ran. 9000011 and
# 9000012 are in the table but work nowhere unless a test's lsof file says so. In w2, 9000013 is a
# shell at its prompt and 9000016 a terminal-tab shell whose only child is another shell: neither
# does work. 9000014 is a login shell running `make`, so it is busy.
ps_extra="${sandbox}/ps-extra"
cat >"${ps_extra}" <<PS
9000001 ${me} go
9000002 1 /usr/local/bin/claude
9000003 1 node
9000004 ${me} sleep
9000005 1 git
9000006 1 sleep
9000007 1 bash
9000009 1 git
9000010 1 vim
9000011 1 codex
9000012 1 disclaimer
9000013 1 zsh
9000014 1 -bash
9000015 9000014 make
9000016 1 zsh (kiro-cli-term)
9000017 9000016 zsh
9000018 ${me} go
PS
lsof_empty="${sandbox}/lsof-empty"
: >"${lsof_empty}"
lsof_outer="${sandbox}/lsof-outer"
cat "${lsof_full}" >"${lsof_outer}"
printf 'p9000011\nfcwd\nn%s\n' "${w2}" >>"${lsof_outer}"
lsof_wrapper="${sandbox}/lsof-wrapper"
cat "${lsof_full}" >"${lsof_wrapper}"
# ...and a fourth holder of the asker's own, so the name list is capped while the count is not.
printf 'p9000012\nfcwd\nn%s\np9000018\nfcwd\nn%s\n' "${w1}" "${w1}" >>"${lsof_wrapper}"
lsof_idle_shells="${sandbox}/lsof-idle-shells"
printf 'p9000013\nfcwd\nn%s\np9000016\nfcwd\nn%s\np9000017\nfcwd\nn%s\n' "${w2}" "${w2}" "${w2}" >"${lsof_idle_shells}"
lsof_busy_shell="${sandbox}/lsof-busy-shell"
printf 'p9000013\nfcwd\nn%s\np9000014\nfcwd\nn%s\n' "${w2}" "${w2}" >"${lsof_busy_shell}"

# pr <owner/repo> <n> <head> [<head-owner>] [<head-repo>] — one gh pr view --json
# url,headRefName,headRepositoryOwner,headRepository object; the head defaults to the base repository.
pr() {
  local base_owner="${1%%/*}" base_name="${1#*/}"
  jq -nc --arg repo "$1" --arg n "$2" --arg head "$3" --arg owner "${4:-${base_owner}}" \
    --arg name "${5:-${base_name}}" \
    '{url: "https://github.com/\($repo)/pull/\($n)", headRefName: $head,
      headRepositoryOwner: {id: "x", login: $owner}, headRepository: {id: "y", name: $name}}'
}

# expect <label> <asking-dir> <self-row> <want-rc> <want-stdout> <stdin> [lsof-file] [lsof-rc] [ps-fail]
expect() {
  local label="$1" dir="$2" self_row="$3" want_rc="$4" want_out="$5" payload="$6"
  local lsof_file="${7:-${lsof_full}}" lsof_rc="${8:-0}" ps_fail="${9:-0}" out rc=0
  checks=$((checks + 1))
  out="$(cd "${dir}" && PATH="${shims}:${PATH}" FIXTURE_LSOF="${lsof_file}" FIXTURE_LSOF_RC="${lsof_rc}" \
    FIXTURE_PS_FAIL="${ps_fail}" FIXTURE_PS_EXTRA="${ps_extra}" FIXTURE_SELF_ROW="${self_row}" \
    "${tool}" --input - <<<"${payload}" 2>/dev/null)" || rc=$?
  if [ "${rc}" = "${want_rc}" ] && [ "${out}" = "${want_out}" ]; then
    echo "ok   ${label}"
  else
    printf 'FAIL %s\n  want rc=%s [%s]\n  got  rc=%s [%s]\n' "${label}" "${want_rc}" "${want_out}" "${rc}" "${out}" >&2
    failures=$((failures + 1))
  fi
}

# The asking session: the test shell plays its `claude` process. Its parent is cut to 1 so a real
# session process further up (when this test itself runs under one) cannot stand in for it.
session="${me} 1 claude"
plain="${me} 1 testshell"

# ── Who holds what ──────────────────────────────────────────────────────────────────────────────
expect "another session in the asker's own worktree is live; the asker and its child are self" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#1 holder=live:1:9000002/claude+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/demo 1 claude/feature-1)"
expect "a sibling's process in another worktree is live even though it descends from the session" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#2 holder=live:3:9000003/node,9000004/sleep,9000014/-bash" \
  "$(pr devantler-tech/demo 2 claude/feature-2)"
expect "a session at its worktree root holds the branch in its populated submodule" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#7 holder=live:2:9000002/claude,9000006/sleep+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/product 7 claude/product-7)"
expect "a per-session worktree holds the product worktree nested in its submodule" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#8 holder=live:1:9000002/claude+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/product 8 claude/product-8)"
expect "a main checkout never claims a worktree nested in its own submodule" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#9 holder=none" \
  "$(pr devantler-tech/product 9 claude/product-main-nested)"
expect "a branch no checkout has is none" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#3 holder=none" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)"
expect "the same branch name in another repository is not a match" \
  "${w1}" "${session}" 0 \
  "devantler-tech/other#4 holder=none" \
  "$(pr devantler-tech/other 4 claude/feature-2)"
expect "a fork head is not examined locally" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#5 holder=fork" \
  "$(pr devantler-tech/demo 5 claude/feature-1 someone)"
expect "a checkout detached mid-rebase still holds the branch it is rebasing" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#10 holder=live:1:9000009/git" \
  "$(pr devantler-tech/demo 10 claude/rebasing-10)"
expect "any remote names the repository, not only one called origin" \
  "${w1}" "${session}" 0 \
  "devantler-tech/tool#11 holder=live:1:9000010/vim" \
  "$(pr devantler-tech/tool 11 claude/tool-11)"
expect "a cross-repository head inside the organisation is matched on the HEAD repository" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#12 holder=live:1:9000010/vim" \
  "$(pr devantler-tech/demo 12 claude/tool-11 devantler-tech tool)"
expect "a base-repository checkout of the same branch name is not a cross-repository head's checkout" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#13 holder=none" \
  "$(pr devantler-tech/demo 13 claude/feature-2 devantler-tech other)"

# ── Who is self ─────────────────────────────────────────────────────────────────────────────────
expect "asked from w2, the session's process in w2 is self and its process in w1 is live" \
  "${w2}" "${session}" 0 \
  "devantler-tech/demo#2 holder=live:2:9000003/node,9000014/-bash+self:1:9000004/sleep" \
  "$(pr devantler-tech/demo 2 claude/feature-2)"
expect "asked from w2, the asker's own ancestor is still self wherever it works" \
  "${w2}" "${session}" 0 \
  "devantler-tech/demo#1 holder=live:2:9000002/claude,9000001/go+self:1:${me}/claude" \
  "$(pr devantler-tech/demo 1 claude/feature-1)"
expect "asked from inside a submodule, the asker's tree is the whole superproject checkout" \
  "${w1}/product" "${session}" 0 \
  "devantler-tech/product#7 holder=live:2:9000002/claude,9000006/sleep+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/product 7 claude/product-7)"
expect "with no session process among the ancestors, only the asker's own ancestry is self" \
  "${w1}" "${plain}" 0 \
  "devantler-tech/demo#1 holder=live:2:9000002/claude,9000001/go+self:1:${me}/testshell" \
  "$(pr devantler-tech/demo 1 claude/feature-1)"
expect "the session's own launcher above it (the app's wrapper) is self, not a rival" \
  "${w1}" "${me} 9000012 claude" 0 \
  "devantler-tech/demo#1 holder=live:1:9000002/claude+self:4:${me}/claude,9000001/go,9000012/disclaimer" \
  "$(pr devantler-tech/demo 1 claude/feature-1)" "${lsof_wrapper}"
expect "shells waiting at a prompt hold nothing, even a terminal tab with a shell under it" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#2 holder=none" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_idle_shells}"
expect "a shell running a command holds its checkout" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#2 holder=live:1:9000014/-bash" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_busy_shell}"
expect "an outer session that launched the asking one is live, not part of the asker" \
  "${w1}" "${me} 9000011 claude" 0 \
  "devantler-tech/demo#2 holder=live:4:9000011/codex,9000003/node,9000004/sleep" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_outer}"

# ── Several PRs at once ─────────────────────────────────────────────────────────────────────────
expect "an array answers every PR in input order" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#3 holder=none
devantler-tech/demo#2 holder=live:3:9000003/node,9000004/sleep,9000014/-bash
devantler-tech/demo#5 holder=fork" \
  "$(jq -sc . <<<"$(pr devantler-tech/demo 3 claude/nobody-3) $(pr devantler-tech/demo 2 claude/feature-2) $(pr devantler-tech/demo 5 x someone)")"
expect "paginated arrays answer every PR in page order" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#3 holder=none
devantler-tech/demo#5 holder=fork" \
  "[$(pr devantler-tech/demo 3 claude/nobody-3)]
[$(pr devantler-tech/demo 5 x someone)]"
expect "an empty PR list prints nothing" "${w1}" "${session}" 0 "" '[]'

# ── UNKNOWN is never none ───────────────────────────────────────────────────────────────────────
expect "a partial lsof (output, but a nonzero exit) is unknown, not the holders it printed" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#2 holder=unknown:lsof-failed
devantler-tech/demo#5 holder=fork" \
  "$(jq -sc . <<<"$(pr devantler-tech/demo 2 claude/feature-2) $(pr devantler-tech/demo 5 x someone)")" \
  "${lsof_full}" 1
expect "a failed lsof with no output is unknown, never none" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lsof-failed" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_empty}" 1
expect "an lsof that lists no working directory at all is unknown, never none" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lsof-empty" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_empty}" 0
expect "a failed process-table read is unknown" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#2 holder=unknown:ps-failed" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_full}" 0 1

# ── Unreadable input ────────────────────────────────────────────────────────────────────────────
expect "a PR without a head branch is unknown input" "${w1}" "${session}" 2 \
  "devantler-tech/demo#6 holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/pull/6","headRepositoryOwner":{"login":"devantler-tech"}}'
expect "a PR without a head owner is unknown input, not a guess at fork or not" "${w1}" "${session}" 2 \
  "devantler-tech/demo#6 holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/pull/6","headRefName":"claude/feature-2"}'
expect "a same-owner PR without its head repository is unknown input, not keyed to the base" "${w1}" "${session}" 2 \
  "devantler-tech/demo#6 holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/pull/6","headRefName":"claude/feature-2","headRepositoryOwner":{"login":"devantler-tech"},"headRepository":null}'
expect "a URL that is not a pull request is unknown input" "${w1}" "${session}" 2 \
  "pr[0] holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/issues/6","headRefName":"x","headRepositoryOwner":{"login":"devantler-tech"}}'
expect "a non-object array element is unknown input; the others are still answered" "${w1}" "${session}" 2 \
  "devantler-tech/demo#3 holder=none
pr[1] holder=unknown:input" \
  "[$(pr devantler-tech/demo 3 claude/nobody-3),\"oops\"]"
expect "stdin that is not JSON is unknown input" "${w1}" "${session}" 2 "? holder=unknown:input" 'not json'
expect "a JSON scalar is unknown input" "${w1}" "${session}" 2 "? holder=unknown:input" '"text"'
expect "empty stdin is unknown input" "${w1}" "${session}" 2 "? holder=unknown:input" ''

# ── Usage ───────────────────────────────────────────────────────────────────────────────────────
checks=$((checks + 1))
usage_rc=0
"${tool}" </dev/null >/dev/null 2>&1 || usage_rc=$?
if [ "${usage_rc}" = 2 ]; then
  echo "ok   no --input - is a usage error (exit 2)"
else
  echo "FAIL no --input - must exit 2, got ${usage_rc}" >&2
  failures=$((failures + 1))
fi

finished=1
if [ "${failures}" -ne 0 ]; then
  echo "pr-worktree-holder.test.sh: ${failures} of ${checks} checks FAILED" >&2
  exit 1
fi
echo "pr-worktree-holder.test.sh: all ${checks} checks passed"
