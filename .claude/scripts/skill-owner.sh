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
#
# `--check-reviewed [file]` compares what each skill CLAIMS against the REVIEWED mapping in
# `.claude/bundled-skill-ownership.tsv` (rows `<plugin>\t<skill>\t<owner>`), which lives outside the
# skills so an upstream cannot grant itself a row. Output rows are
# `verdict<TAB>reviewed<TAB>claimed<TAB>skill<TAB>path`, where verdict is MATCH, MISMATCH (the claim
# disagrees with the row — the claim only ever WITHDRAWS, never grants), UNLISTED (bundled but not
# mapped — treated as third-party until a row is reviewed in), STALE (mapped but no longer bundled),
# or UNKNOWN (the claim could not be read). Exit 0 only when every row is MATCH; 1 when any row is
# MISMATCH, UNLISTED or STALE; 2 when anything is UNKNOWN, including a missing or malformed mapping.

set -euo pipefail

PROG="${0##*/}"
SUBMODULE_PATH="libraries/agent-plugins"
PLUGIN_NAME=""            # empty = every plugin bundled at the pin
SOURCE="auto"
ONLY_SKILL=""
FILTER_ONLY=0
CHECK_REVIEWED=0
REVIEWED_FILE=""

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
    # Compare every claimed owner against the REVIEWED mapping (default:
    # .claude/bundled-skill-ownership.tsv under the repo root). Rows become
    # `verdict<TAB>reviewed<TAB>claimed<TAB>skill<TAB>path`; see --help.
    --check-reviewed)
      CHECK_REVIEWED=1; shift
      if [ $# -gt 0 ]; then case "$1" in -*) ;; *) REVIEWED_FILE="$1"; shift ;; esac; fi ;;
    --filter-only)    FILTER_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done

if [ -n "$PLUGIN_NAME" ]; then SCOPE_DESC="plugins/$PLUGIN_NAME/skills/"; else SCOPE_DESC="plugins/*/skills/ (every plugin)"; fi
case "$SOURCE" in auto|submodule|forge) ;; *) usage_die "--source must be auto, submodule or forge" ;; esac

command -v yq >/dev/null 2>&1 || die "yq is required to read skill frontmatter structurally"

PLUGIN_ROOT="plugins/"
# NOTE: SCOPE_DESC is computed above, from PLUGIN_NAME. It is deliberately NOT re-initialised here:
# both `die` messages interpolate it, so blanking it after the fact left them naming an empty scope —
# "enumerated NO skills under '' at <pin>" — on exactly the fail-closed paths whose whole job is to
# tell a reader WHAT could not be established.

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

# The reviewed mapping is loaded and validated WHOLE before any skill is compared: a malformed row
# is a malformed file, not a different owner, because an empty or drifted third field would still
# compare unequal to the claim and read as a MISMATCH somebody has to chase — or, worse, a duplicate
# key would let whichever row came last decide. Malformed is UNKNOWN (exit 2), never a verdict.
REVIEWED_ROWS=""
if [ "$CHECK_REVIEWED" = 1 ]; then
  [ -n "$REVIEWED_FILE" ] || REVIEWED_FILE="$REPO_ROOT/.claude/bundled-skill-ownership.tsv"
  [ -r "$REVIEWED_FILE" ] || die "reviewed mapping '$REVIEWED_FILE' is missing or unreadable — UNKNOWN, never 'nothing is mapped'"
  REVIEWED_ROWS="$(
    awk -F'\t' '
        { sub(/\r$/, "") }
        /^[ \t]*#/ { next }
        { sub(/[ \t]+$/, "") }
        $0 == "" { next }
        NF != 3 || $1 == "" || $2 == "" || $3 == "" { print "MALFORMED: " $0 > "/dev/stderr"; exit 1 }
        # A `#` is only ever a whole-line comment here: stripping it mid-line would rewrite a value
        # (`…/agent-skills#readme` would compare as `…/agent-skills`), and a control character in a
        # key or value would let one row print as two. Both are malformed, never a different owner.
        $1 ~ /[#[:cntrl:]]/ || $2 ~ /[#[:cntrl:]]/ || $3 ~ /[#[:cntrl:]]/ { print "MALFORMED: " $0 > "/dev/stderr"; exit 1 }
        $1 ~ /\// || $2 ~ /\// { print "MALFORMED: " $0 > "/dev/stderr"; exit 1 }
        seen[$1 "\t" $2]++ { print "DUPLICATE: " $0 > "/dev/stderr"; exit 1 }
        { print $1 "\t" $2 "\t" $3 }' "$REVIEWED_FILE"
  )" || die "reviewed mapping '$REVIEWED_FILE' is malformed — UNKNOWN, never a verdict"
  [ -n "$REVIEWED_ROWS" ] || die "reviewed mapping '$REVIEWED_FILE' names no skill — UNKNOWN, never 'nothing is mapped'"
