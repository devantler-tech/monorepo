#!/usr/bin/env bash
# Tests for codex-worktree-retention.sh (monorepo#4329).
#
# The helper DELETES, so every case is a safety property proved by ablation: each kept fixture
# differs from a removable one in exactly one dimension (age, an open file, uncommitted work,
# an unpushed commit, an open pull request, ownership of the answer), so a helper that removed
# everything could not pass. Every case runs against a fixture Codex home with stub lsof and gh;
# none reads the real ~/.codex of the machine running the suite.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="${script_dir}/codex-worktree-retention.sh"

failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}
ok() { printf 'ok: %s\n' "$*"; }

tmp=$(mktemp -d) || { echo 'cannot create a temp dir' >&2; exit 2; }
tests_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local status=$?
  rm -rf -- "$tmp"
  if [ "$tests_finished" != 1 ]; then
    echo "FAIL: the suite aborted before finishing (status ${status})" >&2
    exit 1
  fi
}
trap cleanup EXIT
tmp=$(cd -P -- "$tmp" && pwd -P) || exit 2

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

home="${tmp}/codex"
root="${home}/worktrees"
bin="${tmp}/bin"
mkdir -p "$root" "$bin" || exit 2
stamp=$(date -v-30d +%Y%m%d%H%M 2>/dev/null || date -d '30 days ago' +%Y%m%d%H%M)

# age <path> makes everything at or below <path> look 30 days old (links included, not followed).
age() { find "$1" -exec touch -h -t "$stamp" {} + 2>/dev/null; }

