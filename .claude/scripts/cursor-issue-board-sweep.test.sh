#!/usr/bin/env bash
#
# Self-test for cursor-issue-board-sweep.sh.
#
# BEHAVIOURAL, not textual: `gh` is stubbed on PATH to emit a chosen result set and to RECORD its
# own argv, and `board-add.sh` is stubbed to LOG every URL it is handed. The central assertion is
# a set comparison — every discovered issue reached the helper — and it is ABLATED at the end
# against a copy of the script that drops one issue, so a check that could never fail is not
# mistaken for a passing one.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep="$here/cursor-issue-board-sweep.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = yes ]; then echo "PASS: $name"; else echo "FAIL: $name${detail:+ — $detail}"; fail=1; fi
}

# A `gh` stub emitting $2.. as URLs (one per line) and recording argv to $tmp/gh-argv.
# GH_EXIT selects a failed search so the fail-closed path can be exercised.
mkstub_gh() {
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_ARGV_LOG}"
if [ -n "${GH_STDERR:-}" ]; then printf '%s\n' "${GH_STDERR}" >&2; fi
if [ "${GH_EXIT:-0}" != 0 ]; then echo "stub: simulated search failure" >&2; exit "${GH_EXIT}"; fi
[ -s "${GH_RESULTS}" ] && cat "${GH_RESULTS}"
exit 0
STUB
  chmod +x "$tmp/bin/gh"
}

# A `board-add.sh` stub logging each URL. BOARD_ADD_FAIL_ON / BOARD_ADD_PRIVATE_ON select
# an operational failure or a private-repo refusal for one URL.
mkstub_board_add() {
  cat > "$tmp/board-add-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${BOARD_LOG}"
if [ -n "${BOARD_ADD_PRIVATE_ON:-}" ] && [ "$1" = "${BOARD_ADD_PRIVATE_ON}" ]; then
  echo "board-add: devantler-tech/x is PRIVATE; project 5 is public — adding it is a maintainer decision, not an agent default"; exit 2
fi
if [ -n "${BOARD_ADD_FAIL_ON:-}" ] && [ "$1" = "${BOARD_ADD_FAIL_ON}" ]; then
  echo "board-add: set failed"; exit 2
fi
echo "board-add: ok $1"
STUB
  chmod +x "$tmp/board-add-stub.sh"
}

mkstub_gh
mkstub_board_add
export GH_ARGV_LOG="$tmp/gh-argv" GH_RESULTS="$tmp/results" BOARD_LOG="$tmp/board-log"

U1=https://github.com/devantler-tech/monorepo/issues/1
U2=https://github.com/devantler-tech/platform/issues/2
U3=https://github.com/devantler-tech/ksail/issues/3

# Run the sweep (arg $1 = script under test) with a fresh log; sets $rc and $out.
run_sweep() {
  local script="$1"; shift
  : > "$BOARD_LOG"; : > "$GH_ARGV_LOG"
  rc=0
  out="$(PATH="$tmp/bin:$PATH" "$script" --board-add "$tmp/board-add-stub.sh" --pace-seconds 0 "$@" 2>&1)" || rc=$?
}

# ---------------------------------------------------------------------------
# 1. THE CENTRAL ASSERTION — every discovered issue reaches the helper.
printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" > "$GH_RESULTS"
run_sweep "$sweep"
got="$(sort "$BOARD_LOG")"
want="$(printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" | sort)"
report "every discovered issue is passed to board-add" \
  "$([ "$got" = "$want" ] && [ "$rc" -eq 0 ] && echo yes || echo no)" "rc=$rc got=[$(echo "$got" | tr '\n' ' ')]"
report "summary counts the sweep" \
  "$(printf '%s' "$out" | grep -q 'discovered=3 boarded=3 skipped=0 failed=0' && echo yes || echo no)" "$out"

# 2. Discovery flags are pinned (the AC names each one).
argv="$(cat "$GH_ARGV_LOG")"
for flag in "--archived=false" "--owner devantler-tech" "--state open" "--author app/cursor" "--limit 300" "--sort created" "--order asc"; do
  report "discovery pins ${flag}" "$(printf '%s' "$argv" | grep -qF -- "$flag" && echo yes || echo no)" "$argv"
done

# 3. An EMPTY but SUCCESSFUL sweep is believed: exit 0, nothing handed to the helper.
: > "$GH_RESULTS"
run_sweep "$sweep"
report "empty successful sweep exits 0 with no board-add call" \
  "$([ "$rc" -eq 0 ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc log=[$(cat "$BOARD_LOG")]"
report "empty sweep reports discovered=0" \
  "$(printf '%s' "$out" | grep -q 'discovered=0 boarded=0' && echo yes || echo no)" "$out"

# 4. FAIL-CLOSED: a failed discovery is not an empty one. This is the control for case 3 —
#    both produce no output from `gh`, and only the exit status separates them.
printf '%s\n' "$U1" > "$GH_RESULTS"
GH_EXIT=1 run_sweep "$sweep"
report "a FAILED discovery exits 2 and boards nothing" \
  "$([ "$rc" -eq 2 ] && [ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "rc=$rc"
unset GH_EXIT

# 5. One helper failure does not abort the sweep, and is not absorbed either.
printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" > "$GH_RESULTS"
BOARD_ADD_FAIL_ON="$U2" run_sweep "$sweep"
report "a board-add failure still boards the others" \
  "$([ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 3 ] && echo yes || echo no)" "log=[$(cat "$BOARD_LOG")]"
