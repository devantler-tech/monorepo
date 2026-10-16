#!/usr/bin/env bash
# sibling-lane-watch.test.sh — coverage for sibling-lane-watch.sh (monorepo#3801).
#
# The cases that matter most are the ones that keep the last-resort Slack DM rare and single: no
# page inside the threshold, no page for a usage-limit outage, no page off a verdict the check could
# not reach, and exactly one page per outage even when two runs overlap. The contract section at the
# end pins the rule that makes each runtime run this against its sibling.
#
# Hermetic. The watch always runs the liveness check BESIDE it, so most cases run a copy of the watch
# from a directory holding stub checks that print a fixture and exit with a chosen status. The one
# section that drives the real Claude check points it at a synthetic store through its own
# environment variables. Every case pins --now-epoch.

set -euo pipefail
export TZ=UTC

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/sibling-lane-watch.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

FIX=$(mktemp -d)
test_run_completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$FIX"
  if [ "${test_run_completed}" != 1 ]; then
    echo "sibling-lane-watch.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# One stub serves both lanes and every case: it reads its behaviour from files, and records the
# arguments it was given.
mkdir -p "$FIX/bin"
cp "$SCRIPT" "$FIX/bin/sibling-lane-watch.sh"
cat > "$FIX/bin/claude-lane-liveness.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$FIX/liveness.args"
# The verdict is read BEFORE the delay, so a case can change it for the next run meanwhile.
out=\$(cat "$FIX/liveness.out"); rc=\$(cat "$FIX/liveness.rc")
# A case may script ONE entry: the id is the second argument, after --task or --automation.
if [ -f "$FIX/entry.\$2.rc" ]; then out=\$(cat "$FIX/entry.\$2.out"); rc=\$(cat "$FIX/entry.\$2.rc"); fi
printf '%s\n' "\$*" >> "$FIX/liveness.calls"
: > "$FIX/liveness.read"
[ ! -f "$FIX/liveness.sleep" ] || sleep "\$(cat "$FIX/liveness.sleep")"
printf '%s\n' "\$out"
exit "\$rc"
EOF
cp "$FIX/bin/claude-lane-liveness.sh" "$FIX/bin/codex-lane-liveness.sh"
chmod +x "$FIX/bin/"*.sh
STUBBED="$FIX/bin/sibling-lane-watch.sh"

# liveness <rc> <line>... — set what the stubbed check prints and returns
liveness() {
  printf '%s\n' "$1" > "$FIX/liveness.rc"; shift
  printf '%s\n' "header line" "$@" > "$FIX/liveness.out"
}

DOWN_NO_SESSION='  NOT-PRODUCING  daily-ai-assistant -- dispatched at 2026-10-03T04:03:00Z and no session started within 120s of it'
DOWN_QUOTA='  NOT-PRODUCING  daily-ai-engineer — newest 2 settled runs all ended within 60s with no inbox item (cause=quota/billing)'
DOWN_AUTH='  NOT-PRODUCING  daily-ai-assistant -- dispatched at X, session produced 0 assistant turns in 3s (runtime error record only, cause=credentials/auth)'
OK_LINE='  OK  daily-ai-assistant — produced work'

STATE="$FIX/state/claude.json"
# T0 is on the hour. The watched Claude task is scheduled at :50, so the sibling slot that contains
# T0 runs from T0-600 to T0+3000: offsets 0 and 2999 share a slot, 3000 starts the next one.
T0=1800000000
SLOT=3600

# watch <now-offset-seconds> [args...]
watch() {
  local offset=$1; shift
  bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch $((T0 + offset)) "$@" 2>/dev/null
}

# check <name> <want-rc> <want-stdout-substring> <now-offset> [args...]
check() {
  local name=$1 want_rc=$2 want=$3; shift 3
  local out rc=0
  out=$(watch "$@") || rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want" <<<"$out"; then
    ok
  else
    bad "$name (rc=$rc want=$want_rc, wanted '$want')"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

reset() { chmod -R u+w "$FIX/state" 2>/dev/null || true; rm -rf "$FIX/state" "$FIX/liveness.sleep" "$FIX/liveness.calls" "$FIX"/entry.*; }

# no_state <what must hold> — the state file must not exist
no_state() { if [ ! -e "$STATE" ]; then ok; else bad "$1"; fi; }
# state_has <what must hold> <jq filter that must be true>
state_has() { if jq -e "$2" "$STATE" >/dev/null 2>&1; then ok; else bad "$1"; fi; }

# --- a healthy lane ----------------------------------------------------------------------------
reset; liveness 0 "$OK_LINE"
check "a producing lane is OK" 0 "verdict=OK" 0
no_state "OK must not create state"

# --- the outage that motivated the script: three hourly slots, one page, then silence -----------
reset; liveness 1 "$DOWN_NO_SESSION"
check "first bad slot only watches" 0 "verdict=WATCHING lane=claude observations=1/3" 0
check "a second run inside the same slot does not count twice" 0 "observations=1/3" 600
check "the last second of a slot is still that slot" 0 "observations=1/3" 2999
# 2400 s after the previous run, but a different slot: slots are counted, not elapsed seconds.
check "a run in the next slot counts although less than an hour passed" 0 "verdict=WATCHING lane=claude observations=2/3" 3000
esc_rc=0
esc_out=$(bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch $((T0 + 2 * SLOT)) 2>"$FIX/esc.err") || esc_rc=$?
if [ "$esc_rc" -eq 1 ] && grep -qF 'verdict=ESCALATE lane=claude observations=3/3' <<<"$esc_out"; then ok; else bad "third bad slot escalates (rc=$esc_rc: $esc_out)"; fi
# The escalation names what to do next, on stderr so the summary line stays quotable.
if grep -qF -- '--mark-notified' "$FIX/esc.err" && grep -qF 'maintainer-channels.md' "$FIX/esc.err"; then ok; else bad "ESCALATE does not say what to do next"; fi
check "a run beside the one that was handed the page does not page too" 0 "verdict=ESCALATION-CLAIMED" $((2 * SLOT + 60))
check "an unrecorded escalation is asked for again once its claim expires" 1 "verdict=ESCALATE" $((3 * SLOT))
check "recording the send succeeds" 0 "verdict=ALREADY-NOTIFIED" $((3 * SLOT + 60)) --mark-notified
check "no second page in the same outage" 0 "verdict=ALREADY-NOTIFIED" $((4 * SLOT))
# A notified outage stays that outage however long the watch went without looking.
check "no second page after the watch itself was away for many slots" 0 "verdict=ALREADY-NOTIFIED" $((20 * SLOT))
case "$(watch $((21 * SLOT)))" in *"first_seen_epoch=$T0 "*) ok ;; *) bad "first_seen must stay at the first bad slot" ;; esac

# --- recovery clears the outage, so the next one pages afresh ------------------------------------
liveness 0 "$OK_LINE"
check "recovery reads OK" 0 "verdict=OK" $((22 * SLOT))
no_state "recovery must clear state"
liveness 1 "$DOWN_NO_SESSION"
check "a new outage starts counting from one" 0 "observations=1/3" $((23 * SLOT))
check "a new outage: second slot" 0 "observations=2/3" $((24 * SLOT))
check "a new outage pages again" 1 "verdict=ESCALATE" $((25 * SLOT))

