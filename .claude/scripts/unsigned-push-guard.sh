#!/usr/bin/env bash
# unsigned-push-guard.sh — refuse to push a branch that adds a commit with no signature.
#
# WHY THIS EXISTS (monorepo#3322)
#   Every recent unsigned lane commit that reached a merged pull request was traced to the
#   run that made it, and every one was self-inflicted: three were real commits made with
#   `-c commit.gpgsign=false` (the throwaway-fixture pattern, carried into a real worktree),
#   and one was written through the REST contents API. None was a session that lost its
#   signing configuration. unsigned-commit-report.sh sees these only after they merge; this
#   checks the commits a branch adds at the one moment the author can still fix them —
#   before they leave the machine.
#
# USAGE
#   unsigned-push-guard.sh <repo-dir> [<base>]
#     Checks every commit in <base>..HEAD. <base> defaults to the branch's upstream, else
#     origin/main. Run it immediately before `git push`.
#
# WHAT COUNTS
#   git's %G? letter for each commit:
#     N  no signature        -> finding
#     B  bad signature       -> finding
#     anything else          -> a signature is present. `E` (cannot be checked here, e.g. a
#                               missing public key) is NOT this guard's failure class, so it
#                               passes; GitHub's own verification is the authority for it.
#
# EXIT CODES
#   0  every commit in the range carries a signature (an empty range is stated, not assumed)
#   1  at least one commit has no signature or a bad one; each is named
#   2  UNKNOWN: usage error, unresolvable base, or a failed git read. Never read this as clean.
#
# FIXING A FINDING
#   The commit is still local, so re-sign it rather than pushing it:
#     git -C <repo-dir> rebase --exec 'git commit --amend --no-edit -S' <base>
#   and never pass `-c commit.gpgsign=false` to a commit on a real branch.

set -euo pipefail

PROG="$(basename "$0")"
unknown() { printf '%s: UNKNOWN — %s\n' "$PROG" "$*" >&2; exit 2; }

[ $# -ge 1 ] && [ $# -le 2 ] || unknown "usage: $PROG <repo-dir> [<base>]"
repo="$1"
[ -d "$repo" ] || unknown "not a directory: $repo"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || unknown "not a git repository: $repo"

if [ $# -eq 2 ]; then
  base="$2"
elif upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" && [ -n "$upstream" ]; then
  base="$upstream"
else
  base="origin/main"
fi

git --no-replace-objects -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
  || unknown "base does not resolve to a commit: $base"

# Capture first and check the status: piping `git log` straight into the loop would take the
# loop's exit status, so a failed read would print nothing and look like an all-signed range.
if ! log="$(git --no-replace-objects -C "$repo" log --format='%H %G?' "${base}..HEAD")"; then
  unknown "git log failed for ${base}..HEAD"
fi

examined=0
findings=0
while IFS=' ' read -r sha class; do
  [ -n "$sha" ] || continue
  examined=$((examined + 1))
  case "$class" in
    N) findings=$((findings + 1)); printf 'UNSIGNED  %s\n' "$sha" ;;
    B) findings=$((findings + 1)); printf 'BAD-SIG   %s\n' "$sha" ;;
    '') unknown "no signature class reported for $sha" ;;
    *) ;;
  esac
done <<EOF
$log
EOF

printf '%s: examined=%d findings=%d range=%s..HEAD\n' "$PROG" "$examined" "$findings" "$base"
[ "$findings" -eq 0 ] || exit 1
exit 0