# Stub lsof: prints `n<path>` for every line of $bin/open, or fails when $bin/lsof-fail exists.
cat > "${bin}/lsof" <<EOF
#!/bin/sh
[ -e '${bin}/lsof-fail' ] && exit 1
printf 'p1\nn/dev/null\n'
[ -f '${bin}/open' ] && sed 's/^/n/' '${bin}/open'
exit 0
EOF
# Stub gh: answers `pr list ... --head <branch>` with 1 for branches listed in $bin/prs, 0
# otherwise, or fails when $bin/gh-fail exists.
cat > "${bin}/gh" <<EOF
#!/bin/sh
[ -e '${bin}/gh-fail' ] && exit 1
branch=''
while [ \$# -gt 0 ]; do [ "\$1" = --head ] && branch=\$2; shift; done
if [ -n "\$branch" ] && [ -f '${bin}/prs' ] && grep -qxF "\$branch" '${bin}/prs'; then echo 1; else echo 0; fi
EOF
chmod +x "${bin}/lsof" "${bin}/gh"

run() {
  CODEX_WORKTREE_RETENTION_HOME="$home" CODEX_WORKTREE_RETENTION_LSOF="${bin}/lsof" \
    CODEX_WORKTREE_RETENTION_GH="${bin}/gh" bash "$impl" "$@" 2>&1
}

# A remote and a helper that makes a clean clone of it inside a task folder.
remote="${tmp}/remote.git"
git init -q --bare -b main "$remote" || exit 2
seed="${tmp}/seed"
git init -q -b main "$seed" && git -C "$seed" commit -q --allow-empty -m init &&
  git -C "$seed" remote add origin "$remote" && git -C "$seed" push -q origin main || exit 2
git -C "$seed" remote set-url origin "https://github.com/devantler-tech/fixture.git" || exit 2
# clone_into <task> clones the remote into <task>/repo, with a GitHub origin the gh stub can name.
clone_into() {
  mkdir -p "$1" && git clone -q "$remote" "$1/repo" &&
    git -C "$1/repo" remote set-url origin "https://github.com/devantler-tech/fixture.git"
}

idle="${root}/idle"         # no checkout, nothing recent: removed
young="${root}/young"       # a file written now: kept
held="${root}/held"         # a process uses it: kept
clean="${root}/clean"       # a clean clone fully on the remote: removed
dirty="${root}/dirty"       # an uncommitted change: kept
ahead="${root}/ahead"       # a commit no remote has: kept
open_pr="${root}/open-pr"   # on the branch of an open pull request: kept
codex_noise="${root}/noise" # only Codex's own .codex/ tool folder untracked: removed
mkdir -p "$idle/sub" "$young" "$held" || exit 2
printf 'x\n' > "$idle/sub/file"
printf 'x\n' > "$young/old" && printf 'x\n' > "$held/file"
clone_into "$clean" && clone_into "$dirty" && clone_into "$ahead" && clone_into "$open_pr" &&
  clone_into "$codex_noise" || exit 2
printf 'change\n' > "$dirty/repo/new-file"
git -C "$ahead/repo" commit -q --allow-empty -m local || exit 2
git -C "$open_pr/repo" switch -q -c codex/feature-1 || exit 2
git -C "$open_pr/repo" update-ref refs/remotes/origin/codex/feature-1 HEAD || exit 2
mkdir -p "$codex_noise/repo/.codex" && printf 'x\n' > "$codex_noise/repo/.codex/state"
printf 'codex/feature-1\n' > "${bin}/prs"
printf '%s\n' "$held" > "${bin}/open"
for d in "$idle" "$young" "$held" "$clean" "$dirty" "$ahead" "$open_pr" "$codex_noise"; do age "$d"; done
printf 'x\n' > "$young/new"

# 1. A dry run reports exactly the removable folders and deletes nothing.
out=$(run dry-run)
rc=$?
[ "$rc" -eq 0 ] || fail "1: a clean dry run exited ${rc}: $out"
for d in "$idle" "$young" "$held" "$clean" "$dirty" "$ahead" "$open_pr" "$codex_noise"; do
  [ -d "$d" ] || fail "1: a dry run removed ${d}"
done
grep -qF 'would remove=3 ' <<<"$out" || fail "1: the dry run did not count three removable folders: $out"
for d in "$idle" "$clean" "$codex_noise"; do
  grep -qF "would remove ${d} " <<<"$out" || fail "1: the dry run did not name ${d}: $out"
done
grep -qF "kept ${held}: a process is using it" <<<"$out" || fail "1: the held folder was not named as in use: $out"
grep -qF "kept ${dirty}: uncommitted changes" <<<"$out" || fail "1: the dirty clone was not named: $out"
grep -qF "kept ${ahead}: unpushed commits" <<<"$out" || fail "1: the unpushed clone was not named: $out"
grep -qF "kept ${open_pr}: open pull request on codex/feature-1" <<<"$out" ||
  fail "1: the open pull request clone was not named: $out"
[ "$failures" -eq 0 ] && ok '1: a dry run names every decision and removes nothing'

# 2. The checks themselves must not write: a dry run leaves an old clone old.
out=$(run dry-run)
grep -qF "would remove ${clean} " <<<"$out" || fail "2: a first dry run made the clean clone look recent: $out"

# 3. A failed open-file list removes nothing and is UNKNOWN.
: > "${bin}/lsof-fail"
out=$(run apply)
rc=$?
rm -f "${bin}/lsof-fail"
[ "$rc" -eq 2 ] || fail "3: an unreadable open-file list exited ${rc}, not 2: $out"
[ -d "$idle" ] && [ -d "$clean" ] || fail '3: a folder was removed although the open-file list failed'

# 4. A failed pull-request lookup keeps the folder whose branch it could not check, and is UNKNOWN.
: > "${bin}/gh-fail"
out=$(run dry-run)
rc=$?
rm -f "${bin}/gh-fail"
[ "$rc" -eq 2 ] || fail "4: a failed pull-request lookup exited ${rc}, not 2: $out"
grep -qF "UNKNOWN: a checkout under ${open_pr} could not be judged; kept" <<<"$out" ||
  fail "4: the folder with an unchecked branch was not kept as UNKNOWN: $out"

# 5. Usage errors: a too-short age, a bad mode, and a root that is a symbolic link.
run apply 6 > /dev/null
[ $? -eq 2 ] || fail '5: an age below 7 days was not refused'
run remove > /dev/null
[ $? -eq 2 ] || fail '5: an unknown mode was not refused'
linked="${tmp}/linked-home"
mkdir -p "$linked" && ln -s "$root" "${linked}/worktrees"
out=$(CODEX_WORKTREE_RETENTION_HOME="$linked" CODEX_WORKTREE_RETENTION_LSOF="${bin}/lsof" \
  CODEX_WORKTREE_RETENTION_GH="${bin}/gh" bash "$impl" apply 2>&1)
[ $? -eq 2 ] || fail "5: a symbolic-link worktrees root was not refused: $out"
[ -d "$idle" ] || fail '5: a folder was removed through a symbolic-link root'

# 6. A task folder that is a symbolic link is never followed or removed.
target="${tmp}/elsewhere"
mkdir -p "$target" && printf 'x\n' > "$target/file" && age "$target"
ln -s "$target" "${root}/link"
touch -h -t "$stamp" "${root}/link"

# 7. Apply removes exactly the removable folders, and prunes a removed git worktree's registration.
wt_repo="${tmp}/wt-main"
git clone -q "$remote" "$wt_repo" || exit 2
wt="${root}/registered/repo"
mkdir -p "${root}/registered" && git -C "$wt_repo" worktree add -q --detach "$wt" main || exit 2
age "${root}/registered"
out=$(run apply)
rc=$?
[ "$rc" -eq 0 ] || fail "7: a clean apply exited ${rc}: $out"
for d in "$idle" "$clean" "$codex_noise" "${root}/registered"; do
  [ -e "$d" ] && fail "7: apply kept the removable ${d}: $out"
done
for d in "$young" "$held" "$dirty" "$ahead" "$open_pr"; do
  [ -d "$d" ] || fail "7: apply removed the kept ${d}"
done
[ -L "${root}/link" ] && [ -f "$target/file" ] || fail '7: a symbolic-link task folder or its target was touched'
wt_list=$(git -C "$wt_repo" worktree list --porcelain) || fail '7: the worktree list could not be read'
grep -qF "$wt" <<<"$wt_list" && fail "7: the removed worktree is still registered in its repository"
grep -qF 'removed=4 ' <<<"$out" || fail "7: apply did not count four removals: $out"

# 8. No Codex worktrees at all is a clean no-op.
out=$(CODEX_WORKTREE_RETENTION_HOME="${tmp}/no-codex" CODEX_WORKTREE_RETENTION_LSOF="${bin}/lsof" \
  CODEX_WORKTREE_RETENTION_GH="${bin}/gh" bash "$impl" apply 2>&1)
[ $? -eq 0 ] && grep -qF 'no Codex worktrees at ' <<<"$out" || fail "8: a missing root was not a clean no-op: $out"

tests_finished=1
if [ "$failures" -gt 0 ]; then
  printf '%d failure(s)\n' "$failures" >&2
  exit 1
fi
echo 'all codex-worktree-retention tests passed'