# --- an outage that resolves itself inside the threshold never pages -----------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
check "short outage: slot one" 0 "verdict=WATCHING" 0
check "short outage: slot two" 0 "verdict=WATCHING" $SLOT
liveness 0 "$OK_LINE"
check "short outage: recovered without a page" 0 "verdict=OK" $((2 * SLOT))

# --- old bad slots do not combine with a new one -------------------------------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch $SLOT >/dev/null
check "two unobserved slots restart the count instead of paging" 0 "verdict=WATCHING lane=claude observations=1/3" $((4 * SLOT))
state_has "a restarted count restarts first_seen" ".first_seen_epoch == $((T0 + 4 * SLOT))"
# One unobserved slot does not: the caller's scheduler drops a dispatch that overlaps a long run, so
# a watcher can look every second hour for a whole outage, and it must still page.
reset
check "a two-hourly watcher: first look" 0 "observations=1/3" 0
check "a two-hourly watcher: second look" 0 "observations=2/3" $((2 * SLOT))
check "a two-hourly watcher still pages" 1 "verdict=ESCALATE lane=claude observations=3/3" $((4 * SLOT))

# --- a usage limit has a known reset and must not page -------------------------------------------
reset; liveness 1 "$DOWN_QUOTA" "$DOWN_QUOTA"
check "quota-only outage: slot one" 0 "verdict=KNOWN-RESET" 0
check "quota-only outage: slot five" 0 "verdict=KNOWN-RESET" $((4 * SLOT))
check "quota-only outage: a day later" 0 "verdict=KNOWN-RESET" $((24 * SLOT))
no_state "a quota-only outage must not start a count"
# ...but one task down for another cause beside a quota refusal is not a known reset.
liveness 1 "$DOWN_QUOTA" "$DOWN_NO_SESSION"
check "a mixed outage counts" 0 "verdict=WATCHING lane=claude observations=1/3" $((25 * SLOT))
# A quota-only slot ends a count nobody was paged for: bad slots on either side of a usage limit are
# two outages, and adding them together would page after one look at the second.
check "a mixed outage: second slot" 0 "observations=2/3" $((26 * SLOT))
liveness 1 "$DOWN_QUOTA"
check "a quota slot ends the count" 0 "verdict=KNOWN-RESET lane=claude observations=0/3" $((27 * SLOT))
no_state "a quota slot must clear an unpaged count"
liveness 1 "$DOWN_NO_SESSION"
check "the count starts again after the quota slot" 0 "verdict=WATCHING lane=claude observations=1/3" $((28 * SLOT))
# ...but an outage he was already told about stays recorded through a usage limit.
check "second slot again" 0 "observations=2/3" $((29 * SLOT))
check "third slot pages" 1 "verdict=ESCALATE" $((30 * SLOT))
# A quota-only look between the page and its record must not drop the claim: the send could then
# not be recorded, and the same outage would page again.
liveness 1 "$DOWN_QUOTA"
check "a quota look while the page is claimed" 0 "verdict=KNOWN-RESET lane=claude observations=3/3" $((30 * SLOT + 30))
check "the send is still recorded" 0 "verdict=ALREADY-NOTIFIED" $((30 * SLOT + 60)) --mark-notified
liveness 1 "$DOWN_QUOTA"
check "a quota slot after the page" 0 "verdict=KNOWN-RESET" $((31 * SLOT))
state_has "a quota slot keeps a notified outage" '.notified_epoch > 0'
liveness 1 "$DOWN_NO_SESSION"
check "and the outage is not paged again after it" 0 "verdict=ALREADY-NOTIFIED" $((32 * SLOT))
# The quiet rule matches a literal the liveness checks print. Pin that both still print it.
for live in claude codex; do
  if grep -qF 'quota/billing' "$SCRIPT_DIR/${live}-lane-liveness.sh"; then ok; else bad "${live}-lane-liveness.sh no longer names the quota/billing cause class"; fi
done

# --- the cause class is bounded ------------------------------------------------------------------
reset; liveness 1 "$DOWN_AUTH"
check "a credentials cause is named by class" 0 "cause=credentials/auth" 0
reset; liveness 1 "$DOWN_NO_SESSION"
check "an unclassified cause is unknown" 0 "cause=unknown" 0
out=$(watch $SLOT)
if grep -qE 'daily-ai-assistant|dispatched at|header line' <<<"$out"; then bad "the liveness report leaked into the output"; else ok; fi

# --- only the hourly entries are judged, by the check beside the script --------------------------
# Each lane names two engineer entries (AGENTS.md, Cadence & focus). With no --entries the watch asks
# about exactly those two, one call each, and about nothing else: never the improver, and never an
# unscoped call, which would let the caller's own dispatch decide the verdict.
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null
calls=$(cat "$FIX/liveness.calls" 2>/dev/null || echo "<check not invoked>")
want_calls="--task daily-ai-assistant --grace-seconds 300 --now-epoch $T0
--task agentic-engineer-2 --grace-seconds 300 --now-epoch $T0"
if [ "$calls" = "$want_calls" ]; then ok; else bad "the Claude check is not limited to the lane's two hourly entries with the short grace: $calls"; fi
reset
bash "$STUBBED" --lane codex --state-file "$FIX/state/codex.json" --now-epoch "$T0" >/dev/null 2>&1 || true
calls=$(cat "$FIX/liveness.calls" 2>/dev/null || echo "<check not invoked>")
want_calls="--automation daily-ai-engineer --now-ms ${T0}000
--automation agentic-engineer-2 --now-ms ${T0}000"
if [ "$calls" = "$want_calls" ]; then ok; else bad "the Codex check is not limited to the lane's two hourly automations: $calls"; fi
# The check is the one beside the script and nothing else: no environment variable names one.
if grep -qE '\$\{?[A-Z_]*LIVENESS_CMD' "$SCRIPT"; then bad "the liveness check can be replaced through the environment"; else ok; fi
# shellcheck disable=SC2016  # matching the literal source text
if grep -qF 'liveness_cmd="${script_dir}/${LANE}-lane-liveness.sh"' "$SCRIPT"; then ok; else bad "the liveness check is no longer resolved beside the script"; fi

# --- fail closed ---------------------------------------------------------------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch $SLOT >/dev/null
liveness 2 "  UNKNOWN  daily-ai-assistant -- newest dispatch is still within the grace window"
check "an UNKNOWN liveness verdict is UNKNOWN" 2 "verdict=UNKNOWN" $((2 * SLOT))
state_has "an UNKNOWN slot leaves the count where it was" '.observations == 2'
hint=$(bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch $((T0 + 2 * SLOT)) 2>&1 >/dev/null || true)
if grep -qF 'once more before the run report' <<<"$hint"; then ok; else bad "an UNKNOWN liveness verdict does not ask for a second look"; fi
# The second look the hint asks for, later in the same slot, completes the count.
liveness 1 "$DOWN_NO_SESSION"
check "a second look in the UNKNOWN slot completes the count" 1 "observations=3/3" $((2 * SLOT + 900))
# And so does the next slot when there was no second look.
reset; watch 0 >/dev/null; watch $SLOT >/dev/null
check "the slot after an unjudged one completes the count" 1 "observations=3/3" $((3 * SLOT))

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

