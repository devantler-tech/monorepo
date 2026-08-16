#!/usr/bin/env bash
# plugin-definition-refresh.sh — move the runtime's installed plugin ONTO the consumer's pin,
# and refuse to move it anywhere else.
#
# WHY THIS IS GATED RATHER THAN A PAIR OF COMMANDS
#
# `plugin-definition-currency.sh` (monorepo#2847) detects that the runtime is serving a definition
# other than the pinned one. Nothing applies the update, so the drift re-accumulates — monorepo#2856,
# and measured: a 21-day drift cleared by hand on 2026-08-15 was back within 3.4 hours of the next
# plugin rollout, after which 5 of 6 sessions in the drift window ran a superseded skill file.
#
# The obvious fix is the two commands that cleared it by hand:
#     claude plugin marketplace update <marketplace>
#     claude plugin update <plugin>@<marketplace>
#
# That fix is WRONG, and wrong in the dangerous direction. `plugin update` installs the MARKETPLACE
# LATEST — its own `--help` reads "Update a plugin to the latest version", and it exposes no ref or
# version selector. On 2026-08-15 the marketplace tip happened to BE the pin (`564a6a0f`), which is
# the only reason the by-hand run appeared to install the pinned revision. On 2026-08-16 it was not:
# pin `11b241cc` (4.3.4) against an upstream `main` already at `73109ad9` (4.3.6). Wired into
# pre-flight as-is, those two commands would install definitions this consumer has never reviewed,
# on every dispatch, silently. Stale-install drift at least runs a PREVIOUSLY REVIEWED definition;
# this would run one nobody has read. The cure would be worse than the disease.
#
# So the contract here is: refresh the marketplace, then apply the update ONLY when the revision it
# would install is EXACTLY the pinned one. When it is not, change nothing and say why — a consumer
# gitlink and an upstream tip that have diverged is a real, reportable condition (it tells the
# engineer the gitlink needs bumping), not something to paper over by installing the tip.
#
# It never edits the plugin cache. The cache is read-only evidence; every mutation here goes through
# the runtime's own control plane, which is what AGENTS.md authorises.
#
# Usage: plugin-definition-refresh.sh [--repo-root DIR] [--plugins-root DIR] [--gitlink SHA]
#                                     [--marketplace-dir DIR] [--marketplace NAME]
#                                     [--plugin-id ID] [--submodule-path PATH]
#                                     [--cli PATH] [--dry-run] [--quiet]
#
# Exit 0  the runtime install is now pinned — this run either applied the pin or found it already
#         applied. NOTE: `plugin update` requires a restart, so exit 0 never means THIS run used it.
#      1  the install is NOT on the pin and this run could not safely put it there. The reason is
#         named. Nothing was changed.
#      2  UNKNOWN — could not determine (usage error, no CLI, unreadable pin or marketplace).
#
# Exit 2 is deliberately not exit 1 and never exit 0: "I could not check" is a third answer, and
# collapsing it into either of the verdicts is how a currency control becomes decoration.
set -euo pipefail

REPO_ROOT=""
PLUGINS_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
GITLINK=""
MARKETPLACE_DIR=""
MARKETPLACE="devantler-plugins"
PLUGIN_ID="agentic-engineering@devantler-plugins"
SUBMODULE_PATH="libraries/agent-plugins"
CLI="${CLAUDE_CLI:-}"
DRY_RUN=0
QUIET=0

die() { printf 'plugin-definition-refresh: %s\n' "$*" >&2; exit 2; }
# `shift 2` on a lone trailing flag returns 1, and under `set -e` that would exit with 1 — the code
# that means "not on the pin". A typo must never produce an evidence-free verdict.
need() { [ "$1" -ge 2 ] || die "missing value for $2"; }
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) need $# "$1"; REPO_ROOT="$2"; shift 2 ;;
    --plugins-root) need $# "$1"; PLUGINS_ROOT="$2"; shift 2 ;;
    --gitlink) need $# "$1"; GITLINK="$2"; shift 2 ;;
    --marketplace-dir) need $# "$1"; MARKETPLACE_DIR="$2"; shift 2 ;;
    --marketplace) need $# "$1"; MARKETPLACE="$2"; shift 2 ;;
    --plugin-id) need $# "$1"; PLUGIN_ID="$2"; shift 2 ;;
    --submodule-path) need $# "$1"; SUBMODULE_PATH="$2"; shift 2 ;;
    --cli) need $# "$1"; CLI="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '1,44p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required"

