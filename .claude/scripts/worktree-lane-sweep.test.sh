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
  cleanup) # as the real sweep does: one repository's cleanup, writing the lane's manifest
        "$fx/scripts/worktree-cleanup.sh" "$fx/repo" \\
          "\$HOME/.claude/worktree-cleanup-manifests/monorepo-20261002T000000Z.tsv" apply 24 336
        exit 0 ;;
esac
exit 3
EOF
# The fake per-repository cleanup: hangs until released, as one busy with a large repository does.
cat >"$fx/scripts/worktree-cleanup.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$fx/pids/cleanup-\$\$"
touch "$fx/hanging"
while [ ! -e "$fx/release" ]; do sleep 0.1; done
exit 0
EOF
chmod +x "$fx/scripts/worktree-cleanup-all.sh" "$fx/scripts/worktree-cleanup.sh"
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
# live_cleanups — pids of the fake per-repository cleanups still running, one per line.
live_cleanups() {
  local f pid
  for f in "$fx"/pids/cleanup-*; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null) || continue
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
  done
  return 0
}
# started_sweeps — how many fake sweeps have ever started.
started_sweeps() {
  local f n=0
  for f in "$fx"/pids/sweep-*; do [ ! -f "$f" ] || n=$((n + 1)); done
  printf '%s\n' "$n"
}
wait_gone() { # <pid>
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  ! kill -0 "$1" 2>/dev/null
}
# Before it starts a sweep the launcher looks for the lane's supervisors and sweepers by what they
# run, across the whole host, so a real sweep of the same lane on this machine would decide these
# cases. Every launcher this file starts therefore reads the process table through this filter,
# which keeps only the fixture's own processes; a case that scripts its own `ps` puts it in front.
# A question about one process (`-p`) is passed through: its answer names no path to keep it by.
real_ps=$(command -v ps) || { printf 'cannot find ps\n' >&2; exit 2; }
mkdir -p "$fx/fxbin"
cat >"$fx/fxbin/ps" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" -A "*) "$real_ps" "\$@" | grep -F -- "$fx/" ;;
  *) exec "$real_ps" "\$@" ;;