# An internal failure on the way to ESCALATE must not come out as exit 1. A closed stdout fails the
# summary line, which is the last step before the page is claimed.
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch $SLOT >/dev/null
closed_rc=0
bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch $((T0 + 2 * SLOT)) >&- 2>/dev/null || closed_rc=$?
if [ "$closed_rc" -eq 2 ]; then ok; else bad "a closed stdout on the ESCALATE path exits $closed_rc, want 2"; fi
state_has "a failed ESCALATE claims nothing, so the next run still pages" '.claimed_epoch == 0'
check "the run after a failed ESCALATE pages" 1 "verdict=ESCALATE" $((2 * SLOT + 60))
# A closed stderr only loses the hint: the verdict and the exit status still agree.
reset; watch 0 >/dev/null; watch $SLOT >/dev/null
closed_rc=0
closed_out=$(bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch $((T0 + 2 * SLOT)) 2>&-) || closed_rc=$?
if [ "$closed_rc" -eq 1 ] && grep -qF 'verdict=ESCALATE' <<<"$closed_out"; then ok; else bad "a closed stderr on the ESCALATE path gave rc=$closed_rc: $closed_out"; fi

# --- a bad state file is set aside, not left to blind the watch ----------------------------------
quarantined() {
  local name=$1
  check "$name is UNKNOWN" 2 "verdict=UNKNOWN" 0
  if [ ! -e "$STATE" ] && [ -e "$STATE.corrupt" ]; then ok; else bad "$name was not set aside"; fi
  check "the run after $name starts afresh" 0 "observations=1/3" 60
}
reset; mkdir -p "$FIX/state"; liveness 1 "$DOWN_NO_SESSION"
printf 'not json\n' > "$STATE"
quarantined "a malformed state file"
reset; mkdir -p "$FIX/state"
printf '{"lane":"claude","observations":"9","first_seen_epoch":1,"last_slot":1,"claimed_epoch":0,"notified_epoch":0}\n' > "$STATE"
quarantined "a non-numeric count"
# A number the shell cannot compare must not reach the comparisons: they would error, read as
# false, and fall through to a page.
reset; mkdir -p "$FIX/state"
printf '{"lane":"claude","observations":3.0,"first_seen_epoch":1e9,"last_slot":1,"claimed_epoch":0,"notified_epoch":0}\n' > "$STATE"
quarantined "a non-integer count"
reset; mkdir -p "$FIX/state"
printf '{"lane":"claude","observations":1,"first_seen_epoch":1,"last_slot":%s,"claimed_epoch":0,"notified_epoch":0}\n' $((T0 / SLOT + 5)) > "$STATE"
quarantined "a state file from the future"
# Another lane's file is somebody else's record: refuse it, and leave it where it is.
reset; mkdir -p "$FIX/state"
printf '{"lane":"codex","observations":9,"first_seen_epoch":1,"last_slot":1,"claimed_epoch":0,"notified_epoch":0}\n' > "$STATE"
check "another lane's state file is UNKNOWN" 2 "verdict=UNKNOWN" 0
state_has "another lane's state file is left in place" '.lane == "codex" and .observations == 9'

# --- recording a send ----------------------------------------------------------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
check "marking a send with no tracked outage is UNKNOWN" 2 "verdict=UNKNOWN" 0 --mark-notified
no_state "a refused mark must not create state"
watch 0 >/dev/null; watch $SLOT >/dev/null
check "marking a send before any ESCALATE is UNKNOWN" 2 "verdict=UNKNOWN" $((SLOT + 60)) --mark-notified
state_has "a refused mark records nothing" '.notified_epoch == 0'

# start_slow <now-offset> — start a run in the background whose check is delayed, and return only
# once that check has read its verdict, so what the case does next cannot race it.
start_slow() {
  local n=0
  rm -f "$FIX/liveness.read" "$FIX/slow.out" "$FIX/slow.rc"
  (rc=0; watch "$1" > "$FIX/slow.out" || rc=$?; echo "$rc" > "$FIX/slow.rc") &
  slow_pid=$!
  until [ -e "$FIX/liveness.read" ]; do
    n=$((n + 1))
    if [ "$n" -ge 100 ]; then bad "the slow run never reached its check"; return 0; fi
    sleep 0.1
  done
}
# slow_was <name> <want-rc> <want-stdout-substring> — wait for that run and judge what it reported
slow_was() {
  wait "$slow_pid" || true
  if [ "$(cat "$FIX/slow.rc" 2>/dev/null)" = "$2" ] && grep -qF -- "$3" "$FIX/slow.out"; then
    ok
  else
    bad "$1 (rc=$(cat "$FIX/slow.rc" 2>/dev/null), wanted rc=$2 '$3': $(cat "$FIX/slow.out" 2>/dev/null))"
  fi
}

# --- two runs at once ----------------------------------------------------------------------------
# A slow check holds a run between its start and its state update. A --mark-notified that lands in
# that gap must survive it. The slow run is in a new slot, so it does write the state back.
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch $SLOT >/dev/null; watch $((2 * SLOT)) >/dev/null || true
echo 2 > "$FIX/liveness.sleep"
start_slow $((2 * SLOT + 3100))
rm -f "$FIX/liveness.sleep"
check "a send is recorded while another run is mid-check" 0 "verdict=ALREADY-NOTIFIED" $((2 * SLOT + 3110)) --mark-notified
slow_was "the slower run then sees the recorded send" 0 "verdict=ALREADY-NOTIFIED lane=claude observations=4/3"
state_has "the slower run did not overwrite the recorded send" '.notified_epoch > 0'
state_has "and the slower run still counted its own slot" ".observations == 4"
check "and the outage is not paged again" 0 "verdict=ALREADY-NOTIFIED" $((4 * SLOT))

# A run that saw the lane healthy clears only the state it saw before looking. A bad slot counted
# while it was still checking is newer than its verdict and must survive it.
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null
liveness 0 "$OK_LINE"; echo 2 > "$FIX/liveness.sleep"
start_slow $SLOT
rm -f "$FIX/liveness.sleep"; liveness 1 "$DOWN_NO_SESSION"
check "a bad slot is counted while a healthy verdict is still in flight" 0 "observations=2/3" $((SLOT + 5))
slow_was "the slower run did report the lane healthy" 0 "verdict=OK"
state_has "the slower healthy run did not clear the newer count" '.observations == 2'
# With nothing newer in the way, the same healthy verdict does clear it.
liveness 0 "$OK_LINE"
check "an undisturbed healthy run clears the count" 0 "verdict=OK" $((SLOT + 60))
no_state "an undisturbed healthy run must clear state"