# ── the gate must bind the clone we READ to the plugin the CLI UPDATES ─────────
# `--marketplace` selects the clone whose HEAD becomes `candidate`, while `--plugin-id` names what
# `plugin update` installs. Left independent, `--marketplace staging` would refresh and gate on the
# staging clone while the default id still installed `…@devantler-plugins` — the gate would pass
# against one marketplace and the install would come from another, which is precisely the fail-open
# this script exists to prevent. The qualified id therefore MUST name the same marketplace.
case "$PLUGIN_ID" in
  *@*) [ "${PLUGIN_ID##*@}" = "$MARKETPLACE" ] || die "plugin id '$PLUGIN_ID' names marketplace '${PLUGIN_ID##*@}' but --marketplace is '$MARKETPLACE' — refusing to gate on one marketplace and install from another" ;;
  *) die "plugin id '$PLUGIN_ID' is not marketplace-qualified (expected '<plugin>@$MARKETPLACE')" ;;
esac

# ── the CLI ────────────────────────────────────────────────────────────────────
# Resolved dynamically, never from a baked-in path. The by-hand invocation that worked on
# 2026-08-15 named a literal `claude-code/<version>/` directory; hardcoding that would break
# silently on the next runtime upgrade — the same unbounded-staleness class this script closes.
# The suite asserts the absence of such a literal over the WHOLE file, comments included, because
# a version pinned in prose is how the next reader learns to pin one in code.
if [ -z "$CLI" ]; then
  CLI="$(command -v claude 2>/dev/null || true)"
fi
if [ -z "$CLI" ]; then
  # The app-bundled binary is not on PATH on this host. Pick the highest version present, by
  # version sort rather than mtime — a reinstall can touch an older directory last.
  base="$HOME/Library/Application Support/Claude/claude-code"
  if [ -d "$base" ]; then
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      cand="$base/$v/claude.app/Contents/MacOS/claude"
      [ -x "$cand" ] && { CLI="$cand"; break; }
    done <<EOF
$(ls -1 "$base" 2>/dev/null | sort -t. -k1,1nr -k2,2nr -k3,3nr)
EOF
  fi
fi
[ -n "$CLI" ] && [ -x "$CLI" ] || die "cannot resolve an executable claude CLI (tried --cli, \$CLAUDE_CLI, PATH, and the app bundle) — UNKNOWN, not a verdict"

# ── the PINNED revision ────────────────────────────────────────────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
[ -d "$REPO_ROOT" ] || die "repo root does not exist: $REPO_ROOT"

if [ -z "$GITLINK" ]; then
  # `--no-replace-objects` is load-bearing, exactly as in AGENTS.md *Git safety*: a refs/replace
  # entry for HEAD makes `HEAD:<path>` resolve THROUGH the replacement while `git rev-parse HEAD`
  # still prints the expected commit — so the gate below would faithfully compare against, and then
  # install, an unreviewed revision. That is a fail-open on the one value everything here trusts.
  GITLINK="$(git --no-replace-objects -C "$REPO_ROOT" rev-parse "HEAD:$SUBMODULE_PATH" 2>/dev/null)" \
    || die "cannot read the gitlink for '$SUBMODULE_PATH' at HEAD in $REPO_ROOT"
fi
[ -n "$GITLINK" ] || die "no gitlink for '$SUBMODULE_PATH' at HEAD — cannot establish the pinned revision"

[ -n "$MARKETPLACE_DIR" ] || MARKETPLACE_DIR="$PLUGINS_ROOT/marketplaces/$MARKETPLACE"
[ -d "$MARKETPLACE_DIR" ] || die "marketplace clone not found: $MARKETPLACE_DIR"

say "pinned revision ......... $GITLINK"