fi

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
  if ! paths="$(git -C "$sub" --no-replace-objects ls-tree -r -z --name-only "$PIN" -- "$PLUGIN_ROOT" 2>/dev/null | tr "\0" "\n" \
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

# One row per skill, in whichever shape the caller asked for. In the default listing the claim IS
# the row. Under --check-reviewed the claim is compared against the reviewed row for the same
# (plugin, skill): equal is MATCH; unequal is MISMATCH, so a self-attested claim can only ever
# withdraw an ownership the reviewed file granted; no reviewed row is UNLISTED; an unreadable claim
# stays UNKNOWN whatever the reviewed row says, because unproven is not proven.

# One row per skill, in whichever shape the caller asked for. In the default listing the claim IS
# the row. Under --check-reviewed the claim is compared against the reviewed row for the same
# (plugin, skill): equal is MATCH; unequal is MISMATCH, so a self-attested claim can only ever
# withdraw an ownership the reviewed file granted; no reviewed row is UNLISTED; an unreadable claim
# stays UNKNOWN whatever the reviewed row says, because unproven is not proven.
DRIFT=0
SEEN_KEYS="
"
# Reviewed-row lookup done in the SHELL, never through `awk -v`: awk expands backslash escapes in
# -v values, so a skill directory named `synce\144` would look up the `synced` row and read MATCH.
# `read` and `[ = ]` compare bytes.
reviewed_owner_for() { # <plugin> <skill> -> stdout: the reviewed owner, or nothing
  local r_plug r_skill r_owner
  while IFS=$'\t' read -r r_plug r_skill r_owner; do
    [ "$r_plug" = "$1" ] && [ "$r_skill" = "$2" ] && { printf '%s' "$r_owner"; return 0; }
  done <<EOF_ROWS
$REVIEWED_ROWS
EOF_ROWS
  return 0
}
emit_row() { # <claimed-owner-or-LOCAL-or-UNKNOWN> <skill> <path>
  local claim="$1" skill="$2" path="$3" plug reviewed verdict
  if [ "$CHECK_REVIEWED" != 1 ]; then
    printf '%s\t%s\t%s\n' "$claim" "$skill" "$path"
    return 0
  fi
  plug="${path#"$PLUGIN_ROOT"}"; plug="${plug%%/*}"
  # A tab, newline or other control character in a claim or a key would let one skill print as two
  # rows — including a forged `MATCH` line for a reader that greps rows. That is UNKNOWN, and the
  # offending bytes are shown as `?` so the row stays one line.
  case "${claim}${skill}${plug}" in *[[:cntrl:]]*)
    claim=UNKNOWN; skill="$(printf '%s' "$skill" | tr '[:cntrl:]' '?')"; path="$(printf '%s' "$path" | tr '[:cntrl:]' '?')"; plug="$(printf '%s' "$plug" | tr '[:cntrl:]' '?')"; status=2 ;;
  esac
  # Keys are newline-delimited on BOTH sides so a key that is a suffix of another (`engineering`
  # inside `agentic-engineering`) cannot satisfy the STALE sweep's containment test.
  SEEN_KEYS="${SEEN_KEYS}${plug}	${skill}