# Two runs that both reach the threshold: exactly one is handed the page.
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch $SLOT >/dev/null
echo 1 > "$FIX/liveness.sleep"
(rc=0; watch $((2 * SLOT)) > "$FIX/race.a" 2>&1 || rc=$?; echo "$rc" > "$FIX/race.a.rc") &
(rc=0; watch $((2 * SLOT + 5)) > "$FIX/race.b" 2>&1 || rc=$?; echo "$rc" > "$FIX/race.b.rc") &
wait
rm -f "$FIX/liveness.sleep"
pages=$(cat "$FIX/race.a" "$FIX/race.b" | grep -c 'verdict=ESCALATE ' || true)
held=$(cat "$FIX/race.a" "$FIX/race.b" | grep -c 'verdict=ESCALATION-CLAIMED ' || true)
rcs=$(cat "$FIX/race.a.rc" "$FIX/race.b.rc" | sort | tr '\n' ' ')
if [ "$pages" -eq 1 ] && [ "$held" -eq 1 ] && [ "$rcs" = "0 1 " ]; then ok; else bad "two runs at the threshold: $pages paged, $held held, exits '$rcs'"; fi

# A lock nobody will release: a fresh one is respected, an old one is taken over.
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null
mkdir "$STATE.lock"
check "a held lock is UNKNOWN" 2 "verdict=UNKNOWN" $SLOT
state_has "a held lock leaves the count where it was" '.observations == 1'
touch -t 202001010000 "$STATE.lock"
check "a lock left by a dead run is taken over" 0 "observations=2/3" $SLOT
if [ ! -e "$STATE.lock" ]; then ok; else bad "the lock was not released"; fi
# Many waiters meeting one dead lock: exactly one of them may reap it, so the lock is never held
# twice (which would page twice) and never left behind (which would blind the next runs).
doubles=0; stranded=0; unpaged=0
for _ in 1 2 3 4 5 6; do
  reset; watch 0 >/dev/null; watch $SLOT >/dev/null
  mkdir "$STATE.lock"; touch -t 202001010000 "$STATE.lock"
  for k in 1 2 3 4 5 6 7 8 9 10 11 12; do
    (watch $((2 * SLOT + k)) > "$FIX/herd.$k" 2>&1 || true) &
  done
  wait
  n=$(cat "$FIX"/herd.* | grep -c 'verdict=ESCALATE ' || true)
  [ "$n" -le 1 ] || doubles=$((doubles + 1))
  [ "$n" -ge 1 ] || unpaged=$((unpaged + 1))
  if [ -e "$STATE.lock" ] || [ -e "$STATE.reap" ]; then stranded=$((stranded + 1)); fi
  rm -f "$FIX"/herd.*
done
if [ "$doubles" -eq 0 ] && [ "$stranded" -eq 0 ] && [ "$unpaged" -eq 0 ]; then ok; else bad "twelve waiters on a dead lock, 6 rounds: $doubles paged twice, $stranded left a lock, $unpaged did not page"; fi

reset; mkdir -p "$FIX/state"; chmod 500 "$FIX/state"
if [ "$(id -u)" -ne 0 ]; then
  check "an unwritable state directory is UNKNOWN" 2 "verdict=UNKNOWN" 0
else
  ok
fi
chmod 700 "$FIX/state"

# --- a lane with more than one engineer entry (monorepo#4117) ------------------------------------
# The lane is down only when EVERY entry is down. One dead entry beside a producing one is named in
# the summary and never counted or paged; a partial reading with nothing seen producing is UNKNOWN.
SECOND=agentic-engineer-2
DOWN_SECOND="  NOT-PRODUCING  ${SECOND} -- dispatched at 2026-10-03T04:23:00Z and no session started within 120s of it"
DOWN_SECOND_QUOTA="  NOT-PRODUCING  ${SECOND} -- newest run ended at once (cause=quota/billing)"
DOWN_FIRST_QUOTA='  NOT-PRODUCING  daily-ai-assistant -- newest run ended at once (cause=quota/billing)'
# entry <id> <rc> <line>... — set what the stubbed check prints and returns for ONE entry
entry() {
  local id=$1; shift
  printf '%s\n' "$1" > "$FIX/entry.$id.rc"; shift
  printf '%s\n' "header line" "$@" > "$FIX/entry.$id.out"
}
PAIR="daily-ai-assistant,${SECOND}"
calls() { wc -l < "$FIX/liveness.calls" 2>/dev/null | tr -d ' ' || echo 0; }

reset; entry daily-ai-assistant 0 "$OK_LINE"; entry "$SECOND" 0 "  OK  ${SECOND} -- produced work"
out=$(watch 0 --entries "$PAIR"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "verdict=OK lane=claude observations=0/3 first_seen_epoch=0 notified_epoch=0 cause=none" ]; then ok
else bad "two producing entries must read OK with no entry note (rc=$rc: $out)"; fi
if [ "$(calls)" = 2 ] && grep -q -- "^--task daily-ai-assistant --grace-seconds 300 " "$FIX/liveness.calls" &&
  grep -q -- "^--task ${SECOND} --grace-seconds 300 " "$FIX/liveness.calls"; then ok
else bad "each entry must be judged once, by its own id: $(cat "$FIX/liveness.calls" 2>/dev/null)"; fi

reset; entry daily-ai-assistant 0 "$OK_LINE"; entry "$SECOND" 1 "$DOWN_SECOND"
for i in 0 1 2 3 4; do
  check "a dead second entry beside a producing first is reported, slot $i" 0 "verdict=OK lane=claude observations=0/3 first_seen_epoch=0 notified_epoch=0 cause=none degraded=${SECOND}" $((i * SLOT)) --entries "$PAIR"
done
no_state "a degraded lane must not start a count"

# A dead FIRST entry must not page while the second produces, and a count both entries built ends
# the moment either produces again.
reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"; entry "$SECOND" 1 "$DOWN_SECOND"
check "both entries down starts the count" 0 "verdict=WATCHING lane=claude observations=1/3" 0 --entries "$PAIR"
check "both entries down, second slot" 0 "observations=2/3" $SLOT --entries "$PAIR"
entry "$SECOND" 0 "  OK  ${SECOND} -- produced work"
check "the second entry producing ends the outage" 0 "cause=none degraded=daily-ai-assistant" $((2 * SLOT)) --entries "$PAIR"
no_state "a lane with one producing entry must clear the count"
for i in 3 4 5 6; do
  check "a dead first entry beside a producing second never pages, slot $i" 0 "verdict=OK" $((i * SLOT)) --entries "$PAIR"
done

reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"; entry "$SECOND" 1 "$DOWN_SECOND"
check "all entries down, slot 1" 0 "verdict=WATCHING" 0 --entries "$PAIR"
check "all entries down, slot 2" 0 "verdict=WATCHING" $SLOT --entries "$PAIR"
check "all entries down for the threshold pages once" 1 "verdict=ESCALATE lane=claude observations=3/3" $((2 * SLOT)) --entries "$PAIR"

reset; entry daily-ai-assistant 1 "$DOWN_FIRST_QUOTA"; entry "$SECOND" 1 "$DOWN_SECOND_QUOTA"
check "every entry on a usage limit is a known reset" 0 "verdict=KNOWN-RESET" 0 --entries "$PAIR"
no_state "a usage limit on every entry must not start a count"
reset; entry daily-ai-assistant 1 "$DOWN_FIRST_QUOTA"; entry "$SECOND" 1 "$DOWN_SECOND"
check "a usage limit on one entry does not excuse the other" 0 "verdict=WATCHING lane=claude observations=1/3" 0 --entries "$PAIR"

