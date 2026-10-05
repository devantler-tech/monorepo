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
trap 'rm -rf "$FIX"' EXIT
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
[ ! -f "$FIX/liveness.sleep" ] || sleep "\$(cat "$FIX/liveness.sleep")"
cat "$FIX/liveness.out"
exit "\$(cat "$FIX/liveness.rc")"
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

reset() { chmod -R u+w "$FIX/state" 2>/dev/null || true; rm -rf "$FIX/state" "$FIX/liveness.sleep"; }

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
check "one unobserved slot is tolerated" 1 "verdict=ESCALATE lane=claude observations=3/3" $((3 * SLOT))
reset
watch 0 >/dev/null; watch $SLOT >/dev/null
check "a count two slots stale starts again instead of paging" 0 "verdict=WATCHING lane=claude observations=1/3" $((4 * SLOT))
state_has "a restarted count restarts first_seen" ".first_seen_epoch == $((T0 + 4 * SLOT))"

# --- a usage limit has a known reset and must not page -------------------------------------------
reset; liveness 1 "$DOWN_QUOTA" "$DOWN_QUOTA"
check "quota-only outage: slot one" 0 "verdict=KNOWN-RESET" 0
check "quota-only outage: slot five" 0 "verdict=KNOWN-RESET" $((4 * SLOT))
check "quota-only outage: a day later" 0 "verdict=KNOWN-RESET" $((24 * SLOT))
no_state "a quota-only outage must not start a count"
# ...but one task down for another cause beside a quota refusal is not a known reset.
liveness 1 "$DOWN_QUOTA" "$DOWN_NO_SESSION"
check "a mixed outage counts" 0 "verdict=WATCHING lane=claude observations=1/3" $((25 * SLOT))
# A quota observation in the middle neither advances nor clears the running count.
liveness 1 "$DOWN_QUOTA"
check "a quota slot leaves the count alone" 0 "verdict=KNOWN-RESET" $((26 * SLOT))
liveness 1 "$DOWN_NO_SESSION"
check "the count resumes after the quota slot" 0 "observations=2/3" $((27 * SLOT))
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

# --- only the hourly task is judged, by the check beside the script ------------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null
args=$(cat "$FIX/liveness.args")
case "$args" in *"--task daily-ai-assistant --grace-seconds 300 --now-epoch $T0") ok ;; *) bad "the Claude check is not limited to the hourly task with the short grace: $args" ;; esac
bash "$STUBBED" --lane codex --state-file "$FIX/state/codex.json" --now-epoch "$T0" >/dev/null 2>&1 || true
args=$(cat "$FIX/liveness.args")
case "$args" in "--automation daily-ai-engineer --now-ms ${T0}000") ok ;; *) bad "the Codex check is not limited to the hourly automation: $args" ;; esac
# No environment variable can swap the check for another program.
printf '#!/usr/bin/env bash\necho "  OK  x"\nexit 0\n' > "$FIX/fake-ok"; chmod +x "$FIX/fake-ok"
reset
out=$(SIBLING_LANE_LIVENESS_CMD="$FIX/fake-ok" bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch "$T0" 2>/dev/null) || true
case "$out" in *verdict=WATCHING*) ok ;; *) bad "an environment variable replaced the liveness check: $out" ;; esac

# --- fail closed ---------------------------------------------------------------------------------
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch $SLOT >/dev/null
liveness 2 "  UNKNOWN  daily-ai-assistant -- newest dispatch is still within the grace window"
check "an UNKNOWN liveness verdict is UNKNOWN" 2 "verdict=UNKNOWN" $((2 * SLOT))
state_has "an UNKNOWN slot leaves the count where it was" '.observations == 2'
hint=$(bash "$STUBBED" --lane claude --state-file "$STATE" --now-epoch $((T0 + 2 * SLOT)) 2>&1 >/dev/null || true)
if grep -qF 'once more before the run report' <<<"$hint"; then ok; else bad "an UNKNOWN liveness verdict does not ask for a second look"; fi
liveness 1 "$DOWN_NO_SESSION"
check "the slot after an UNKNOWN one still completes the count" 1 "observations=3/3" $((3 * SLOT))

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

# --- two runs at once ----------------------------------------------------------------------------
# A slow check holds a run between its start and its state update. A --mark-notified that lands in
# that gap must survive it. The slow run is in a new slot, so it does write the state back.
reset; liveness 1 "$DOWN_NO_SESSION"
watch 0 >/dev/null; watch $SLOT >/dev/null; watch $((2 * SLOT)) >/dev/null || true
echo 2 > "$FIX/liveness.sleep"
watch $((2 * SLOT + 3100)) >/dev/null 2>&1 &
slow_pid=$!
sleep 0.5
rm -f "$FIX/liveness.sleep"
check "a send is recorded while another run is mid-check" 0 "verdict=ALREADY-NOTIFIED" $((2 * SLOT + 3110)) --mark-notified
wait "$slow_pid" || true
state_has "the slower run did not overwrite the recorded send" '.notified_epoch > 0'
state_has "and the slower run still counted its own slot" ".observations == 4"
check "and the outage is not paged again" 0 "verdict=ALREADY-NOTIFIED" $((4 * SLOT))

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

reset; mkdir -p "$FIX/state"; chmod 500 "$FIX/state"
if [ "$(id -u)" -ne 0 ]; then
  check "an unwritable state directory is UNKNOWN" 2 "verdict=UNKNOWN" 0
else
  ok
fi
chmod 700 "$FIX/state"

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
# session_at <file> <dispatch-epoch> — a transcript attributable to the hourly task, with one turn
session_at() {
  {
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<scheduled-task name=\\"daily-ai-assistant\\" file=\\"/x\\">go</scheduled-task>"}}\n' "$(iso_at $(($2 + 1)))"
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
  'three consecutive hourly slots' 'once more before the run report'; do
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

echo "sibling-lane-watch.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
