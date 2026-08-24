#!/usr/bin/env bash
# Resolve which upstream repository AUTHORS each bundled plugin skill.
#
# WHY THIS EXISTS. `AGENTS.md` makes skill ownership a per-FILE question, because one plugin
# directory mixes locally-authored files with copies synced from several different upstreams, and
# editing a synced copy in the plugin repository is reverted by the `update-agent-skills` workflow
# with no conflict, no CI failure and no signal. The command that question used to be asked with
# globbed the submodule working tree:
#
#     for f in libraries/agent-plugins/plugins/*/skills/*/SKILL.md; do ... done
#
# That cannot run where the rule applies. Runs work in per-run worktrees, where the submodule is
# EMPTY, and the failure looks like an answer rather than an error: under zsh the loop body never
# executes and prints nothing, while under bash the unmatched glob is passed through literally, so
# the loop iterates once on a nonexistent path and exits 0. Neither shell produces an ownership row
# and neither says the enumeration failed, so "no rows" reads as "nothing is synced" — the exact
# inverse of the truth, since 5 of the 6 skills bundled here are upstream-authored.
#
# So this helper reads the skills at the PINNED revision, from a source that exists in a fresh
# worktree, and fails CLOSED: it never prints an all-LOCAL listing it could not actually establish.
#
# Exit codes:
#   0  every requested skill resolved; rows printed as `owner<TAB>skill<TAB>path`
#   1  usage error
#   2  UNKNOWN — the enumeration or a frontmatter read failed, or nothing was enumerated.
#      UNKNOWN is never "everything is local": absence of rows is a claim about the enumeration.
#
# `LOCAL` means the skill declares no `metadata.github-repo` and is therefore authored in the plugin
# repository itself. Any other value is printed VERBATIM so a caller can compare it exactly — a
# prefix-extended lookalike (`agent-skills-v2`) must not be mistaken for the suite upstream.

set -euo pipefail

PROG="${0##*/}"
SUBMODULE_PATH="libraries/agent-plugins"
PLUGIN_NAME="agentic-engineering"
SOURCE="auto"
ONLY_SKILL=""

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
usage_die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
need() { [ "$1" -ge 2 ] || usage_die "$2 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --submodule-path) need $# "$1"; SUBMODULE_PATH="$2"; shift 2 ;;
    --plugin)         need $# "$1"; PLUGIN_NAME="$2";    shift 2 ;;
    --source)         need $# "$1"; SOURCE="$2";         shift 2 ;;
    --skill)          need $# "$1"; ONLY_SKILL="$2";     shift 2 ;;
    --repo-root)      need $# "$1"; REPO_ROOT_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done

case "$SOURCE" in auto|submodule|forge) ;; *) usage_die "--source must be auto, submodule or forge" ;; esac

command -v yq >/dev/null 2>&1 || die "yq is required to read skill frontmatter structurally"

if [ -n "${REPO_ROOT_OVERRIDE:-}" ]; then
  REPO_ROOT="$REPO_ROOT_OVERRIDE"
else
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
[ -d "$REPO_ROOT/.git" ] || [ -f "$REPO_ROOT/.git" ] || die "'$REPO_ROOT' is not a git working tree"

# --no-replace-objects: a refs/replace entry for HEAD makes this resolve through the replacement
# commit while `rev-parse HEAD` still prints the expected value, so the pin would silently name an
# unreviewed revision. Same rule the currency check follows.
gitlink_line="$(git -C "$REPO_ROOT" --no-replace-objects ls-tree HEAD "$SUBMODULE_PATH" 2>/dev/null)" \
  || die "could not read the gitlink for '$SUBMODULE_PATH' at HEAD"
PIN="$(printf '%s' "$gitlink_line" | awk '$2=="commit"{print $3}')"
[ -n "$PIN" ] || die "no gitlink for '$SUBMODULE_PATH' at HEAD — cannot establish the pinned revision"

prefix="plugins/$PLUGIN_NAME/skills/"
sub="$REPO_ROOT/$SUBMODULE_PATH"

resolved_source=""
paths=""

