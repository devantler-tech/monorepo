#!/usr/bin/env bash
# plugin-definition-currency.sh — is the definition the runtime LOADED the one the consumer PINNED?
#
# The deployment verifies that chain everywhere except its last link. `agent-role-delivery-contract`
# hashes the desired state against the repository submodule at the gitlink, and monorepo#2736 tracks
# the gitlink against upstream `main` — but the copy the agent and skill entrypoints are actually
# served from is a runtime-managed install with no writer at all. Its staleness is therefore
# unbounded: nothing advances it, and nothing notices. Measured 2026-08-14 on the Claude instance,
# 7 of 9 definition files differed from the pin and had not moved in 20 days, while both existing
# controls read clean. See monorepo#2847.
#
# READ-ONLY. It never edits, and never needs write access to, the runtime's plugin install. Refresh
# is a runtime control-plane action (the `/plugin` marketplace update), never a cache edit.
#
# Comparison is by GIT BLOB IDENTITY, not by version string: a version can be bumped without the
# definitions moving, and — the case that actually bit — the definitions can be superseded while the
# installed version string still looks plausible.
#
# Usage: plugin-definition-currency.sh [--repo-root DIR] [--plugins-root DIR] [--gitlink SHA]
#                                      [--installed DIR] [--submodule-path PATH] [--quiet]
#
# Exit 0  every pinned definition file was CLASSIFIED and MATCHED
#      1  DRIFT — at least one differs, is missing, or is unexpected
#      2  UNKNOWN — could not determine (usage error, unresolvable install, unreachable revision,
#         or a path inside the definition directories this script cannot classify)
#
# Any OTHER non-zero status is an unexpected internal failure under `set -e` and also means UNKNOWN.
# Only 0 and 1 are verdicts; a caller must not read anything else as "current". The lone exception
# is `--help`, which exits 0 without checking anything.
#
# Exit 0 is deliberately narrow: every pinned path under the definition directories was recognised
# AND matched, never "everything I happened to recognise matched".
#
# Exit 2 is deliberately NOT exit 0. "I could not check" and "it is current" are different answers,
# and collapsing them is how a currency check becomes decoration.

set -euo pipefail

REPO_ROOT=""
PLUGINS_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
GITLINK=""
INSTALLED=""
SUBMODULE_PATH="libraries/agent-plugins"
PLUGIN_ID="agentic-engineering@devantler-plugins"
PLUGIN_NAME="agentic-engineering"
QUIET=0
nl="\n"

# Named beside every UNKNOWN that a fresh worktree can actually hit. A guard that blocks without
# naming the resolving action is a friction tax the deployment's own hardening rule forbids — and it
# was named on the DRIFT path but not here, which is the path an unattended run reaches first.
RECOVERY="
  To resolve: populate the pinned plugin submodule with .claude/scripts/submodule-init.sh
  libraries/agent-plugins, or make gh available so the pinned tree can be read from the forge.
  UNKNOWN means UNCHECKED: never read it as current, report it, and carry on against the reviewed
  definition at the pinned gitlink — it must never halt a run."

die() { printf 'plugin-definition-currency: %s\n' "$*" >&2; exit 2; }
# `shift 2` on a lone trailing flag returns 1, and under `set -e` that exits the script with 1 — the
# code that means DRIFT. A typo would otherwise produce a silent, evidence-free stale verdict.
need() { [ "$1" -ge 2 ] || die "missing value for $2"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) need $# "$1"; REPO_ROOT="$2"; shift 2 ;;
    --plugins-root) need $# "$1"; PLUGINS_ROOT="$2"; shift 2 ;;
    --gitlink) need $# "$1"; GITLINK="$2"; shift 2 ;;
    --installed) need $# "$1"; INSTALLED="$2"; shift 2 ;;
    --submodule-path) need $# "$1"; SUBMODULE_PATH="$2"; shift 2 ;;
    --plugin-id) need $# "$1"; PLUGIN_ID="$2"; shift 2 ;;
    --plugin-name) need $# "$1"; PLUGIN_NAME="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '1,34p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required"

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }


# ── the PINNED revision ────────────────────────────────────────────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
[ -d "$REPO_ROOT" ] || die "repo root does not exist: $REPO_ROOT"

if [ -z "$GITLINK" ]; then
  # `ls-tree` prints "160000 commit <sha>\t<path>" for a gitlink. Read the sha field.
  # Guarded: an explicitly-passed --repo-root that is not a git repository would otherwise abort
  # with git's own 128 rather than the documented UNKNOWN, and that is the path every caller uses.
  gitlink_line="$(git -C "$REPO_ROOT" ls-tree HEAD "$SUBMODULE_PATH" 2>/dev/null)" \
    || die "cannot read HEAD in $REPO_ROOT — is it a git repository?"
  GITLINK="$(printf '%s\n' "$gitlink_line" | awk '$2=="commit"{print $3}')"
fi
[ -n "$GITLINK" ] || die "no gitlink for '$SUBMODULE_PATH' at HEAD — cannot establish the pinned revision"

