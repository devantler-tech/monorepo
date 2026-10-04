#!/usr/bin/env bash
# plugin-definition-currency.sh — is the definition the runtime LOADED the one the consumer PINNED?
#
# The deployment verifies that chain everywhere except its last link. `agent-role-delivery-contract`
# hashes the desired state against the repository submodule at the gitlink, and monorepo#2736 tracks
# the gitlink against upstream `main` — but the machine-local copy the agent and skill entrypoints are
# actually served from is a runtime-managed install. Its staleness can therefore be unbounded.
# Measured 2026-08-14 on the Claude instance, 7 of 9 definition files differed from the pin and had
# not moved in 20 days, while both existing controls read clean. See monorepo#2847. The optional
# git-ref backend compares a declared source revision only; it cannot attest a loaded session.
#
# READ-ONLY. It never edits, and never needs write access to, the runtime's plugin install. Refresh
# is a runtime control-plane action (the `/plugin` marketplace update), never a cache edit. The one
# thing it may add to the consumer repository is objects: when the default branch's tip is not in the
# local object database it fetches that one commit, and moves no ref.
#
# Comparison is by GIT BLOB IDENTITY, not by version string: a version can be bumped without the
# loaded files moving, and — the case that actually bit — the definitions can be superseded while the
# installed version string still looks plausible. The loaded surface is every agent and skill file
# plus every provider-neutral requiredRuntimeAsset declared by this consumer.
#
# WHICH PIN. The deployment's pin is the gitlink its DEFAULT BRANCH records: the one it has ADOPTED.
# The working tree this runs in can hold a different one in either direction, without the lane
# drifting at all. A rollout branch carries a bump that has not merged (measured 2026-09-06: a lane
# byte-identical to the adopted pin read DRIFT against its own unmerged bump), and a checkout taken
# before a rollout merged still carries the previous pin (measured 2026-09-24: an install on the
# live pin read DRIFT from a dispatch-time checkout). A DRIFT verdict opens a lane-drift tracker, so
# either reading files one for a condition that does not exist. See monorepo#3230.
#
# So the verdict is always measured against the adopted pin, and the working tree's own gitlink is
# reported beside it as a separate fact that never changes the verdict or the exit status:
#   ROLLOUT     this branch changes the gitlink; the change is not adopted until it merges
#   SUPERSEDED  the default branch moved the gitlink after this checkout was taken
#   UNADOPTED   the two differ and no common history shows which side moved
# The runtime-asset declaration is read from the same consumer revision as the pin it is checked
# against, so a rollout that declares a new asset cannot turn a current lane into UNKNOWN.
#
# The pin comes from one of three places, and every verdict prints which:
#   (default)          the gitlink at the tip of --remote's default branch, read from the remote now
#   --adopted-ref REF  the gitlink at a consumer revision the caller names: a full commit ID or a
#                      remote-tracking ref (refs/remotes/...). Nothing is fetched, so the caller
#                      owns its freshness, and every verdict says so (CALLER-NAMED PIN). A local
#                      branch or tag is refused: this checkout wrote it, so it shows a proposal.
#   --gitlink SHA      a pin the caller names outright. Neither the adopted nor the working-tree pin
#                      is resolved; the refresh script binds its gated target this way.
# An adopted pin that cannot be read is UNKNOWN. The working tree's gitlink never stands in for it.
# --remote takes the NAME of a configured remote, never a path or URL. Each remote call is bounded
# by PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS (default 20): a remote that does not answer in time is
# UNKNOWN, not a hang.
#
# Usage: plugin-definition-currency.sh [--runtime claude|codex|git-ref] [--repo-root DIR]
#                                      [--plugins-root DIR] [--codex-home DIR]
#                                      [--adopted-ref REF | --gitlink SHA] [--remote NAME]
#                                      [--installed DIR] [--submodule-path PATH]
#                                      [--loaded-ref REF] [--quiet]
#
# git-ref requires --loaded-ref with a full commit ID or fully qualified ref. Its exit 0 means
# source parity only; it does not attest the loaded session, effective runtime state, or authority.
#
# Exit 0  installed paths were CLASSIFIED and MATCHED, or the declared git-ref source matched
#      1  DRIFT — at least one differs, is missing, or is unexpected
#      2  UNKNOWN — could not determine (usage error, unreadable adopted pin, unresolvable install,
#         unreachable revision, or a path inside the definition directories this script cannot
#         classify)
#
# Any OTHER non-zero status is an unexpected internal failure under `set -e` and also means UNKNOWN.
# Only 0 and 1 are verdicts; a caller must not read anything else as "current". The lone exception
# is `--help`, which exits 0 without checking anything.
#
# An installed-backend exit 0 is deliberately narrow: every pinned path under the definition
# directories was recognised AND matched, never "everything I happened to recognise matched".
#
# Exit 2 is deliberately NOT exit 0. "I could not check" and "it is current" are different answers,
# and collapsing them is how a currency check becomes decoration.

set -euo pipefail

REPO_ROOT=""
PLUGINS_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
GITLINK=""
ADOPTED_REF=""
ADOPTED_REF_SET=0
REMOTE="origin"
INSTALLED=""
SUBMODULE_PATH="libraries/agent-plugins"
PLUGIN_ID="agentic-engineering@devantler-plugins"
PLUGIN_NAME="agentic-engineering"
RUNTIME="claude"
LOADED_REF=""
LOADED_REF_SET=0
QUIET=0

# Named beside every UNKNOWN that a fresh worktree can actually hit. A guard that blocks without
# naming the resolving action is a friction tax the deployment's own hardening rule forbids — and it
# was named on the DRIFT path but not here, which is the path an unattended run reaches first.
RECOVERY="
  To resolve: populate the pinned plugin submodule with .claude/scripts/submodule-init.sh
  libraries/agent-plugins, or make gh available so the pinned tree can be read from the forge.
  UNKNOWN means UNCHECKED: never read it as current, report it, and carry on against the reviewed
  definition at the pinned gitlink — it must never halt a run."