# Nothing seen producing and one entry unjudged: the lane cannot be called down.
reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"; entry "$SECOND" 1 "$DOWN_SECOND"
check "seed one bad slot" 0 "observations=1/3" 0 --entries "$PAIR"
entry "$SECOND" 2 "could not judge"
check "one unjudged entry and none producing is UNKNOWN" 2 "verdict=UNKNOWN" $SLOT --entries "$PAIR"
state_has "an unjudged look must leave the count where it was" '.observations == 1'
entry "$SECOND" 1 "a line that names no task"
check "an entry exiting 1 without a NOT-PRODUCING line is unjudged" 2 "verdict=UNKNOWN" $SLOT --entries "$PAIR"
state_has "a malformed entry verdict must leave the count where it was" '.observations == 1'
entry daily-ai-assistant 0 "$OK_LINE"; entry "$SECOND" 2 "could not judge"
check "an unjudged entry beside a producing one is named, not fatal" 0 "cause=none unjudged=${SECOND}" $SLOT --entries "$PAIR"
entry "$SECOND" 1 "$DOWN_SECOND"; entry third-entry 2 "could not judge"
check "a dead and an unjudged entry beside a producing one are both named" 0 "cause=none degraded=${SECOND} unjudged=third-entry" $SLOT --entries "${PAIR},third-entry"

# The Codex check takes its entries through its own flag.
reset; entry daily-ai-engineer 0 "  OK  daily-ai-engineer"; entry "$SECOND" 1 "$DOWN_SECOND"
out=$(bash "$STUBBED" --lane codex --state-file "$FIX/state/codex.json" --now-epoch "$T0" --entries "daily-ai-engineer,${SECOND}" 2>/dev/null) || true
if grep -qF "verdict=OK lane=codex" <<<"$out" && grep -qF "degraded=${SECOND}" <<<"$out" &&
  grep -q -- "^--automation daily-ai-engineer --now-ms ${T0}000\$" "$FIX/liveness.calls" &&
  grep -q -- "^--automation ${SECOND} --now-ms ${T0}000\$" "$FIX/liveness.calls"; then ok
else bad "the codex lane must judge each entry through --automation: $out / $(cat "$FIX/liveness.calls" 2>/dev/null)"; fi

# --- an entry the scheduler is not dispatching (monorepo#4116) -----------------------------------
# The lane names an entry before its runtime entry exists, and an entry can be switched off later.
# The liveness check answers UNKNOWN for it and names it on a NOT-SCHEDULED line. Such an entry is
# reported, never read as healthy, and never holds back the outage of the entries that do run.
NOT_SCHEDULED="  NOT-SCHEDULED  ${SECOND} -- the scheduler holds no entry with this id (not created yet, or removed)"
reset; entry daily-ai-assistant 0 "$OK_LINE"; entry "$SECOND" 2 "$NOT_SCHEDULED"
out=$(watch 0 --entries "$PAIR"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "verdict=OK lane=claude observations=0/3 first_seen_epoch=0 notified_epoch=0 cause=none unscheduled=${SECOND}" ]; then ok
else bad "a producing first entry beside one not created yet must read OK and name it (rc=$rc: $out)"; fi
no_state "an entry that is not created yet must not start a count"
if grep -qE 'unjudged=|degraded=' <<<"$out"; then bad "an entry that is not scheduled is neither unjudged nor degraded: $out"; else ok; fi

# The outage this watch exists for, in the window before the second entry is created: the first
# entry dies and the second does not exist. That must count and page exactly as a one-entry lane did.
reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"; entry "$SECOND" 2 "$NOT_SCHEDULED"
check "a dead first entry beside one not created yet counts" 0 "verdict=WATCHING lane=claude observations=1/3 first_seen_epoch=$T0 notified_epoch=0 cause=unknown unscheduled=${SECOND}" 0 --entries "$PAIR"
check "a dead first entry beside one not created yet, second slot" 0 "observations=2/3" $SLOT --entries "$PAIR"
check "a dead first entry beside one not created yet pages" 1 "verdict=ESCALATE lane=claude observations=3/3" $((2 * SLOT)) --entries "$PAIR"
check "the page names the entry that is not scheduled" 0 "verdict=ESCALATION-CLAIMED lane=claude observations=3/3" $((2 * SLOT + 60)) --entries "$PAIR"
case "$(watch $((2 * SLOT + 120)) --entries "$PAIR")" in *" unscheduled=${SECOND}") ok ;; *) bad "an outage verdict must still name the entry that is not scheduled" ;; esac
# The second entry is created and produces: the outage is over.
entry "$SECOND" 0 "  OK  ${SECOND} -- produced work"
check "the second entry, once created and producing, ends the outage" 0 "cause=none degraded=daily-ai-assistant" $((3 * SLOT)) --entries "$PAIR"
no_state "a lane whose new entry produces must clear the count"
# A usage limit on the only scheduled entry is still a known reset.
reset; entry daily-ai-assistant 1 "$DOWN_FIRST_QUOTA"; entry "$SECOND" 2 "$NOT_SCHEDULED"
check "a usage limit on the only scheduled entry is a known reset" 0 "verdict=KNOWN-RESET lane=claude observations=0/3 first_seen_epoch=0 notified_epoch=0 cause=quota/billing unscheduled=${SECOND}" 0 --entries "$PAIR"

# No entry of the lane is scheduled: there is nothing to call down, and nothing produced.
reset; entry daily-ai-assistant 2 "  NOT-SCHEDULED  daily-ai-assistant -- the scheduler holds this entry switched off"; entry "$SECOND" 2 "$NOT_SCHEDULED"
check "a lane with no scheduled entry is UNKNOWN" 2 "verdict=UNKNOWN" 0 --entries "$PAIR"
no_state "a lane with no scheduled entry must not start a count"
hint=$(bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch "$T0" --entries "$PAIR" 2>&1 >/dev/null || true)
if grep -qF 'dispatching no engineer entry of the claude lane' <<<"$hint"; then ok; else bad "a lane with no scheduled entry must say so: $hint"; fi

# An entry that could not be judged still makes a look with nothing producing UNKNOWN, whatever
# else is not scheduled.
reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"; entry "$SECOND" 2 "$NOT_SCHEDULED"; entry third-entry 2 "could not judge"
check "an unjudged entry beside a dead and an unscheduled one is UNKNOWN" 2 "verdict=UNKNOWN" 0 --entries "${PAIR},third-entry"
no_state "a partial reading must not start a count"