# ── serialize refresh → read → apply against overlapping runs ──────────────────
# The gate is a time-of-check/time-of-use pair: this run reads `candidate` from the shared clone,
# then installs from it. Both machine-local lanes dispatch hourly and 46% of runs exceed the hour,
# so a sibling refreshing the SAME clone between those two steps would have this run install a
# revision it never gated on — the exact fail-open the gate exists to close. `mkdir` is the atomic
# primitive here; a lock file written with `>` is not.
LOCK=""
release_lock() { [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null; LOCK=""; }
trap release_lock EXIT INT TERM

if [ "$DRY_RUN" -eq 0 ]; then
  lockdir="$PLUGINS_ROOT/.plugin-definition-refresh.lock"
  # A crashed run must not park the lock forever (the stale-marker lesson from the worktree claim):
  # reap one older than 10 minutes, then contend normally.
  if [ -d "$lockdir" ] && [ -n "$(find "$lockdir" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    say "reaped a stale lock ..... $lockdir"
    rmdir "$lockdir" 2>/dev/null || true
  fi
  lock_wait="${PLUGIN_REFRESH_LOCK_WAIT:-30}"
  tries=0
  until mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -ge "$lock_wait" ] && die "another plugin-definition-refresh holds $lockdir after ${lock_wait}s — UNKNOWN, not a verdict"
    sleep 1
  done
  LOCK="$lockdir"
fi

# ── refresh the marketplace clone, THEN read what an update would install ──────
# Order matters and is asserted by the suite. The clone is its own staleness surface: on 2026-08-15
# it was two days behind, so `plugin update` alone would have landed 4.1.7 against a pinned 4.3.3 —
# a plausible-looking version that is still not the pin.
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry-run ................. skipping 'plugin marketplace update'"
else
  "$CLI" plugin marketplace update "$MARKETPLACE" >/dev/null 2>&1 \
    || die "'plugin marketplace update $MARKETPLACE' failed — cannot establish what an update would install"
fi

candidate="$(git -C "$MARKETPLACE_DIR" rev-parse HEAD 2>/dev/null)" \
  || die "cannot read the marketplace clone HEAD: $MARKETPLACE_DIR"
say "marketplace would install $candidate"

# ── the gate ───────────────────────────────────────────────────────────────────
if [ "$candidate" != "$GITLINK" ]; then
  say ""
  say "NOT-ON-PIN — refusing to apply, nothing changed."
  say "  The marketplace carries $candidate; this consumer pins $GITLINK."
  say "  'plugin update' installs the marketplace LATEST and has no ref selector, so applying it"
  say "  here would install a revision this deployment has not reviewed. That is worse than the"
  say "  stale install it would replace, which at least runs a previously reviewed definition."
  say "  To resolve: bump the '$SUBMODULE_PATH' gitlink to the revision you intend to run, through"
  say "  the normal reviewed rollout, then re-run this. Until then, follow the reviewed definition"
  say "  at the pinned gitlink per AGENTS.md and report the drift."
  exit 1
fi

# ── apply ──────────────────────────────────────────────────────────────────────
registry="$PLUGINS_ROOT/installed_plugins.json"
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry-run ................. marketplace carries the pin; would apply 'plugin update $PLUGIN_ID'"
  exit 0
fi

# A runtime-local mutation is backed up BEFORE it happens, to a timestamped copy naming the reason.
# The registry is not version-controlled, so an unbacked change is a one-way edit.
if [ -r "$registry" ]; then
  backup="$registry.bak-$(date -u +%Y%m%dT%H%M%SZ)-plugin-definition-refresh"
  cp "$registry" "$backup" || die "could not back up the runtime plugin registry: $registry"
  say "backed up ............... $backup"
fi

"$CLI" plugin update "$PLUGIN_ID" >/dev/null 2>&1 \
  || die "'plugin update $PLUGIN_ID' failed after the gate passed — install state is unchanged or partial; re-run and check plugin-definition-currency.sh"

say ""
say "APPLIED — the runtime install now points at the pinned revision $GITLINK."
if command -v jq >/dev/null 2>&1 && [ -r "$registry" ]; then
  # This is a REPORTING nicety and must never change the verdict. A malformed registry makes `jq`
  # exit non-zero; under `set -e` + `pipefail` that aborted the script AFTER a successful apply and
  # BEFORE the declared `exit 0`, reporting a completed apply as a failure. Select inside `jq`
  # (no `head` stage, so no SIGPIPE either) and swallow the status explicitly.
  now="$(jq -r --arg id "$PLUGIN_ID" 'first(.plugins[$id][]?.gitCommitSha // empty) // empty' "$registry" 2>/dev/null || true)"
  if [ -n "$now" ]; then say "  registry now records ... $now"; fi
fi
say "  ⚠️  'plugin update' requires a RESTART to take effect. THIS run keeps executing the"
say "      definition it booted with; the pinned copy is served from the next dispatch onward."
say "      Do not read this exit 0 as 'this run used the new definition' — that would be the same"
say "      fail-open as the drift itself. Verify with plugin-definition-currency.sh next dispatch."
exit 0
