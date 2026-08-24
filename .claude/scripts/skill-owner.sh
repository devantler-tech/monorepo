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
PLUGIN_NAME=""            # empty = every plugin bundled at the pin
SOURCE="auto"
ONLY_SKILL=""
FILTER_ONLY=0

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
    # Test seam. The literal-vs-regex distinction below is only observable on the forge path, where
    # a whole tree listing is filtered in-process; on the submodule path git's pathspec has already
    # filtered literally, so nothing hermetic can exercise it end to end. This mode applies the
    # selector to candidate paths on stdin so the property can be proven without a network call.
    --filter-only)    FILTER_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done

if [ -n "$PLUGIN_NAME" ]; then SCOPE_DESC="plugins/$PLUGIN_NAME/skills/"; else SCOPE_DESC="plugins/*/skills/ (every plugin)"; fi
case "$SOURCE" in auto|submodule|forge) ;; *) usage_die "--source must be auto, submodule or forge" ;; esac

command -v yq >/dev/null 2>&1 || die "yq is required to read skill frontmatter structurally"

PLUGIN_ROOT="plugins/"
SCOPE_DESC=""             # set after argument parsing, for messages only

# PLUGIN_NAME is caller-supplied via --plugin, so it must never reach a regular expression: a name
# containing `.` or `*` would match OTHER plugins' skills, which is a silent wrong answer rather than
# an error. Compare it LITERALLY, then validate only the remaining shape.
#
# The default enumerates EVERY plugin, because ownership is a per-FILE question across the whole
# bundle: `AGENTS.md`'s routing inventory names skills bundled by other plugins (astro, git-commit,
# refactor, test-driven-development, find-skills), and a resolver that silently covered one plugin
# would answer UNKNOWN for them while looking like it had checked. Scoping to one plugin is opt-in
# via --plugin, never the default.
select_skill_paths() { # stdin: candidate paths -> stdout: plugins/<plugin>/skills/<skill>/SKILL.md
  local line rest plug r1 seg2 r2 sk leaf
  while IFS= read -r line; do
    case "$line" in "$PLUGIN_ROOT"*) rest="${line#"$PLUGIN_ROOT"}" ;; *) continue ;; esac
    # Segment-by-segment, so a deeper path cannot pass: `leaf` must be exactly SKILL.md, which a
    # nested `<skill>/sub/SKILL.md` fails because its leaf still carries a slash.
    plug="${rest%%/*}"; r1="${rest#*/}"
    [ "$r1" != "$rest" ] || continue                 # no second segment
    [ -n "$plug" ] || continue
    if [ -n "$PLUGIN_NAME" ] && [ "$plug" != "$PLUGIN_NAME" ]; then continue; fi
    seg2="${r1%%/*}"; r2="${r1#*/}"
    [ "$r2" != "$r1" ] || continue                   # no third segment
    [ "$seg2" = skills ] || continue
    sk="${r2%%/*}"; leaf="${r2#*/}"
    [ "$leaf" != "$r2" ] || continue                 # no fourth segment
    [ "$leaf" = SKILL.md ] || continue
    [ -n "$sk" ] || continue                         # an empty skill segment
    printf '%s\n' "$line"
  done
}
if [ "$FILTER_ONLY" = 1 ]; then
  select_skill_paths
  exit 0
fi

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

sub="$REPO_ROOT/$SUBMODULE_PATH"

resolved_source=""
paths=""

