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
# live_sweeps — pids of the fake sweeps still running, one per line.
live_sweeps() {
  local f pid
  for f in "$fx"/pids/sweep-*; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null) || continue
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
  done
  return 0
}
count_live_sweeps() { live_sweeps | grep -c . || true; }
wait_gone() { # <pid>
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  ! kill -0 "$1" 2>/dev/null
}
# Where the launcher has no record naming a process it looks for the lane's processes by name,
# across the host. A real sweep of the same lane on this machine must not decide such a case, so
# those cases read the process table through this filter: only processes of this fixture.
real_ps=$(command -v ps) || { printf 'cannot find ps\n' >&2; exit 2; }
mkdir -p "$fx/fxbin"
cat >"$fx/fxbin/ps" <<EOF
#!/usr/bin/env bash
"$real_ps" "\$@" | grep -F -- "$fx/"
EOF
chmod +x "$fx/fxbin/ps"
run_fx() { # [args...] -> sets out, rc; sees only this fixture's processes
  out=$(HOME="$fx/home" PATH="$fx/fxbin:$PATH" bash "$sut" "$@" 2>&1); rc=$?
}

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

# The next run starts the launcher from its OWN checkout, never from the one that started the
# sweep. A supervisor matched by the asking copy's path would read as gone from there, and a
# second sweep would be stacked on the running one.
mkdir -p "$fx/other/scripts"
cp "$impl" "$fx/other/scripts/worktree-lane-sweep.sh"
cp "$fx/scripts/worktree-cleanup-all.sh" "$fx/other/scripts/worktree-cleanup-all.sh"
chmod +x "$fx/other/scripts/worktree-lane-sweep.sh" "$fx/other/scripts/worktree-cleanup-all.sh"
out=$(HOME="$fx/home" bash "$fx/other/scripts/worktree-lane-sweep.sh" status --lane claude 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q "($hang_id, pid $hang_pid) has been running since" <<<"$out"; then
  ok "a running sweep is seen from another checkout"
else bad "a running sweep is seen from another checkout" "rc=$rc $out"; fi
out=$(HOME="$fx/home" bash "$fx/other/scripts/worktree-lane-sweep.sh" start --lane claude 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'not starting a second claude sweep' <<<"$out" \
   && [ "$(field claude started id)" = "$hang_id" ]; then
  ok "start from another checkout does not stack a second sweep"
else bad "start from another checkout does not stack a second sweep" "rc=$rc $out"; fi

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
run_fx start --lane claude
track claude
if [ "$rc" -eq 2 ] && grep -q 'malformed sweep record' <<<"$out" \
   && grep -q 'started the claude sweep' <<<"$out" && wait_finished claude; then
  ok "start on a malformed record is UNKNOWN (2) and still sweeps, replacing it"
else bad "start on a malformed record is UNKNOWN (2) and still sweeps, replacing it" "rc=$rc $out"; fi
run status --lane claude
if [ "$rc" -eq 0 ]; then ok "the replaced record reads as clean once that sweep finishes"
else bad "the replaced record reads as clean once that sweep finishes" "rc=$rc $out"; fi

# --- a second sweep never starts beside a live one (#3823) ------------------------
# A start record nobody can read names no supervisor. Before replacing it the launcher looks for
# any supervisor of the lane: one still running means the sweep that record stood for is live.
mode hang
rm -f "$fx/release" "$fx/hanging"
run start --lane claude
live_id=$(field claude started id); live_pid=$(field claude started pid)
track claude
wait_for "$fx/hanging" || bad "the sweep behind the unreadable record started" "$(cat "$log" 2>&1)"
printf 'garbage\n' >"$records/cleanup-claude.started"
run_fx start --lane claude
if [ "$rc" -eq 2 ] && grep -q 'malformed sweep record' <<<"$out" \
   && grep -Eq "not starting a second claude sweep while supervisor pid( [0-9]+)* $live_pid( [0-9]+)* still runs" <<<"$out" \
   && [ "$(cat "$records/cleanup-claude.started")" = garbage ] && [ "$(count_live_sweeps)" -eq 1 ]; then
  ok "a malformed start record cannot replace a live supervisor of the lane"
else
  bad "a malformed start record cannot replace a live supervisor of the lane" \
    "rc=$rc live-sweeps=$(count_live_sweeps) $out"
  [ "$(cat "$records/cleanup-claude.started")" = garbage ] || track claude
fi
# The same record with an unreadable process table proves neither running nor gone.
printf 'garbage\n' >"$records/cleanup-claude.started"
mkdir -p "$fx/bin"
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" bash "$sut" start --lane claude 2>&1); rc=$?
rm -f "$fx/bin/ps"
if [ "$rc" -eq 2 ] && grep -q 'UNKNOWN.*cannot read the process table' <<<"$out" \
   && [ "$(cat "$records/cleanup-claude.started")" = garbage ] && [ "$(count_live_sweeps)" -eq 1 ]; then
  ok "a malformed start record with an unreadable process table starts nothing"
else bad "a malformed start record with an unreadable process table starts nothing" \
  "rc=$rc live-sweeps=$(count_live_sweeps) $out"; fi
# Once that supervisor has ended, the same unreadable record is replaced as before.
touch "$fx/release"
wait_gone "$live_pid" || bad "the supervisor behind the unreadable record ended" "pid=$live_pid"
rm -f "$fx/release" "$fx/hanging"
mode ok
run_fx start --lane claude
track claude
if [ "$rc" -eq 2 ] && grep -q 'started the claude sweep' <<<"$out" && wait_finished claude \
   && [ "$(field claude started id)" != "$live_id" ]; then
  ok "the unreadable record is replaced once no supervisor of the lane runs"
else bad "the unreadable record is replaced once no supervisor of the lane runs" "rc=$rc $out"; fi

# kill -9 reaches only the supervisor: the sweeper it started goes on sweeping with nothing
# recording its end. The next start must not put a second sweeper beside it.
mode hang
rm -f "$fx/release" "$fx/hanging"
run start --lane claude
orphan_id=$(field claude started id); orphan_sup=$(field claude started pid)
track claude
wait_for "$fx/hanging" || bad "the sweep to orphan started" "$(cat "$log" 2>&1)"
orphan_sweeper=$(live_sweeps)
if [ -n "$orphan_sweeper" ] && [ "$(field claude sweeper pid)" = "$orphan_sweeper" ] \
   && [ "$(field claude sweeper id)" = "$orphan_id" ]; then
  ok "a running sweeper is on record under its sweep's id"
else bad "a running sweeper is on record under its sweep's id" \
  "live=$orphan_sweeper $(cat "$records/cleanup-claude.sweeper" 2>&1)"; fi
kill -9 "$orphan_sup" 2>/dev/null
wait_gone "$orphan_sup" || bad "the supervisor was killed" "pid=$orphan_sup"
if [ "$(count_live_sweeps)" -eq 1 ]; then ok "fixture: the sweeper outlives its killed supervisor"
else bad "fixture: the sweeper outlives its killed supervisor" "live-sweeps=$(count_live_sweeps)"; fi
run start --lane claude
if [ "$rc" -eq 1 ] && grep -q 'NEVER FINISHED' <<<"$out" \
   && grep -q "not starting a second claude sweep: sweeper pid $orphan_sweeper is still running without its supervisor" <<<"$out" \
   && grep -q "kill $orphan_sweeper" <<<"$out" \
   && [ "$(field claude started id)" = "$orphan_id" ] && [ "$(count_live_sweeps)" -eq 1 ]; then
  ok "start does not put a second sweeper beside an orphaned one"
else
  bad "start does not put a second sweeper beside an orphaned one" \
    "rc=$rc live-sweeps=$(count_live_sweeps) $out"
  [ "$(field claude started id)" = "$orphan_id" ] || track claude
fi
# A pid that is alive but is not the lane's sweeper (a recycled pid) blocks nothing, and neither
# does a sweeper that has ended.
touch "$fx/release"
[ -z "$orphan_sweeper" ] || wait_gone "$orphan_sweeper" || bad "the orphaned sweeper ended" "pid=$orphan_sweeper"
i=0; while [ "$(count_live_sweeps)" -gt 0 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
rm -f "$fx/release" "$fx/hanging"
printf 'id=%s pid=%s at=2026-10-02T12:00:00Z\n' "$orphan_id" "$$" >"$records/cleanup-claude.sweeper"
printf 'id=%s pid=999996 at=2026-10-02T12:00:00Z\n' "$orphan_id" >"$records/cleanup-claude.started"
rm -f "$records/cleanup-claude.finished"
mode ok
run start --lane claude
track claude
if [ "$rc" -eq 1 ] && grep -q 'NEVER FINISHED' <<<"$out" && grep -q 'started the claude sweep' <<<"$out" \
   && wait_finished claude; then
  ok "a recorded sweeper pid that is not the lane's sweeper blocks nothing"
else bad "a recorded sweeper pid that is not the lane's sweeper blocks nothing" "rc=$rc $out"; fi
if [ ! -e "$records/cleanup-claude.sweeper" ]; then ok "a finished sweep leaves no sweeper on record"
else bad "a finished sweep leaves no sweeper on record" "$(cat "$records/cleanup-claude.sweeper" 2>&1)"; fi

# A sweeper record nobody can read names no pid, so any sweeper of the lane counts.
mode hang
rm -f "$fx/release" "$fx/hanging"
run start --lane claude
orphan_id=$(field claude started id); orphan_sup=$(field claude started pid)
track claude
wait_for "$fx/hanging" || bad "the second sweep to orphan started" "$(cat "$log" 2>&1)"
orphan_sweeper=$(live_sweeps)
kill -9 "$orphan_sup" 2>/dev/null
wait_gone "$orphan_sup" || bad "the second supervisor was killed" "pid=$orphan_sup"
printf 'garbage\n' >"$records/cleanup-claude.sweeper"
run_fx start --lane claude
if [ "$rc" -eq 2 ] && grep -q 'unreadable sweeper record' <<<"$out" \
   && grep -q "sweeper pid $orphan_sweeper is still running without its supervisor" <<<"$out" \
   && [ "$(field claude started id)" = "$orphan_id" ] && [ "$(count_live_sweeps)" -eq 1 ]; then
  ok "an unreadable sweeper record still finds the lane's running sweeper"
else
  bad "an unreadable sweeper record still finds the lane's running sweeper" \
    "rc=$rc live-sweeps=$(count_live_sweeps) $out"
  [ "$(field claude started id)" = "$orphan_id" ] || track claude
fi
touch "$fx/release"
i=0; while [ "$(count_live_sweeps)" -gt 0 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
rm -f "$fx/release" "$fx/hanging"
mode ok
run_fx start --lane claude
track claude
if [ "$rc" -eq 2 ] && grep -q 'unreadable sweeper record' <<<"$out" \
   && grep -q 'started the claude sweep' <<<"$out" && wait_finished claude; then
  ok "an unreadable sweeper record is replaced once no sweeper of the lane runs"
else bad "an unreadable sweeper record is replaced once no sweeper of the lane runs" "rc=$rc $out"; fi

# A supervisor that ran a copy of the launcher from before sweepers recorded themselves leaves no
# sweeper record at all. Killed, it leaves a sweep that never finished, a sweeper still running
# and nothing that names it: any sweeper of the lane has to count then too.
mode hang
rm -f "$fx/release" "$fx/hanging"
run start --lane claude
orphan_id=$(field claude started id); orphan_sup=$(field claude started pid)
track claude
wait_for "$fx/hanging" || bad "the sweep to orphan without a record started" "$(cat "$log" 2>&1)"
orphan_sweeper=$(live_sweeps)
kill -9 "$orphan_sup" 2>/dev/null
wait_gone "$orphan_sup" || bad "the third supervisor was killed" "pid=$orphan_sup"
rm -f "$records/cleanup-claude.sweeper"
run_fx start --lane claude
if [ "$rc" -eq 1 ] && grep -q 'NEVER FINISHED' <<<"$out" \
   && grep -q "sweeper pid $orphan_sweeper is still running without its supervisor" <<<"$out" \
   && [ "$(field claude started id)" = "$orphan_id" ] && [ "$(count_live_sweeps)" -eq 1 ]; then
  ok "an unfinished sweep with no sweeper on record still finds the lane's running sweeper"
else
  bad "an unfinished sweep with no sweeper on record still finds the lane's running sweeper" \
    "rc=$rc live-sweeps=$(count_live_sweeps) $out"
  [ "$(field claude started id)" = "$orphan_id" ] || track claude
fi
touch "$fx/release"
i=0; while [ "$(count_live_sweeps)" -gt 0 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
rm -f "$fx/release" "$fx/hanging"
mode ok
run_fx start --lane claude
track claude
if [ "$rc" -eq 1 ] && grep -q 'NEVER FINISHED' <<<"$out" \
   && grep -q 'started the claude sweep' <<<"$out" && wait_finished claude; then
  ok "an unfinished sweep with no sweeper on record is replaced once nothing of the lane runs"
else bad "an unfinished sweep with no sweeper on record is replaced once nothing of the lane runs" "rc=$rc $out"; fi

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
if [ ! -e "$stale_records/cleanup-codex.launch.lock" ]; then ok "the recovered lock is released with its dead owner's record"
else bad "the recovered lock is released with its dead owner's record" \
  "$(ls -la "$stale_records/cleanup-codex.launch.lock" 2>&1)"; fi

# --- recovering a dead launcher's lock is one atomic step (#3823) -----------------
# lock_start <home> <ps-listing-lines...> — start the codex lane with a process table that holds
# this launcher and the given extra lines. Sets out, rc. `@SUT@` in a line is the launcher's path.
lock_start() {
  local home=$1 line; shift
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # expanded by the generated script, not here
    printf 'printf "%%s 00:00:01 bash %%s start --lane codex\\n" "$FAKE_PS_SELF_PID" "$SUT_PATH"\n'
    for line in "$@"; do printf 'printf "%%s\\n" %q\n' "${line//@SUT@/$sut}"; done
  } >"$fx/bin/ps"
  chmod +x "$fx/bin/ps"
  out=$(HOME="$home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
    bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane codex' 2>&1); rc=$?
  rm -f "$fx/bin/ps"
}
# lock_settle <home> — wait for the sweep that home started, so no supervisor outlives its case.
lock_settle() {
  local dir="$1/.claude/worktree-cleanup-manifests" sid i=0
  sid=$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$dir/cleanup-codex.started" 2>/dev/null)
  [ -n "$sid" ] || return 0
  while [ "$i" -lt 100 ] && \
    [ "$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$dir/cleanup-codex.finished" 2>/dev/null)" != "$sid" ]; do
    sleep 0.1; i=$((i + 1))
  done
}
mkdir -p "$fx/bin"
mode ok

# A launcher that died while taking a dead lock over leaves two records: the dead owner's and its
# own. The next launcher follows them to the last and takes over from that one.
chain_home="$fx/chain-home"
chain_lock="$chain_home/.claude/worktree-cleanup-manifests/cleanup-codex.launch.lock"
mkdir -p "$chain_lock"
printf 'pid=999999 at=2026-10-02T12:00:00Z\n' >"$chain_lock/owner"
printf 'pid=999997 at=2026-10-02T12:00:05Z\n' >"$chain_lock/takeover.999999.2026-10-02T12:00:00Z"
lock_start "$chain_home"
if [ "$rc" -eq 1 ] && grep -q 'started the codex sweep' <<<"$out" && [ ! -e "$chain_lock" ]; then
  ok "a launcher that died mid-takeover does not leave a permanent lock"
else bad "a launcher that died mid-takeover does not leave a permanent lock" \
  "rc=$rc $out $(ls -la "$chain_lock" 2>&1)"; fi
lock_settle "$chain_home"

# The last record names the owner. While that launcher runs, the dead records before it mean
# nothing: the lock is held and no record in it may change.
held_home="$fx/held-home"
held_lock="$held_home/.claude/worktree-cleanup-manifests/cleanup-codex.launch.lock"
mkdir -p "$held_lock"
printf 'pid=999999 at=2026-10-02T12:00:00Z\n' >"$held_lock/owner"
printf 'pid=4343 at=2026-10-02T12:00:05Z\n' >"$held_lock/takeover.999999.2026-10-02T12:00:00Z"
held_before=$(ls "$held_lock")
lock_start "$held_home" '4343 00:00:02 bash @SUT@ start --lane codex'
if [ "$rc" -eq 2 ] && grep -q 'another codex sweep launcher (pid 4343) holds' <<<"$out" \
   && [ "$(ls "$held_lock")" = "$held_before" ] \
   && [ ! -e "$held_home/.claude/worktree-cleanup-manifests/cleanup-codex.started" ]; then
  ok "a lock taken over by a running launcher is held, whatever its first record says"
else bad "a lock taken over by a running launcher is held, whatever its first record says" \
  "rc=$rc $out $(ls "$held_lock" 2>&1)"; fi

# While a launcher decides, the dead lock it read can be taken over, released and made again by
# others. The record it then adds belongs to a chain that is gone and must own nothing in the new
# lock, whose owner is running.
swap_home="$fx/swap-home"
swap_lock="$swap_home/.claude/worktree-cleanup-manifests/cleanup-codex.launch.lock"
mkdir -p "$swap_lock"
printf 'pid=999999 at=2026-10-02T12:00:00Z\n' >"$swap_lock/owner"
cat >"$fx/bin/ps" <<EOF
#!/usr/bin/env bash
if [ ! -e "$fx/swap-done" ]; then
  : >"$fx/swap-done"
  rm -rf "$swap_lock"
  mkdir "$swap_lock"
  printf 'pid=4343 at=2026-10-02T12:30:00Z\n' >"$swap_lock/owner"
fi
printf '%s 00:00:01 bash %s start --lane codex\n' "\$FAKE_PS_SELF_PID" "$sut"
printf '4343 00:00:02 bash %s start --lane codex\n' "$sut"
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$swap_home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane codex' 2>&1); rc=$?
rm -f "$fx/bin/ps"
if [ -e "$fx/swap-done" ] && [ "$rc" -eq 2 ] && grep -q 'another codex sweep launcher holds' <<<"$out" \
   && [ "$(cat "$swap_lock/owner" 2>/dev/null)" = 'pid=4343 at=2026-10-02T12:30:00Z' ] \
   && [ ! -e "$swap_home/.claude/worktree-cleanup-manifests/cleanup-codex.started" ]; then
  ok "a record added to a lock that was made again in the meantime owns nothing"
else
  bad "a record added to a lock that was made again in the meantime owns nothing" "rc=$rc $out"
  lock_settle "$swap_home"
fi

# An owner record nobody can read names no launcher to look for, so only age can show the lock was
# abandoned: a launcher that has just made the directory has not written its record yet.
garbled_home="$fx/garbled-home"
garbled_lock="$garbled_home/.claude/worktree-cleanup-manifests/cleanup-codex.launch.lock"
mkdir -p "$garbled_lock"
printf 'garbage\n' >"$garbled_lock/owner"
lock_start "$garbled_home"
if [ "$rc" -eq 2 ] && grep -q 'not old enough to recover' <<<"$out" \
   && [ "$(cat "$garbled_lock/owner")" = garbage ] \
   && [ ! -e "$garbled_home/.claude/worktree-cleanup-manifests/cleanup-codex.started" ]; then
  ok "a fresh lock with an unreadable owner record is not taken over"
else bad "a fresh lock with an unreadable owner record is not taken over" "rc=$rc $out"; fi
touch -t 202601010000 "$garbled_lock"
lock_start "$garbled_home"
if [ "$rc" -eq 1 ] && grep -q 'started the codex sweep' <<<"$out" && [ ! -e "$garbled_lock" ]; then
  ok "an old lock with an unreadable owner record is taken over"
else bad "an old lock with an unreadable owner record is taken over" \
  "rc=$rc $out $(ls -la "$garbled_lock" 2>&1)"; fi
lock_settle "$garbled_home"

# The race itself. Launcher B reads the dead owner and asks the process table whether it still
# runs. Before B gets its answer, launcher A recovers the same lock and holds it. B then acts on
# what it read: it must not remove A's lock, and only one of the two may start a sweep.
race_home="$fx/race-home"
race_records="$race_home/.claude/worktree-cleanup-manifests"
mkdir -p "$race_records/cleanup-codex.launch.lock" "$fx/race/bin-a" "$fx/race/bin-b"
printf 'pid=999999 at=2026-10-02T12:00:00Z\n' >"$race_records/cleanup-codex.launch.lock/owner"
# An unfinished sweep on record makes a launcher read the process table once more after it has
# the lock, which is where A is held while it owns the lock.
printf 'id=20261002T110000Z-7 pid=999998 at=2026-10-02T11:00:00Z\n' >"$race_records/cleanup-codex.started"
cat >"$fx/race/bin-a/ps" <<EOF
#!/usr/bin/env bash
calls=\$(cat "$fx/race/a-calls" 2>/dev/null || echo 0)
calls=\$((calls + 1))
echo "\$calls" >"$fx/race/a-calls"
if [ "\$calls" -eq 2 ]; then
  : >"$fx/race/a-holding"
  i=0
  while [ ! -e "$fx/race/release-a" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done
fi
printf '%s 00:00:01 bash %s start --lane codex\n' "\$FAKE_PS_SELF_PID" "$sut"
EOF
cat >"$fx/race/bin-b/ps" <<EOF
#!/usr/bin/env bash
if [ ! -e "$fx/race/b-asked" ]; then
  : >"$fx/race/b-asked"
  HOME="$race_home" PATH="$fx/race/bin-a:$PATH" SUT_PATH="$sut" \\
    bash -c 'export FAKE_PS_SELF_PID=\$\$; exec bash "\$SUT_PATH" start --lane codex' \\
    >"$fx/race/a.out" 2>&1 &
  echo \$! >"$fx/race/a-pid"
  i=0
  while [ ! -e "$fx/race/a-holding" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done
fi
printf '%s 00:00:01 bash %s start --lane codex\n' "\$FAKE_PS_SELF_PID" "$sut"
printf '%s 00:00:01 bash %s start --lane codex\n' "\$(cat "$fx/race/a-pid")" "$sut"
EOF
chmod +x "$fx/race/bin-a/ps" "$fx/race/bin-b/ps"
race_before=0
for f in "$fx"/pids/sweep-*; do [ ! -f "$f" ] || race_before=$((race_before + 1)); done
out=$(HOME="$race_home" PATH="$fx/race/bin-b:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane codex' 2>&1); rc=$?
race_a_pid=$(cat "$fx/race/a-pid" 2>/dev/null)
if [ -e "$fx/race/a-holding" ] && [ -n "$race_a_pid" ] && kill -0 "$race_a_pid" 2>/dev/null; then
  ok "fixture: launcher A recovered the lock and holds it while B decides"
else bad "fixture: launcher A recovered the lock and holds it while B decides" \
  "a-pid=$race_a_pid $(cat "$fx/race/a.out" 2>&1)"; fi
race_owner=$(cat "$race_records/cleanup-codex.launch.lock/takeover.999999.2026-10-02T12:00:00Z" 2>/dev/null)
if [ "$rc" -eq 2 ] && grep -q 'took .* first' <<<"$out" && ! grep -q 'started the codex sweep' <<<"$out" \
   && [ "${race_owner%% *}" = "pid=$race_a_pid" ]; then
  ok "a launcher that read the dead owner first cannot remove the lock another just took"
else bad "a launcher that read the dead owner first cannot remove the lock another just took" \
  "rc=$rc owner=$race_owner $out"; fi
touch "$fx/race/release-a"
[ -z "$race_a_pid" ] || wait_gone "$race_a_pid" || bad "launcher A finished" "$(cat "$fx/race/a.out" 2>&1)"
lock_settle "$race_home"
race_after=0
for f in "$fx"/pids/sweep-*; do [ ! -f "$f" ] || race_after=$((race_after + 1)); done
if [ $((race_after - race_before)) -eq 1 ] && grep -q 'started the codex sweep' "$fx/race/a.out" \
   && [ ! -e "$race_records/cleanup-codex.launch.lock" ]; then
  ok "launchers recovering one dead lock start exactly one sweep"
else bad "launchers recovering one dead lock start exactly one sweep" \
  "started=$((race_after - race_before)) a: $(cat "$fx/race/a.out" 2>&1) b: $out"; fi

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
# What the launcher refuses and how a stuck sweep is stopped are part of that procedure (#3823): a
# run told only to `kill` reaches for `kill -9`, which is what leaves a sweeper running alone.
# shellcheck disable=SC2016 # the backticks are literal Markdown, not a command substitution
if grep -qF 'never `kill -9`' <<<"$section" \
   && grep -qF 'A sweeper left running without' <<<"$section" \
   && grep -qF 'an unreadable record still starts a replacement, unless a supervisor' <<<"$section"; then
  ok "the guide's pre-flight says how to stop a stuck sweep and what blocks a replacement"
else bad "the guide's pre-flight says how to stop a stuck sweep and what blocks a replacement" "$section"; fi
# shellcheck disable=SC2016 # the backticks are literal Markdown, not a command substitution
if grep -qF '`worktree-lane-sweep.sh start --lane <your lane>`' "$skill" \
   && grep -qF 'never finished, is still running or no sweep is on record' "$skill" \
   && ! grep -qF 'Start `worktree-cleanup-all.sh apply 24' "$skill"; then
  ok "the run procedure starts the sweep and names every non-clean status"
else bad "the run procedure starts the sweep and names every non-clean status" "$skill"; fi

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
