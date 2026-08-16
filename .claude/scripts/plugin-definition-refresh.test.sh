#!/usr/bin/env bash
# plugin-definition-refresh.test.sh — contract test for plugin-definition-refresh.sh
#
# The defect under test (measured 2026-08-16, monorepo#2856):
#   `claude plugin update <plugin>` installs the MARKETPLACE LATEST, not the consumer's PINNED
#   revision — its own `--help` says "Update a plugin to the latest version" and it exposes no
#   ref/version selector. On 2026-08-15 the two coincided (clone HEAD == pin `564a6a0f`), which is
#   the only reason the by-hand refresh appeared to install the pin. On 2026-08-16 they did NOT:
#   pin `11b241cc` (4.3.4) against an upstream `main` already at `73109ad9` (4.3.6). A pre-flight
#   wired to the two commands as #2856 describes them would therefore install definitions this
#   consumer has never reviewed — a strictly worse failure than the stale-install drift it fixes,
#   because drift at least runs a PREVIOUSLY REVIEWED definition.
#
# So the contract is a GATED refresh: refresh the marketplace, then apply the plugin update ONLY
# when the revision it would install is exactly the pinned one. Otherwise refuse and report.
#
# Read-only against the real host: every assertion runs against fixtures in a temp dir with a
# stubbed CLI. The suite never touches the runtime's plugin install.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/plugin-definition-refresh.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; }

[ -x "$SCRIPT" ] || { printf 'plugin-definition-refresh.sh is missing or not executable: %s\n' "$SCRIPT" >&2; exit 1; }

# ── fixture ────────────────────────────────────────────────────────────────────
# A marketplace clone with two commits, a consumer repo whose gitlink names one of them, and a
# stub CLI that records every invocation and moves the clone on `marketplace update`.
make_fixture() {
  ROOT="$(mktemp -d)"
  MK="$ROOT/marketplace"; CONSUMER="$ROOT/consumer"; BIN="$ROOT/bin"
  PLUGINS="$ROOT/plugins"; INSTALLED="$ROOT/installed"
  mkdir -p "$MK" "$CONSUMER" "$BIN" "$PLUGINS" "$INSTALLED"

  git -C "$MK" init -q -b main
  git -C "$MK" config user.email t@t; git -C "$MK" config user.name t
  echo old > "$MK/f"; git -C "$MK" add f; git -C "$MK" commit -qm one
  MK_OLD="$(git -C "$MK" rev-parse HEAD)"
  echo new > "$MK/f"; git -C "$MK" add f; git -C "$MK" commit -qm two
  MK_NEW="$(git -C "$MK" rev-parse HEAD)"
  git -C "$MK" checkout -q "$MK_OLD"        # clone starts STALE, as the real one was

  # consumer repo carrying a gitlink to the marketplace at a chosen revision
  git -C "$CONSUMER" init -q -b main
  git -C "$CONSUMER" config user.email t@t; git -C "$CONSUMER" config user.name t
  git -C "$CONSUMER" config protocol.file.allow always 2>/dev/null || true
  echo x > "$CONSUMER/x"; git -C "$CONSUMER" add x; git -C "$CONSUMER" commit -qm base

  # runtime registry pointing at an install dir
  cat > "$PLUGINS/installed_plugins.json" <<JSON
{"version":2,"plugins":{"agentic-engineering@devantler-plugins":[
  {"scope":"user","installPath":"$INSTALLED","version":"0.0.0","gitCommitSha":"$MK_OLD"}]}}
JSON

  CLI_LOG="$ROOT/cli.log"; : > "$CLI_LOG"
  cat > "$BIN/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CLI_LOG"
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = marketplace ] && [ "\${3:-}" = update ]; then
  git -C "$MK" checkout -q "\${STUB_MARKETPLACE_TARGET:-$MK_OLD}"
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = update ]; then
  touch "$ROOT/APPLIED"
fi
exit 0
STUB
  chmod +x "$BIN/claude"
}

# Point the consumer's gitlink at $1 by writing the tree entry directly — no network, no submodule
# machinery, and it is exactly the "160000 commit <sha>" shape the script must read.
# A silently-failed fixture is worse than a failed test: the assertions still run, but against the
# PREVIOUS consumer tree rather than the pin they asked for, so they pass without testing anything.
# Both commands are checked explicitly and stderr is preserved.
set_gitlink() {
  local sha="$1"
  git -C "$CONSUMER" update-index --add --cacheinfo 160000,"$sha",libraries/agent-plugins \
    || { printf 'FIXTURE FAILURE: update-index for %s failed\n' "$sha" >&2; exit 9; }
  git -C "$CONSUMER" commit -qm "pin $sha" >/dev/null \
    || { printf 'FIXTURE FAILURE: commit for %s failed\n' "$sha" >&2; exit 9; }
}

run() {
  CLAUDE_CLI="$BIN/claude" "$SCRIPT" \
    --repo-root "$CONSUMER" --plugins-root "$PLUGINS" --marketplace-dir "$MK" \
    "$@" 2>&1
}

