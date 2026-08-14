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

# The SHARED classifier. Both trees must be classified by the same rule: the reviewed side treating an
# odd path as UNKNOWN while the installed side silently ignored it would leave the same fail-open this
# check exists to close, just mirrored. Prints definition | unclassified | outside.
classify() {
  case "$1" in
    agents/*) rest="${1#agents/}"
      case "$rest" in */*) echo unclassified ;; *.agent.md) echo definition ;; *) echo unclassified ;; esac ;;
    skills/*) rest="${1#skills/}"
      case "$rest" in */*/*) echo unclassified ;; */SKILL.md) echo definition ;; *) echo unclassified ;; esac ;;
    *) echo outside ;;
  esac
}

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
            | awk -F'\t' '{split($1, m, " "); if (m[2]=="blob") print m[3] "\t" $2}')" \
    || die "could not read the pinned tree $GITLINK from $sub"
else
  command -v gh >/dev/null 2>&1 || die "commit $GITLINK is not in the local object database and gh is unavailable"
  # Derived, never hard-coded: --submodule-path is a flag, so a fixed slug here would silently query
  # a different repository than the one whose gitlink was just read.
  url="$(git -C "$REPO_ROOT" config -f .gitmodules --get "submodule.$SUBMODULE_PATH.url" 2>/dev/null)" \
    || die "no .gitmodules url for '$SUBMODULE_PATH' — cannot resolve $GITLINK from the forge"
  slug="${url##*:}"; slug="${slug##*/github.com/}"; slug="${slug%.git}"
  case "$slug" in */*) ;; *) die "could not derive an owner/repo slug from '$url'" ;; esac
  tree="$(gh api "repos/$slug/git/trees/$GITLINK?recursive=1" \
            --jq '.tree[] | select(.type=="blob") | [.sha,.path] | @tsv' 2>/dev/null)" \
    || die "could not read the pinned tree $GITLINK from $slug"
fi
[ -n "$tree" ] || die "pinned revision $GITLINK yielded no tree entries"

# A path INSIDE agents/ or skills/ that matches neither shape is emitted as UNCLASSIFIED rather than
# dropped. Dropping it is a FAIL-OPEN: the reviewed loop would never check it and the EXTRA sweep
# only fires when it is present, so "pinned but unrecognised AND absent from the install" would
# report CURRENT while a whole role definition was missing from the runtime.
#
# The DEFINITION surface only: the agent entrypoints and skill procedures a role actually executes.
# README and the plugin manifest are excluded on purpose — a version bump that moves no definition is
# not a behavioural drift, and firing on it would train the reader to ignore this check.
# Selected by splitting on "/" rather than by a regex: a bracket expression containing a slash is
# not portable inside an awk /…/ literal — BSD awk aborts on it, which this script did until it was
# run for real.
reviewed="$(printf '%s\n' "$tree" \
  | awk -F'\t' -v p="$prefix" '
      index($2,p)==1 {
        rel = substr($2, length(p) + 1)
        n = split(rel, c, "/")
        if (n == 2 && c[1] == "agents" && rel ~ /\.agent\.md$/) print $1 "\t" rel
        else if (n == 3 && c[1] == "skills" && c[3] == "SKILL.md") print $1 "\t" rel
        else if (c[1] == "agents" || c[1] == "skills") print "UNCLASSIFIED\t" rel
      }' \
  | sort -k2,2)"
[ -n "$reviewed" ] || die "pinned revision $GITLINK contains no definition files under $prefix"

# ── compare ────────────────────────────────────────────────────────────────────
drift=0
checked=0
unclassified=0
say "pinned revision : $GITLINK"
say "installed copy  : $INSTALLED"
say ""

while IFS=$'\t' read -r rev_sha rel; do
  [ -n "$rel" ] || continue
  if [ "$rev_sha" = "UNCLASSIFIED" ]; then
    say "UNKNOWN  $rel  (inside the definition directories but not a shape this check can compare)"
    unclassified=$((unclassified + 1))
    continue
  fi
  checked=$((checked + 1))
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
  if [ "$own_sha" = "$rev_sha" ]; then
    say "match    $rel"
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
inst_list="$(mktemp)"
trap 'rm -f "$inst_list"' EXIT
inst_dirs=""
for d in agents skills; do
  [ -d "$INSTALLED/$d" ] && inst_dirs="$inst_dirs $INSTALLED/$d"
done
if [ -n "$inst_dirs" ]; then
  # shellcheck disable=SC2086  # deliberate word splitting: zero, one or two directories
  find $inst_dirs -type f > "$inst_list" \
    || die "could not enumerate the installed definitions under $INSTALLED"
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  rel="${path#"$INSTALLED"/}"
  case "$(classify "$rel")" in
    outside) continue ;;
    unclassified)
      say "UNKNOWN  $rel  (installed, inside the definition directories, but not a shape this check can compare)"
      unclassified=$((unclassified + 1))
      continue ;;
  esac
  if ! printf '%s\n' "$reviewed" | awk -F'\t' -v r="$rel" '$2==r{found=1} END{exit !found}'; then
    say "EXTRA    $rel  (installed but absent from the pinned revision)"
    drift=$((drift + 1))
  fi
done < <(sort "$inst_list")

say ""
if [ "$unclassified" -gt 0 ]; then
  say "UNKNOWN — $unclassified path(s) in the definition directories could not be classified, so this"
  say "check cannot vouch for the installed copy. Widen the selector, or verify those paths by hand."
  exit 2
fi
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