try_submodule() {
  [ -e "$sub" ] || return 1
  git -C "$sub" --no-replace-objects cat-file -e "$PIN^{commit}" 2>/dev/null || return 1
  paths="$(git -C "$sub" --no-replace-objects ls-tree -r --name-only "$PIN" -- "$prefix" 2>/dev/null \
             | grep -E "^${prefix}[^/]+/SKILL\.md$" || true)"
  resolved_source="submodule"
  return 0
}

try_forge() {
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Derived, never hard-coded: --submodule-path is a flag, so a fixed slug would query a different
  # repository than the one whose gitlink was just read.
  local url slug raw
  url="$(git -C "$REPO_ROOT" config -f .gitmodules --get "submodule.$SUBMODULE_PATH.url" 2>/dev/null)" || return 1
  slug="${url##*:}"; slug="${slug##*/github.com/}"; slug="${slug%.git}"
  case "$slug" in */*) ;; *) return 1 ;; esac
  raw="$(gh api "repos/$slug/git/trees/$PIN?recursive=1" 2>/dev/null)" || return 1
  # A truncated response is a PARTIAL tree; treating it as complete would drop a skill silently.
  case "$(printf '%s' "$raw" | jq -r '.truncated // false')" in
    true) return 1 ;;
  esac
  paths="$(printf '%s' "$raw" | jq -r '.tree[] | select(.type=="blob") | .path' 2>/dev/null \
             | grep -E "^${prefix}[^/]+/SKILL\.md$" || true)"
  FORGE_SLUG="$slug"
  resolved_source="forge"
  return 0
}

case "$SOURCE" in
  submodule) try_submodule || die "the submodule at '$SUBMODULE_PATH' cannot supply the pinned tree $PIN" ;;
  forge)     try_forge     || die "the forge cannot supply the pinned tree $PIN" ;;
  auto)      try_submodule || try_forge \
               || die "no source could supply the pinned tree $PIN — populate '$SUBMODULE_PATH' at the pin, or make gh and jq available" ;;
esac

# An EMPTY enumeration is UNKNOWN, never an all-LOCAL listing. This is the whole point of the
# helper: the shape that used to be produced by an unpopulated submodule was silence, and silence
# read as "nothing is synced".
[ -n "$paths" ] || die "enumerated NO skills under '$prefix' at $PIN via $resolved_source — UNKNOWN, never 'nothing is synced'"

read_blob() {
  case "$resolved_source" in
    submodule) git -C "$sub" --no-replace-objects show "$PIN:$1" 2>/dev/null ;;
    forge)     gh api "repos/$FORGE_SLUG/contents/$1?ref=$PIN" -H "Accept: application/vnd.github.raw" 2>/dev/null ;;
  esac
}

status=0
matched=0
# Process substitution, not a here-document: an unquoted heredoc would expand `$` and backticks in a
# path, and a quoted one would not expand `$paths` at all. This keeps the loop in the current shell,
# so `status` and `matched` survive it.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  skill="${p#"$prefix"}"; skill="${skill%/SKILL.md}"
  if [ -n "$ONLY_SKILL" ] && [ "$skill" != "$ONLY_SKILL" ]; then continue; fi
  matched=$((matched + 1))
  body="$(read_blob "$p")" || { printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue; }
  [ -n "$body" ] || { printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue; }
  # Structural frontmatter read, never a grep: a grep matches a URL that merely appears in the BODY,
  # accepts a value living under some other mapping, and cannot tell an absent key from an empty one.
  owner="$(printf '%s\n' "$body" | yq --front-matter=extract '.metadata.github-repo // "LOCAL"' 2>/dev/null)" \
    || { printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue; }
  case "$owner" in ""|null) owner="LOCAL" ;; esac
  printf '%s\t%s\t%s\n' "$owner" "$skill" "$p"
done < <(printf '%s\n' "$paths")

if [ -n "$ONLY_SKILL" ] && [ "$matched" -eq 0 ]; then
  die "no skill named '$ONLY_SKILL' under '$prefix' at $PIN"
fi

printf '%s: source=%s pin=%s skills=%d\n' "$PROG" "$resolved_source" "$PIN" "$matched" >&2
exit "$status"