# The same rule for the adopted pin. It names the one supported substitute, because the tempting one
# — falling back to the working tree's gitlink — is the defect this resolution exists to remove.
ADOPTED_RECOVERY="
  To resolve: restore access to the remote and re-run. Or fetch the default branch yourself and
  name it, as ONE command, so the check runs only when the fetch succeeded:
    git fetch origin '+refs/heads/main:refs/remotes/origin/main' &&
      plugin-definition-currency.sh --adopted-ref refs/remotes/origin/main ...
  A failed fetch leaves the old ref in place. Naming that ref anyway measures against a pin the
  deployment may have moved off, and can report an install as up to date when it has drifted.
  The working tree's own gitlink is never used instead: on a branch that changes the pin it names a
  proposal, not what the deployment adopted. UNKNOWN means UNCHECKED: never read it as current,
  report it, and carry on against the reviewed definition — it must never halt a run."

die() { printf 'plugin-definition-currency: %s\n' "$*" >&2; exit 2; }
# `shift 2` on a lone trailing flag returns 1, and under `set -e` that exits the script with 1 — the
# code that means DRIFT. A typo would otherwise produce a silent, evidence-free stale verdict.
need() { [ "$1" -ge 2 ] || die "missing value for $2"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) need $# "$1"; RUNTIME="$2"; shift 2 ;;
    --repo-root) need $# "$1"; REPO_ROOT="$2"; shift 2 ;;
    --plugins-root) need $# "$1"; PLUGINS_ROOT="$2"; shift 2 ;;
    --codex-home) need $# "$1"; CODEX_HOME_DIR="$2"; shift 2 ;;
    --gitlink) need $# "$1"; GITLINK="$2"; shift 2 ;;
    --adopted-ref) need $# "$1"; ADOPTED_REF="$2"; ADOPTED_REF_SET=1; shift 2 ;;
    --remote) need $# "$1"; REMOTE="$2"; shift 2 ;;
    --installed) need $# "$1"; INSTALLED="$2"; shift 2 ;;
    --submodule-path) need $# "$1"; SUBMODULE_PATH="$2"; shift 2 ;;
    --plugin-id) need $# "$1"; PLUGIN_ID="$2"; shift 2 ;;
    --plugin-name) need $# "$1"; PLUGIN_NAME="$2"; shift 2 ;;
    --loaded-ref) need $# "$1"; LOADED_REF="$2"; LOADED_REF_SET=1; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) awk '/^set -euo pipefail$/ { exit } { print }' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required"
case "$RUNTIME" in
  claude|codex|git-ref) ;;
  *) die "unsupported runtime '$RUNTIME' (expected claude, codex, or git-ref)" ;;
esac
if [ "$RUNTIME" != claude ] && [ -n "$INSTALLED" ]; then
  die "runtime '$RUNTIME' does not accept --installed; resolve the copy that lane actually loaded"