# ── the INSTALLED copy ─────────────────────────────────────────────────────────
# Resolved from the runtime's own record rather than guessed from a directory listing: the cache can
# hold several versions at once and only this file says which one is served.
if [ -z "$INSTALLED" ]; then
  # jq is checked HERE, not at the top: it is needed only to read the registry, and every caller
  # that passes --installed (the whole test suite) would otherwise fail for an unrelated reason.
  command -v jq >/dev/null 2>&1 || die "jq is required to read the runtime plugin registry"
  registry="$PLUGINS_ROOT/installed_plugins.json"
  [ -r "$registry" ] || die "cannot read the runtime plugin registry: $registry"
  # No `mapfile`: the host runs bash 3.2, where it does not exist and the array would stay empty.
  # Guarded: malformed JSON, or entries of an unexpected shape, make jq exit 5.
  paths="$(jq -r --arg id "$PLUGIN_ID" '.plugins[$id][]?.installPath // empty' "$registry" 2>/dev/null)" \
    || die "could not parse the runtime plugin registry: $registry"
  [ -n "$paths" ] || die "plugin '$PLUGIN_ID' is not installed in $registry"
  count="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || die "plugin '$PLUGIN_ID' has $count install paths; pass --installed to pick one"
  INSTALLED="$paths"
fi
[ -d "$INSTALLED" ] || die "installed plugin path does not exist: $INSTALLED"

# ── the pinned revision's definition tree ──────────────────────────────────────
# Prefer the local submodule object database (offline, no API budget). Fall back to the forge only
# when the pinned commit is not present locally, which is the normal state of a fresh worktree.
#
# Both branches normalise to "<sha>TAB<path>". The local branch splits the leading
# "<mode> <type> <sha>" on spaces but the PATH on the tab only — reading the whole line with awk's
# default whitespace splitting truncates any path containing a space, and a truncated path is then
# dropped by the selector and invisible on BOTH sides of the comparison.
prefix="plugins/$PLUGIN_NAME/"
tree=""
sub="$REPO_ROOT/$SUBMODULE_PATH"
if [ -e "$sub" ] && git -C "$sub" cat-file -e "$GITLINK^{commit}" 2>/dev/null; then
  tree="$(git -C "$sub" ls-tree -r "$GITLINK" -- "$prefix" 2>/dev/null \
            | awk -F'\t' '{split($1, m, " "); if (m[2]=="blob") print m[3] "\t" m[1] "\t" $2}')" \
    || die "could not read the pinned tree $GITLINK from $sub${RECOVERY}"