# The marker is read narrowly. Only exit 2 carries it, it must name THIS entry, and an id that
# merely starts with the entry's id is another entry.
reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"
entry "$SECOND" 2 "  NOT-SCHEDULED  ${SECOND}0 -- the scheduler holds no entry with this id (not created yet, or removed)"
check "a NOT-SCHEDULED line naming a longer id is not this entry" 2 "verdict=UNKNOWN" 0 --entries "$PAIR"
entry "$SECOND" 2 "  NOT-SCHEDULED  daily-ai-assistant -- the scheduler holds this entry switched off"
check "a NOT-SCHEDULED line naming another entry is not this entry" 2 "verdict=UNKNOWN" 0 --entries "$PAIR"
entry "$SECOND" 2 "the text NOT-SCHEDULED  ${SECOND} inside a sentence"
check "NOT-SCHEDULED must open the line" 2 "verdict=UNKNOWN" 0 --entries "$PAIR"
entry "$SECOND" 3 "$NOT_SCHEDULED"
check "only exit 2 carries NOT-SCHEDULED" 2 "verdict=UNKNOWN" 0 --entries "$PAIR"
no_state "a marker that does not name the entry must not start a count"
# The exit status still decides: a verdict beside the marker is the verdict.
entry "$SECOND" 0 "$NOT_SCHEDULED" "  OK  ${SECOND} -- produced work"
check "exit 0 beside a NOT-SCHEDULED line is producing" 0 "cause=none degraded=daily-ai-assistant" 0 --entries "$PAIR"
entry "$SECOND" 1 "$NOT_SCHEDULED" "$DOWN_SECOND"
out=$(watch 0 --entries "$PAIR") || true
if grep -qF "verdict=WATCHING lane=claude observations=1/3" <<<"$out" && ! grep -qF 'unscheduled=' <<<"$out"; then ok
else bad "exit 1 beside a NOT-SCHEDULED line is a dead entry, not an unscheduled one: $out"; fi

# Negative control: a watch that reads NOT-SCHEDULED as "could not judge" must FAIL the outage case
# above, and for that reason: it answers UNKNOWN for as long as the second entry does not exist.
mkdir -p "$FIX/mutant"
cp "$FIX/bin/"*-lane-liveness.sh "$FIX/mutant/"
# shellcheck disable=SC2016 # The pattern and its replacement are literal script text.
sed 's/^      if \[ "\$entry_rc" -eq 2 \] &&$/      if false \&\&/' "$SCRIPT" > "$FIX/mutant/sibling-lane-watch.sh"
if cmp -s "$SCRIPT" "$FIX/mutant/sibling-lane-watch.sh"; then
  bad "negative control: the NOT-SCHEDULED mutation did not change the script"
else
  reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"; entry "$SECOND" 2 "$NOT_SCHEDULED"
  mutant_rc=0
  out=$(bash "$FIX/mutant/sibling-lane-watch.sh" --lane claude --state-file "$STATE" --now-epoch "$T0" --entries "$PAIR" 2>/dev/null) || mutant_rc=$?
  if [ "$mutant_rc" -eq 2 ] && grep -qF "verdict=UNKNOWN" <<<"$out" && [ ! -e "$STATE" ]; then ok
  else bad "negative control: a watch that reads NOT-SCHEDULED as unjudged should answer UNKNOWN and count nothing (rc=$mutant_rc: $out)"; fi
  out=$(watch 0 --entries "$PAIR") || true
  if grep -qF "verdict=WATCHING lane=claude observations=1/3" <<<"$out"; then ok
  else bad "the real watch must count the same fixture: $out"; fi
fi

# A malformed set is refused before any check runs: an id reaches the check as an argument.
for bad_set in "" "daily-ai-assistant," ",daily-ai-assistant" "a,,b" "a,a" "Daily" "-x" "a b" 'a;b' "a,b,c,d,e"; do
  reset
  out=$(watch 0 --entries "$bad_set") && rc=0 || rc=$?
  if [ "$rc" -eq 2 ] && grep -qF "verdict=UNKNOWN" <<<"$out" && [ ! -e "$FIX/liveness.calls" ]; then ok
  else bad "a malformed --entries value must be UNKNOWN before any check runs: '$bad_set' (rc=$rc, calls=$(calls))"; fi
done

# Negative control: a watch that judges only the first entry must FAIL the case above that needs the
# second, and for that reason — it keeps counting an outage the second entry had ended.
mkdir -p "$FIX/mutant"
cp "$FIX/bin/"*-lane-liveness.sh "$FIX/mutant/"
# shellcheck disable=SC2016 # The pattern and its replacement are literal script text.
sed 's/^for entry in "\${ENTRY_LIST\[@\]}"; do$/for entry in "${ENTRY_LIST[0]}"; do/' "$SCRIPT" > "$FIX/mutant/sibling-lane-watch.sh"
if cmp -s "$SCRIPT" "$FIX/mutant/sibling-lane-watch.sh"; then
  bad "negative control: the mutation did not change the script"
else
  reset; entry daily-ai-assistant 1 "$DOWN_NO_SESSION"; entry "$SECOND" 0 "  OK  ${SECOND} -- produced work"
  out=$(bash "$FIX/mutant/sibling-lane-watch.sh" --lane claude --state-file "$STATE" --now-epoch "$T0" --entries "$PAIR" 2>/dev/null) || true
  if grep -qF "verdict=WATCHING lane=claude observations=1/3" <<<"$out"; then ok
  else bad "negative control: a first-entry-only watch should count the slot the second entry covers: $out"; fi
  out=$(watch 0 --entries "$PAIR") || true
  if grep -qF "verdict=OK" <<<"$out" && grep -qF "degraded=daily-ai-assistant" <<<"$out"; then ok
  else bad "the real watch must read the same fixture as OK and degraded: $out"; fi
fi
reset

# --- usage ---------------------------------------------------------------------------------------
usage() {
  local name=$1; shift
  local rc=0
  bash "$STUBBED" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then ok; else bad "$name (rc=$rc want=2)"; fi
}
reset; liveness 1 "$DOWN_NO_SESSION"
usage "a missing lane is a usage error" --state-file "$STATE"
usage "an unregistered lane is a usage error" --lane cursor --state-file "$STATE"
usage "a zero threshold is a usage error" --lane claude --state-file "$STATE" --threshold 0
usage "an oversized threshold is a usage error" --lane claude --state-file "$STATE" --threshold 99999
usage "a non-numeric clock is a usage error" --lane claude --state-file "$STATE" --now-epoch soon
usage "an oversized clock is a usage error" --lane claude --state-file "$STATE" --now-epoch 999999999999
usage "a retired flag is a usage error" --lane claude --state-file "$STATE" --min-gap-seconds 60
usage "an unknown flag is a usage error" --lane claude --state-file "$STATE" --send
usage "a flag without its value is a usage error" --lane claude --state-file
no_state "a usage error must not create state"

# The default state file belongs to the CALLER's runtime, never the watched lane's.
reset
for pair in "claude:.codex/lane-watch/claude.json" "codex:.claude/lane-watch/codex.json"; do
  default_rc=0
  HOME="$FIX/home" bash "$STUBBED" --lane "${pair%%:*}" >/dev/null 2>&1 || default_rc=$?
  if [ "$default_rc" -eq 0 ] && [ -f "$FIX/home/${pair#*:}" ]; then ok; else bad "watching ${pair%%:*} did not write ${pair#*:} (rc=$default_rc)"; fi
done

