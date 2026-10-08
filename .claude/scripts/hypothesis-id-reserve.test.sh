#!/usr/bin/env bash
# hypothesis-id-reserve.test.sh — RED/GREEN coverage for hypothesis-id-reserve.sh (monorepo#3536).
#
# The case that matters most is the one the helper exists for: callers that run at the same moment
# must each get a different identifier. The fail-closed cases come next — an unreadable store or an
# empty one must reserve nothing, because a number minted from a partial read can repeat an old one.
#
# Every case works in a throwaway directory; no real store is read.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/hypothesis-id-reserve.sh"
GUIDE="$SCRIPT_DIR/../guides/durable-memory.md"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

FIX=$(mktemp -d)
hypothesis_id_reserve_test_finished=0
cleanup() {
  rc=$?
  chmod -R u+w "$FIX" 2>/dev/null || true
  rm -rf "$FIX"
  if [ "$hypothesis_id_reserve_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "hypothesis-id-reserve.test: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

pass=0; fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

# run <case dir> <args...> — runs the helper; leaves stdout in $out, stderr in $err, status in $rc.
run() {
  rc=0
  out=$(bash "$SCRIPT" "$@" 2>"$FIX/stderr") || rc=$?
  err=$(cat "$FIX/stderr")
}

# expect <name> <want rc> <want stdout>
expect() {
  if [ "$rc" -eq "$2" ] && [ "$out" = "$3" ]; then
    ok "$1"
  else
    bad "$1: wanted exit $2 and '$3', got exit $rc and '$out' ($err)"
  fi
}

# reserved_count <dir> — how many reservations the directory holds.
reserved_count() { find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }

echo "== the next identifier =="
store="$FIX/store.md"
printf '%s\n' '## SETTLED H70 · H76 — archived' '## H93 (opened 2026-10-06) — a signature' '### H94 — another' 'Upper bounds H8653/60, H898/10 and H120 in running text' > "$store"
res="$FIX/res"

run --reservations "$res" --owner run-a --scan "$store"
expect "one above the highest in the store" 0 H95
if [ "$(cat "$res/H95/owner" 2>/dev/null)" = run-a ]; then
  ok "the reservation records its owner"
else
  bad "the reservation does not record its owner"
fi

run --reservations "$res" --owner run-b --scan "$store"
expect "a reservation counts before the store is written" 0 H96

mkdir "$res/H120"
run --reservations "$res" --owner run-c --scan "$store"
expect "a reservation above the store wins" 0 H121

echo "== what counts as an identifier =="
words="$FIX/words.md"
printf '%s\n' '# SHA256 H2O xH999 H12345678 h500 H_700 H44' '## (H45), [H46]' '### CH47' '####### H300 has seven marks' '#H400 has no space' ' # H500 is indented' > "$words"
run --reservations "$FIX/res-words" --owner run-a --scan "$words"
expect "only a whole-word H<n> in a heading counts" 0 H47

zeros="$FIX/zeros.md"
printf '%s\n' '## H007 and H08' > "$zeros"
run --reservations "$FIX/res-zeros" --owner run-a --scan "$zeros"
expect "leading zeros are read as decimal" 0 H9

echo "== running text is not read =="
prose="$FIX/prose.md"
printf '%s\n' '## H89 — a signature' 'UpperboundsH8653/60,H87a11/30,H898/10 NOT-YET-DUE' 'see H500' > "$prose"
run --reservations "$FIX/res-prose" --owner run-a --scan "$prose"
expect "an identifier run together with a figure is not read as a larger one" 0 H90
run --reservations "$FIX/res-atleast" --owner run-a --scan "$prose" --at-least 500
expect "--at-least raises the floor" 0 H501
run --reservations "$FIX/res-atleast-low" --owner run-a --scan "$prose" --at-least 3
expect "--at-least never lowers it" 0 H90
only_prose="$FIX/only-prose.md"
printf '%s\n' 'H12 is mentioned, never in a heading' > "$only_prose"
run --reservations "$FIX/res-only-prose" --owner run-a --scan "$only_prose"
expect "a store with no identifier in a heading is unknown" 2 ""
run --reservations "$FIX/res-only-prose" --owner run-a --scan "$only_prose" --at-least 12
expect "--at-least stands in for it" 0 H13

echo "== several stores =="
sibling="$FIX/sibling.md"
printf '%s\n' '### Hypotheses / next run — H101' > "$sibling"
run --reservations "$FIX/res-two" --owner run-a --scan "$store" --scan "$sibling"
expect "the highest across every store" 0 H102
run --reservations "$FIX/res-two-b" --owner run-a --scan "$sibling" --scan "$store"
expect "the order of the stores does not matter" 0 H102

echo "== nothing is reserved when the answer is unknown =="
run --reservations "$FIX/res-missing" --owner run-a --scan "$store" --scan "$FIX/absent.md"
expect "a missing store" 2 ""
if [ ! -d "$FIX/res-missing" ] || [ "$(reserved_count "$FIX/res-missing")" -eq 0 ]; then
  ok "a missing store reserves nothing"
else
  bad "a missing store still reserved an identifier"
fi
case "$err" in *"cannot read the store"*) ok "a missing store is named as the cause" ;; *) bad "a missing store gave the wrong reason: $err" ;; esac

mkdir "$FIX/a-directory.md"
run --reservations "$FIX/res-dir" --owner run-a --scan "$FIX/a-directory.md"
expect "a store that is a directory" 2 ""

empty="$FIX/empty.md"
: > "$empty"
run --reservations "$FIX/res-empty" --owner run-a --scan "$empty"
expect "no identifier anywhere" 2 ""
case "$err" in *"no identifier found"*) ok "an empty store is named as the cause" ;; *) bad "an empty store gave the wrong reason: $err" ;; esac
if [ "$(reserved_count "$FIX/res-empty")" -eq 0 ]; then
  ok "an empty store reserves nothing"