esac
EOF
chmod +x "$fx/fxbin/ps"
PATH="$fx/fxbin:$PATH"
export PATH
# quiet_lane <lane> — wait until no supervisor or sweeper of that lane is left in the fixture. A
# supervisor is still alive for a moment after it has recorded its end, and a case that starts
# from another home directory has no record that says so.
quiet_lane() {
  local i=0 listing
  while [ "$i" -lt 100 ]; do
    listing=$(ps -A -ww -o command= 2>/dev/null) || listing=""
    grep -Eq "worktree-lane-sweep\.sh __supervise --lane $1 |worktree-cleanup-all\.sh apply 24 --lane $1\$" \
      <<<"$listing" || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
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
run start --lane claude
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
run start --lane claude
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
run start --lane claude
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
kill -9 "$orphan_sup" 2>/dev/null
wait_gone "$orphan_sup" || bad "the supervisor was killed" "pid=$orphan_sup"
if [ "$(count_live_sweeps)" -eq 1 ]; then ok "fixture: the sweeper outlives its killed supervisor"
else bad "fixture: the sweeper outlives its killed supervisor" "live-sweeps=$(count_live_sweeps)"; fi
run start --lane claude
if [ "$rc" -eq 1 ] && grep -q 'NEVER FINISHED' <<<"$out" \
   && grep -q "not starting a second claude sweep: sweeper pid $orphan_sweeper is still running without its supervisor" <<<"$out" \
   && grep -qF "\`kill -- -$orphan_sweeper\`" <<<"$out" \
   && [ "$(field claude started id)" = "$orphan_id" ] && [ "$(count_live_sweeps)" -eq 1 ]; then
  ok "start does not put a second sweeper beside an orphaned one"
else
  bad "start does not put a second sweeper beside an orphaned one" \
    "rc=$rc live-sweeps=$(count_live_sweeps) $out"
  [ "$(field claude started id)" = "$orphan_id" ] || track claude
fi
# The same orphan behind a start record nobody can read: the record names no sweep at all, and
# the sweeper still has to block the replacement.
printf 'garbage\n' >"$records/cleanup-claude.started"
run start --lane claude
if [ "$rc" -eq 2 ] && grep -q 'malformed sweep record' <<<"$out" \
   && grep -q "sweeper pid $orphan_sweeper is still running without its supervisor" <<<"$out" \
   && [ "$(cat "$records/cleanup-claude.started")" = garbage ] && [ "$(count_live_sweeps)" -eq 1 ]; then
  ok "an orphaned sweeper blocks the replacement of an unreadable start record"
else
  bad "an orphaned sweeper blocks the replacement of an unreadable start record" \
    "rc=$rc live-sweeps=$(count_live_sweeps) $out"
  [ "$(cat "$records/cleanup-claude.started")" = garbage ] || track claude
fi
# Once the sweeper has ended on its own, the next start replaces the record and sweeps.
touch "$fx/release"
[ -z "$orphan_sweeper" ] || wait_gone "$orphan_sweeper" || bad "the orphaned sweeper ended" "pid=$orphan_sweeper"
rm -f "$fx/release" "$fx/hanging"
mode ok
run start --lane claude
track claude
if [ "$rc" -eq 2 ] && grep -q 'started the claude sweep' <<<"$out" && wait_finished claude; then
  ok "the lane is swept again once the orphaned sweeper has ended"
else bad "the lane is swept again once the orphaned sweeper has ended" "rc=$rc $out"; fi

# A sweeper runs one repository's cleanup at a time and waits for it. Stopped alone, it leaves that
# cleanup going on with nothing of the sweeper's name left in the process table, so the cleanup
# itself has to block the next start, and the advice has to stop both.
mode cleanup
rm -f "$fx/release" "$fx/hanging"
run start --lane claude
group_id=$(field claude started id); group_sup=$(field claude started pid)
track claude
wait_for "$fx/hanging" || bad "the sweep's cleanup started" "$(cat "$log" 2>&1)"
group_sweeper=$(live_sweeps); group_cleanup=$(live_cleanups)
kill -9 "$group_sup" 2>/dev/null
wait_gone "$group_sup" || bad "the supervisor of the cleaning sweep was killed" "pid=$group_sup"
run start --lane claude
if [ "$rc" -eq 1 ] && [ -n "$group_sweeper" ] \
   && grep -qF "\`kill -- -$group_sweeper\`" <<<"$out" && [ "$(field claude started id)" = "$group_id" ]; then
  ok "the advice for an orphaned sweeper stops its whole process group"
else bad "the advice for an orphaned sweeper stops its whole process group" "rc=$rc $out"; fi
# What a plain `kill <pid>` does: the sweeper is gone and the cleanup it ran goes on.
kill "$group_sweeper" 2>/dev/null
wait_gone "$group_sweeper" || bad "the sweeper was stopped alone" "pid=$group_sweeper"
if [ -n "$group_cleanup" ] && kill -0 "$group_cleanup" 2>/dev/null; then
  ok "fixture: the cleanup outlives the sweeper that was stopped alone"
else bad "fixture: the cleanup outlives the sweeper that was stopped alone" "cleanup=$group_cleanup"; fi
group_before=$(started_sweeps)
run start --lane claude
if [ "$rc" -eq 1 ] \
   && grep -q "not starting a second claude sweep: cleanup pid $group_cleanup, which a sweep of the lane started, is still running" <<<"$out" \
   && [ "$(field claude started id)" = "$group_id" ] && [ "$(started_sweeps)" -eq "$group_before" ]; then
  ok "start does not put a sweep beside a cleanup whose sweeper was stopped alone"
else
  bad "start does not put a sweep beside a cleanup whose sweeper was stopped alone" \
    "rc=$rc started=$(started_sweeps)/$group_before $out"
  [ "$(field claude started id)" = "$group_id" ] || track claude
fi
# The command the advice gave still reaches that cleanup: it stayed in the sweeper's group.
kill -- "-$group_sweeper" 2>/dev/null
if [ -n "$group_cleanup" ] && wait_gone "$group_cleanup"; then
  ok "the advised group signal reaches the cleanup after its sweeper is gone"
else bad "the advised group signal reaches the cleanup after its sweeper is gone" "cleanup=$group_cleanup"; fi
rm -f "$fx/release" "$fx/hanging"
mode ok
run start --lane claude
track claude
if [ "$rc" -eq 1 ] && grep -q 'started the claude sweep' <<<"$out" && wait_finished claude; then
  ok "the lane is swept again once nothing of the stopped sweep runs"
else bad "the lane is swept again once nothing of the stopped sweep runs" "rc=$rc $out"; fi
run status --lane claude
clean_id=$(field claude started id)
if [ "$rc" -eq 0 ]; then ok "fixture: the records show the last sweep finished cleanly"
else bad "fixture: the records show the last sweep finished cleanly" "rc=$rc $out"; fi

# The records can say "finished cleanly" while a supervisor of the lane is running that they do
# not name. What may start is decided by the process table, so that one blocks a start too.
mkdir -p "$fx/bin"
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf '4242 00:03:00 bash %s __supervise --lane claude --id 20261002T990000Z-9\n' "$SUT_PATH"
printf '%s 00:00:01 bash %s start --lane claude\n' "$FAKE_PS_SELF_PID" "$SUT_PATH"
EOF
chmod +x "$fx/bin/ps"
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane claude' 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'finished cleanly' <<<"$out" \
   && grep -q 'not starting a second claude sweep while supervisor pid 4242 still runs' <<<"$out" \
   && [ "$(field claude started id)" = "$clean_id" ]; then
  ok "a supervisor of the lane the records do not name blocks a start after a clean sweep"
else bad "a supervisor of the lane the records do not name blocks a start after a clean sweep" "rc=$rc $out"; fi
# The supervisor of the sweep the records show finished has written its last record and is on its
# way out. It is not a sweep in progress, and the next start does not wait for it.
cat >"$fx/bin/ps" <<'EOF'
#!/usr/bin/env bash
id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$HOME/.claude/worktree-cleanup-manifests/cleanup-claude.finished")
printf '4242 00:03:00 bash %s __supervise --lane claude --id %s\n' "$SUT_PATH" "$id"
printf '%s 00:00:01 bash %s start --lane claude\n' "$FAKE_PS_SELF_PID" "$SUT_PATH"
EOF
out=$(HOME="$fx/home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" \
  bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane claude' 2>&1); rc=$?
rm -f "$fx/bin/ps"
track claude
if [ "$rc" -eq 0 ] && grep -q 'started the claude sweep' <<<"$out" \
   && [ "$(field claude started id)" != "$clean_id" ] && wait_finished claude; then
  ok "the supervisor of a sweep already recorded as finished does not block the next start"
else bad "the supervisor of a sweep already recorded as finished does not block the next start" "rc=$rc $out"; fi

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
quiet_lane codex || bad "fixture: the codex lane is quiet before its own case" "$(ps -A -ww -o command= 2>&1)"
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
mkdir -p "$supervisor_records/cleanup-claude.finished" "$supervisor_records/cleanup-claude.launch.lock"
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
quiet_lane claude || bad "fixture: the claude lane is quiet before the handshake case" "$(ps -A -ww -o command= 2>&1)"
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

# --- a supervisor is not yet a supervisor in the process table (#3823) -------------
# A supervisor is forked from its launcher and shows the launcher's command line until it has
# replaced it. The launcher keeps its lock until the supervisor has said it is running, and a
# supervisor nobody holds the lock for sweeps nothing.
nolock_home="$fx/nolock-home"
mkdir -p "$nolock_home/.claude/worktree-cleanup-manifests"
before=$(started_sweeps)
out=$(HOME="$nolock_home" SUT_PATH="$sut" bash -c '
  printf "id=20261002T150000Z-4 pid=%s at=2026-10-02T15:00:00Z\n" "$$" \
    >"$HOME/.claude/worktree-cleanup-manifests/cleanup-claude.started"
  exec bash "$SUT_PATH" __supervise --lane claude --id 20261002T150000Z-4
' 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no longer holds' <<<"$out" && [ "$(started_sweeps)" -eq "$before" ]; then
  ok "a supervisor whose launcher holds no lock sweeps nothing"
else bad "a supervisor whose launcher holds no lock sweeps nothing" \
  "rc=$rc started=$(started_sweeps)/$before $out"; fi

# A `nohup` that waits before it runs the supervisor stands for the moment between the fork and
# the supervisor's own command line.
slow_home="$fx/slow-home"
slow_records="$slow_home/.claude/worktree-cleanup-manifests"
mkdir -p "$slow_home" "$fx/slow"
cat >"$fx/slow/nohup" <<EOF
#!/usr/bin/env bash
while [ ! -e "$fx/slow/go" ]; do sleep 0.05; done
exec "\$@"
EOF
chmod +x "$fx/slow/nohup"
quiet_lane codex || bad "fixture: the codex lane is quiet before the slow supervisor" "$(ps -A -ww -o command= 2>&1)"
HOME="$slow_home" PATH="$fx/slow:$PATH" bash "$sut" start --lane codex >"$fx/slow/a.out" 2>&1 & slow_a=$!
wait_for "$slow_records/cleanup-codex.started" || bad "the slow launcher recorded its supervisor" "$(cat "$fx/slow/a.out" 2>&1)"
sleep 0.3
if kill -0 "$slow_a" 2>/dev/null && [ -d "$slow_records/cleanup-codex.launch.lock" ]; then
  ok "the launcher keeps its lock until its supervisor has said it is running"
else bad "the launcher keeps its lock until its supervisor has said it is running" \
  "$(cat "$fx/slow/a.out" 2>&1) $(ls "$slow_records" 2>&1)"; fi
before=$(started_sweeps)
out=$(HOME="$slow_home" bash "$sut" start --lane codex 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q "holds $slow_records/cleanup-codex.launch.lock" <<<"$out" \
   && [ "$(started_sweeps)" -eq "$before" ]; then
  ok "a launcher arriving before the supervisor is one starts nothing"
else bad "a launcher arriving before the supervisor is one starts nothing" "rc=$rc $out"; fi
touch "$fx/slow/go"
wait_gone "$slow_a" || bad "the slow launcher finished" "$(cat "$fx/slow/a.out" 2>&1)"
slow_id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$slow_records/cleanup-codex.started" 2>/dev/null)
i=0
while [ "$i" -lt 100 ] && \
  [ "$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$slow_records/cleanup-codex.finished" 2>/dev/null)" != "$slow_id" ]; do
  sleep 0.1; i=$((i + 1))
done
if grep -q 'started the codex sweep' "$fx/slow/a.out" && [ ! -e "$slow_records/cleanup-codex.launch.lock" ] \
   && [ "$(started_sweeps)" -eq $((before + 1)) ] && [ "$i" -lt 100 ]; then
  ok "once the supervisor has said so, the launcher reports the start and frees the lock"
else bad "once the supervisor has said so, the launcher reports the start and frees the lock" \
  "started=$(started_sweeps)/$before $(cat "$fx/slow/a.out" 2>&1)"; fi

# A supervisor that ends without saying it is running, and one that never says it.
mkdir -p "$fx/dead" "$fx/mute"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fx/dead/nohup"
printf '#!/usr/bin/env bash\nexec sleep 60\n' >"$fx/mute/nohup"
chmod +x "$fx/dead/nohup" "$fx/mute/nohup"
before=$(started_sweeps)
quiet_lane codex || bad "fixture: the codex lane is quiet before the dead supervisor" "$(ps -A -ww -o command= 2>&1)"
out=$(HOME="$fx/dead-home" PATH="$fx/dead:$PATH" bash "$sut" start --lane codex 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'ended before it began the sweep' <<<"$out" \
   && ! grep -q 'started the codex sweep' <<<"$out" && [ "$(started_sweeps)" -eq "$before" ] \
   && [ ! -e "$fx/dead-home/.claude/worktree-cleanup-manifests/cleanup-codex.launch.lock" ]; then
  ok "a supervisor that ended before sweeping is UNKNOWN (2), not a started sweep"
else bad "a supervisor that ended before sweeping is UNKNOWN (2), not a started sweep" "rc=$rc $out"; fi
out=$(HOME="$fx/mute-home" PATH="$fx/mute:$PATH" bash "$sut" start --lane codex 2>&1); rc=$?
mute_pid=$(sed -nE 's/^id=[^ ]+ pid=([0-9]+) .*/\1/p' \
  "$fx/mute-home/.claude/worktree-cleanup-manifests/cleanup-codex.started" 2>/dev/null)
if [ "$rc" -eq 2 ] && grep -q 'did not say it was running within ten seconds; it was stopped' <<<"$out" \
   && [ "$(started_sweeps)" -eq "$before" ] && [ -n "$mute_pid" ] && ! kill -0 "$mute_pid" 2>/dev/null; then
  ok "a supervisor that never says it is running is stopped, and the start is UNKNOWN (2)"
else bad "a supervisor that never says it is running is stopped, and the start is UNKNOWN (2)" \
  "rc=$rc pid=$mute_pid $out"; fi

# table_start <lane> <home> <ps-listing-lines...> — start <lane> with a process table that holds
# this launcher and the given lines. Sets out, rc. In a line `@SUT@` is the launcher's path,
# `@ALL@` the sweeper's, `@ONE@` the per-repository cleanup's and `@DIR@` that home's records.
table_start() {
  local table_lane=$1 home=$2 line; shift 2
  mkdir -p "$fx/bin"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # expanded by the generated script, not here
    printf 'printf "%%s 00:00:01 bash %%s start --lane %s\\n" "$FAKE_PS_SELF_PID" "$SUT_PATH"\n' "$table_lane"
    for line in "$@"; do
      line=${line//@SUT@/$sut}
      line=${line//@ALL@/$fx/scripts/worktree-cleanup-all.sh}
      line=${line//@ONE@/$fx/scripts/worktree-cleanup.sh}
      line=${line//@DIR@/$home/.claude/worktree-cleanup-manifests}
      printf 'printf "%%s\\n" %q\n' "$line"
    done
  } >"$fx/bin/ps"
  chmod +x "$fx/bin/ps"
  out=$(HOME="$home" PATH="$fx/bin:$PATH" SUT_PATH="$sut" TABLE_LANE="$table_lane" \
    bash -c 'export FAKE_PS_SELF_PID=$$; exec bash "$SUT_PATH" start --lane "$TABLE_LANE"' 2>&1); rc=$?
  rm -f "$fx/bin/ps"
}

# The record names a pid that still shows the launcher's command line: the supervisor in the
# moment before it is one. It is running, not gone, whatever happened to the launcher's lock.
fork_home="$fx/fork-home"
fork_records="$fork_home/.claude/worktree-cleanup-manifests"
mkdir -p "$fork_records"
printf 'id=20261002T160000Z-5 pid=4242 at=2026-10-02T16:00:00Z\n' >"$fork_records/cleanup-codex.started"
before=$(started_sweeps)
table_start codex "$fork_home" '4242 00:00:02 bash @SUT@ start --lane codex'
if [ "$rc" -eq 1 ] && grep -q 'has been running since' <<<"$out" \
   && grep -q 'not starting a second codex sweep while that one runs' <<<"$out" \
   && [ "$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$fork_records/cleanup-codex.started")" = 20261002T160000Z-5 ] \
   && [ "$(started_sweeps)" -eq "$before" ]; then
  ok "a recorded supervisor that still shows the launcher's command line is running, not gone"
else bad "a recorded supervisor that still shows the launcher's command line is running, not gone" \
  "rc=$rc $out"; fi

# --- every spelling of a sweep is the same sweep (#3823) --------------------------
# What blocks a start is read from a command line the way the script it names reads its own
# arguments. Each line below is one process beside the launcher; nothing is on record.
spell_home="$fx/spell-home"
mkdir -p "$spell_home"
refused() { # <lane> <process line> <what the refusal names> <case name>
  local before_refused
  before_refused=$(started_sweeps)
  table_start "$1" "$spell_home" "$2"
  if [ "$rc" -eq 1 ] && grep -q "not starting a second $1 sweep" <<<"$out" && grep -q "$3" <<<"$out" \
     && [ "$(started_sweeps)" -eq "$before_refused" ] \
     && [ ! -e "$spell_home/.claude/worktree-cleanup-manifests/cleanup-$1.started" ]; then ok "$4"
  else bad "$4" "rc=$rc $out"; fi
}
refused codex '4301 00:01:00 bash @ALL@ apply 24 336 --lane codex' 'sweeper pid 4301 ' \
  "a sweeper given a salvage age blocks its lane's start"
refused codex '4302 00:01:00 bash @ALL@ --lane=codex apply' 'sweeper pid 4302 ' \
  "a sweeper given --lane=<lane> first blocks its lane's start"
refused codex '4303 00:01:00 bash @ALL@ apply --lane codex 24' 'sweeper pid 4303 ' \
  "a sweeper given its lane between the other arguments blocks its lane's start"
refused codex '4304 00:01:00 bash @ALL@ apply 24 --lane' 'sweeper pid 4304 ' \
  "a sweeper whose lane cannot be read blocks the start"
refused claude '4305 00:01:00 bash @ALL@ apply 24' 'sweeper pid 4305 ' \
  "a sweeper given no lane sweeps the claude lane, and blocks its start"
refused codex '4306 00:01:00 bash @SUT@ __supervise --id 20261002T990000Z-9 --lane codex' 'supervisor pid 4306 ' \
  "a supervisor given its id first blocks its lane's start"
refused codex '4307 00:01:00 bash @ONE@ /repo @DIR@/codex/monorepo-20261002T000000Z.tsv apply 24 336' 'cleanup pid 4307,' \
  "a cleanup writing the codex lane's manifest blocks the codex start"
refused claude '4308 00:01:00 bash @ONE@ /repo @DIR@/monorepo-20261002T000000Z.tsv apply 24 336' 'cleanup pid 4308,' \
  "a cleanup writing the claude lane's manifest blocks the claude start"
# None of these sweeps the lane asked about, or removes anything, so none blocks it.
mode ok
quiet_lane codex || bad "fixture: the codex lane is quiet before the spellings that do not block" "$(ps -A -ww -o command= 2>&1)"
table_start codex "$spell_home" \
  '4311 00:01:00 bash @ALL@ apply 24' \
  '4312 00:01:00 bash @ALL@ dry-run 24 --lane codex' \
  '4313 00:01:00 bash @ALL@ --lane codex' \
  '4314 00:01:00 bash @ALL@ 24 apply --lane codex' \
  '4315 00:01:00 bash @SUT@ __supervise --lane claude --id 20261002T990000Z-9' \
  '4316 00:01:00 bash @SUT@ status --lane codex' \
  '4317 00:01:00 bash @ONE@ /repo @DIR@/monorepo-20261002T000000Z.tsv apply 24 336' \
  '4318 00:01:00 bash @ONE@ /repo @DIR@/codex/monorepo-20261002T000000Z.tsv dry-run 24' \
  '4319 00:01:00 bash @ONE@ /repo /elsewhere/.claude/worktree-cleanup-manifests/codex/monorepo-1.tsv apply 24' \
  '4320 00:01:00 sed -n 1,40p @ALL@'
if [ "$rc" -eq 1 ] && grep -q 'started the codex sweep' <<<"$out"; then
  ok "another lane's sweep, a dry run and a cleanup for another home do not block the codex start"
else bad "another lane's sweep, a dry run and a cleanup for another home do not block the codex start" "rc=$rc $out"; fi
quiet_lane claude || bad "fixture: the claude lane is quiet before the spellings that do not block" "$(ps -A -ww -o command= 2>&1)"
table_start claude "$spell_home" \
  '4321 00:01:00 bash @ALL@ apply 24 --lane codex' \
  '4322 00:01:00 bash @ALL@ --lane=codex apply' \
  '4323 00:01:00 bash @SUT@ __supervise --id 20261002T990000Z-9 --lane codex' \
  '4324 00:01:00 bash @ONE@ /repo @DIR@/codex/monorepo-20261002T000000Z.tsv apply 24 336'
if [ "$rc" -eq 1 ] && grep -q 'started the claude sweep' <<<"$out"; then
  ok "the codex lane's sweeper, supervisor and cleanup do not block the claude start"
else bad "the codex lane's sweeper, supervisor and cleanup do not block the claude start" "rc=$rc $out"; fi
for spell_lane in codex claude; do
  spell_id=$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$spell_home/.claude/worktree-cleanup-manifests/cleanup-$spell_lane.started" 2>/dev/null)
  i=0
  while [ "$i" -lt 100 ] && \
    [ "$(sed -nE 's/^id=([^ ]+) .*/\1/p' "$spell_home/.claude/worktree-cleanup-manifests/cleanup-$spell_lane.finished" 2>/dev/null)" != "$spell_id" ]; do
    sleep 0.1; i=$((i + 1))
  done
done

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
   && grep -qF 'together with the cleanup it is running' <<<"$section" \
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