# --- the real Claude check, at the offsets the deployment actually runs at -----------------------
# The Claude scheduler dispatches the `:50` task 3 to 13 minutes late (measured 523 s and 763 s), and
# the Codex run that watches it starts at `:10`. With the liveness check's default 900 s grace that
# run always landed inside the grace window and read UNKNOWN, so the outage this script exists for
# could not page. Driving the real check keeps the two scripts' numbers honest with each other.
iso_at() {
  local out
  out=$(date -u -r "$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || out=""
  [ -n "$out" ] || { echo "FAIL: cannot render epoch $1 as ISO" >&2; exit 1; }
  printf '%s.000Z\n' "$out"
}
touch_at() {
  local out
  out=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  [ -n "$out" ] || { echo "FAIL: cannot render epoch $1 as a touch stamp" >&2; exit 1; }
  printf '%s\n' "$out"
}
# session_at <file> <dispatch-epoch> [task] — a transcript attributable to an hourly task, with one turn
session_at() {
  {
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<scheduled-task name=\\"%s\\" file=\\"/x\\">go</scheduled-task>"}}\n' "$(iso_at $(($2 + 1)))" "${3:-daily-ai-assistant}"
    printf '{"type":"assistant","timestamp":"%s"}\n' "$(iso_at $(($2 + 20)))"
    printf '{"type":"system","timestamp":"%s"}\n' "$(iso_at $(($2 + 200)))"
  } > "$1"
  touch -t "$(touch_at $(($2 + 200)))" "$1"
}
REAL="$FIX/real"
SCHEDULED=$((T0 - 600))          # the :50 slot
CODEX_RUN=$((T0 + 604))          # the Codex run at :10:04
# real_case <name> <jitter-seconds> <session: none|healthy> <want-rc> <want-stdout-substring>
real_case() {
  local name=$1 jitter=$2 session=$3 want_rc=$4 want=$5 dispatched out rc=0
  dispatched=$((SCHEDULED + jitter))
  rm -rf "$REAL"; mkdir -p "$REAL/projects/proj-a"
  printf '{"scheduledTasks":[{"id":"daily-ai-assistant","enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"50 * * * *","filePath":"/x","cwd":"/y"}]}\n' \
    "$(iso_at "$dispatched")" "$(iso_at "$SCHEDULED")" > "$REAL/store.json"
  # The slot before always ran, as it does in a real store: with no attributable transcript at all
  # the check cannot tell a dead lane from a changed marker and answers UNKNOWN.
  session_at "$REAL/projects/proj-a/previous.jsonl" $((dispatched - 3600))
  [ "$session" != healthy ] || session_at "$REAL/projects/proj-a/newest.jsonl" "$dispatched"
  out=$(CLAUDE_SCHEDULE_STORE_PATH="$REAL/store.json" CLAUDE_PROJECTS_ROOT="$REAL/projects" \
    bash "$SCRIPT" --lane claude --state-file "$REAL/state.json" --now-epoch "$CODEX_RUN" 2>/dev/null) || rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want" <<<"$out"; then ok; else bad "$name (rc=$rc want=$want_rc, wanted '$want': $out)"; fi
}
real_case "a dead dispatch at the latest measured jitter is judged from the Codex run" 763 none 0 "verdict=WATCHING lane=claude observations=1/3"
real_case "a dead dispatch at the shorter measured jitter is judged too" 523 none 0 "verdict=WATCHING lane=claude observations=1/3"
real_case "a healthy dispatch at the latest measured jitter reads OK" 763 healthy 0 "verdict=OK"
real_case "a healthy dispatch at the shorter measured jitter reads OK" 523 healthy 0 "verdict=OK"
# A dispatch younger than the short grace is still in flight, and that stays UNKNOWN.
real_case "a dispatch four minutes old is still UNKNOWN" 964 none 2 "verdict=UNKNOWN"
# The store above holds the first entry only, which is the deployment between this change and the
# creation of the second entry. The real check must name the second as not scheduled, and the cases
# above show it neither hides the first entry's outage nor reads as healthy.
real_case "the real check names an entry that is not created yet" 763 healthy 0 "cause=none unscheduled=agentic-engineer-2"
real_case "a dead first entry is still counted while the second is not created" 763 none 0 "cause=unknown unscheduled=agentic-engineer-2"

# The lane with both entries, read by the real check. The second entry is scheduled at `:20`, so the
# Codex run at `:10` reads its dispatch of the hour before.
SECOND_SCHEDULED=$((T0 - 2400))
# real_pair <name> <first: none|healthy> <second: none|healthy|off> <want-rc> <want-stdout-substring>
real_pair() {
  local name=$1 first=$2 second=$3 want_rc=$4 want=$5 d1 d2 enabled=true out rc=0
  d1=$((SCHEDULED + 763)); d2=$((SECOND_SCHEDULED + 523))
  [ "$second" != off ] || enabled=false
  rm -rf "$REAL"; mkdir -p "$REAL/projects/proj-a"
  printf '{"scheduledTasks":[{"id":"daily-ai-assistant","enabled":true,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"50 * * * *","filePath":"/x","cwd":"/y"},{"id":"agentic-engineer-2","enabled":%s,"lastRunAt":"%s","lastScheduledFor":"%s","cronExpression":"20 * * * *","filePath":"/x2","cwd":"/y"}]}\n' \
    "$(iso_at "$d1")" "$(iso_at "$SCHEDULED")" "$enabled" "$(iso_at "$d2")" "$(iso_at "$SECOND_SCHEDULED")" > "$REAL/store.json"
  session_at "$REAL/projects/proj-a/previous.jsonl" $((d1 - 3600))
  [ "$first" != healthy ] || session_at "$REAL/projects/proj-a/first.jsonl" "$d1"
  [ "$second" != healthy ] || session_at "$REAL/projects/proj-a/second.jsonl" "$d2" agentic-engineer-2
  out=$(CLAUDE_SCHEDULE_STORE_PATH="$REAL/store.json" CLAUDE_PROJECTS_ROOT="$REAL/projects" \
    bash "$SCRIPT" --lane claude --state-file "$REAL/state.json" --now-epoch "$CODEX_RUN" 2>/dev/null) || rc=$?
  if [ "$rc" -eq "$want_rc" ] && [ "$out" = "$want" ]; then ok; else bad "$name (rc=$rc want=$want_rc, wanted '$want': $out)"; fi
}
OK_PREFIX="verdict=OK lane=claude observations=0/3 first_seen_epoch=0 notified_epoch=0 cause=none"
real_pair "two producing entries read OK with nothing to report" healthy healthy 0 "$OK_PREFIX"
real_pair "a dead second entry beside a producing first is degraded, not an outage" healthy none 0 "$OK_PREFIX degraded=agentic-engineer-2"
real_pair "a dead first entry beside a producing second is degraded, not an outage" none healthy 0 "$OK_PREFIX degraded=daily-ai-assistant"
real_pair "two dead entries are the outage" none none 0 "verdict=WATCHING lane=claude observations=1/3 first_seen_epoch=$CODEX_RUN notified_epoch=0 cause=unknown"
real_pair "a second entry switched off is named beside a producing first" healthy off 0 "$OK_PREFIX unscheduled=agentic-engineer-2"
real_pair "a second entry switched off does not hide a dead first" none off 0 "verdict=WATCHING lane=claude observations=1/3 first_seen_epoch=$CODEX_RUN notified_epoch=0 cause=unknown unscheduled=agentic-engineer-2"

# --- contract: every run watches its sibling, and the DM rules are stated where they are used ----
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
AGENTS="$REPO_ROOT/AGENTS.md"
CHANNELS="$REPO_ROOT/.claude/guides/maintainer-channels.md"

every_run=$(awk '/^The deployed definition is assembled/{on=1} on && /^Assembly and pin reading/{exit} on' "$AGENTS")
[ -n "$every_run" ] || { echo "FAIL: could not find the every-run list in AGENTS.md" >&2; exit 1; }
if grep -qF 'sibling-lane-watch.sh' <<<"$every_run"; then ok; else bad "contract — AGENTS.md every-run list does not name the watch"; fi

section=$(awk '/^## Sibling lane outage/{on=1; print; next} on && /^## /{exit} on' "$CHANNELS")
[ -n "$section" ] || { echo "FAIL: maintainer-channels.md has no 'Sibling lane outage' section" >&2; exit 1; }
# shellcheck disable=SC2016  # the backticks are literal Markdown, not a command substitution
for needle in 'sibling-lane-watch.sh --lane' '--mark-notified' 'Exit `1`' 'Exit `2`' 'KNOWN-RESET' \
  'ESCALATION-CLAIMED' '`verdict=ESCALATE`' 'both directions' 'once per outage' 'cause class' \
  'three hourly slots running' 'once more before the run report' \
  '`degraded=<ids>`' '`unjudged=<ids>`' '`unscheduled=<ids>`' 'not created yet'; do
  if grep -qF -- "$needle" <<<"$section"; then ok; else bad "contract — the outage section lacks: $needle"; fi
done
if grep -qE '^THRESHOLD=3$' "$SCRIPT"; then ok; else bad "the script default threshold is not 3"; fi
# The slot arithmetic uses the minute each lane's hourly task is scheduled at. Pin it to the Cadence
# table, so a schedule change cannot leave the watch counting the wrong slots.
cadence=$(awk '/^### Cadence & focus/{on=1; next} on && /^### /{exit} on' "$AGENTS")
[ -n "$cadence" ] || { echo "FAIL: could not find Cadence & focus in AGENTS.md" >&2; exit 1; }
for pair in claude:50 codex:10; do
  lane=${pair%%:*}; minute=${pair##*:}
  if grep -qF -- "\`${lane}/*\`, hourly at \`:${minute}\`" <<<"$cadence" &&
    awk -v lane="$lane" -v m="$minute" '$1 == lane")" {on=1} on && $1 == "sibling_minute=" m {found=1} on && /;;/ {exit} END {exit !found}' "$SCRIPT"; then
    ok
  else
    bad "contract — the watch's minute for the $lane lane does not match the Cadence table"
  fi
done
# The table gives each lane two engineer starts an hour, one per scheduler entry, and the watch must
# judge both entries. A table that gained or lost a start without the watch's entry list following
# would leave an entry unwatched, or page on one that no longer exists.
for triple in "claude:daily-ai-assistant,agentic-engineer-2:20:50" "codex:daily-ai-engineer,agentic-engineer-2:10:40"; do
  lane=${triple%%:*}; rest=${triple#*:}; entries=${rest%%:*}; minutes=${rest#*:}
  row=$(grep -F -- "\`${lane}/*\`" <<<"$cadence" || true)
  if grep -qF -- "| Every hour at \`:${minutes%%:*}\` and \`:${minutes##*:}\` |" <<<"$row" &&
    awk -v lane="$lane" -v e="$entries" '$1 == lane")" {on=1} on && $1 == "default_entries=\"" e "\"" {found=1} on && /;;/ {exit} END {exit !found}' "$SCRIPT"; then
    ok
  else
    bad "contract — the $lane lane's two engineer starts in the Cadence table do not match the watch's entries ($entries)"
  fi
done

# Exercise both real Codex entries with short completed audits (#4208). Nothing in this
# fixture reads the host's scheduler, transcripts, watch state or notification channels.
command -v sqlite3 >/dev/null || { echo "FAIL: sqlite3 is required" >&2; exit 1; }
CODEX_REAL="$FIX/codex-real"
mkdir -p "$CODEX_REAL/sessions"
cp "$SCRIPT" "$CODEX_REAL/sibling-lane-watch.sh"
cat > "$CODEX_REAL/codex-lane-liveness.sh" <<EOF
#!/usr/bin/env bash
exec bash "$SCRIPT_DIR/codex-lane-liveness.sh" --store "$CODEX_REAL/store.db" --sessions "$CODEX_REAL/sessions" "\$@"
EOF
chmod +x "$CODEX_REAL/codex-lane-liveness.sh"
sqlite3 "$CODEX_REAL/store.db" "
  CREATE TABLE automations(id TEXT, status TEXT, next_run_at INTEGER);
  CREATE TABLE automation_runs(thread_id TEXT, automation_id TEXT, status TEXT,
    inbox_title TEXT, created_at INTEGER, updated_at INTEGER);
"
for automation in daily-ai-engineer agentic-engineer-2; do
  sqlite3 "$CODEX_REAL/store.db" "INSERT INTO automations VALUES('$automation','ACTIVE',$(( (T0 + 14400) * 1000 )));"
  for age in 600 1200; do
    ended=$(( (T0 - age) * 1000 ))
    sqlite3 "$CODEX_REAL/store.db" "INSERT INTO automation_runs VALUES(
      '$automation-$age','$automation','ARCHIVED','completed audit',$((ended - 540000)),$ended);"
    printf '%s\n' '{"type":"event_msg","payload":{"type":"task_complete","error":null}}' \
      > "$CODEX_REAL/sessions/rollout-fixture-$automation-$age.jsonl"
  done
done
rc=0
out=$(bash "$CODEX_REAL/codex-lane-liveness.sh" --automation daily-ai-engineer --now-ms "${T0}000" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'short-window=2/2' <<<"$out"; then ok
else bad "the completed-short fixture must reach the real duration classifier: rc=$rc $out"; fi
for offset in 0 "$SLOT" "$((2 * SLOT))"; do
  rc=0
  out=$(bash "$CODEX_REAL/sibling-lane-watch.sh" --lane codex \
    --entries daily-ai-engineer,agentic-engineer-2 --state-file "$CODEX_REAL/state.json" \
    --now-epoch "$((T0 + offset))" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'verdict=UNKNOWN' <<<"$out"; then ok
  else bad "real completed-short Codex entries must remain UNKNOWN, not an outage: rc=$rc $out"; fi
done
if [ ! -e "$CODEX_REAL/state.json" ]; then ok
else bad "short completed audits must not accumulate outage observations"; fi

# A true outputless stub still enters the existing three-slot escalation path.
sqlite3 "$CODEX_REAL/store.db" "UPDATE automation_runs SET inbox_title=NULL, created_at=updated_at-4000;"
for offset in 0 "$SLOT" "$((2 * SLOT))"; do
  want_rc=0; want_verdict=WATCHING
  if [ "$offset" -eq "$((2 * SLOT))" ]; then want_rc=1; want_verdict=ESCALATE; fi
  rc=0
  out=$(bash "$CODEX_REAL/sibling-lane-watch.sh" --lane codex \
    --entries daily-ai-engineer,agentic-engineer-2 --state-file "$CODEX_REAL/state.json" \
    --now-epoch "$((T0 + offset))" 2>/dev/null) || rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF "verdict=$want_verdict" <<<"$out"; then ok
  else bad "real Codex stubs must retain escalation: rc=$rc $out"; fi
done

echo "sibling-lane-watch.test: $pass passed, $fail failed"
test_run_completed=1
[ "$fail" -eq 0 ]