try_submodule() {
  [ -e "$sub" ] || return 1
  git -C "$sub" --no-replace-objects cat-file -e "$PIN^{commit}" 2>/dev/null || return 1
  # NOT `|| true`. `select_skill_paths` returns 0 even when it matches nothing, so the only status
  # this pipeline can carry is the ENUMERATOR's — exactly the one that must not be swallowed. An
  # enumerator that emits some paths and THEN fails leaves `paths` non-empty, so the empty-list guard
  # below cannot catch it, and the resolver would print an authoritative-looking SUBSET and exit 0.
  # A partial listing is the same fail-open as an empty one: absence of a row is a claim about the
  # enumeration, and a half-finished enumeration cannot support it.
  if ! paths="$(git -C "$sub" --no-replace-objects ls-tree -r --name-only "$PIN" -- "$PLUGIN_ROOT" 2>/dev/null \
                  | select_skill_paths)"; then
    paths=""   # discard the partial listing; it must never reach the caller
    return 1
  fi
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
  # Same reasoning as try_submodule: preserve the pipeline status. `jq` STREAMS `.tree[]`, so a
  # malformed element part-way through the array prints every path before it and THEN exits non-zero
  # — a partial listing that is non-empty, which `|| true` would have converted into success.
  if ! paths="$(printf '%s' "$raw" | jq -r '.tree[] | select(.type=="blob") | .path' 2>/dev/null \
                  | select_skill_paths)"; then
    paths=""
    return 1
  fi
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
[ -n "$paths" ] || die "enumerated NO skills under '$SCOPE_DESC' at $PIN via $resolved_source — UNKNOWN, never 'nothing is synced'"

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
  _rest="${p#"$PLUGIN_ROOT"}"; _sk="${_rest#*/}"; _sk="${_sk#skills/}"; skill="${_sk%/SKILL.md}"
  if [ -n "$ONLY_SKILL" ] && [ "$skill" != "$ONLY_SKILL" ]; then continue; fi
  matched=$((matched + 1))
  body="$(read_blob "$p")" || { printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue; }
  [ -n "$body" ] || { printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue; }
  # Structural frontmatter read, never a grep: a grep matches a URL that merely appears in the BODY,
  # accepts a value living under some other mapping, and cannot tell an absent key from an empty one.
  #
  # ABSENT and PRESENT-BUT-INVALID are different answers and must not collapse. `// "LOCAL"` maps an
  # explicit `github-repo: ""` or `github-repo: {…}` onto LOCAL, which asserts local authorship from a
  # malformed declaration — the same fail-open direction as an empty enumeration. So ask whether the
  # key exists first, and accept only a non-empty scalar as a value.
  # `metadata` itself must be a MAPPING before asking what it contains. `(.metadata // {})` maps a
  # present-but-non-mapping value onto `{}` — the `//` alternative fires on `false` and `null` alike —
  # so `metadata: false`, `metadata: 42` and `metadata: "str"` all answer has("github-repo") == false
  # and would be reported LOCAL with exit 0. That asserts local authorship from a malformed
  # declaration, the same fail-open this block exists to close, one level up. Measured: all three
  # yield `false` from the has() form. The tag discriminates cleanly — `!!map` is a real mapping and
  # `!!null` is genuinely absent; anything else is malformed and therefore UNKNOWN.
  # Herestring, NEVER `printf ... | yq`. yq stops reading once it has the front matter, so on any
  # body larger than the pipe buffer printf takes SIGPIPE and `pipefail` turns a successful read
  # into a non-zero status — which the `|| ...=""` fallbacks below then report as UNKNOWN. Real
  # skills are 5–32 KB, so the piped form answered UNKNOWN for EVERY skill on the forge path while
  # the suite passed on few-hundred-byte fixtures. `skill-owner.test.sh` pins this with a fixture
  # deliberately larger than a pipe buffer.
  meta_kind="$(yq --front-matter=extract '.metadata | tag' 2>/dev/null <<<"$body")" || meta_kind=""
  case "$meta_kind" in
    '!!map') ;;
    '!!null') printf 'LOCAL\t%s\t%s\n' "$skill" "$p"; continue ;;
    *) printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue ;;
  esac
  present="$(yq --front-matter=extract '.metadata | has("github-repo")' 2>/dev/null <<<"$body")" \
    || { printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue; }
  case "$present" in
    false) owner="LOCAL" ;;
    true)
      kind="$(yq --front-matter=extract '.metadata.github-repo | tag' 2>/dev/null <<<"$body")" || kind=""
      owner="$(yq --front-matter=extract '.metadata.github-repo' 2>/dev/null <<<"$body")" || owner=""
      case "$kind" in
        # A repository slug is a STRING. yq renders a scalar of any tag as text, so accepting
        # !!int/!!float/!!bool would print `false` or `42` as though it were an owner and exit 0 —
        # the same fail-open direction as an all-LOCAL listing, and harder to spot because the row
        # looks well-formed. A non-string declaration is malformed, so it is UNKNOWN.
        '!!str') ;;
        *) owner="" ;;
      esac
      if [ -z "$owner" ] || [ "$owner" = null ]; then
        printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue
      fi
      ;;
    *) printf 'UNKNOWN\t%s\t%s\n' "$skill" "$p"; status=2; continue ;;
  esac
  printf '%s\t%s\t%s\n' "$owner" "$skill" "$p"
done < <(printf '%s\n' "$paths")

if [ -n "$ONLY_SKILL" ] && [ "$matched" -eq 0 ]; then
  die "no skill named '$ONLY_SKILL' under '$SCOPE_DESC' at $PIN"
fi

printf '%s: source=%s pin=%s skills=%d\n' "$PROG" "$resolved_source" "$PIN" "$matched" >&2
exit "$status"