else
  command -v gh >/dev/null 2>&1 || die "commit $GITLINK is not in the local object database and gh is unavailable${RECOVERY}"
  command -v jq >/dev/null 2>&1 || die "jq is required to read the pinned tree from the forge"
  # Derived, never hard-coded: --submodule-path is a flag, so a fixed slug here would silently query
  # a different repository than the one whose gitlink was just read.
  url="$(git -C "$REPO_ROOT" config -f .gitmodules --get "submodule.$SUBMODULE_PATH.url" 2>/dev/null)" \
    || die "no .gitmodules url for '$SUBMODULE_PATH' — cannot resolve $GITLINK from the forge${RECOVERY}"
  slug="${url##*:}"; slug="${slug##*/github.com/}"; slug="${slug%.git}"
  case "$slug" in */*) ;; *) die "could not derive an owner/repo slug from '$url'" ;; esac
  raw="$(gh api "repos/$slug/git/trees/$GITLINK?recursive=1" 2>/dev/null)" \
    || die "could not read the pinned tree $GITLINK from $slug${RECOVERY}"
  # A truncated response is a PARTIAL tree. Comparing it as if complete is a fail-open: a pinned file
  # the API omitted is also absent from `reviewed`, so an install missing it reports CURRENT.
  case "$(printf '%s' "$raw" | jq -r '.truncated // false')" in
    true) die "the forge returned a TRUNCATED tree for $GITLINK — cannot verify completeness${RECOVERY}" ;;
  esac
  tree="$(printf '%s' "$raw" | jq -r '.tree[] | select(.type=="blob") | [.sha,.mode,.path] | @tsv')" \
    || die "could not parse the pinned tree $GITLINK from $slug"
fi
[ -n "$tree" ] || die "pinned revision $GITLINK yielded no tree entries"

# README, the manifest and resources/ stay outside the surface: they sit outside these two
# directories, so a version bump that moves no definition still does not fire.
reviewed="$(printf '%s
' "$tree" \
  | awk -F'	' -v p="$prefix" '
      substr($3,1,1)=="\"" { print "QUOTED" ORS; next }
      index($3,p)==1 {
        rel = substr($3, length(p) + 1)
        if (rel ~ /^agents\// || rel ~ /^skills\//) print $1 "	" $2 "	" rel
      }' \
  | sort -k3,3)"
case "$reviewed" in
  QUOTED*|*"${nl}QUOTED"*) die "the pinned tree contains a path git had to quote (tab, newline or backslash) — cannot verify it${RECOVERY}" ;;
esac
[ -n "$reviewed" ] || die "pinned revision $GITLINK contains no definition files under $prefix"

# ── compare ────────────────────────────────────────────────────────────────────
drift=0
checked=0
say "pinned revision : $GITLINK"
say "installed copy  : $INSTALLED"
say ""

while IFS=$'\t' read -r rev_sha rev_mode rel; do
  [ -n "$rel" ] || continue
  checked=$((checked + 1))
  if [ -L "$INSTALLED/$rel" ]; then
    # -f, `git hash-object` and -x all FOLLOW a symlink, so a definition replaced by a link to an
    # identical file passed every test. The pinned tree has no symlinks (an unsupported mode already
    # fails closed), so a link here is drift by construction.
    say "DRIFT    $rel  installed as a SYMLINK where the pinned revision has a regular file"
    drift=$((drift + 1))
    continue
  fi
  if [ ! -f "$INSTALLED/$rel" ]; then
    say "MISSING  $rel  (reviewed $rev_sha — the installed copy does not have this definition at all)"
    drift=$((drift + 1))
    continue
  fi
  # --no-filters: without it a clean filter (e.g. `* text eol=lf`) normalises the content first, so
  # a CRLF copy and its LF twin hash identically and the "byte identity" promised above is not what
  # was measured.
  own_sha="$(git hash-object --no-filters "$INSTALLED/$rel" 2>/dev/null)" \
    || die "cannot hash the installed definition $INSTALLED/$rel"
  # Mode matters as much as content: a skill helper that loses its executable bit still hashes
  # identically, so a content-only comparison reports `match` while a SKILL.md invoking it fails.
  case "$rev_mode" in
    100644) want_exec=no ;;
    100755) want_exec=yes ;;
    *) die "pinned $rel has unsupported mode $rev_mode — cannot verify it" ;;
  esac
  if [ -x "$INSTALLED/$rel" ]; then have_exec=yes; else have_exec=no; fi
  if [ "$own_sha" = "$rev_sha" ] && [ "$want_exec" = "$have_exec" ]; then
    say "match    $rel"
  elif [ "$own_sha" = "$rev_sha" ]; then
    say "DRIFT    $rel  content matches but mode differs (reviewed executable=$want_exec, installed executable=$have_exec)"
    drift=$((drift + 1))
  else
    say "DRIFT    $rel  installed=${own_sha:0:12} reviewed=${rev_sha:0:12}"
    drift=$((drift + 1))
  fi
done <<< "$reviewed"

# A definition present in the install but absent from the pin is drift too: it is a role the runtime
# can still dispatch and the reviewed revision no longer describes.
#
# Enumerated WITHOUT a filename filter and classified by the shared rule above, so an installed path
# in an unexpected shape is reported rather than skipped. The listing goes through a temp file because
# a process substitution's exit status is not observable — an unreadable subtree would otherwise look
# like an empty one, hiding an extra definition and allowing CURRENT.
# Guarded: an unwritable or exhausted TMPDIR makes mktemp exit 1 under `set -e`, and 1 is the DRIFT
# verdict — an infrastructure failure would have been read as a finding about the install.
inst_list="$(mktemp)" || die "could not create a temporary file (is TMPDIR writable?)"
trap 'rm -f "$inst_list"' EXIT
: > "$inst_list"
for d in agents skills; do
  [ -d "$INSTALLED/$d" ] || continue
  # One quoted invocation per directory: joining them into a string and splitting it would break any
  # installPath containing whitespace, turning a MATCHING install into UNKNOWN.
  find "$INSTALLED/$d" \( -type f -o -type l \) >> "$inst_list" \
    || die "could not enumerate the installed definitions under $INSTALLED/$d${RECOVERY}"
done

while IFS= read -r path; do
  [ -n "$path" ] || continue
  rel="${path#"$INSTALLED"/}"
  if ! printf '%s\n' "$reviewed" | awk -F'\t' -v r="$rel" '$3==r{found=1} END{exit !found}'; then
    say "EXTRA    $rel  (installed but absent from the pinned revision)"
    drift=$((drift + 1))
  fi
done < <(sort "$inst_list")

say ""
if [ "$drift" -eq 0 ]; then
  say "CURRENT — $checked pinned definition(s) match the installed copy."
  exit 0
fi

# `drift` counts EXTRA files too, which are not among the `checked` pinned definitions — so phrasing
# this as "N of M differ" can print a count larger than its own denominator.
say "DRIFT — $drift finding(s) across $checked pinned definition(s)."
say ""
say "What to do, in this order:"
say "  1. Do NOT proceed as if the loaded definition were current. Read the reviewed definition at"
say "     $GITLINK and follow that, then report the drift in the run report."
say "  2. Refresh through the runtime's own control plane — the /plugin marketplace update flow."
say "     Never edit the plugin cache: it is read-only evidence."
say "  3. If the refresh needs an interactive session this run cannot open, surface it to the"
say "     maintainer on a declared channel rather than leaving it unreported."
exit 1
