#!/usr/bin/env bash
# claude-dispatch-rate.test.sh — RED/GREEN coverage for the Claude scheduled-vs-actual dispatch rate.
#
# The rate is only useful if it neither invents drops nor hides them, so both directions are pinned:
# a delayed dispatch that starts before the next slot is NOT a drop, an open slot is never counted,
# and a session that merely quotes the marker is not attributed. Fixtures are synthetic; every case
# pins --now-epoch and TZ=UTC, so no assertion depends on wall-clock time or the host timezone.

set -euo pipefail
export TZ=UTC

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/claude-dispatch-rate.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 2026-09-01T00:00:00Z. Slots below are offsets from here.
BASE=1788220800
NOW=$(( BASE + 24 * 3600 ))
fails=0; asserts=0
note_fail() { echo "FAIL: $1" >&2; fails=$(( fails + 1 )); }

iso_at() {
  local out
  out=$(date -u -r "$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || out=""
  [ -n "$out" ] || { echo "FAIL: cannot render epoch $1" >&2; exit 1; }
  printf '%sZ\n' "$out"
}
touch_at() {
  local out
  out=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  [ -n "$out" ] || out=$(date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null) || out=""
  printf '%s\n' "$out"
}

mkcase() {
  CASE="$TMP/$1"; mkdir -p "$CASE/projects/proj"
  STORE="$CASE/store.json"; PROJECTS="$CASE/projects"
  printf '{"scheduledTasks":[{"id":"eng","enabled":true,"lastRunAt":"x","createdAt":%s,"cronExpression":"%s"},{"id":"imp","enabled":true,"lastRunAt":"x","createdAt":%s,"cronExpression":"0 0,12 * * *"}]}\n' \
    "${CREATED_MS:-$(( (BASE - 86400) * 1000 ))}" "${2:-50 * * * *}" "$(( (BASE - 86400) * 1000 ))" > "$STORE"
}

# A transcript whose first line opens with the task marker, exactly as the runtime writes it.
# `quoted` puts the marker mid-message instead, which must attribute nothing.
mksession() {
  local id=$1 start=$2 shape=${3:-anchored} f bsq='\"' content
  f="$PROJECTS/proj/sess-$id-$start-$RANDOM.jsonl"
  if [ "$shape" = quoted ]; then
    content="see <scheduled-task name=${bsq}${id}${bsq}>"
  else
    content="<scheduled-task name=${bsq}${id}${bsq} file=${bsq}/x${bsq}>go</scheduled-task>"
  fi
  if [ "$shape" = malformed ]; then
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}\n' "$(iso_at "$start")" "$content" > "$f"
  elif [ "$shape" = double ]; then
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' \
      "$(iso_at "$start")" "$content" "$(iso_at "$start")" "$content" > "$f"
  elif [ "$shape" = untimed ]; then
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$content" > "$f"
  else
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' "$(iso_at "$start")" "$content" > "$f"
  fi
  touch -t "$(touch_at $(( start + 600 )))" "$f"
}

OUT=""
run() { OUT=$("$SCRIPT" --store "$STORE" --projects "$PROJECTS" --now-epoch "$NOW" "$@" 2>&1); }

expect() {
  local want_rc=$1 want_out=$2 label=$3; shift 3
  local rc=0
  run "$@" || rc=$?
  asserts=$(( asserts + 1 ))
  [ "$rc" -eq "$want_rc" ] || { note_fail "$label: exit $rc, want $want_rc -- $OUT"; return 0; }
  [ -z "$want_out" ] || case "$OUT" in *"$want_out"*) : ;; *) note_fail "$label: output lacks '$want_out' -- $OUT" ;; esac
}

W=(--task eng --since "$(iso_at "$BASE")" --until "$(iso_at $(( BASE + 6 * 3600 )))")
# Hourly :50 from 00:00 to 06:00 settles five slots: 00:50 .. 04:50 (05:50's successor is past --until).

mkcase all-dispatched
for h in 0 1 2 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
expect 0 "scheduled=5 dispatched=5 dropped=0 drop_rate=0.0%" "every slot dispatched" "${W[@]}"