fi
if [ "$RUNTIME" = git-ref ]; then
  [ -n "$LOADED_REF" ] || die "runtime git-ref requires --loaded-ref"
  if [[ "$LOADED_REF" = refs/* ]]; then
    git check-ref-format "$LOADED_REF" >/dev/null 2>&1 \
      || die "--loaded-ref must be a fully qualified ref or full commit ID"
  elif ! [[ "$LOADED_REF" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
    die "--loaded-ref must be a fully qualified ref or full commit ID"
  fi
elif [ "$LOADED_REF_SET" -eq 1 ]; then
  die "--loaded-ref is only valid with --runtime git-ref"
fi
if [ "$ADOPTED_REF_SET" -eq 1 ]; then
  # Two flags that each name the pin cannot both be honoured, and silently preferring one would
  # report a verdict against a pin the caller did not expect.
  [ -z "$GITLINK" ] || die "--adopted-ref and --gitlink both name the pin; pass only one"
  # Same shape rule as --loaded-ref, for the same reason: a short name such as `origin/main` can be
  # shadowed by a tag, so it does not identify one revision.
  # A ref must be a REMOTE-TRACKING one. A local branch or tag is something this checkout wrote
  # itself: on a rollout branch `refs/heads/<branch>` is the proposal, and naming it would report
  # the unmerged pin as the adopted one.
  if [[ "$ADOPTED_REF" = refs/remotes/* ]]; then
    git check-ref-format "$ADOPTED_REF" >/dev/null 2>&1 \
      || die "--adopted-ref must be a remote-tracking ref (refs/remotes/...) or full commit ID"
  elif [[ "$ADOPTED_REF" = refs/* ]]; then
    die "--adopted-ref '$ADOPTED_REF' is a local ref, which this checkout wrote itself and so cannot show what the deployment adopted — name a remote-tracking ref (refs/remotes/...) or a full commit ID"
  elif ! [[ "$ADOPTED_REF" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
    die "--adopted-ref must be a remote-tracking ref (refs/remotes/...) or full commit ID"
  fi
fi
case "$REMOTE" in
  ''|-*) die "--remote must name a git remote" ;;
esac
# Bounds each remote call below. Validated here, once: the calls run inside command substitutions
# and behind `|| true`, where a bad value would surface as a hang or a confusing git error.
REMOTE_TIMEOUT_SECS="${PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS:-20}"
[[ "$REMOTE_TIMEOUT_SECS" =~ ^[1-9][0-9]{0,2}$ ]] \
  || die "PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS must be a whole number of seconds from 1 to 999, got '$REMOTE_TIMEOUT_SECS'"

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }


# ── the PINNED revision ────────────────────────────────────────────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
[ -d "$REPO_ROOT" ] || die "repo root does not exist: $REPO_ROOT"

PIN_SOURCE=""       # where GITLINK came from; printed with every verdict
ADOPTED_COMMIT=""   # the consumer commit whose gitlink is the adopted pin
ADOPTED_BRANCH=""   # the remote's default branch, when it advertises one
WORKTREE_HEAD=""    # this working tree's HEAD commit
WORKTREE_PIN=""     # the gitlink recorded at that commit
WORKTREE_LINE=""    # the header line describing it
WORKTREE_NOTE=""    # ROLLOUT, SUPERSEDED or UNADOPTED when it is not the adopted pin

# The gitlink a consumer revision records for the plugin submodule. Prints nothing when the path is
# not a gitlink there, and fails only when the revision cannot be read. `ls-tree` prints
# "160000 commit <sha>\t<path>" for a gitlink.
# --no-replace-objects: a refs/replace entry makes `ls-tree` read the REPLACEMENT's tree while
# `rev-parse` still prints the expected commit, so the pin would silently name an unreviewed revision.
gitlink_at() {
  local entry
  entry="$(git -C "$REPO_ROOT" --no-replace-objects ls-tree "$1" -- "$SUBMODULE_PATH" 2>/dev/null)" \
    || return 1
  printf '%s\n' "$entry" | awk '$1 == "160000" && $2 == "commit" { print $3 }'
}

# bounded_remote <seconds> <command...> — run a remote git call that can never hang the check.
# This is a pre-flight step of every dispatch. A remote that accepts the connection and then goes
# silent would otherwise hold it until the caller's own ceiling, not until exit 2. The host has no
# `timeout` binary and its ssh configuration sets no connect timeout, so the bound is a bash-3.2
# watchdog: the command gets its own process group (job control) and the whole group is signalled,
# because git hands the transport to a helper (ssh, git-remote-https) that outlives a kill aimed at
# git alone. Same mechanism as `bounded_remote` in worktree-claim.sh, where each step is explained.
# GIT_TERMINAL_PROMPT=0 and BatchMode: an unattended run must get a failure, never a credential or
# passphrase prompt it cannot answer.
bounded_remote() {
  local secs="$1"
  shift
  local cmd_pid killer_pid rc=0 had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=$secs" "$@" &
  cmd_pid=$!
  (
    sleep "$secs"
    kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  killer_pid=$!
  [ "$had_monitor" -eq 1 ] || set +m
  { wait "$cmd_pid" || rc=$?; } 2>/dev/null
  kill -TERM -"$killer_pid" 2>/dev/null || kill -TERM "$killer_pid" 2>/dev/null || true
  { wait "$killer_pid" || true; } 2>/dev/null
  # TERM only asks. KILL reaps whatever in the group outlived the command.
  kill -KILL -"$cmd_pid" 2>/dev/null || true
  return "$rc"
}

# The tip of the remote's default branch, asked of the remote itself. A local remote-tracking ref is
# only as fresh as the last fetch, and a stale one fails in BOTH directions: an install on the live
# pin reads DRIFT, and an install on the superseded pin reads CURRENT.
resolve_adopted_from_remote() {
  local advertised
  # The remote must be one this repository has CONFIGURED. Git also accepts a path or URL here, and
  # `.` or this repository's own path would answer with the working tree's HEAD: the proposal on a
  # rollout branch, reported as "read from the remote".
  git -C "$REPO_ROOT" config --get "remote.$REMOTE.url" >/dev/null 2>&1 \
    || die "'$REMOTE' is not a configured remote of $REPO_ROOT — the adopted pin is unknown. --remote takes a remote NAME, never a path or URL${ADOPTED_RECOVERY}"
  # A configured remote can still point back at this repository. It would answer with this
  # repository's own HEAD, so it is refused for the same reason as a path.
  local remote_url remote_common own_common
  remote_url="$(git -C "$REPO_ROOT" config --get "remote.$REMOTE.url")"
  if [ -d "$remote_url" ]; then
    remote_common="$(cd "$remote_url" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || remote_common=""
    own_common="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || own_common=""
    if [ -n "$remote_common" ] && [ "$remote_common" = "$own_common" ]; then
      die "remote '$REMOTE' points back at this repository, so it cannot show what the deployment adopted — the adopted pin is unknown${ADOPTED_RECOVERY}"
    fi
  fi
  advertised="$(bounded_remote "$REMOTE_TIMEOUT_SECS" git -C "$REPO_ROOT" \
      -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$REMOTE_TIMEOUT_SECS" \
      ls-remote --symref -- "$REMOTE" HEAD 2>/dev/null)" \
    || die "cannot read the default branch of remote '$REMOTE' from $REPO_ROOT within ${REMOTE_TIMEOUT_SECS}s — the adopted pin is unknown${ADOPTED_RECOVERY}"
  # Two records for HEAD: "ref: refs/heads/<branch>\tHEAD" and "<sha>\tHEAD".
  ADOPTED_BRANCH="$(printf '%s\n' "$advertised" \
    | awk -F'\t' '!seen && $2 == "HEAD" && index($1, "ref: refs/heads/") == 1 { print substr($1, 6); seen = 1 }')"
  ADOPTED_COMMIT="$(printf '%s\n' "$advertised" \
    | awk -F'\t' '!seen && $2 == "HEAD" && index($1, "ref: ") != 1 { print $1; seen = 1 }')"
  [[ "$ADOPTED_COMMIT" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] \
    || die "remote '$REMOTE' advertised no default-branch commit — the adopted pin is unknown${ADOPTED_RECOVERY}"
  if ! git -C "$REPO_ROOT" --no-replace-objects cat-file -e "$ADOPTED_COMMIT^{commit}" 2>/dev/null; then
    # Fetch that one commit and nothing else. The empty --refmap and the bare object id mean no
    # remote-tracking ref moves and FETCH_HEAD is not written, so a check never changes what another
    # session's `origin/main` resolves to. The fetch's own status is not the evidence: the object
    # being readable afterwards is. --no-auto-maintenance: the repository is shared by every
    # session, and this check promises to add objects and nothing else.
    bounded_remote "$REMOTE_TIMEOUT_SECS" git -C "$REPO_ROOT" \
      -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$REMOTE_TIMEOUT_SECS" \
      fetch --quiet --no-tags --no-recurse-submodules --no-auto-maintenance \
      --no-write-fetch-head --refmap= -- "$REMOTE" "$ADOPTED_COMMIT" >/dev/null 2>&1 || true
    git -C "$REPO_ROOT" --no-replace-objects cat-file -e "$ADOPTED_COMMIT^{commit}" 2>/dev/null \
      || die "the default-branch tip $ADOPTED_COMMIT of remote '$REMOTE' is not in the local object database and could not be fetched — the adopted pin is unknown${ADOPTED_RECOVERY}"
  fi
}

if [ -n "$GITLINK" ]; then
  PIN_SOURCE="named by --gitlink; neither the adopted nor the working-tree pin was resolved"
else
  # Guarded: an explicitly-passed --repo-root that is not a git repository would otherwise abort
  # with git's own 128 rather than the documented UNKNOWN, and that is the path every caller uses.
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || die "cannot read $REPO_ROOT as a git repository — the adopted pin is unknown"
  if [ "$ADOPTED_REF_SET" -eq 1 ]; then
    ADOPTED_COMMIT="$(git -C "$REPO_ROOT" --no-replace-objects rev-parse --verify --quiet --end-of-options "$ADOPTED_REF^{commit}" 2>/dev/null)" \
      || die "cannot resolve the adopted revision '$ADOPTED_REF' in $REPO_ROOT — the adopted pin is unknown${ADOPTED_RECOVERY}"
    # Not labelled "adopted": this check did not ask the remote, so it cannot say that. The caller
    # says so, and the notice after the verdict states what that claim rests on.
    PIN_SOURCE="caller-named — the gitlink at $ADOPTED_REF ($ADOPTED_COMMIT), named by --adopted-ref and NOT refreshed by this check"
  else
    resolve_adopted_from_remote
    PIN_SOURCE="adopted — the gitlink at $REMOTE ${ADOPTED_BRANCH:-HEAD} ($ADOPTED_COMMIT), read from the remote by this check"
  fi
  GITLINK="$(gitlink_at "$ADOPTED_COMMIT")" \
    || die "cannot read the tree of the adopted revision $ADOPTED_COMMIT in $REPO_ROOT — the adopted pin is unknown${ADOPTED_RECOVERY}"
  [ -n "$GITLINK" ] \
    || die "no gitlink for '$SUBMODULE_PATH' at the adopted revision $ADOPTED_COMMIT — cannot establish the pinned revision"

  # The working tree's own pin is a second FACT, never a second basis. Everything about it is
  # best-effort: failing to read or classify it must not turn a verdict about the adopted pin into
  # UNKNOWN, so each read falls back to "not established" instead of dying.
  WORKTREE_HEAD="$(git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD 2>/dev/null)" || WORKTREE_HEAD=""
  if [ -n "$WORKTREE_HEAD" ]; then
    WORKTREE_PIN="$(gitlink_at "$WORKTREE_HEAD")" || WORKTREE_PIN=""
  fi
  if [ -z "$WORKTREE_PIN" ]; then
    WORKTREE_LINE="no gitlink readable at HEAD — only the adopted pin was compared"
  elif [ "$WORKTREE_PIN" = "$GITLINK" ]; then
    if [ "$ADOPTED_REF_SET" -eq 1 ]; then
      WORKTREE_LINE="$WORKTREE_PIN at HEAD $WORKTREE_HEAD — the caller-named pin"
    else
      WORKTREE_LINE="$WORKTREE_PIN at HEAD $WORKTREE_HEAD — the adopted pin"
    fi
  else
    # Which side moved is read from the fork point, not from ancestry alone: a branch cut from an
    # older default branch is "behind" by ancestry whether or not it also bumps the gitlink.
    fork_point="$(git -C "$REPO_ROOT" --no-replace-objects merge-base "$ADOPTED_COMMIT" "$WORKTREE_HEAD" 2>/dev/null)" \
      || fork_point=""
    fork_pin=""
    if [ -n "$fork_point" ]; then
      fork_pin="$(gitlink_at "$fork_point")" || fork_pin=""
    fi
    if [ -z "$fork_pin" ]; then
      WORKTREE_NOTE="UNADOPTED"
    elif [ "$fork_pin" = "$WORKTREE_PIN" ]; then
      WORKTREE_NOTE="SUPERSEDED"
    else
      WORKTREE_NOTE="ROLLOUT"
    fi
    WORKTREE_LINE="$WORKTREE_PIN at HEAD $WORKTREE_HEAD — NOT the adopted pin ($WORKTREE_NOTE, explained below)"
  fi
fi

# Printed after the verdict, never instead of it. $1 says how the checked copy relates to the working
# tree's pin. Naming what must NOT be done with this notice is the point: it is the state that used
# to read as DRIFT.
worktree_notice() {
  if [ "$ADOPTED_REF_SET" -eq 1 ]; then
    # Printed with EVERY --adopted-ref verdict. A stale ref and a fresh one produce the same output
    # otherwise, and a CURRENT measured against a stale ref is the fail-open direction.
    say ""
    say "CALLER-NAMED PIN — this check did not ask the remote which pin is adopted. It measured"
    say "  against $ADOPTED_REF as it stands in this repository."
    say "  The verdict above holds for the deployment only if that revision was fetched from the"
    say "  default branch just before this check, and that fetch succeeded. Otherwise it is"
    say "  UNCHECKED: never read it as current."
  fi
  [ -n "$WORKTREE_NOTE" ] || return 0
  say ""
  case "$WORKTREE_NOTE" in
    ROLLOUT)
      say "ROLLOUT — this working tree proposes a pin the deployment has not adopted. Its branch"
      say "  changes the gitlink, and that change is not adopted until it merges." ;;
    SUPERSEDED)
      say "SUPERSEDED — this working tree holds a pin the deployment no longer uses. The default"
      say "  branch moved the gitlink after this checkout was taken." ;;
    *)
      say "UNADOPTED — this working tree holds a pin that is not the adopted one, and no common"
      say "  history shows which side moved." ;;
  esac
  say "    working tree : $WORKTREE_PIN"
  say "    adopted      : $GITLINK"
  say "  $1"
  say "  This describes the WORKING TREE, not the lane. The verdict above is measured against the"
  say "  adopted pin and is the only lane-drift signal: never open, update or close a lane-drift"
  say "  tracker on this notice, and never refresh an install onto a pin that is not adopted."
}

# A declared source ref does not identify what a native harness loaded. Compare only that source
# with the consumer pin; never substitute a sibling runtime's cache for missing loaded-state evidence.
if [ "$RUNTIME" = git-ref ]; then
  source_sub="$REPO_ROOT/$SUBMODULE_PATH"
  [ -e "$source_sub/.git" ] \
    || die "plugin source submodule is not initialised: $source_sub"
  # A plain `git show <ref>:<path>` resolves THROUGH refs/replace. A revision comparison made with
  # --no-replace-objects cannot establish the bytes such a reader sees: a replacement inside THIS
  # submodule changes the source content without changing either compared revision.
  # There is no safe verdict available from a revision comparison, so refuse to produce one.
  # Git's replacement namespace is CONFIGURABLE: GIT_REPLACE_REF_BASE moves it off refs/replace/,
  # and git then honours only that namespace. A scan hard-coded to the default therefore returns
  # nothing while a plain `git show` still resolves through the replacement — the enumeration reads
  # clean and the verdict is issued over unreviewed bytes. Follow the namespace git is actually
  # honouring, and keep scanning the default too so neither placement can hide a replacement.
  replace_base="${GIT_REPLACE_REF_BASE:-refs/replace/}"
  replace_base="${replace_base%/}"
  if [ "$replace_base" = "refs/replace" ]; then
    replaced="$(git -C "$source_sub" for-each-ref --format='%(refname)' 'refs/replace/*' 2>/dev/null)" \
      || die "cannot enumerate replacement refs in $source_sub"
  else
    replaced="$(git -C "$source_sub" for-each-ref --format='%(refname)' \
        'refs/replace/*' "$replace_base/*" 2>/dev/null)" \
      || die "cannot enumerate replacement refs in $source_sub"
  fi
  if [ -n "$replaced" ]; then
    # UNKNOWN reasons must survive --quiet: say() is suppressed when QUIET=1, and every other
    # UNKNOWN path uses die() → stderr. Keep this multi-line explanation on stderr so a quiet
    # caller still sees why the source check refused a verdict.
    {
      printf 'pinned revision        : %s\n\n' "$GITLINK"
      printf 'UNKNOWN — the plugin submodule carries replacement ref(s):\n'
      printf '%s\n' "$replaced" | while IFS= read -r r; do
        [ -n "$r" ] && printf '  %s\n' "$r"
      done
      printf '\nA source reader using plain '\''git show'\'' resolves through refs/replace, so comparing\n'
      printf 'revisions cannot establish the source bytes it reads. Remove the\n'
      printf 'replacement ref, or verify the loaded blobs against the pinned tree directly.\n'
    } >&2
    exit 2
  fi
  loaded_revision="$(git -C "$source_sub" --no-replace-objects rev-parse --verify --end-of-options "$LOADED_REF^{commit}" 2>/dev/null)" \
    || die "cannot resolve source revision '$LOADED_REF' in $source_sub"
  say "pinned revision        : $GITLINK"
  say "pin source             : $PIN_SOURCE"
  [ -z "$WORKTREE_LINE" ] || say "worktree pin           : $WORKTREE_LINE"
  say "declared source revision: $loaded_revision ($LOADED_REF)"
  say ""
  if [ "$loaded_revision" = "$WORKTREE_PIN" ]; then
    source_vs_worktree="The declared source revision is the working tree's pin."
  else
    source_vs_worktree="The declared source revision is not the working tree's pin."
  fi
  if [ "$loaded_revision" = "$GITLINK" ]; then
    say "CURRENT — declared source revision matches the pinned gitlink."
    say "Evidence: source parity only; this does not attest the loaded session."
    worktree_notice "$source_vs_worktree"
    exit 0
  fi
  say "DRIFT — declared source revision $loaded_revision differs from pinned gitlink $GITLINK."
  worktree_notice "$source_vs_worktree"
  say ""
  say "Do not inspect another runtime's cache. Follow the reviewed definition at $GITLINK and"
  say "report that the declared source $LOADED_REF must be reconciled with the consumer pin."
  exit 1
fi

# ── the INSTALLED copy ─────────────────────────────────────────────────────────
if [ -z "$INSTALLED" ] && [ "$RUNTIME" = codex ]; then
  # Enablement is an EFFECTIVE-STATE question. Only the runtime can parse its complete TOML model
  # (including multiline strings and every valid key spelling), so never infer loaded state from
  # line-oriented config text. If either half of the structured query is unavailable, the only safe
  # verdict is UNKNOWN.
  command -v codex >/dev/null 2>&1 \
    || die "codex is required to establish effective plugin state for $CODEX_HOME_DIR"
  command -v jq >/dev/null 2>&1 \
    || die "jq is required to parse Codex runtime state for $CODEX_HOME_DIR"
  if codex_json="$(CODEX_HOME="$CODEX_HOME_DIR" codex plugin list --json 2>/dev/null)"; then
    [ -n "$codex_json" ] \
      || die "Codex runtime state query returned no data for $CODEX_HOME_DIR"
    enabled="$(printf '%s' "$codex_json" | jq -r --arg id "$PLUGIN_ID" '
        if (.installed | type) != "array" then "unparseable"
        else [ .installed[] | select(.pluginId == $id) | .enabled ]
             | if length == 0 then "false" elif any(. == true) then "true" else "false" end
        end
      ' 2>/dev/null)" \
      || die "Codex runtime state query returned malformed JSON for $CODEX_HOME_DIR"
    [ "$enabled" != unparseable ] \
      || die "Codex runtime state query returned an unexpected shape for $CODEX_HOME_DIR"
  else
    die "Codex runtime state query failed for $CODEX_HOME_DIR — cannot establish effective plugin state"
  fi
  [ "$enabled" = true ] \
    || die "plugin '$PLUGIN_ID' is not enabled according to the Codex runtime state query"

  marketplace="${PLUGIN_ID#*@}"
  [ "$marketplace" != "$PLUGIN_ID" ] \
    || die "Codex plugin id '$PLUGIN_ID' has no marketplace suffix"
  codex_cache="$CODEX_HOME_DIR/plugins/cache/$marketplace/$PLUGIN_NAME"
  [ -d "$codex_cache" ] \
    || die "Codex plugin cache does not exist: $codex_cache"
  paths="$(find "$codex_cache" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)" \
    || die "could not enumerate the Codex plugin cache: $codex_cache"
  [ -n "$paths" ] || die "Codex plugin '$PLUGIN_ID' has no cached copy in $codex_cache"
  count="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] \
    || die "Codex plugin '$PLUGIN_ID' has $count cached copies; cannot identify the loaded one"
  INSTALLED="$paths"
elif [ -z "$INSTALLED" ]; then
  # Claude resolves from the runtime's own record rather than guessing from a directory listing: its
  # cache can hold several versions at once and only this registry says which one is served.
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

# A definition present in the install but absent from the pin is drift too: it is a role the runtime
# can still dispatch and the reviewed revision no longer describes.
#
# The installed tree is enumerated ONCE, because it does not depend on which pin it is compared
# against. Enumerated WITHOUT a filename filter and classified by the shared rule below, so an
# installed path in an unexpected shape is reported rather than skipped. Each directory is captured
# on its own so `find`'s exit status is observable — an unreadable subtree would otherwise look like
# an empty one, hiding an extra definition and allowing CURRENT. Captured in a variable, never a
# temporary file: an EXIT trap that removes one can report a `set -u` abort as exit 0 on bash 3.2,
# and exit 0 is this script's CURRENT.
installed_listing=""
for d in agents skills; do
  [ -d "$INSTALLED/$d" ] || continue
  # One quoted invocation per directory: joining them into a string and splitting it would break any
  # installPath containing whitespace, turning a MATCHING install into UNKNOWN.
  listed="$(find "$INSTALLED/$d" \( -type f -o -type l \))" \
    || die "could not enumerate the installed definitions under $INSTALLED/$d${RECOVERY}"
  [ -z "$listed" ] || installed_listing="${installed_listing}${listed}
"
done
installed_listing="$(printf '%s' "$installed_listing" | sort)" \
  || die "could not sort the installed definition listing for $INSTALLED"

# ── the comparison, in two steps that both pins go through ─────────────────────
# The verdict runs them against the pin being measured. A working tree holding a different pin runs
# them a second time in a subshell, where `die` ends only that comparison — so an unreadable
# proposal can never change, delay or suppress the verdict.
desired_state_rel=".claude/plugin-consumption/agentic-engineering.desired-state.json"
prefix="plugins/$PLUGIN_NAME/"
sub="$REPO_ROOT/$SUBMODULE_PATH"
reviewed=""
cmp_drift=0
cmp_checked=0

# Builds `reviewed`: one "<blob>TAB<mode>TAB<path>" record per file of the loaded surface at a pin.
#   $1 pin          the plugin revision
#   $2 declaration  the consumer commit whose desired state declares the runtime assets, or empty
#                   for the working-tree file (--gitlink names a pin without a consumer revision)
#   $3 forge        1 to read a pin absent from the local object database from the forge, 0 to
#                   treat that as unreadable
load_reviewed() {
  local pin="$1" declaration="$2" forge="$3"
  local desired_state runtime_assets runtime_filter tree url slug raw path_safety quoted_record
  local runtime_asset runtime_record runtime_mode

  # Agents and skills are implicit runtime entrypoints. Other executable dependencies are explicit in
  # the provider-neutral desired state; omitting them is how a stale classifier continued to report
  # CURRENT even though the surveyor actually executed it. Read the consumer declaration that the
  # delivery-contract test separately proves byte-identical to the pinned plugin resource.
  command -v jq >/dev/null 2>&1 || die "jq is required to read the provider-neutral runtime assets"
  runtime_filter='
    .spec.source.requiredRuntimeAssets
    | select(type == "array" and length > 0)
    | select(all(.[];
        type == "object"
        and (.path | type == "string" and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$"))
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and .executable == true
      ))
    | select((map(.path) | unique | length) == length)
    | .[].path
  '
  if [ -n "$declaration" ]; then
    # The declaration and the pin come from ONE consumer revision. Read from the working tree while
    # the pin came from the default branch, a rollout that declares a new runtime asset would look
    # for it in a plugin revision that predates it and report UNKNOWN for a lane that is current.
    desired_state="$desired_state_rel at $declaration"
    runtime_assets="$(git -C "$REPO_ROOT" --no-replace-objects cat-file blob "$declaration:$desired_state_rel" 2>/dev/null \
        | jq -er "$runtime_filter" 2>/dev/null)" \
      || die "provider-neutral requiredRuntimeAssets are missing or malformed in $desired_state"
  else
    desired_state="$REPO_ROOT/$desired_state_rel"
    [ -r "$desired_state" ] || die "cannot read the provider-neutral desired state: $desired_state"
    runtime_assets="$(jq -er "$runtime_filter" "$desired_state" 2>/dev/null)" \
      || die "provider-neutral requiredRuntimeAssets are missing or malformed in $desired_state"
  fi
  [ -n "$runtime_assets" ] \
    || die "provider-neutral requiredRuntimeAssets are empty in $desired_state"

  # ── the pinned revision's definition tree ────────────────────────────────────
  # Prefer the local submodule object database (offline, no API budget). Fall back to the forge only
  # when the pinned commit is not present locally, which is the normal state of a fresh worktree.
  #
  # Both branches normalise to "<sha>TAB<path>". The local branch splits the leading
  # "<mode> <type> <sha>" on spaces but the PATH on the tab only — reading the whole line with awk's
  # default whitespace splitting truncates any path containing a space, and a truncated path is then
  # dropped by the selector and invisible on BOTH sides of the comparison.
  tree=""
  # --no-replace-objects on BOTH reads. `cat-file` and `ls-tree` resolve THROUGH refs/replace, so a
  # replacement for the gitlink rewrites the REVIEWED side of the comparison itself: an install
  # carrying the replacement bytes then matches and reports CURRENT. The git-ref branch above refuses a
  # verdict for the same hazard, but it exits before this point, so every other runtime reaches these
  # reads unprotected. Same rule the pin resolution above already follows.
  if [ -e "$sub" ] && git -C "$sub" --no-replace-objects cat-file -e "$pin^{commit}" 2>/dev/null; then
    tree="$(git -C "$sub" --no-replace-objects ls-tree -r "$pin" -- "$prefix" 2>/dev/null \
              | awk -F'\t' '{split($1, m, " "); if (m[2]=="blob") print m[3] "\t" m[1] "\t" $2}')" \
      || die "could not read the pinned tree $pin from $sub${RECOVERY}"
  else
    [ "$forge" -eq 1 ] || die "commit $pin is not in the local object database"
    command -v gh >/dev/null 2>&1 || die "commit $pin is not in the local object database and gh is unavailable${RECOVERY}"
    command -v jq >/dev/null 2>&1 || die "jq is required to read the pinned tree from the forge"
    # Derived, never hard-coded: --submodule-path is a flag, so a fixed slug here would silently query
    # a different repository than the one whose gitlink was just read.
    url="$(git -C "$REPO_ROOT" config -f .gitmodules --get "submodule.$SUBMODULE_PATH.url" 2>/dev/null)" \
      || die "no .gitmodules url for '$SUBMODULE_PATH' — cannot resolve $pin from the forge${RECOVERY}"
    slug="${url##*:}"; slug="${slug##*/github.com/}"; slug="${slug%.git}"
    case "$slug" in */*) ;; *) die "could not derive an owner/repo slug from '$url'" ;; esac
    raw="$(gh api "repos/$slug/git/trees/$pin?recursive=1" 2>/dev/null)" \
      || die "could not read the pinned tree $pin from $slug${RECOVERY}"
    # A truncated response is a PARTIAL tree. Comparing it as if complete is a fail-open: a pinned file
    # the API omitted is also absent from `reviewed`, so an install missing it reports CURRENT.
    case "$(printf '%s' "$raw" | jq -r '.truncated // false')" in
      true) die "the forge returned a TRUNCATED tree for $pin — cannot verify completeness${RECOVERY}" ;;
    esac
    path_safety="$(printf '%s' "$raw" | jq -er '
        if any(.tree[] | select(.type=="blob");
            .path | (contains("\\") or contains("\t") or contains("\r") or contains("\n")))
        then "unsafe" else "safe" end
      ' 2>/dev/null)" \
      || die "could not validate pinned forge paths for $pin from $slug"
    [ "$path_safety" = safe ] \
      || die "the forge tree contains an unsafe path (tab, newline, carriage return or backslash) — cannot serialize it losslessly${RECOVERY}"
    tree="$(printf '%s' "$raw" | jq -r '.tree[] | select(.type=="blob") | [.sha,.mode,.path] | @tsv')" \
      || die "could not parse the pinned tree $pin from $slug"
  fi
  [ -n "$tree" ] || die "pinned revision $pin yielded no tree entries"

  # README, the manifest and resources/ stay outside the surface: a version bump that moves no loaded
  # behaviour still does not fire. Runtime assets are an explicit allow-list, never all of scripts/.
  reviewed="$(printf '%s
' "$tree" \
    | RUNTIME_ASSETS="$runtime_assets" awk -F'	' -v p="$prefix" '
        BEGIN {
          count = split(ENVIRON["RUNTIME_ASSETS"], paths, "\n")
          for (i = 1; i <= count; i++) required[paths[i]] = 1
        }
        substr($3,1,1)=="\"" { print "QUOTED" ORS; next }
        index($3,p)==1 {
          rel = substr($3, length(p) + 1)
          if (rel ~ /^agents\// || rel ~ /^skills\// || required[rel]) print $1 "	" $2 "	" rel
        }' \
    | sort -k3,3)"
  quoted_record="$(printf '%s\n' "$reviewed" | awk '$0=="QUOTED"{print 1; exit}')"
  [ -z "$quoted_record" ] \
    || die "the pinned tree contains a path git had to quote (tab, newline or backslash) — cannot verify it${RECOVERY}"
  [ -n "$reviewed" ] || die "pinned revision $pin contains no definition files under $prefix"

  # A declaration absent from the pinned tree must be UNKNOWN, not silently omitted from both sides.
  # Executability is part of the provider-neutral contract, so a non-executable pin is invalid even if
  # the install happens to carry the same non-executable mode.
  while IFS= read -r runtime_asset; do
    [ -n "$runtime_asset" ] || continue
    runtime_record="$(printf '%s\n' "$reviewed" | awk -F'	' -v r="$runtime_asset" '$3==r{print $2 "\t" $3}')"
    [ -n "$runtime_record" ] \
      || die "required runtime asset '$runtime_asset' is absent from pinned revision $pin"
    runtime_mode="${runtime_record%%$'\t'*}"
    [ "$runtime_mode" = 100755 ] \
      || die "required runtime asset '$runtime_asset' is not executable at pinned revision $pin"
  done <<< "$runtime_assets"
}

installed_path_has_symlink() {
  local rel_path="$1" probe="$INSTALLED" segment
  while [ -n "$rel_path" ]; do
    case "$rel_path" in
      */*) segment="${rel_path%%/*}"; rel_path="${rel_path#*/}" ;;
      *) segment="$rel_path"; rel_path="" ;;
    esac
    probe="$probe/$segment"
    [ ! -L "$probe" ] || return 0
  done
  return 1
}

