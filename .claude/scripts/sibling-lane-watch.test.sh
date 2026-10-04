#!/usr/bin/env bash
# sibling-lane-watch.test.sh — coverage for sibling-lane-watch.sh (monorepo#3801).
#
# The cases that matter most are the ones that keep the last-resort Slack DM rare and single: no
# page inside the threshold, no page for a usage-limit outage, no page off a verdict the check could
# not reach, and exactly one page per outage. The contract section at the end pins the rule that
# makes each runtime run this against its sibling.
#
# Hermetic: the liveness check is replaced through SIBLING_LANE_LIVENESS_CMD by a stub that prints a
# fixture and exits with a chosen status, so no runtime store is read.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/sibling-lane-watch.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0

# The stub reads its behaviour from two files so one executable serves every case.
cat > "$FIX/liveness" <<EOF
#!/usr/bin/env bash
cat "$FIX/liveness.out"
exit "\$(cat "$FIX/liveness.rc")"
EOF
chmod +x "$FIX/liveness"

# liveness <rc> <line>... — set what the stubbed check prints and returns
liveness() {
  printf '%s\n' "$1" > "$FIX/liveness.rc"; shift
  printf '%s\n' "header line" "$@" > "$FIX/liveness.out"
}

DOWN_NO_SESSION='  NOT-PRODUCING  daily-ai-assistant -- dispatched at 2026-10-03T04:03:00Z and no session started within 120s of it'
DOWN_QUOTA='  NOT-PRODUCING  daily-ai-engineer — newest 2 settled runs all ended within 60s with no inbox item (cause=quota/billing)'
DOWN_AUTH='  NOT-PRODUCING  daily-ai-assistant -- dispatched at X, session produced 0 assistant turns in 3s (runtime error record only, cause=credentials/auth)'
OK_LINE='  OK  agent-improver — 0/2 newest settled runs are stubs'

STATE="$FIX/state/claude.json"
T0=1800000000

# watch <now-offset-seconds> [args...]
watch() {
  local offset=$1; shift
  SIBLING_LANE_LIVENESS_CMD="$FIX/liveness" bash "$SCRIPT" --lane claude --state-file "$STATE" \
    --now-epoch $((T0 + offset)) "$@" 2>/dev/null
}