else
  bad "an empty store still reserved an identifier"
fi
run --reservations "$FIX/res-empty" --owner run-a --scan "$empty" --first
expect "--first allows the first identifier" 0 H1
run --reservations "$FIX/res-empty" --owner run-a --scan "$empty"
expect "after the first, the reservation is enough" 0 H2

if [ "$(id -u)" -ne 0 ]; then
  mkdir "$FIX/res-readonly"
  chmod 555 "$FIX/res-readonly"
  run --reservations "$FIX/res-readonly" --owner run-a --scan "$store"
  expect "an unwritable reservations directory" 2 ""
  chmod 755 "$FIX/res-readonly"

  : > "$FIX/unreadable.md"
  chmod 000 "$FIX/unreadable.md"
  run --reservations "$FIX/res-unreadable" --owner run-a --scan "$FIX/unreadable.md" --scan "$store"
  expect "an unreadable store beside a readable one" 2 ""
  chmod 644 "$FIX/unreadable.md"
else
  echo "  skip permission cases (running as root)"
fi

: > "$FIX/res-is-a-file"
run --reservations "$FIX/res-is-a-file" --owner run-a --scan "$store"
expect "a reservations path that is a file" 2 ""

echo "== usage =="
run --owner run-a --scan "$store"
expect "no reservations directory" 2 ""
run --reservations "$FIX/res-usage" --scan "$store"
expect "no owner" 2 ""
run --reservations "$FIX/res-usage" --owner run-a
expect "no store" 2 ""
run --reservations "$FIX/res-usage" --owner 'run a; rm -rf x' --scan "$store"
expect "an owner that is not a plain token" 2 ""
for bad_floor in 0 007 -3 1.5 abc 1234567 ''; do
  run --reservations "$FIX/res-usage" --owner run-a --scan "$store" --at-least "$bad_floor"
  expect "--at-least '$bad_floor' is refused" 2 ""
done
run --reservations "$FIX/res-usage" --owner run-a --scan "$store" --unknown
expect "an unknown argument" 2 ""
run --reservations "$FIX/res-usage" --owner run-a --scan
expect "a flag without its value" 2 ""
if [ ! -d "$FIX/res-usage" ] || [ "$(reserved_count "$FIX/res-usage")" -eq 0 ]; then
  ok "a usage error reserves nothing"
else
  bad "a usage error still reserved an identifier"
fi

echo "== callers at the same moment each get their own =="
race="$FIX/res-race"
callers=16
i=0
while [ "$i" -lt "$callers" ]; do
  i=$((i + 1))
  ( bash "$SCRIPT" --reservations "$race" --owner "run-$i" --scan "$store" > "$FIX/race-$i.out" 2> "$FIX/race-$i.err"
    echo "$?" > "$FIX/race-$i.rc" ) &
done
wait
failed=0
i=0
: > "$FIX/race-ids"
while [ "$i" -lt "$callers" ]; do
  i=$((i + 1))
  if [ "$(cat "$FIX/race-$i.rc")" != 0 ]; then
    failed=$((failed + 1))
  fi
  cat "$FIX/race-$i.out" >> "$FIX/race-ids"
done
distinct=$(sort -u "$FIX/race-ids" | grep -c '^H[0-9][0-9]*$' || true)
if [ "$failed" -eq 0 ] && [ "$distinct" -eq "$callers" ]; then
  ok "$callers concurrent callers got $callers different identifiers"
else
  bad "$callers concurrent callers: $failed failed and only $distinct identifiers were distinct"
fi
lowest=$(sed 's/^H//' "$FIX/race-ids" | sort -n | sed -n '1p')
highest=$(sed 's/^H//' "$FIX/race-ids" | sort -n | sed -n '$p')
if [ "$lowest" = 95 ] && [ "$highest" = $((94 + callers)) ]; then
  ok "they took the next $callers numbers with no gap"
else
  bad "the concurrent identifiers ran from H$lowest to H$highest, wanted H95 to H$((94 + callers))"
fi
if [ "$(reserved_count "$race")" -eq "$callers" ]; then
  ok "one reservation exists per caller"
else
  bad "wanted $callers reservations, found $(reserved_count "$race")"
fi

echo "== contract: the memory guide states the rule =="
# Scoped to the paragraph that carries the rule, and fail-closed when it cannot be found: an empty
# extraction would pass every substring check.
section=$(awk '/Reserve a hypothesis identifier before it is written/ { on = 1 } on { print } on && /monorepo#3536\)/ { exit }' "$GUIDE")
if [ -z "$section" ]; then
  bad "the memory guide has no paragraph on reserving a hypothesis identifier"
else
  ok "the memory guide has the paragraph"
  # needs <label> <fixed text> — the paragraph, with its line breaks folded, holds the text.
  folded=$(printf '%s' "$section" | tr -s ' \n' '  ')
  needs() {
    case "$folded" in *"$2"*) ok "the guide states: $1" ;; *) bad "the guide does not state: $1" ;; esac
  }
  needs "the helper by name" 'hypothesis-id-reserve.sh --reservations'
  needs "reserve before writing" 'Before it writes a new hypothesis'
  needs "exit 2 means do not mint" 'never mint one by hand'
  needs "every store is scanned, the sibling's included" "sibling's"
  needs "the ledger is appended to in a section of the run's own" 'section of its own'
  needs "a whole-file rewrite needs the live-run check" 'claude-task-live-runs.sh'
fi

echo
echo "hypothesis-id-reserve.test: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  hypothesis_id_reserve_test_finished=1
  exit 1
fi
hypothesis_id_reserve_test_finished=1