mkcase delayed-is-not-dropped
for h in 0 1 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
mksession eng $(( BASE + 2 * 3600 + 3000 + 3000 ))   # 02:50 slot starts at 03:40, before 03:50
expect 0 "scheduled=5 dispatched=5 dropped=0" "a dispatch delayed within its interval still counts" "${W[@]}"

mkcase one-dropped
for h in 0 1 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
expect 0 "scheduled=5 dispatched=4 dropped=1 drop_rate=20.0%" "a slot with no session is dropped" "${W[@]}"
expect 0 "$(iso_at $(( BASE + 2 * 3600 + 3000 ))) dropped" "--slots names the dropped slot" "${W[@]}" --slots

mkcase quoted-marker
for h in 0 1 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
mksession eng $(( BASE + 2 * 3600 + 3000 + 5 )) quoted
expect 0 "dispatched=4 dropped=1" "a quoted marker attributes nothing" "${W[@]}"

mkcase other-task
for h in 0 1 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
mksession imp $(( BASE + 2 * 3600 + 3000 + 5 ))
expect 0 "dispatched=4 dropped=1" "another task's session does not fill a slot" "${W[@]}"

mkcase before-window
mksession eng $(( BASE - 60 ))
for h in 1 2 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
expect 0 "dispatched=4 dropped=1" "a session before --since does not fill the first slot" "${W[@]}"

mkcase daily-hours
mksession imp $(( BASE + 5 ))
expect 0 "scheduled=2 dispatched=1 dropped=1" "a daily hour-list cron settles its own slots" \
  --task imp --since "$(iso_at "$BASE")" --until "$(iso_at $(( BASE + 24 * 3600 )))"

mkcase open-slot
mksession eng $(( BASE + 3000 + 5 ))
expect 0 "scheduled=1 dispatched=1" "a slot whose successor is past --until is not counted" \
  --task eng --since "$(iso_at "$BASE")" --until "$(iso_at $(( BASE + 2 * 3600 )))"
expect 2 "no settled slot" "a window with no settled slot is UNKNOWN" \
  --task eng --since "$(iso_at "$BASE")" --until "$(iso_at $(( BASE + 3600 )))"

mkcase untimed
mksession eng $(( BASE + 3000 + 5 )) untimed
expect 2 "no readable start timestamp" "an attributed but untimed transcript is UNKNOWN" "${W[@]}"

mkcase bad-cron '*/5 * * * *'
expect 2 "supported shape" "an unsupported cron is UNKNOWN" "${W[@]}"

mkcase bad-hour '0 0,25 * * *'
mksession eng $(( BASE + 5 ))
expect 2 "unsupported cron hour list" "an out-of-range hour is UNKNOWN even after a valid one" \
  --task eng --since "$(iso_at "$BASE")" --until "$(iso_at "$NOW")"

mkcase malformed-header
mksession eng $(( BASE + 3000 + 5 )) malformed
expect 2 "not valid JSON" "a marker-bearing header that is not JSON is UNKNOWN, not a drop" "${W[@]}"

mkcase double-object-header
for h in 0 1 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
mksession eng $(( BASE + 2 * 3600 + 3000 + 5 )) double
expect 2 "not valid JSON" "a header carrying two JSON objects is UNKNOWN, not a drop" "${W[@]}"

CREATED_MS=$(( (BASE + 3600) * 1000 )) mkcase before-created
expect 2 "predates task" "a window starting before the task existed is UNKNOWN" "${W[@]}"

mkcase multiline-cron '50 * * * *\nINVALID'
expect 2 "supported shape" "a multi-line cron is UNKNOWN, never judged by its first line" "${W[@]}"

mkcase future-start
for h in 0 1 2 3 4; do mksession eng $(( BASE + h * 3600 + 3000 + 5 )); done
mksession eng $(( NOW + 3600 ))
expect 2 "starts after now" "a transcript starting after now is UNKNOWN, not a drop" "${W[@]}"