cleanup() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }
trap cleanup EXIT

printf '\nplugin-definition-refresh contract\n'

# ── A1 — the measured defect: marketplace latest != pin ⇒ REFUSE, and never apply ─────────────
make_fixture
set_gitlink "$MK_OLD"                      # pin = OLD; marketplace will refresh to NEW
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok "A1 refuses (exit 1) when the refreshed marketplace does not carry the pin"
else bad "A1 refuses (exit 1) when the refreshed marketplace does not carry the pin" "exit was $rc"; fi
if [ ! -e "$ROOT/APPLIED" ]; then ok "A1b does NOT invoke 'plugin update' when the pin is unavailable"
else bad "A1b does NOT invoke 'plugin update' when the pin is unavailable" "it applied an unreviewed revision"; fi
cleanup

# ── A2 — the safe case: marketplace latest == pin ⇒ apply ──────────────────────────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ -e "$ROOT/APPLIED" ] && [ "$rc" -eq 0 ]; then ok "A2 invokes 'plugin update' when the marketplace carries exactly the pin"
else bad "A2 invokes 'plugin update' when the marketplace carries exactly the pin" "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A3 — a runtime-local mutation is backed up BEFORE it happens ───────────────────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if ls "$PLUGINS"/installed_plugins.json.bak-* >/dev/null 2>&1 && [ "$rc" -eq 0 ]; then ok "A3 backs up installed_plugins.json before applying"
else bad "A3 backs up installed_plugins.json before applying" "exit was $rc; no timestamped backup was written"; fi
cleanup

# ── A4 — refresh is attempted BEFORE the gate is evaluated ─────────────────────────────────────
# Clone starts at OLD and the pin is NEW. Only a script that refreshes FIRST can ever apply here;
# one that read the clone HEAD up front would see OLD != NEW and refuse. This is the assertion that
# pins the ORDER, which is the half #2856 got right and is easy to drop when adding the gate.
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if grep -q 'plugin marketplace update' "$CLI_LOG" && [ -e "$ROOT/APPLIED" ] && [ "$rc" -eq 0 ]; then
  ok "A4 refreshes the marketplace before evaluating the gate"
else bad "A4 refreshes the marketplace before evaluating the gate" "exit was $rc; $(tr '\n' '|' < "$CLI_LOG")"; fi
cleanup

# ── A5 — an unresolvable CLI is UNKNOWN (exit 2), never a verdict ──────────────────────────────
make_fixture
set_gitlink "$MK_NEW"
CLAUDE_CLI="$ROOT/nope" "$SCRIPT" --repo-root "$CONSUMER" --plugins-root "$PLUGINS" \
  --marketplace-dir "$MK" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "A5 exits 2 (UNKNOWN) when the CLI cannot be resolved"
else bad "A5 exits 2 (UNKNOWN) when the CLI cannot be resolved" "exit was $rc — 0/1 would be a fabricated verdict"; fi
cleanup

# ── A12 — the gate binds the clone it READS to the plugin the CLI UPDATES ──────────────────────
# `--marketplace staging` would refresh and gate on the staging clone while the default plugin id
# still installed `…@devantler-plugins`: the gate passes against one marketplace, the install comes
# from another. That is the fail-open this whole script exists to prevent, so a mismatch is UNKNOWN
# (2) and must never reach 'plugin update'.
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run --marketplace staging >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ]; then
  ok "A12 refuses (exit 2) when --marketplace and --plugin-id name different marketplaces"
else bad "A12 refuses (exit 2) when --marketplace and --plugin-id name different marketplaces" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A13 — an unqualified plugin id is UNKNOWN, never a silent default ──────────────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run --plugin-id agentic-engineering >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ]; then
  ok "A13 refuses (exit 2) when the plugin id is not marketplace-qualified"
else bad "A13 refuses (exit 2) when the plugin id is not marketplace-qualified" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A14 — a malformed registry must not turn a SUCCESSFUL apply into a failure ─────────────────
# The post-apply registry read is a reporting nicety. Under `set -e` + `pipefail` a malformed
# registry aborted the script after 'plugin update' had already run and before the declared
# `exit 0`, reporting a completed apply as a failure.
make_fixture
set_gitlink "$MK_NEW"
printf '%s\n' 'this is not json {{{' > "$PLUGINS/installed_plugins.json"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ -e "$ROOT/APPLIED" ] && [ "$rc" -eq 0 ]; then
  ok "A14 still exits 0 after applying when the registry is malformed"
else bad "A14 still exits 0 after applying when the registry is malformed" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A15 — refresh → read → apply is serialized against an overlapping run ──────────────────────
# Both machine-local lanes dispatch hourly and 46% of runs exceed the hour, so a sibling refreshing
# the same clone between this run's read and its install would have it apply an ungated revision.
make_fixture
set_gitlink "$MK_NEW"
mkdir -p "$PLUGINS/.plugin-definition-refresh.lock"          # a live sibling holds it
STUB_MARKETPLACE_TARGET="$MK_NEW" PLUGIN_REFRESH_LOCK_WAIT=2 run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ]; then
  ok "A15 exits 2 (UNKNOWN) rather than applying while another run holds the lock"