# Compares the installed copy against `reviewed`, one line per file, and sets cmp_drift (findings)
# and cmp_checked (pinned files compared).
compare_reviewed() {
  local rev_sha rev_mode rel own_sha want_exec have_exec path
  cmp_drift=0
  cmp_checked=0
  while IFS=$'\t' read -r rev_sha rev_mode rel; do
    [ -n "$rel" ] || continue
    cmp_checked=$((cmp_checked + 1))
    if installed_path_has_symlink "$rel"; then
      # -f, `git hash-object` and -x all FOLLOW a symlink, so a definition replaced by a link to an
      # identical file passed every test. Check every component as well as the leaf: a scripts/
      # symlink can redirect a required asset while the final file itself is regular.
      say "DRIFT    $rel  installed through a SYMLINK where the pinned revision has a regular path"
      cmp_drift=$((cmp_drift + 1))
      continue
    fi
    if [ ! -f "$INSTALLED/$rel" ]; then
      say "MISSING  $rel  (reviewed $rev_sha — the installed copy does not have this definition at all)"
      cmp_drift=$((cmp_drift + 1))
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
      cmp_drift=$((cmp_drift + 1))
    else
      say "DRIFT    $rel  installed=${own_sha:0:12} reviewed=${rev_sha:0:12}"
      cmp_drift=$((cmp_drift + 1))
    fi
  done <<< "$reviewed"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rel="${path#"$INSTALLED"/}"
    if ! printf '%s\n' "$reviewed" | awk -F'\t' -v r="$rel" '$3==r{found=1} END{exit !found}'; then
      say "EXTRA    $rel  (installed but absent from the pinned revision)"
      cmp_drift=$((cmp_drift + 1))
    fi
  done <<< "$installed_listing"
}