# Europe/Copenhagen falls back at 2026-10-25T01:00Z, so local 02:30 happens at 00:30Z AND 01:30Z that
# day. A daily 02:30 schedule fires once, so the repeated hour must not become an invented drop.
DST=1792800000   # 2026-10-24T00:00:00Z
mkcase dst-fallback '30 2 * * *'
mksession eng $(( DST + 1800 + 5 ))            # 10-24 02:30 CEST
mksession eng $(( DST + 86400 + 1800 + 5 ))    # 10-25 02:30 CEST (first occurrence)
NOW=$(( DST + 3 * 86400 )) TZ=Europe/Copenhagen expect 0 "scheduled=2 dispatched=2 dropped=0" "a DST-repeated local hour is one slot" \
  --task eng --since "$(iso_at "$DST")" --until "$(iso_at $(( DST + 2 * 86400 + 12 * 3600 )))"

mkcase trailing-newline-cron '50 * * * *\n'
mksession eng $(( BASE + 3000 + 5 ))
expect 2 "supported shape" "a cron with a trailing newline is UNKNOWN, not trimmed into shape" "${W[@]}"

# --since between the two 02:30 occurrences on the fallback day: the first already fired, so the
# repeat is not a slot.
mkcase dst-since-between '30 2 * * *'
mksession eng $(( DST + 86400 + 1800 + 5 ))
mksession eng $(( DST + 2 * 86400 + 5400 + 5 ))   # 10-26 02:30 CET
NOW=$(( DST + 4 * 86400 )) TZ=Europe/Copenhagen expect 0 "scheduled=1 dispatched=1 dropped=0" \
  "a fallback repeat after --since is not a slot when its first occurrence preceded --since" \
  --task eng --since "$(iso_at $(( DST + 86400 + 3600 )))" --until "$(iso_at $(( DST + 3 * 86400 + 12 * 3600 )))"

mkcase no-evidence
expect 2 "attributable to any scheduled task" "an empty projects root is UNKNOWN, never a 100% drop" "${W[@]}"

mkcase unreadable-candidate
mksession eng $(( BASE + 3000 + 5 ))
mkdir -p "$CASE/root/a/good" "$CASE/root/b/bad"
cp "$STORE" "$CASE/root/a/good/scheduled-tasks.json"
printf '{not json\n' > "$CASE/root/b/bad/scheduled-tasks.json"
asserts=$(( asserts + 1 ))
rc=0; OUT=$(CLAUDE_SCHEDULE_STORE_ROOT="$CASE/root" "$SCRIPT" --projects "$PROJECTS" --now-epoch "$NOW" "${W[@]}" 2>&1) || rc=$?
case "$rc:$OUT" in 2:*"not readable JSON"*) : ;; *) note_fail "an unreadable candidate store is UNKNOWN: exit $rc -- $OUT" ;; esac
rm "$CASE/root/b/bad/scheduled-tasks.json"
asserts=$(( asserts + 1 ))
rc=0; OUT=$(CLAUDE_SCHEDULE_STORE_ROOT="$CASE/root" "$SCRIPT" --projects "$PROJECTS" --now-epoch "$NOW" "${W[@]}" 2>&1) || rc=$?
case "$rc:$OUT" in 0:*"scheduled=5"*) : ;; *) note_fail "discovery control: a single readable store is used: exit $rc -- $OUT" ;; esac

mkcase args
expect 2 "later than now" "--until past now is UNKNOWN" \
  --task eng --since "$(iso_at "$BASE")" --until "$(iso_at $(( NOW + 60 )))"
expect 2 "not a single enabled task" "an unknown task is UNKNOWN" \
  --task nope --since "$(iso_at "$BASE")" --until "$(iso_at "$NOW")"
expect 2 "--since is required" "a missing --since is UNKNOWN" --task eng
expect 2 "not a UTC instant" "a malformed --since is UNKNOWN" --task eng --since yesterday
expect 2 "not a UTC instant" "an offset-bearing --since is UNKNOWN, never read as UTC" \
  --task eng --since "2026-09-01T02:00:00.000+02:00" --until "$(iso_at "$NOW")"
expect 2 "not a UTC instant" "a non-numeric fraction is UNKNOWN" --task eng --since "2026-09-01T00:00:00.x1Z"

if [ "$fails" -gt 0 ]; then
  echo "claude-dispatch-rate.test.sh: $fails of $asserts assertions FAILED" >&2
  exit 1
fi
echo "claude-dispatch-rate.test.sh: all $asserts assertions passed"