else bad "A15 exits 2 (UNKNOWN) rather than applying while another run holds the lock" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
rmdir "$PLUGINS/.plugin-definition-refresh.lock" 2>/dev/null || true
cleanup

# ── A16 — the lock is RELEASED on a normal apply, so the next run is not parked ────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$PLUGINS/.plugin-definition-refresh.lock" ]; then
  ok "A16 releases the lock after a successful apply"
else bad "A16 releases the lock after a successful apply" \
  "exit was $rc, lock still present=$([ -d "$PLUGINS/.plugin-definition-refresh.lock" ] && echo yes || echo no)"; fi
cleanup

# ── A6 — no hardcoded claude-code version directory ────────────────────────────────────────────
# The by-hand invocation that worked on 2026-08-15 hardcoded `claude-code/2.1.229/`. Baking that in
# breaks silently on the next runtime upgrade, which is the same unbounded-staleness class this
# script exists to close.
if ! grep -Eq 'claude-code/[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT"; then
  ok "A6 does not hardcode a claude-code version directory"
else bad "A6 does not hardcode a claude-code version directory" "$(grep -Eon 'claude-code/[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT" | head -1)"; fi

# ── A7 — the pin is resolved with --no-replace-objects ─────────────────────────────────────────
# AGENTS.md *Git safety*: a refs/replace entry makes HEAD:<path> resolve through a replacement
# commit while `git rev-parse HEAD` still prints the expected value, so the pin silently names an
# unreviewed revision — a fail-open on the one value everything downstream trusts.
#
# Matched on the INVOCATION line — both `--no-replace-objects` and `rev-parse` on one line — not
# anywhere in the file. Ablation caught the loose form passing vacuously: stripping the flag from
# the command still left the phrase in the comment explaining it, so the assertion could never fail
# while the rationale was documented. An assertion a comment can satisfy tests the prose.
if grep -Eq -- '--no-replace-objects[^\n]*rev-parse|rev-parse[^\n]*--no-replace-objects' "$SCRIPT"; then
  ok "A7 resolves the pinned revision with --no-replace-objects"
else bad "A7 resolves the pinned revision with --no-replace-objects" "the gate can be pointed at an unreviewed revision"; fi

# ── A8 — the restart semantics are stated on the applying path ─────────────────────────────────
# `plugin update` says "restart required to apply". The applying run keeps executing the OLD
# definition, so an exit 0 that reads as "this run used the new definition" is the same fail-open
# as the drift itself (#2856 acceptance criterion 2).
make_fixture
set_gitlink "$MK_NEW"
#
# Keyed on the CLI's own word, `restart`. The first draft also accepted "next dispatch" and "this
# run"; ablation showed that set survived deleting the restart sentence outright, because those
# phrases recur throughout the surrounding prose. A needle that common asserts the topic, not the
# statement.
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"
if printf '%s' "$out" | grep -qi 'restart'; then
  ok "A8 states that the applying run still executes the previous definition"
else bad "A8 states that the applying run still executes the previous definition" "$(printf '%s' "$out" | tail -3 | tr '\n' '|')"; fi
cleanup

# ── A9–A11 — the CONTRACT carries the rule, not just this script ───────────────────────────────
# A script nobody is told to run is decoration, and the marketplace-latest hazard is the one fact
# that makes the gate look like needless friction if it is not written down. Scoped to the plugin
# contract section, matching the currency suite: these phrases also appear in this file and in the
# script header, so a file-wide match would pass while the operative section said nothing.
CONSTITUTION="$(cd "$HERE/../.." && pwd)/AGENTS.md"
if [ -r "$CONSTITUTION" ]; then
  section="$(awk '
      /^### Agentic engineering plugin contract$/ { ins = 1; next }
      ins && /^### / { exit }
      ins { print }
    ' "$CONSTITUTION" | tr '\n' ' ')"
  [ -n "$section" ] || bad "A9-A11 could not extract the plugin contract section from AGENTS.md"

  case "$section" in
    *"plugin-definition-refresh.sh"*) ok "A9 the contract names the gated refresh script" ;;
    *) bad "A9 the contract names the gated refresh script" "pre-flight has no prescribed way to apply the pin" ;;
  esac
  # The hazard, not merely the gate: without it the refusal reads as over-caution and the next
  # reader "fixes" it by dropping the gate — which is precisely the fail-open.
  case "$section" in
    *"installs the MARKETPLACE LATEST"*) ok "A10 the contract states that plugin update installs the marketplace latest" ;;
    *) bad "A10 the contract states that plugin update installs the marketplace latest" "the reason for the gate is unrecorded" ;;
  esac
  case "$section" in
    *"requires a restart"*) ok "A11 the contract states the restart semantics of an apply" ;;
    *) bad "A11 the contract states the restart semantics of an apply" "an apply-time exit 0 could be read as 'this run is current'" ;;
  esac
else
  bad "A9-A11 AGENTS.md is unreadable at $CONSTITUTION"
fi

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