# ── compare ────────────────────────────────────────────────────────────────────
load_reviewed "$GITLINK" "$ADOPTED_COMMIT" 1
say "pinned revision : $GITLINK"
say "pin source      : $PIN_SOURCE"
[ -z "$WORKTREE_LINE" ] || say "worktree pin    : $WORKTREE_LINE"
say "installed copy  : $INSTALLED"
say ""
compare_reviewed
drift="$cmp_drift"
checked="$cmp_checked"

# The same comparison against the pin the working tree holds, reported as a count only. It runs
# after the verdict's own counts are captured and in a subshell, so nothing it does — including
# dying on a tree it cannot read — reaches them. The forge is not consulted: this is a second fact
# for the reader, and it is not worth an API call or a network failure.
worktree_comparison=""
if [ -n "$WORKTREE_NOTE" ]; then
  set +e
  worktree_counts="$(
    set -e
    QUIET=1
    { load_reviewed "$WORKTREE_PIN" "$WORKTREE_HEAD" 0; compare_reviewed; } >/dev/null 2>&1
    printf '%s %s\n' "$cmp_drift" "$cmp_checked"
  )"
  worktree_status=$?
  set -e
  # Only a completed comparison that printed exactly "<findings> <files>" is reported as one.
  worktree_comparison="Against the working tree's pin the installed copy was not compared: the pin's tree or its runtime-asset declaration is not readable locally."
  if [ "$worktree_status" -eq 0 ] && [[ "$worktree_counts" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
    if [ "${BASH_REMATCH[1]}" -eq 0 ]; then
      worktree_comparison="Against the working tree's pin the installed copy matches all ${BASH_REMATCH[2]} file(s)."
    else
      worktree_comparison="Against the working tree's pin the installed copy shows ${BASH_REMATCH[1]} finding(s) across ${BASH_REMATCH[2]} file(s)."
    fi
  fi
fi

say ""
if [ "$drift" -eq 0 ]; then
  say "CURRENT — $checked pinned loaded file(s) match the installed copy."
  # Scope the verdict explicitly. This compares the INSTALLED copy on disk; the running process
  # executes whatever it loaded at startup, and an install only becomes live on the next dispatch.
  # Left unstated, a CURRENT produced after a concurrent refresh reads as "this run is current" —
  # the fail-open direction, since the run would then follow a superseded definition believing it
  # had verified otherwise.
  say "Scope: this describes the INSTALLED copy on disk, not the definition this process booted."
  say "An install becomes live on the next dispatch, so a run whose install changed mid-flight is"
  say "still executing what it booted; only a LATER run's check establishes that the pin is live."
  worktree_notice "$worktree_comparison"
  exit 0
fi

# `drift` counts EXTRA files too, which are not among the `checked` pinned definitions — so phrasing
# this as "N of M differ" can print a count larger than its own denominator.
say "DRIFT — $drift finding(s) across $checked pinned loaded file(s)."
worktree_notice "$worktree_comparison"
say ""
say "What to do, in this order:"
say "  1. Do NOT proceed as if the loaded definition were current. Read the reviewed definition at"
say "     $GITLINK and follow that, then report the drift in the run report."
# The control plane is per-runtime. `codex plugin` exposes add/list/marketplace/remove and no update
# command, so prescribing Claude's /plugin flow to a Codex operator names an action that cannot
# repair this lane — and could refresh the sibling Claude installation instead.
say "  2. Refresh through the runtime's own control plane. Never edit the plugin cache: it is"
say "     read-only evidence."
if [ "$RUNTIME" = codex ]; then
  say "     For Codex: \`codex plugin add\` installs the marketplace snapshot's LATEST, so the only"
  say "     safe sequence is one that never advances the snapshot. Check the snapshot's revision"
  say "     against $GITLINK first — and the revision ALONE does not establish the content, because"
  say "     a dirty file, a clean/smudge filter, or a replacement object each leave the revision"
  say "     reading correct while the bytes on disk differ. In the snapshot checkout <snapshot>,"
  say "     all four must pass before any install:"
  say "         git -C <snapshot> --no-replace-objects rev-parse HEAD   # must equal $GITLINK"
  say "         git -C <snapshot> status --porcelain                    # must print NOTHING"
  say "         git -C <snapshot> ls-files --others --ignored --exclude-standard -- \\"
  say "           <prefix>/agents <prefix>/skills <runtime-asset>        # must print NOTHING"
  say "         # repeat <runtime-asset> for every declared requiredRuntimeAsset; ignored untracked"
  say "         # files are hidden from status but the marketplace installer can still copy them"
  say "         and EVERY definition file must equal its pinned blob — one file proves only itself,"
  say "         so a filter or index flag altering any OTHER file survives a single-file check:"
  say "           git -C <snapshot> --no-replace-objects ls-tree -r --name-only HEAD -- <prefix>"
  say "           # for each: --no-replace-objects rev-parse HEAD:<f> must equal"
  say "           # hash-object --no-filters -- <f>"
  say "         and EVERY executable requiredRuntimeAsset must retain its pinned mode:"
  say "           git -C <snapshot> --no-replace-objects ls-tree HEAD -- <runtime-asset>"
  say "           # must start '100755 blob'; test -x <snapshot>/<runtime-asset> must succeed"
  say "       * snapshot AT the pin and all of the above clean -> reinstall WITHOUT upgrading."
  say "         \`codex plugin remove\` deletes the plugin from local config AND cache, so an 'add'"
  say "         that then fails — bad snapshot, disk error, interrupted run — leaves this lane with"
  say "         no definition to load. Do NOT rely on 'add' overwriting an existing install; the"
  say "         CLI does not document that. There is no safe local rollback of the cache: it is"
  say "         read-only evidence, so restoring a copy of it by hand is itself a violation, and a"
  say "         cache copy would not restore the deleted config entry in any case. Save the config"
  say "         entry first so registration can be rebuilt through the control plane:"
  say "           # copy the [plugins.\"$PLUGIN_ID\"] table out of $CODEX_HOME_DIR/config.toml"
  say "           codex plugin remove $PLUGIN_ID && codex plugin add $PLUGIN_ID"
  say "         If the 'add' fails, restore that config entry and re-run 'add'. If it still fails,"
  say "         this lane can neither load a definition nor repair itself: surface it to the"
  say "         maintainer on a declared channel as an outage, rather than editing the cache."
  say "       * snapshot NOT at the pin -> do NOT reinstall, and do NOT run"
  say "         'codex plugin marketplace upgrade': it moves the snapshot to the upstream tip, so a"
  say "         following 'add' installs a revision nobody here has reviewed. Reconcile the consumer"
  say "         gitlink with the revision you intend to run through the reviewed rollout instead."
else
  say "     For Claude: the /plugin marketplace update flow."
  if [ -n "$WORKTREE_NOTE" ]; then
    # The refresh script resolves its pin from the working tree it runs in. Left to that default
    # here it would gate on, and could install, the pin this notice says is not adopted.
    say "     plugin-definition-refresh.sh resolves its pin from the working tree, which here does"
    say "     not hold the adopted one: name the adopted pin to it with --gitlink $GITLINK."
  fi
fi
say "  3. If the refresh needs an interactive session this run cannot open, surface it to the"
say "     maintainer on a declared channel rather than leaving it unreported."
exit 1
