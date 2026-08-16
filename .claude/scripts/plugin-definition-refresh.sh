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
#                                     [--marketplace NAME]
#                                     [--plugin-id ID] [--submodule-path PATH]
#                                     [--cli PATH] [--verify-cmd PATH] [--dry-run] [--quiet]
#
# --verify-cmd names the post-apply check (default: .claude/scripts/plugin-definition-currency.sh).
# It is invoked with --repo-root, --plugins-root, --plugin-id, --plugin-name, --gitlink and
# --submodule-path, all bound to the values this run gated on, and its exit status IS the verdict:
# 0 verified, 2 UNKNOWN (preserved, never folded into 1), anything else NOT-ON-PIN.
#
# Exit 0  the runtime install is now pinned, and that was VERIFIED by an independent blob-identity
#         check after the apply — never by `plugin update`'s own exit status, which can report
#         success having repaired nothing. NOTE: `plugin update` requires a restart, so exit 0 still
#         never means THIS run used the new definition.
#      1  the install is NOT on the pin. Either the marketplace could not supply the pinned revision
#         (nothing was changed), or the apply ran and the post-apply check still does not report
#         CURRENT. The reason is named.
#      2  UNKNOWN — no verdict was produced: usage error, no CLI, unreadable pin or marketplace, a
#         marketplace/plugin-id marketplace mismatch, a concurrent run holding the lock, a
#         marketplace worktree whose BYTES do not provably match the pinned commit, an apply whose
#         verification command is unavailable, or --dry-run (a simulation asserts nothing).
#
# Exit 2 is deliberately not exit 1 and never exit 0: "I could not check" is a third answer, and
# collapsing it into either of the verdicts is how a currency control becomes decoration.
set -euo pipefail

REPO_ROOT=""
PLUGINS_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
GITLINK=""
MARKETPLACE="devantler-plugins"
PLUGIN_ID="agentic-engineering@devantler-plugins"
SUBMODULE_PATH="libraries/agent-plugins"
CLI="${CLAUDE_CLI:-}"
VERIFY_CMD="${PLUGIN_REFRESH_VERIFY:-}"
DRY_RUN=0
QUIET=0
# How many registry backups to retain. Overridable so the suite can drive the prune with a small
# bound instead of writing eleven files.
PLUGIN_REFRESH_BACKUP_KEEP="${PLUGIN_REFRESH_BACKUP_KEEP:-10}"

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
    --marketplace) need $# "$1"; MARKETPLACE="$2"; shift 2 ;;
    --plugin-id) need $# "$1"; PLUGIN_ID="$2"; shift 2 ;;
    --submodule-path) need $# "$1"; SUBMODULE_PATH="$2"; shift 2 ;;
    --cli) need $# "$1"; CLI="$2"; shift 2 ;;
    --verify-cmd) need $# "$1"; VERIFY_CMD="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    # Derived, not a hardcoded line count: the header grew past the old `1,44p` and `--help` began
    # truncating mid-sentence, dropping the entire exit-code contract — the most important part of it.
    -h|--help) sed -n '1,/^set -euo pipefail/{/^set -euo pipefail/!p;}' "$0"; exit 0 ;;
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
  #
  # Read the entry MODE, not just the object id. `HEAD:<path>` resolves for ANY tracked path: a
  # regular file yields a blob id and a directory yields a tree id. Both are non-empty, so an
  # emptiness check passes them through, and neither can ever equal a commit id — so the pin gate
  # below reports NOT-ON-PIN and exits 1. That is a fabricated verdict produced by what is actually
  # a configuration error (a mistyped --submodule-path), and the header contract puts that class at
  # exit 2. Requiring mode 160000 is what keeps "I could not check" from being answered as "not on
  # the pin".
  pin_entry="$(git --no-replace-objects -C "$REPO_ROOT" ls-tree HEAD -- "$SUBMODULE_PATH" 2>/dev/null)" \
    || die "cannot read the tree entry for '$SUBMODULE_PATH' at HEAD in $REPO_ROOT"
  [ -n "$pin_entry" ] || die "no entry for '$SUBMODULE_PATH' at HEAD — cannot establish the pinned revision"
  pin_mode="${pin_entry%% *}"
  [ "$pin_mode" = "160000" ] || die "'$SUBMODULE_PATH' is not a submodule at HEAD (tree entry mode $pin_mode, expected 160000) — cannot establish a pinned revision"
  pin_rest="${pin_entry#* }"
  pin_rest="${pin_rest#* }"
  GITLINK="${pin_rest%%$'\t'*}"
