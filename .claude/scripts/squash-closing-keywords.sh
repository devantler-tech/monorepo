#!/usr/bin/env bash
# squash-closing-keywords.sh — fail a pull request whose commit messages would close an issue its
# body only marks `Part of` (monorepo#2731).
#
# WHY THIS EXISTS
#   A squash merge copies every commit message on the branch into the squash commit, and GitHub
#   closes each issue a closing keyword there names. So a `Fixes #N` written in an early commit
#   still closes #N after the PR body was corrected to `Part of #N`. On the #2720 squash merge that
#   closed Security parent #2609 with two acceptance criteria unmet and three sub-issues open, while
#   the body correctly said `Fixes #2728` and `Part of #2609`.
#
# USAGE
#   squash-closing-keywords.sh --repo <owner/repo> --body-file <file> --base <rev> --head <rev>
#                              [--repo-dir <dir>]
#
#   Reads the messages of every commit in <base>..<head> (the commits a squash merge would
#   concatenate) from the repository at <repo-dir> (default: the current directory), and compares
#   their closing references against the `Part of` and closing references in the PR body file.
#   A bare `#N` refers to <owner/repo>.
#
# OUTPUT
#   One `OFFENDING` line per issue a commit closes while the body only marks it `Part of`, then the
#   remedy. A summary line always states how many commits were examined.
#
# EXIT CODES
#   0  no commit closes an issue the body marks only `Part of` (an empty range is stated, not assumed)
#   1  at least one such commit; each issue is named with the commit that closes it
#   2  UNKNOWN: usage error, unreadable body file, unresolvable revision, or a failed git read.
#      Never read this as clean.

set -euo pipefail

PROG="$(basename "$0")"
unknown() {
  printf '%s: UNKNOWN — %s\n' "$PROG" "$*" >&2
  exit 2
}

repo='' body_file='' base='' head='' repo_dir='.'
while [ $# -gt 0 ]; do
  case "$1" in
  --repo | --body-file | --base | --head | --repo-dir)
    [ $# -ge 2 ] || unknown "usage: $1 needs a value"
    case "$1" in
    --repo) repo="$2" ;;
    --body-file) body_file="$2" ;;
    --base) base="$2" ;;
    --head) head="$2" ;;
    --repo-dir) repo_dir="$2" ;;
    esac
    shift 2
    ;;
  *) unknown "usage: unknown argument: $1" ;;
  esac
done

if [ -z "$repo" ] || [ -z "$body_file" ] || [ -z "$base" ] || [ -z "$head" ]; then
  unknown "usage: $PROG --repo <owner/repo> --body-file <file> --base <rev> --head <rev> [--repo-dir <dir>]"
fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || unknown "not an owner/repo: $repo"
if [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; then
  unknown "body file is not readable: $body_file"
fi

for rev in "$base" "$head"; do
  git --no-replace-objects -C "$repo_dir" rev-parse --verify --quiet "${rev}^{commit}" >/dev/null ||
    unknown "revision does not resolve to a commit: $rev"
done

repo_lc="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
REF='(#[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+)'
# GitHub needs a closing keyword per issue (`Fixes #1, #2` closes only #1), while `Part of` is this
# portfolio's own convention and may list several issues.
CLOSING="(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]+${REF}"
PART_OF="(^|[^[:alnum:]_])part[[:space:]]+of:?[[:space:]]+${REF}([[:space:]]*(,|&|and)?[[:space:]]*${REF})*"

# refs <pattern> <text> — every issue <pattern> references in <text>, one per line, as a lowercase
# `owner/repo#N` key. A bare `#N` belongs to --repo. Other repositories are kept, because a closing
# keyword in a squash commit closes an issue in any repository the merger can write to.
refs() {
  local ref owner_repo number
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
    '#'*) owner_repo="$repo" number="${ref#\#}" ;;
    [Hh][Tt][Tt][Pp][Ss]://*)
      owner_repo="${ref#*://*/}"
      owner_repo="${owner_repo%/issues/*}"
      number="${ref##*/}"
      ;;
    *) owner_repo="${ref%%#*}" number="${ref##*#}" ;;
    esac
    printf '%s#%s\n' "$owner_repo" "$number"
  done <<<"$({ grep -oiE -- "$1" <<<"$2" || true; } | { grep -oiE -- "$REF" || true; })" |
    tr '[:upper:]' '[:lower:]'
  return 0
}

# display <key> — `#N` for this repository, `owner/repo#N` otherwise.
display() {
  case "$1" in
  "${repo_lc}#"*) printf '#%s' "${1#"${repo_lc}"#}" ;;
  *) printf '%s' "$1" ;;
  esac
}

# The body as GitHub renders it: an HTML comment (template guidance, a stale edit) links nothing,
# so a `Fixes #N` left inside one must not mask a commit that closes #N.
body="$(awk '
  {
    line = $0
    out = ""
    while (line != "") {
      if (in_comment) {
        i = index(line, "-->")
        if (i == 0) { line = "" } else { line = substr(line, i + 3); in_comment = 0 }
      } else {
        i = index(line, "<!--")
        if (i == 0) { out = out line; line = "" } else {
          out = out substr(line, 1, i - 1); line = substr(line, i + 4); in_comment = 1
        }
      }
    }
    print out
  }
' "$body_file")" || unknown "body file could not be read: $body_file"
# The issues the body marks Part of without also closing them: the only ones a commit must not close.
part_only="$(comm -23 <(refs "$PART_OF" "$body" | sort -u) <(refs "$CLOSING" "$body" | sort -u))"

# Capture first and check the status: a failed read inside a pipeline or loop would print nothing
# and look like a range with no offending commit.
commits="$(git --no-replace-objects -C "$repo_dir" rev-list --reverse "${base}..${head}")" ||
  unknown "git rev-list failed for ${base}..${head}"

examined=0 findings=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  examined=$((examined + 1))
  message="$(git --no-replace-objects -C "$repo_dir" log -1 --format=%B "$sha")" ||
    unknown "git log failed for $sha"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    grep -qxF -- "$issue" <<<"$part_only" || continue
    findings=$((findings + 1))
    printf 'OFFENDING %s: commit %s ("%s") closes it, but the PR body only marks it Part of %s\n' \
      "$(display "$issue")" "${sha:0:12}" "${message%%$'\n'*}" "$(display "$issue")"
  done <<<"$(refs "$CLOSING" "$message" | sort -u)"
done <<<"$commits"

printf '%s: examined=%d findings=%d range=%s..%s\n' "$PROG" "$examined" "$findings" "$base" "$head"
if [ "$findings" -gt 0 ]; then
  cat <<'EOF'
A squash merge copies every commit message into the squash commit, and GitHub closes each issue a
closing keyword there names, whatever the PR body says. Make the two agree:
  - if the issue should close, change the body's `Part of #N` to `Fixes #N`; otherwise
  - remove the closing keyword from each commit above. That rewrites branch history, so do it only
    where your repository's rules allow it; else carry the change on a fresh branch whose commit
    messages do not close the issue, and open the pull request from there.
EOF
  exit 1
fi