# check <name> <want-rc> <want-stdout-substring> <now-offset> [args...]
check() {
  local name=$1 want_rc=$2 want=$3; shift 3
  local out rc=0
  out=$(watch "$@") || rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: $name (rc=$rc want=$want_rc, wanted '$want')"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

reset() { rm -rf "$FIX/state"; }

# no_state <what must hold> — the state file must not exist
no_state() {
  if [ ! -e "$STATE" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi
}

# --- a healthy lane ----------------------------------------------------------------------------
reset; liveness 0 "$OK_LINE"
check "a producing lane is OK" 0 "verdict=OK" 0
no_state "OK must not create state"

# --- the outage that motivated the script: three hourly slots, one page, then silence -----------
reset; liveness 1 "$DOWN_NO_SESSION"
check "first bad slot only watches" 0 "verdict=WATCHING lane=claude observations=1/3" 0
check "a second run inside the same slot does not count twice" 0 "observations=1/3" 600
check "second bad slot still only watches" 0 "verdict=WATCHING lane=claude observations=2/3" 3600
check "third bad slot escalates" 1 "verdict=ESCALATE lane=claude observations=3/3" 7200
check "an unrecorded escalation is repeated, not lost" 1 "verdict=ESCALATE" 7800
check "recording the send succeeds" 0 "verdict=ALREADY-NOTIFIED" 7860 --mark-notified
check "no second page in the same outage" 0 "verdict=ALREADY-NOTIFIED" 10800
check "no second page many slots later" 0 "verdict=ALREADY-NOTIFIED" 36000
case "$(watch 39600)" in *"first_seen_epoch=$T0 "*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL: first_seen must stay at the first bad slot" ;; esac

# --- recovery clears the outage, so the next one pages afresh ------------------------------------
liveness 0 "$OK_LINE"
check "recovery reads OK" 0 "verdict=OK" 43200
no_state "recovery must clear state"
liveness 1 "$DOWN_NO_SESSION"
check "a new outage starts counting from one" 0 "observations=1/3" 46800
check "a new outage: second slot" 0 "observations=2/3" 50400
check "a new outage pages again" 1 "verdict=ESCALATE" 54000

# --- an outage that resolves itself inside the threshold never pages -----------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
check "short outage: slot one" 0 "verdict=WATCHING" 0
check "short outage: slot two" 0 "verdict=WATCHING" 3600
liveness 0 "$OK_LINE"
check "short outage: recovered without a page" 0 "verdict=OK" 7200

# --- a usage limit has a known reset and must not page -------------------------------------------
reset; liveness 1 "$DOWN_QUOTA" "$DOWN_QUOTA"
check "quota-only outage: slot one" 0 "verdict=KNOWN-RESET" 0
check "quota-only outage: slot five" 0 "verdict=KNOWN-RESET" 14400
check "quota-only outage: a day later" 0 "verdict=KNOWN-RESET" 86400
no_state "a quota-only outage must not start a count"
# ...but one task down for another cause beside a quota refusal is not a known reset.
liveness 1 "$DOWN_QUOTA" "$DOWN_NO_SESSION"
check "a mixed outage counts" 0 "verdict=WATCHING lane=claude observations=1/3" 90000
# A quota observation in the middle neither advances nor clears the running count.
liveness 1 "$DOWN_QUOTA"
check "a quota slot leaves the count alone" 0 "verdict=KNOWN-RESET" 93600
liveness 1 "$DOWN_NO_SESSION"
check "the count resumes after the quota slot" 0 "observations=2/3" 97200

# --- the cause class is bounded ------------------------------------------------------------------
reset; liveness 1 "$DOWN_AUTH"
check "a credentials cause is named by class" 0 "cause=credentials/auth" 0
reset; liveness 1 "$DOWN_NO_SESSION"
check "an unclassified cause is unknown" 0 "cause=unknown" 0
out=$(watch 3600)
if grep -qE 'daily-ai-assistant|dispatched at|header line' <<<"$out"; then
  fail=$((fail + 1)); echo "FAIL: the liveness report leaked into the output"
else
  pass=$((pass + 1))
fi

# --- fail closed ---------------------------------------------------------------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch 3600 >/dev/null
liveness 2 "  UNKNOWN  agent-improver -- newest dispatch is still within the grace window"
check "an UNKNOWN liveness verdict is UNKNOWN" 2 "verdict=UNKNOWN" 7200
liveness 1 "$DOWN_NO_SESSION"
check "an UNKNOWN slot neither counted nor cleared" 1 "observations=3/3" 10800

# The exit status decides, not the text: a check that could not judge is UNKNOWN even when its
# partial report names a dead task.
reset; liveness 2 "$DOWN_NO_SESSION"
check "an UNKNOWN exit beside a NOT-PRODUCING line is UNKNOWN" 2 "verdict=UNKNOWN" 0
no_state "an UNKNOWN exit must not start a count"

reset; liveness 127 "command not found"
check "an internal liveness failure is UNKNOWN" 2 "verdict=UNKNOWN" 0
reset; liveness 1 "something else entirely"
check "exit 1 without a NOT-PRODUCING line is UNKNOWN" 2 "verdict=UNKNOWN" 0
no_state "an unparsed verdict must not start a count"

reset; mkdir -p "$FIX/state"; liveness 1 "$DOWN_NO_SESSION"
printf 'not json\n' > "$STATE"
check "a malformed state file is UNKNOWN" 2 "verdict=UNKNOWN" 0
printf '{"lane":"codex","observations":9,"first_seen_epoch":1,"last_counted_epoch":1,"notified_epoch":0}\n' > "$STATE"
check "another lane's state file is UNKNOWN" 2 "verdict=UNKNOWN" 0
printf '{"lane":"claude","observations":"9","first_seen_epoch":1,"last_counted_epoch":1,"notified_epoch":0}\n' > "$STATE"
check "a non-numeric count is UNKNOWN" 2 "verdict=UNKNOWN" 0
printf '{"lane":"claude","observations":1,"first_seen_epoch":%s,"last_counted_epoch":%s,"notified_epoch":0}\n' $((T0 + 9000)) $((T0 + 9000)) > "$STATE"
check "a state file from the future is UNKNOWN" 2 "verdict=UNKNOWN" 0

reset; liveness 1 "$DOWN_NO_SESSION"
check "marking a send with no tracked outage is UNKNOWN" 2 "verdict=UNKNOWN" 0 --mark-notified
no_state "a refused mark must not create state"

reset; mkdir -p "$FIX/state"; chmod 500 "$FIX/state"
if [ "$(id -u)" -ne 0 ]; then
  check "an unwritable state directory is UNKNOWN" 2 "verdict=UNKNOWN" 0
else
  pass=$((pass + 1))
fi
chmod 700 "$FIX/state"

# --- usage ---------------------------------------------------------------------------------------
usage() {
  local name=$1; shift
  local rc=0
  SIBLING_LANE_LIVENESS_CMD="$FIX/liveness" bash "$SCRIPT" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name (rc=$rc want=2)"; fi
}
usage "a missing lane is a usage error" --state-file "$STATE"
usage "an unregistered lane is a usage error" --lane cursor --state-file "$STATE"
usage "a zero threshold is a usage error" --lane claude --state-file "$STATE" --threshold 0
usage "a non-numeric gap is a usage error" --lane claude --state-file "$STATE" --min-gap-seconds soon
usage "an unknown flag is a usage error" --lane claude --state-file "$STATE" --send
usage "a flag without its value is a usage error" --lane claude --state-file

# The default state file belongs to the CALLER's runtime, never the watched lane's.
reset; liveness 1 "$DOWN_NO_SESSION"
HOME="$FIX/home" SIBLING_LANE_LIVENESS_CMD="$FIX/liveness" bash "$SCRIPT" --lane claude >/dev/null 2>&1 || true
HOME="$FIX/home" SIBLING_LANE_LIVENESS_CMD="$FIX/liveness" bash "$SCRIPT" --lane codex >/dev/null 2>&1 || true
if [ -f "$FIX/home/.codex/lane-watch/claude.json" ] && [ -f "$FIX/home/.claude/lane-watch/codex.json" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: default state files are not in the caller's runtime directory"
fi

# --- contract: every run watches its sibling, and the DM rules are stated where they are used ----
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
AGENTS="$REPO_ROOT/AGENTS.md"
CHANNELS="$REPO_ROOT/.claude/guides/maintainer-channels.md"

# contract <name> <file> <needle>
contract() {
  if grep -qF -- "$3" "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: contract — $1"; fi
}
every_run=$(awk '/^The deployed definition is assembled/{on=1} on && /^Assembly and pin reading/{exit} on' "$AGENTS")
[ -n "$every_run" ] || { echo "FAIL: could not find the every-run list in AGENTS.md" >&2; exit 1; }
if grep -qF 'sibling-lane-watch.sh' <<<"$every_run"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: contract — AGENTS.md every-run list does not name the watch"; fi

section=$(awk '/^## Sibling lane outage/{on=1; print; next} on && /^## /{exit} on' "$CHANNELS")
[ -n "$section" ] || { echo "FAIL: maintainer-channels.md has no 'Sibling lane outage' section" >&2; exit 1; }
# shellcheck disable=SC2016  # the backticks are literal Markdown, not a command substitution
for needle in 'sibling-lane-watch.sh --lane' '--mark-notified' 'Exit `1`' 'Exit `2`' 'KNOWN-RESET' \
  'both directions' 'once per outage' 'cause class'; do
  if grep -qF -- "$needle" <<<"$section"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: contract — the outage section lacks: $needle"; fi
done
contract "the script's default threshold matches the guide" "$CHANNELS" "three consecutive hourly slots"
if grep -qE '^THRESHOLD=3$' "$SCRIPT"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the script default threshold is not 3"; fi

echo "sibling-lane-watch.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