"
  reviewed="$(reviewed_owner_for "$plug" "$skill")"
  if [ "$claim" = UNKNOWN ]; then
    verdict=UNKNOWN
  elif [ -z "$reviewed" ]; then
    verdict=UNLISTED; DRIFT=1
  elif [ "$claim" = "$reviewed" ]; then
    verdict=MATCH
  else
    verdict=MISMATCH; DRIFT=1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$verdict" "${reviewed:--}" "$claim" "$skill" "$path"
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
  body="$(read_blob "$p")" || { emit_row UNKNOWN "$skill" "$p"; status=2; continue; }
  [ -n "$body" ] || { emit_row UNKNOWN "$skill" "$p"; status=2; continue; }
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
    '!!null') emit_row LOCAL "$skill" "$p"; continue ;;
    *) emit_row UNKNOWN "$skill" "$p"; status=2; continue ;;
  esac
  present="$(yq --front-matter=extract '.metadata | has("github-repo")' 2>/dev/null <<<"$body")" \
    || { emit_row UNKNOWN "$skill" "$p"; status=2; continue; }
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
        emit_row UNKNOWN "$skill" "$p"; status=2; continue
      fi
      ;;
    *) emit_row UNKNOWN "$skill" "$p"; status=2; continue ;;
  esac
  emit_row "$owner" "$skill" "$p"
done < <(printf '%s\n' "$paths")

mapping_names_skill() { # <skill> -> 0 when a reviewed row (inside any --plugin scope) names it
  local r_plug r_skill r_owner
  while IFS=$'\t' read -r r_plug r_skill r_owner; do
    [ -n "$r_plug" ] || continue
    if [ -n "$PLUGIN_NAME" ] && [ "$r_plug" != "$PLUGIN_NAME" ]; then continue; fi
    [ "$r_skill" = "$1" ] && return 0
  done <<EOF_ROWS
$REVIEWED_ROWS
EOF_ROWS
  return 1
}
if [ -n "$ONLY_SKILL" ] && [ "$matched" -eq 0 ]; then
  # Under --check-reviewed a skill the mapping names but the bundle no longer carries is exactly
  # the STALE drift the sweep below reports, so fall through to it instead of dying UNKNOWN.
  if [ "$CHECK_REVIEWED" = 1 ] && mapping_names_skill "$ONLY_SKILL"; then
    :
  else
    die "no skill named '$ONLY_SKILL' under '$SCOPE_DESC' at $PIN"
  fi
fi


# A reviewed row the bundle no longer carries is STALE: the file must not outlive the bundle it
# describes, or a skill re-bundled later under a changed upstream would inherit a row nobody
# re-reviewed. Only rows inside the requested scope are swept, so a --plugin or --skill run does not
# report every other plugin's rows as stale.
if [ "$CHECK_REVIEWED" = 1 ]; then
  while IFS=$'\t' read -r r_plug r_skill r_owner; do
    [ -n "$r_plug" ] || continue
    if [ -n "$PLUGIN_NAME" ] && [ "$r_plug" != "$PLUGIN_NAME" ]; then continue; fi
    if [ -n "$ONLY_SKILL" ] && [ "$r_skill" != "$ONLY_SKILL" ]; then continue; fi
    case "$SEEN_KEYS" in *"
${r_plug}	${r_skill}
"*) continue ;; esac
    printf 'STALE\t%s\t-\t%s\t%s%s/skills/%s/SKILL.md\n' "$r_owner" "$r_skill" "$PLUGIN_ROOT" "$r_plug" "$r_skill"
    DRIFT=1
  done <<EOF_ROWS
$REVIEWED_ROWS
EOF_ROWS
  # UNKNOWN outranks drift: a listing that could not be read is not a verdict about drift.
  if [ "$status" -eq 0 ] && [ "$DRIFT" = 1 ]; then status=1; fi
fi
printf '%s: source=%s pin=%s skills=%d\n' "$PROG" "$resolved_source" "$PIN" "$matched" >&2
exit "$status"