report "a board-add failure makes the sweep exit 2" "$([ "$rc" -eq 2 ] && echo yes || echo no)" "rc=$rc"

# 6. A private repository's issue is SKIPPED, not a failure — it is a maintainer decision.
BOARD_ADD_PRIVATE_ON="$U2" run_sweep "$sweep"
report "a private-repo refusal is skipped, not failed" \
  "$([ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'skipped=1 failed=0' && echo yes || echo no)" "rc=$rc $out"

# 7. Usage errors fail closed rather than sweeping with a wrong bound.
run_sweep "$sweep" --limit not-a-number
report "a non-numeric --limit is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"

# ---------------------------------------------------------------------------
# 7c. SATURATION — a result set at the cap may be truncated, so success would hide unboarded issues.
printf '%s\n%s\n' "$U1" "$U2" > "$GH_RESULTS"
run_sweep "$sweep" --limit 2
report "a result set AT the --limit cap fails closed" \
  "$([ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'TRUNCATED' && echo yes || echo no)" "rc=$rc $out"
report "a saturated discovery boards nothing" "$([ ! -s "$BOARD_LOG" ] && echo yes || echo no)" "log=[$(cat "$BOARD_LOG")]"
# Control: one BELOW the cap is a complete census and sweeps normally.
run_sweep "$sweep" --limit 3
report "control: one result below the cap sweeps normally" \
  "$([ "$rc" -eq 0 ] && [ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 2 ] && echo yes || echo no)" "rc=$rc"

# 7d. A SUCCESSFUL search that writes to stderr must not fold that text into the URL list.
#     The CLI prints an upgrade notice on stderr about once a day, so this is routine, not exotic.
printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" > "$GH_RESULTS"
GH_STDERR="A new release of gh is available: 2.0.0 -> 2.1.0" run_sweep "$sweep"
got_stderr="$(sort "$BOARD_LOG")"
report "a stderr notice is not passed to board-add as an issue" \
  "$([ "$got_stderr" = "$want" ] && [ "$rc" -eq 0 ] && echo yes || echo no)" "rc=$rc got=[$(echo "$got_stderr" | tr '\n' ' ')]"

# 7d2. BOUNDED BATCH — a backfill larger than the batch defers the remainder instead of exceeding
#      the hourly request budget. Deferral is reported and is NOT a failure: board-add is
#      idempotent, so the next run continues from where this one stopped.
printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" > "$GH_RESULTS"
run_sweep "$sweep" --max-mutations 2
report "a batch bound stops after max-mutations issues" \
  "$([ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 2 ] && echo yes || echo no)" "log=[$(cat "$BOARD_LOG" | tr '\n' ' ')]"
report "the deferred remainder is reported, not failed" \
  "$([ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'deferred=1' && printf '%s' "$out" | grep -q 'failed=0' && echo yes || echo no)" "rc=$rc $out"
report "a deferral says the next run continues" \
  "$(printf '%s' "$out" | grep -q 'next sweep continues where this one stopped' && echo yes || echo no)" "$out"
# Control: a batch at least as large as the set defers nothing, so the bound cannot fire vacuously.
run_sweep "$sweep" --max-mutations 3
report "control: a batch covering the whole set defers nothing" \
  "$([ "$rc" -eq 0 ] && [ "$(wc -l < "$BOARD_LOG" | tr -d ' ')" = 3 ] && printf '%s' "$out" | grep -q 'deferred=0' && echo yes || echo no)" "rc=$rc $out"

run_sweep "$sweep" --max-mutations 0
report "a zero --max-mutations is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"
run_sweep "$sweep" --max-mutations nope
report "a non-numeric --max-mutations is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"

# 7e. Pacing is validated like every other numeric option.
run_sweep "$sweep" --pace-seconds nope
report "a non-numeric --pace-seconds is a usage error" "$([ "$rc" -eq 1 ] && echo yes || echo no)" "rc=$rc"

# 8. ABLATION — a copy that drops the LAST discovered issue must make assertion 1 FIRE.
#    Without this, a set comparison that can never fail would read as a passing test.
ablated="$tmp/sweep-ablated.sh"
# Drop the LAST discovered issue by teaching the loop to skip that exact URL. `awk` rather than
# `sed` because the inserted guard contains `||`, which collides with every convenient sed delimiter.
awk -v skip="$U3" '
  { print }
  /^  \[ -n "\$url" \] \|\| continue$/ && !done { printf "  [ \"$url\" = \"%s\" ] && continue\n", skip; done=1 }
' "$sweep" > "$ablated"
chmod +x "$ablated"
grep -q "&& continue" "$ablated" || report "ablation edit landed" no "the awk insert did not apply"
printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" > "$GH_RESULTS"
run_sweep "$ablated"
got_abl="$(sort "$BOARD_LOG")"
if [ "$got_abl" = "$want" ]; then
  report "ablation: dropping an issue makes the set assertion fire" no "the ablated copy still passed — assertion 1 cannot fail"
else
  report "ablation: dropping an issue makes the set assertion fire" yes
fi

if [ "$fail" -eq 0 ]; then echo "cursor-issue-board-sweep self-test: all cases passed"; else echo "cursor-issue-board-sweep self-test: FAILED" >&2; exit 1; fi
