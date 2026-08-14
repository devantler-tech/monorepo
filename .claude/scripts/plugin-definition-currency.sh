#!/usr/bin/env bash
# plugin-definition-currency.sh — is the definition the runtime LOADED the one the consumer PINNED?
#
# The deployment verifies that chain everywhere except its last link. `agent-role-delivery-contract`
# hashes the desired state against the repository submodule at the gitlink, and monorepo#2736 tracks
# the gitlink against upstream `main` — but the copy the agent and skill entrypoints are actually
# served from is a runtime-managed install with no writer at all. Its staleness is therefore
# unbounded: nothing advances it, and nothing notices. Measured 2026-08-14 on the Claude instance,
# all five definition files differed from the pin and had not moved in 20 days, while both existing
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
# Exit 0  every installed definition file matches the pinned revision
#      1  DRIFT — at least one differs, is missing, or is unexpected
#      2  UNKNOWN — could not determine (usage error, unresolvable install, unreachable revision)
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

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --plugins-root) PLUGINS_ROOT="${2:-}"; shift 2 ;;
    --gitlink) GITLINK="${2:-}"; shift 2 ;;
    --installed) INSTALLED="${2:-}"; shift 2 ;;
    --submodule-path) SUBMODULE_PATH="${2:-}"; shift 2 ;;
    --plugin-id) PLUGIN_ID="${2:-}"; shift 2 ;;
    --plugin-name) PLUGIN_NAME="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# ── the PINNED revision ────────────────────────────────────────────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
[ -d "$REPO_ROOT" ] || die "repo root does not exist: $REPO_ROOT"

if [ -z "$GITLINK" ]; then
  # `ls-tree` prints "160000 commit <sha>\t<path>" for a gitlink. Read the sha field.
  GITLINK="$(git -C "$REPO_ROOT" ls-tree HEAD "$SUBMODULE_PATH" | awk '$2=="commit"{print $3}')"
fi
[ -n "$GITLINK" ] || die "no gitlink for '$SUBMODULE_PATH' at HEAD — cannot establish the pinned revision"

# ── the INSTALLED copy ─────────────────────────────────────────────────────────
# Resolved from the runtime's own record rather than guessed from a directory listing: the cache can
# hold several versions at once and only this file says which one is served.
if [ -z "$INSTALLED" ]; then
  registry="$PLUGINS_ROOT/installed_plugins.json"
  [ -r "$registry" ] || die "cannot read the runtime plugin registry: $registry"
  # No `mapfile`: the host runs bash 3.2, where it does not exist and the array would stay empty.
  paths="$(jq -r --arg id "$PLUGIN_ID" '.plugins[$id][]?.installPath // empty' "$registry")"
  [ -n "$paths" ] || die "plugin '$PLUGIN_ID' is not installed in $registry"
  count="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || die "plugin '$PLUGIN_ID' has $count install paths; pass --installed to pick one"
  INSTALLED="$paths"
fi
[ -d "$INSTALLED" ] || die "installed plugin path does not exist: $INSTALLED"

# ── the pinned revision's definition tree ──────────────────────────────────────
# Prefer the local submodule object database (offline, no API budget). Fall back to the forge only
# when the pinned commit is not present locally, which is the normal state of a fresh worktree.
prefix="plugins/$PLUGIN_NAME/"
tree=""
sub="$REPO_ROOT/$SUBMODULE_PATH"
if [ -e "$sub" ] && git -C "$sub" cat-file -e "$GITLINK^{commit}" 2>/dev/null; then
  tree="$(git -C "$sub" ls-tree -r "$GITLINK" -- "$prefix" | awk '$2=="blob"{print $3"\t"$4}')"
else
  command -v gh >/dev/null 2>&1 || die "commit $GITLINK is not in the local object database and gh is unavailable"
  tree="$(gh api "repos/devantler-tech/agent-plugins/git/trees/$GITLINK?recursive=1" \
            --jq '.tree[] | select(.type=="blob") | [.sha,.path] | @tsv' 2>/dev/null)" \
    || die "could not read the pinned tree $GITLINK from the forge"
fi
[ -n "$tree" ] || die "pinned revision $GITLINK yielded no tree entries"

# The DEFINITION surface only: the agent entrypoints and skill procedures a role actually executes.
# README and the plugin manifest are excluded on purpose — a version bump that moves no definition is
# not a behavioural drift, and firing on it would train the reader to ignore this check.
# Selected by splitting on "/" rather than by a regex: a bracket expression containing a slash is
# not portable inside an awk /…/ literal — BSD awk aborts on it, which this script did until it was
# run for real.
reviewed="$(printf '%s\n' "$tree" \
  | awk -v p="$prefix" '
      index($2,p)==1 {
        rel = substr($2, length(p) + 1)
        n = split(rel, c, "/")
        if (n == 2 && c[1] == "agents" && rel ~ /\.agent\.md$/) print $1 "\t" rel
        else if (n == 3 && c[1] == "skills" && c[3] == "SKILL.md") print $1 "\t" rel
      }' \
  | sort -k2,2)"
[ -n "$reviewed" ] || die "pinned revision $GITLINK contains no definition files under $prefix"

# ── compare ────────────────────────────────────────────────────────────────────
drift=0
checked=0
say "pinned revision : $GITLINK"
say "installed copy  : $INSTALLED"
say ""

while IFS=$'\t' read -r rev_sha rel; do
  [ -n "$rel" ] || continue
  checked=$((checked + 1))
  if [ ! -f "$INSTALLED/$rel" ]; then
    say "MISSING  $rel  (reviewed $rev_sha — the installed copy does not have this definition at all)"
    drift=$((drift + 1))
    continue
  fi
  own_sha="$(git hash-object "$INSTALLED/$rel")"
  if [ "$own_sha" = "$rev_sha" ]; then
    say "match    $rel"
  else
    say "DRIFT    $rel  installed=${own_sha:0:12} reviewed=${rev_sha:0:12}"
    drift=$((drift + 1))
  fi
done <<< "$reviewed"

# A definition present in the install but absent from the pin is drift too: it is a role the runtime
# can still dispatch and the reviewed revision no longer describes.
while IFS= read -r path; do
  rel="${path#"$INSTALLED"/}"
  if ! printf '%s\n' "$reviewed" | awk -F'\t' -v r="$rel" '$2==r{found=1} END{exit !found}'; then
    say "EXTRA    $rel  (installed but absent from the pinned revision)"
    drift=$((drift + 1))
  fi
done < <(find "$INSTALLED/agents" "$INSTALLED/skills" \
           \( -name '*.agent.md' -o -name 'SKILL.md' \) -type f 2>/dev/null | sort)

say ""
if [ "$drift" -eq 0 ]; then
  say "CURRENT — $checked definition file(s) match the pinned revision."
  exit 0
fi

say "DRIFT — $drift of $checked definition file(s) differ from the pinned revision."
say ""
say "What to do, in this order:"
say "  1. Do NOT proceed as if the loaded definition were current. Read the reviewed definition at"
say "     $GITLINK and follow that, then report the drift in the run report."
say "  2. Refresh through the runtime's own control plane — the /plugin marketplace update flow."
say "     Never edit the plugin cache: it is read-only evidence."
say "  3. If the refresh needs an interactive session this run cannot open, surface it to the"
say "     maintainer on a declared channel rather than leaving it unreported."
exit 1
