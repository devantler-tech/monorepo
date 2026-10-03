#!/usr/bin/env bash
# Contract tests for worktree-lane-sweep.sh — the supervised, detached lane sweep (#3714).
#
# The launcher runs from a copy beside a fake worktree-cleanup-all.sh whose behaviour each case
# chooses (finish cleanly, abort, or hang until released), with HOME pointed at the fixture, so
# no case sweeps a real worktree or reads the host's records. The property that matters is the
# fail-closed one: a sweep that aborted, never finished, is still running or never ran must never
# be reported as a clean sweep (exit 0).
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="$script_dir/worktree-lane-sweep.sh"
repo_root=$(cd "$script_dir/../.." && pwd)

pass=0; failures=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

fx=$(mktemp -d) || { printf 'cannot create a fixture directory\n' >&2; exit 2; }
fx=$(cd "$fx" && pwd -P)
# Release any hanging fake and stop every supervisor a case left behind before deleting the
# fixture they write into.
cleanup() {
  touch "$fx/release" 2>/dev/null
  local f pid
  for f in "$fx"/pids/*; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null) || continue
    kill "$pid" 2>/dev/null
  done
  sleep 0.3
  rm -rf -- "$fx"
}
trap cleanup EXIT
mkdir -p "$fx/scripts" "$fx/home" "$fx/pids"
cp "$impl" "$fx/scripts/worktree-lane-sweep.sh"
chmod +x "$fx/scripts/worktree-lane-sweep.sh"
sut="$fx/scripts/worktree-lane-sweep.sh"
records="$fx/home/.claude/worktree-cleanup-manifests"

# The fake sweep: echoes its arguments, then does what $fx/mode says.
cat >"$fx/scripts/worktree-cleanup-all.sh" <<EOF
#!/usr/bin/env bash
printf 'fake sweep args: %s\n' "\$*"
printf '%s\n' "\$\$" > "$fx/pids/sweep-\$\$"
case "\$(cat "$fx/mode")" in
  ok) exit 0 ;;
  fail) printf 'worktree-cleanup-all: ABORTING — cannot list worktrees\n' >&2; exit 2 ;;
  hang) touch "$fx/hanging"
        while [ ! -e "$fx/release" ]; do sleep 0.1; done
        exit 0 ;;
esac
exit 3
EOF
chmod +x "$fx/scripts/worktree-cleanup-all.sh"
mode() { printf '%s\n' "$1" >"$fx/mode"; }

run() { # [args...] -> sets out, rc
  out=$(HOME="$fx/home" bash "$sut" "$@" 2>&1); rc=$?
}
field() { # <lane> <started|finished> <key> — one key=value field of a record
  # Anchored to a field boundary: a bare `.*id=` would match inside `pid=`.
  sed -nE "s/^(.* )?$3=([^ ]*).*\$/\\2/p" "$records/cleanup-$1.$2" 2>/dev/null
}
# wait_finished <lane> — until .finished names the id .started names (the detached sweep ended).
wait_finished() {
  local i=0 sid
  sid=$(field "$1" started id)
  while [ "$i" -lt 200 ]; do
    [ -n "$sid" ] && [ "$(field "$1" finished id)" = "$sid" ] && return 0
    sleep 0.1; i=$((i + 1))
    [ -n "$sid" ] || sid=$(field "$1" started id)
  done
  return 1
}
wait_for() { # <file>
  local i=0
  while [ "$i" -lt 200 ]; do [ -e "$1" ] && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
track() { field "$1" started pid >"$fx/pids/supervisor-$(field "$1" started id)"; }

printf 'worktree-lane-sweep.sh contract tests\n'

# --- usage ------------------------------------------------------------------------
for args in "" "start" "status" "start --lane" "start --lane both" "sweep --lane claude" \
            "status --lane claude --id 20261002T120000Z-1" "start --lane claude extra"; do
  # shellcheck disable=SC2086  # word-split on purpose: each entry is an argument list
  run $args
  if [ "$rc" -eq 2 ]; then ok "usage error is UNKNOWN (2): '$args'"
  else bad "usage error is UNKNOWN (2): '$args'" "rc=$rc $out"; fi
done

# --- no sweep on record -----------------------------------------------------------
run status --lane claude
if [ "$rc" -eq 1 ] && grep -q 'no claude sweep on record' <<<"$out"; then
  ok "no record is not a clean sweep (1)"
else bad "no record is not a clean sweep (1)" "rc=$rc $out"; fi

# --- a sweep that finishes cleanly ------------------------------------------------
mode ok
run start --lane claude
first_id=$(field claude started id)
if [ "$rc" -eq 1 ] && grep -q 'no claude sweep on record' <<<"$out" \
   && grep -q "started the claude sweep $first_id" <<<"$out"; then
  ok "start reports the missing previous sweep and starts one"
else bad "start reports the missing previous sweep and starts one" "rc=$rc $out"; fi
track claude
if wait_finished claude && [ "$(field claude finished rc)" = 0 ]; then
  ok "the supervisor records the clean end under the same id"
else bad "the supervisor records the clean end under the same id" \
  "$(cat "$records"/cleanup-claude.* 2>&1)"; fi
log="$records/cleanup-claude.log"
if grep -q '^fake sweep args: apply 24 --lane claude$' "$log" \
   && grep -q "=== lane sweep $first_id finished .*: exit 0 ===" "$log"; then
  ok "the sweep runs as apply 24 --lane claude, its output appended to the lane's log"
else bad "the sweep runs as apply 24 --lane claude, its output appended to the lane's log" \
  "$(cat "$log" 2>&1)"; fi

run status --lane claude
if [ "$rc" -eq 0 ] && grep -q "last claude sweep ($first_id) finished cleanly" <<<"$out"; then
  ok "a clean previous sweep reads as clean (0)"
else bad "a clean previous sweep reads as clean (0)" "rc=$rc $out"; fi

# --- a sweep that aborts ----------------------------------------------------------
mode fail
run start --lane claude
fail_id=$(field claude started id)
track claude
if [ "$rc" -eq 0 ] && [ -n "$fail_id" ] && [ "$fail_id" != "$first_id" ]; then
  ok "start after a clean sweep exits 0 and starts a new one"
else bad "start after a clean sweep exits 0 and starts a new one" "rc=$rc $out"; fi
wait_finished claude || bad "the aborting sweep recorded its end" "$(cat "$records"/cleanup-claude.* 2>&1)"
run status --lane claude
if [ "$rc" -eq 1 ] && grep -q "($fail_id) FAILED with exit 2" <<<"$out" \
   && grep -q "see the end of $log" <<<"$out"; then
  ok "an aborted sweep is reported as FAILED with its exit code (1)"
else bad "an aborted sweep is reported as FAILED with its exit code (1)" "rc=$rc $out"; fi
if grep -q 'ABORTING — cannot list worktrees' "$log"; then
  ok "the abort's reason lands in the lane's log"
else bad "the abort's reason lands in the lane's log" "$(cat "$log" 2>&1)"; fi

mode ok
run start --lane claude
retry_id=$(field claude started id)
track claude
if [ "$rc" -eq 1 ] && grep -q 'FAILED with exit 2' <<<"$out" && [ "$retry_id" != "$fail_id" ]; then
  ok "the next start reports the failure (1) and still starts a fresh sweep"
else bad "the next start reports the failure (1) and still starts a fresh sweep" "rc=$rc $out"; fi
wait_finished claude
run status --lane claude
if [ "$rc" -eq 0 ]; then ok "a later clean sweep clears the report"
else bad "a later clean sweep clears the report" "rc=$rc $out"; fi

# --- a sweep that never finishes --------------------------------------------------
mode hang
rm -f "$fx/hanging" "$fx/release"
run start --lane claude
hang_id=$(field claude started id); hang_pid=$(field claude started pid)
track claude
wait_for "$fx/hanging" || bad "the hanging sweep started" "$(cat "$log" 2>&1)"
run status --lane claude
if [ "$rc" -eq 1 ] && grep -q "($hang_id, pid $hang_pid) has been running since" <<<"$out"; then
  ok "a sweep still running is not a clean sweep (1)"
else bad "a sweep still running is not a clean sweep (1)" "rc=$rc $out"; fi
run start --lane claude
if [ "$rc" -eq 1 ] && grep -q 'not starting a second claude sweep' <<<"$out" \
   && [ "$(field claude started id)" = "$hang_id" ]; then
  ok "start does not stack a second sweep on a running one"
else bad "start does not stack a second sweep on a running one" "rc=$rc $out"; fi

# A failed process-table read proves neither running nor gone. It is UNKNOWN and must not start
# a second sweep over the one whose state could not be read.
mkdir -p "$fx/bin"
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" bash "$sut" start --lane claude 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'UNKNOWN.*cannot read the process table' <<<"$out" \
   && [ "$(field claude started id)" = "$hang_id" ]; then
  ok "a failed process-table read is UNKNOWN and starts no second sweep"
else bad "a failed process-table read is UNKNOWN and starts no second sweep" "rc=$rc $out"; fi

# A live supervisor beyond the documented bound is distinct from a healthy in-progress sweep.
# The launcher reports how to clear it and still refuses to stack another sweep on top.
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
record=$(cat "$HOME/.claude/worktree-cleanup-manifests/cleanup-claude.started")
target_pid=$(sed -nE 's/.* pid=([0-9]+) .*/\1/p' <<<"$record")
target_id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' <<<"$record")
printf '%s 06:00:01 bash %s __supervise --lane claude --id %s\n' \
  "$target_pid" "$SUT_PATH" "$target_id"
printf '%s 00:00:01 bash %s start --lane claude\n' "$FAKE_PS_SELF_PID" "$SUT_PATH"
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane claude' 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'STUCK.*six hours' <<<"$out" \
   && grep -q "kill $hang_pid" <<<"$out" \
   && [ "$(field claude started id)" = "$hang_id" ]; then
  ok "a six-hour supervisor is reported as stuck with a clear recovery step"
else bad "a six-hour supervisor is reported as stuck with a clear recovery step" "rc=$rc $out"; fi

# ps zero-pads elapsed fields; 08 and 09 must stay decimal rather than becoming invalid octal.
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
record=$(cat "$HOME/.claude/worktree-cleanup-manifests/cleanup-claude.started")
target_pid=$(sed -nE 's/.* pid=([0-9]+) .*/\1/p' <<<"$record")
target_id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' <<<"$record")
printf '%s 00:08:09 bash %s __supervise --lane claude --id %s\n' \
  "$target_pid" "$SUT_PATH" "$target_id"
printf '%s 00:00:01 bash %s status --lane claude\n' "$FAKE_PS_SELF_PID" "$SUT_PATH"
EOF
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" status --lane claude' 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'has been running since' <<<"$out"; then
  ok "zero-padded elapsed fields are parsed as decimal"
else bad "zero-padded elapsed fields are parsed as decimal" "rc=$rc $out"; fi
rm -f "$fx/bin/ps"

# The documented recovery signal must stop the supervisor and its cleanup child before a restart.
live_sweep_pid=''
for f in "$fx"/pids/sweep-*; do
  [ -f "$f" ] || continue
  candidate=$(cat "$f")
  kill -0 "$candidate" 2>/dev/null && live_sweep_pid=$candidate
done
kill "$hang_pid" 2>/dev/null
i=0
while { kill -0 "$hang_pid" 2>/dev/null || kill -0 "$live_sweep_pid" 2>/dev/null; } \
  && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if ! kill -0 "$hang_pid" 2>/dev/null && ! kill -0 "$live_sweep_pid" 2>/dev/null; then
  ok "stopping a supervisor also stops its cleanup process"
else
  bad "stopping a supervisor also stops its cleanup process" \
    "supervisor=$hang_pid child=$live_sweep_pid"
  touch "$fx/release"
fi

# Start another hanging sweep so an untrappable crash still proves the unfinished-record path.
rm -f "$fx/release" "$fx/hanging"
mode hang
run start --lane claude
hang_id=$(field claude started id); hang_pid=$(field claude started pid)
track claude
wait_for "$fx/hanging" || bad "the replacement hanging sweep started" "$(cat "$log" 2>&1)"

# The supervisor dies without recording an end, as on a kill -9 or a host restart.
kill -9 "$hang_pid" 2>/dev/null
for f in "$fx"/pids/sweep-*; do kill -9 "$(cat "$f")" 2>/dev/null; done
i=0; while kill -0 "$hang_pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
run status --lane claude
if [ "$rc" -eq 1 ] && grep -q "($hang_id) started at .* and NEVER FINISHED" <<<"$out"; then
  ok "a sweep whose supervisor died is reported as never finished (1)"
else bad "a sweep whose supervisor died is reported as never finished (1)" "rc=$rc $out"; fi
mode ok
mkdir -p "$fx/bin"
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf '%s 00:00:01 bash .claude/scripts/worktree-lane-sweep.sh start --lane claude\n' \
  "$FAKE_PS_SELF_PID"
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane claude' 2>&1); rc=$?
rm -f "$fx/bin/ps"
track claude
if [ "$rc" -eq 1 ] && grep -q 'NEVER FINISHED' <<<"$out" && [ "$(field claude started id)" != "$hang_id" ]; then
  ok "the documented relative invocation proves a dead supervisor and starts a fresh sweep"
else bad "the next start reports it (1) and starts a fresh sweep" "rc=$rc $out"; fi
wait_finished claude

# --- records that prove nothing ---------------------------------------------------
# A live pid that is not this lane's supervisor (a recycled pid) is not a running sweep.
printf 'id=20261002T120000Z-1 pid=%s at=2026-10-02T12:00:00Z\n' "$$" >"$records/cleanup-claude.started"
run status --lane claude
if [ "$rc" -eq 1 ] && grep -q 'NEVER FINISHED' <<<"$out"; then
  ok "a recycled pid does not read as a sweep still running"
else bad "a recycled pid does not read as a sweep still running" "rc=$rc $out"; fi

# A clean end recorded for an EARLIER sweep says nothing about the one that started since.
( : ) & dead=$!; wait "$dead"
printf 'id=20261002T130000Z-2 pid=%s at=2026-10-02T13:00:00Z\n' "$dead" >"$records/cleanup-claude.started"
printf 'id=20261002T120000Z-1 rc=0 at=2026-10-02T12:05:00Z\n' >"$records/cleanup-claude.finished"
run status --lane claude
if [ "$rc" -eq 1 ] && grep -q '(20261002T130000Z-2) started at 2026-10-02T13:00:00Z and NEVER FINISHED' <<<"$out"; then
  ok "a clean end for another sweep's id is not a clean sweep"
else bad "a clean end for another sweep's id is not a clean sweep" "rc=$rc $out"; fi

printf 'id=20261002T130000Z-2 rc=0 at=2026-10-02T13:05:00Z\n' >"$records/cleanup-claude.finished"
printf 'garbage\n' >"$records/cleanup-claude.started"
run status --lane claude
if [ "$rc" -eq 2 ] && grep -q 'malformed sweep record' <<<"$out"; then
  ok "a malformed start record is UNKNOWN (2)"
else bad "a malformed start record is UNKNOWN (2)" "rc=$rc $out"; fi

# Non-regular records are never read: a symlink to an endless device must return promptly.
rm -f "$records/cleanup-claude.started"
ln -s /dev/zero "$records/cleanup-claude.started"
HOME="$fx/home" bash "$sut" status --lane claude >"$fx/nonregular.out" 2>&1 & probe=$!
i=0
while kill -0 "$probe" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$probe" 2>/dev/null; then
  kill -9 "$probe" 2>/dev/null
  wait "$probe" 2>/dev/null
  bad "a non-regular start record returns UNKNOWN without blocking" "reporter hung on a symlink"
else
  wait "$probe"; probe_rc=$?
  if [ "$probe_rc" -eq 2 ] && grep -q 'non-regular or oversized sweep record' "$fx/nonregular.out"; then
    ok "a non-regular start record returns UNKNOWN without blocking"
  else bad "a non-regular start record returns UNKNOWN without blocking" \
    "rc=$probe_rc $(cat "$fx/nonregular.out")"; fi
fi
rm -f "$records/cleanup-claude.started"

printf 'id=20261002T130000Z-2 pid=%s at=2026-10-02T13:00:00Z\n' "$dead" >"$records/cleanup-claude.started"
printf 'id=20261002T130000Z-2 rc=0 at=2026-10-02T13:05:00Z\nid=20261002T130000Z-2 rc=0 at=2026-10-02T13:05:00Z\n' \
  >"$records/cleanup-claude.finished"
run status --lane claude
if [ "$rc" -eq 2 ] && grep -q 'malformed sweep record' <<<"$out"; then
  ok "a finish record with more than one line is UNKNOWN (2)"
else bad "a finish record with more than one line is UNKNOWN (2)" "rc=$rc $out"; fi

# A malformed finish record does not erase a valid live start record. Report UNKNOWN, but do not
# replace the supervisor while the complete process table still proves that it is running.
live_record='id=20261002T130000Z-2 pid=4242 at=2026-10-02T13:00:00Z'
printf '%s\n' "$live_record" >"$records/cleanup-claude.started"
printf 'garbage\n' >"$records/cleanup-claude.finished"
mkdir -p "$fx/bin"
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf '4242 00:00:10 bash %s __supervise --lane claude --id 20261002T130000Z-2\n' "$SUT_PATH"
printf '%s 00:00:01 bash %s start --lane claude\n' "$FAKE_PS_SELF_PID" "$SUT_PATH"
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane claude' 2>&1); rc=$?
rm -f "$fx/bin/ps"
if [ "$rc" -eq 2 ] && grep -q 'malformed sweep record' <<<"$out" \
   && grep -q 'not starting a second claude sweep' <<<"$out" \
   && [ "$(cat "$records/cleanup-claude.started")" = "$live_record" ]; then
  ok "a malformed finish record cannot replace its live supervisor"
else
  bad "a malformed finish record cannot replace its live supervisor" "rc=$rc $out"
  replacement_id=$(field claude started id)
  [ "$replacement_id" = 20261002T130000Z-2 ] || wait_finished claude
fi
printf '%s\n' "$live_record" >"$records/cleanup-claude.started"

printf 'id=20261002T130000Z-2 rc=0 at=2026-10-02T13:05:00Z\n' >"$records/cleanup-claude.finished"
run status --lane claude
if [ "$rc" -eq 0 ]; then ok "control: the same records, well formed, read as clean"
else bad "control: the same records, well formed, read as clean" "rc=$rc $out"; fi

# An unreadable record must not stop the lane being swept on every later run.
printf 'garbage\n' >"$records/cleanup-claude.started"
mode ok
run start --lane claude
track claude
if [ "$rc" -eq 2 ] && grep -q 'malformed sweep record' <<<"$out" \
   && grep -q 'started the claude sweep' <<<"$out" && wait_finished claude; then
  ok "start on a malformed record is UNKNOWN (2) and still sweeps, replacing it"
else bad "start on a malformed record is UNKNOWN (2) and still sweeps, replacing it" "rc=$rc $out"; fi
run status --lane claude
if [ "$rc" -eq 0 ]; then ok "the replaced record reads as clean once that sweep finishes"
else bad "the replaced record reads as clean once that sweep finishes" "rc=$rc $out"; fi

# Two launchers arriving together must serialize the read/start/record transaction. One may see
# the other already running or may lose the lock, but they must create exactly one supervisor.
concurrent_home="$fx/concurrent-home"
mkdir -p "$concurrent_home"
mode hang
rm -f "$fx/release" "$fx/hanging"
before=0
for f in "$fx"/pids/sweep-*; do [ ! -f "$f" ] || before=$((before + 1)); done
HOME="$concurrent_home" bash "$sut" start --lane codex >"$fx/concurrent-1.out" 2>&1 & c1=$!
HOME="$concurrent_home" bash "$sut" start --lane codex >"$fx/concurrent-2.out" 2>&1 & c2=$!
wait "$c1" || true
wait "$c2" || true
wait_for "$fx/hanging" || bad "one concurrent launcher started a sweep" \
  "$(cat "$fx"/concurrent-*.out 2>&1)"
after=0
for f in "$fx"/pids/sweep-*; do [ ! -f "$f" ] || after=$((after + 1)); done
if [ $((after - before)) -eq 1 ]; then
  ok "concurrent launchers create only one supervised sweep"
else bad "concurrent launchers create only one supervised sweep" \
  "started=$((after - before)) $(cat "$fx"/concurrent-*.out 2>&1)"; fi
touch "$fx/release"
i=0
while [ "$i" -lt 200 ]; do
  started_id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' \
    "$concurrent_home/.claude/worktree-cleanup-manifests/cleanup-codex.started" 2>/dev/null)
  finished_id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' \
    "$concurrent_home/.claude/worktree-cleanup-manifests/cleanup-codex.finished" 2>/dev/null)
  [ -n "$started_id" ] && [ "$finished_id" = "$started_id" ] && break
  sleep 0.1; i=$((i + 1))
done
rm -f "$fx/release" "$fx/hanging"
mode ok

# A killed launcher leaves an owner record in its atomic lock. A complete process read proving that
# owner gone allows the next launcher to recover instead of disabling the lane forever.
stale_home="$fx/stale-lock-home"
stale_records="$stale_home/.claude/worktree-cleanup-manifests"
mkdir -p "$stale_records/cleanup-codex.launch.lock" "$fx/bin"
printf 'pid=999999 at=2026-10-02T12:00:00Z\n' \
  >"$stale_records/cleanup-codex.launch.lock/owner"
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf '%s 00:00:01 bash %s start --lane codex\n' "$FAKE_PS_SELF_PID" "$SUT_PATH"
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$stale_home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane codex' 2>&1); rc=$?
rm -f "$fx/bin/ps"
if [ "$rc" -eq 1 ] && grep -q 'started the codex sweep' <<<"$out"; then
  ok "a dead launcher owner does not leave a permanent lock"
else bad "a dead launcher owner does not leave a permanent lock" "rc=$rc $out"; fi
stale_id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$stale_records/cleanup-codex.started" 2>/dev/null)
i=0
while [ "$i" -lt 100 ] && \
  [ "$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$stale_records/cleanup-codex.finished" 2>/dev/null)" != "$stale_id" ]; do
  sleep 0.1; i=$((i + 1))
done

# --- lanes are separate -----------------------------------------------------------
run status --lane codex
if [ "$rc" -eq 1 ] && grep -q 'no codex sweep on record' <<<"$out"; then
  ok "the claude lane's records say nothing about the codex lane"
else bad "the claude lane's records say nothing about the codex lane" "rc=$rc $out"; fi
mode ok
run start --lane codex
track codex
if wait_finished codex && grep -q '^fake sweep args: apply 24 --lane codex$' "$records/cleanup-codex.log" \
   && ! grep -q -- '--lane codex' "$log"; then
  ok "the codex lane sweeps only --lane codex, logged and recorded apart"
else bad "the codex lane sweeps only --lane codex, logged and recorded apart" \
  "$(cat "$records"/cleanup-codex.* 2>&1)"; fi

# --- the supervisor and launcher fail closed --------------------------------------
# The supervisor has a valid launcher handshake, but a directory at .finished keeps it from
# recording the end (independent of permissions, which root ignores).
supervisor_blocked="$fx/supervisor-blocked"
supervisor_records="$supervisor_blocked/.claude/worktree-cleanup-manifests"
mkdir -p "$supervisor_records/cleanup-claude.finished"
out=$(HOME="$supervisor_blocked" SUT_PATH="$sut" bash -c '
  printf "id=20261002T140000Z-3 pid=%s at=2026-10-02T14:00:00Z\n" "$$" \
    >"$HOME/.claude/worktree-cleanup-manifests/cleanup-claude.started"
  exec bash "$SUT_PATH" __supervise --lane claude --id 20261002T140000Z-3
' 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'cannot record the end of sweep 20261002T140000Z-3' <<<"$out"; then
  ok "a supervisor that cannot record the end exits UNKNOWN (2)"
else bad "a supervisor that cannot record the end exits UNKNOWN (2)" "rc=$rc $out"; fi

# The records' directory is a FILE, so a launcher cannot create records.
mkdir -p "$fx/blocked/.claude"
: >"$fx/blocked/.claude/worktree-cleanup-manifests"
out=$(HOME="$fx/blocked" bash "$sut" start --lane claude 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'cannot create' <<<"$out"; then
  ok "a start that cannot keep records is UNKNOWN (2)"
else bad "a start that cannot keep records is UNKNOWN (2)" "rc=$rc $out"; fi

# A supervisor cannot begin cleanup until the launcher has durably recorded it. If .started cannot
# be replaced, the launcher must terminate the waiting supervisor rather than leave an invisible sweep.
handshake_home="$fx/handshake-home"
handshake_records="$handshake_home/.claude/worktree-cleanup-manifests"
mkdir -p "$handshake_records/cleanup-claude.started"
mode hang
rm -f "$fx/release" "$fx/hanging"
before=0
for f in "$fx"/pids/sweep-*; do
  [ -f "$f" ] || continue
  candidate=$(cat "$f")
  kill -0 "$candidate" 2>/dev/null && before=$((before + 1))
done
out=$(HOME="$handshake_home" bash "$sut" start --lane claude 2>&1); rc=$?
sleep 0.3
after=0
for f in "$fx"/pids/sweep-*; do
  [ -f "$f" ] || continue
  candidate=$(cat "$f")
  kill -0 "$candidate" 2>/dev/null && after=$((after + 1))
done
if [ "$rc" -eq 2 ] && grep -q 'cannot record' <<<"$out" && [ "$after" -eq "$before" ]; then
  ok "a failed start-record handshake leaves no invisible cleanup"
else
  bad "a failed start-record handshake leaves no invisible cleanup" \
    "rc=$rc live-before=$before live-after=$after $out"
  touch "$fx/release"
fi
mode ok

# --- the run's pre-flight uses the supervised start -------------------------------
guide="$repo_root/.claude/guides/git-and-worktrees.md"
skill="$repo_root/.claude/skills/portfolio-maintenance/SKILL.md"
section=$(awk '/^\*\*Pre-flight, every run/{f=1} f && /^\*\*End-of-tick/{exit} f' "$guide" 2>/dev/null)
if [ -z "$section" ]; then
  bad "the guide's pre-flight section exists" "cannot find **Pre-flight, every run** in $guide"
elif grep -qF '.claude/scripts/worktree-lane-sweep.sh start --lane <lane>' <<<"$section" \
   && ! grep -q 'nohup' <<<"$section"; then
  ok "the guide's pre-flight starts the sweep through the supervised launcher"
else bad "the guide's pre-flight starts the sweep through the supervised launcher" "$section"; fi
# shellcheck disable=SC2016 # the backticks are literal Markdown, not a command substitution
if grep -qF '`worktree-lane-sweep.sh start --lane <your lane>`' "$skill" \
   && grep -qF 'never finished, is still running or no sweep is on record' "$skill" \
   && ! grep -qF 'Start `worktree-cleanup-all.sh apply 24' "$skill"; then
  ok "the run procedure starts the sweep and names every non-clean status"
else bad "the run procedure starts the sweep and names every non-clean status" "$skill"; fi

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