fi
[ -n "$GITLINK" ] || die "no gitlink for '$SUBMODULE_PATH' at HEAD — cannot establish the pinned revision"

# DERIVED, never passed in. An overridable directory is a decoy vector: a caller could point this at
# a checkout that happens to equal the pin while both CLI commands still select the runtime
# marketplace by name, so the gate would pass against one tree and `plugin update` would install from
# another. The only way to be sure the tree we inspect is the tree the CLI acts on is to compute it
# from the same two values the CLI uses.
MARKETPLACE_DIR="$PLUGINS_ROOT/marketplaces/$MARKETPLACE"
[ -d "$MARKETPLACE_DIR" ] || die "marketplace clone not found: $MARKETPLACE_DIR"

say "pinned revision ......... $GITLINK"

# ── serialize refresh → read → apply against overlapping runs ──────────────────
# The gate is a time-of-check/time-of-use pair: this run reads `candidate` from the shared clone,
# then installs from it. Both machine-local lanes dispatch hourly and 46% of runs exceed the hour,
# so a sibling refreshing the SAME clone between those two steps would have this run install a
# revision it never gated on — the exact fail-open the gate exists to close. `mkdir` is the atomic
# primitive here; a lock file written with `>` is not.
LOCK=""
# Release only a lock this process still OWNS. A blind rmdir lets a run that overran its lock delete
# a SIBLING's replacement on the way out, which would hand a third run the section while the sibling
# believes it holds it.
release_lock() {
  if [ -n "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
  fi
  LOCK=""
}
# INT/TERM must TERMINATE, not just clean up. A handler that returns normally resumes the script at
# the point of interruption — so releasing the lock here and falling through would carry on into the
# candidate check and `plugin update` with the lock already surrendered, which is precisely the
# unserialized apply the lock exists to prevent. Exit instead and let the EXIT trap do the cleanup.
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$DRY_RUN" -eq 0 ]; then
  lockdir="$PLUGINS_ROOT/.plugin-definition-refresh.lock"
  # A crashed run must not park the lock forever (the stale-marker lesson from the worktree claim),
  # but AGE IS THE WRONG TEST: a refresh that legitimately runs longer than the threshold would have
  # its lock reaped by a sibling, putting two runs in the section at once — the precise failure the
  # lock exists to prevent, now triggered by the reaper itself. Reap on OWNER LIVENESS instead. The
  # lock is runtime-local and both machine-local lanes run on this host, so a pid is meaningful here.
  if [ -d "$lockdir" ]; then
    owner="$(cat "$lockdir/pid" 2>/dev/null || true)"
    if [ -n "$owner" ]; then
      # Ownership published: liveness decides. CLAIM the stale lock before removing it — a blind
      # `rmdir` lets two runs both observe the dead owner, both remove, and the slower one delete the
      # FASTER one's freshly created lock, so both proceed. `mv` onto a unique name is a rename(2):
      # exactly one racer can succeed, and only that one is entitled to reap.
      if ! kill -0 "$owner" 2>/dev/null; then
        stale="$lockdir.stale.$$"
        if mv "$lockdir" "$stale" 2>/dev/null; then
          say "reaped a lock ........... owner $owner is not running"
          rm -rf "$stale"
        fi
      fi
    else
      # No pid yet. `mkdir` is atomic but publishing the pid is a separate step, so a rival that
      # reads the lock in that window would see no owner — treating THAT as abandoned lets it delete
      # a live lock and put two runs in the section. A genuine holder publishes within milliseconds,
      # so an ownerless lock is acquisition-in-progress until a short grace has passed; only after
      # that is it debris from a run that died between the two steps.
      if [ -n "$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        stale="$lockdir.stale.$$"
        if mv "$lockdir" "$stale" 2>/dev/null; then
          say "reaped a lock ........... no owner published after the grace period"
          rm -rf "$stale"
        fi
      fi
    fi
  fi
  lock_wait="${PLUGIN_REFRESH_LOCK_WAIT:-30}"
  tries=0
  until mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -ge "$lock_wait" ] && die "another plugin-definition-refresh holds $lockdir after ${lock_wait}s — UNKNOWN, not a verdict"
    sleep 1
  done
  LOCK="$lockdir"
  printf '%s\n' "$$" > "$lockdir/pid" || die "cannot record lock ownership in $lockdir"
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
  if [ "$DRY_RUN" -eq 1 ]; then
    # A dry run skipped the refresh, so this comparison is against a possibly STALE clone. An actual
    # refresh might bring it exactly to the pin, so the simulation has not established that the
    # marketplace cannot supply it — emitting NOT-ON-PIN here would be a false verdict pointing the
    # caller at a gitlink bump it may not need. Same reason the dry-run success path returns 2.
    say ""
    say "dry-run ................. clone is at $candidate, pin is $GITLINK — but the refresh was"
    say "                          skipped, so this is NOT evidence the marketplace lacks the pin."
    say "dry-run ................. exiting 2 (no verdict)."
    exit 2
  fi
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

# ── the revision matched; now prove the BYTES match too ────────────────────────
# `rev-parse HEAD` answers "which commit is checked out", which is a weaker claim than "these are
# the reviewed bytes" — the same gap AGENTS.md documents for reading the pinned submodule. A
# non-conflicting tracked modification, an assume-unchanged/skip-worktree entry, or a clean/smudge
# filter all leave HEAD equal to the pin while the files `plugin update` actually copies differ. The
# gate would then install unreviewed definitions and report success, which is the exact fail-open
# this script exists to close, one level down.
dirty="$(git -C "$MARKETPLACE_DIR" status --porcelain 2>/dev/null)" \
  || die "cannot read the marketplace worktree status: $MARKETPLACE_DIR"
[ -z "$dirty" ] || die "marketplace worktree is not clean at $candidate — refusing to install bytes that differ from the reviewed commit"

hidden="$(git -C "$MARKETPLACE_DIR" ls-files -v 2>/dev/null | awk '$1 ~ /^[a-z]$/ || $1 == "S"')" \
  || die "cannot read the marketplace index flags: $MARKETPLACE_DIR"
[ -z "$hidden" ] || die "marketplace index hides a modification (assume-unchanged/skip-worktree) — status cannot be trusted here"

# `--no-filters` bypasses the clean stage, so a smudge/clean filter cannot launder the comparison.
bytes_unknown=0; bytes_differ=0
# `-z` (NUL-delimited, with the mode) rather than `--name-only`: the latter C-quotes any name that is
# not plain ASCII, so `hash-object` cannot resolve it and a perfectly clean marketplace would refuse.
# The output must NOT go through command substitution, which strips NUL bytes — stream it via a file.
tree_list="$(mktemp)" || die "cannot create a temporary file for the marketplace tree listing"
git -C "$MARKETPLACE_DIR" --no-replace-objects ls-tree -r -z HEAD > "$tree_list" \
  || { rm -f "$tree_list"; die "cannot enumerate the marketplace tree at $candidate"; }
while IFS= read -r -d '' entry; do
  [ -n "$entry" ] || continue
  # entry is "<mode> <type> <object>\t<path>"
  mode="${entry%% *}"
  # A gitlink is a directory, not a blob: it cannot be byte-hashed, and hashing it would make a clean
  # pinned marketplace refuse. Submodule content is covered by the clean-worktree check above.
  [ "$mode" = "160000" ] && continue
  f="${entry#*$'\t'}"
  [ -n "$f" ] || continue
  want="$(git -C "$MARKETPLACE_DIR" --no-replace-objects rev-parse "HEAD:$f" 2>/dev/null)" || { bytes_unknown=$((bytes_unknown + 1)); continue; }
  if [ "$mode" = "120000" ]; then
    # A symlink's blob holds the TARGET PATH as text, but `hash-object` on the link follows it and
    # hashes the target FILE's contents — so the two never match and a clean marketplace containing
    # any symlink would refuse. Hash the link text instead, which keeps symlinks covered rather than
    # exempting them.
    # `perl`'s readlink returns the target EXACTLY. The shell form `printf '%s' "$(readlink …)"`
    # cannot: command substitution strips every trailing newline, so a target ending in one would
    # hash differently from its blob and refuse a clean marketplace.
    # Name the missing interpreter instead of folding it into `bytes_unknown`. Without this, an
    # absent `perl` makes EVERY symlink entry unverifiable, and the run refuses a perfectly clean
    # pinned marketplace with "could not be byte-verified" — a message naming the wrong cause, with
    # no path from it to the real one. That is the same wedge class as the gitlink and symlink
    # defects above: the guard, not the drift, blocks every future refresh.
    command -v perl >/dev/null 2>&1 \
      || die "perl is required to verify symlink entries (mode 120000) and is not on PATH — install perl or the byte check cannot run"
    got="$(perl -e 'my $t = readlink($ARGV[0]); exit 1 unless defined $t; print $t' "$MARKETPLACE_DIR/$f" 2>/dev/null | git -C "$MARKETPLACE_DIR" hash-object --stdin 2>/dev/null)" || { bytes_unknown=$((bytes_unknown + 1)); continue; }
  else
    got="$(git -C "$MARKETPLACE_DIR" hash-object --no-filters -- "$f" 2>/dev/null)" || { bytes_unknown=$((bytes_unknown + 1)); continue; }
  fi
  { [ -n "$want" ] && [ -n "$got" ]; } || { bytes_unknown=$((bytes_unknown + 1)); continue; }
  [ "$want" = "$got" ] || bytes_differ=$((bytes_differ + 1))
done < "$tree_list"
rm -f "$tree_list"
[ "$bytes_differ" -eq 0 ] || die "$bytes_differ marketplace file(s) differ from the pinned blobs despite HEAD matching — refusing to install"
[ "$bytes_unknown" -eq 0 ] || die "$bytes_unknown marketplace file(s) could not be byte-verified — unproven is not proven, refusing to install"
say "marketplace bytes ....... verified against $candidate"

# ── apply ──────────────────────────────────────────────────────────────────────
registry="$PLUGINS_ROOT/installed_plugins.json"
if [ "$DRY_RUN" -eq 1 ]; then
  # A simulation determines nothing about the install, and exit 0 is defined as "the runtime install
  # IS on the pin". Returning 0 here would let a pre-flight caller read a dry run as a cleared drift.
  say "dry-run ................. marketplace carries the pin; would apply 'plugin update $PLUGIN_ID'"
  say "dry-run ................. exiting 2 (no verdict) — a simulation never asserts the install state"
  exit 2
fi

# A runtime-local mutation is backed up BEFORE it happens, to a timestamped copy naming the reason.
# The registry is not version-controlled, so an unbacked change is a one-way edit.
if [ -r "$registry" ]; then
  backup="$registry.bak-$(date -u +%Y%m%dT%H%M%SZ)-plugin-definition-refresh"
  cp "$registry" "$backup" || die "could not back up the runtime plugin registry: $registry"
  # Bounded retention. Two lanes dispatch hourly, so an unbounded set grows forever while nothing
  # ever reads the old copies. The name embeds a UTC ISO-8601 basic timestamp, so a lexical sort IS
  # chronological. Only this script's own suffix is matched, never an unrelated neighbour.
  #
  # Pruning is hygiene and must NEVER change the verdict — a currency control that fails because it
  # could not delete an old backup would be exactly the guard-wedges-the-run class fixed above —
  # hence the trailing `|| true`.
  ls -1 "$registry".bak-*-plugin-definition-refresh 2>/dev/null \
    | sort -r \
    | tail -n +"$((PLUGIN_REFRESH_BACKUP_KEEP + 1))" \
    | while IFS= read -r stale; do [ -n "$stale" ] && rm -f "$stale"; done || true
  say "backed up ............... $backup"
fi

"$CLI" plugin update "$PLUGIN_ID" >/dev/null 2>&1 \
  || die "'plugin update $PLUGIN_ID' failed after the gate passed — install state is unchanged or partial; re-run and check plugin-definition-currency.sh"

# ── the CLI's exit 0 is NOT proof the install now matches the pin ──────────────
# `plugin update` can report success having repaired nothing — most reachably when the registry
# already advertises the pinned version while the installed definition bytes were modified or
# deleted, which is byte-level drift the version string cannot see. Treating the CLI's status as the
# verdict would let exactly that drift persist indefinitely while this script reported it fixed.
# So the verdict comes from an independent blob-identity check, not from the tool we just ran.
[ -n "$VERIFY_CMD" ] || VERIFY_CMD="$REPO_ROOT/.claude/scripts/plugin-definition-currency.sh"
if [ ! -x "$VERIFY_CMD" ]; then
  say ""
  say "APPLIED, BUT UNVERIFIED — '$VERIFY_CMD' is not executable, so this run cannot assert that the"
  say "  install now matches $GITLINK. The apply happened; the verdict is UNKNOWN, never 0."
  exit 2
fi
# Pass the gated target explicitly — including the RESOLVED pin and submodule path. The verifier
# resolves its own defaults otherwise, so under `--gitlink`/`--submodule-path` it would check a
# different revision than the one that passed this run's gate and could report a correct install as
# drifted. Same bind-the-target defect the marketplace/plugin-id check closes above.
# The plugin NAME is derived from the qualified id rather than left at the verifier's default:
# under a `--plugin-id` override the verifier would otherwise locate the selected plugin's install
# but compare it against the DEFAULT plugin's pinned subtree — a false verdict either way, and one
# that could even validate coincidentally matching files.
PLUGIN_NAME="${PLUGIN_ID%@*}"
"$VERIFY_CMD" --repo-root "$REPO_ROOT" --plugins-root "$PLUGINS_ROOT" --plugin-id "$PLUGIN_ID" \
  --plugin-name "$PLUGIN_NAME" --gitlink "$GITLINK" --submodule-path "$SUBMODULE_PATH" >/dev/null 2>&1 && vrc=0 || vrc=$?
# `if ! cmd` would collapse the verifier's own UNKNOWN into the drift branch, turning "I could not
# check" into "the install is not on the pin" — the exact conflation this script's own exit contract
# forbids, and it would point the caller at the wrong remedy.
case "$vrc" in
  0) : ;;
  2)
    say ""
    say "APPLIED, BUT VERIFICATION IS UNKNOWN — the post-apply check could not determine the state."
    say "  The apply happened; nothing here asserts whether the install is on $GITLINK."
    say "  Re-run plugin-definition-currency.sh directly for the reason."
    exit 2
    ;;
  *)
    say ""
    say "APPLIED, BUT STILL NOT ON THE PIN — the post-apply currency check does not report CURRENT."
    say "  'plugin update' exited 0 without bringing the install to $GITLINK, so the drift persists."
    say "  Re-run plugin-definition-currency.sh for the per-file detail and report it."
    exit 1
    ;;
esac

say ""
say "APPLIED — the runtime install now points at the pinned revision $GITLINK."
say "  verified by ............. $VERIFY_CMD"
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
