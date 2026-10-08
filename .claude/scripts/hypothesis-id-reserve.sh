#!/usr/bin/env bash
# hypothesis-id-reserve.sh — reserve the next Agent Improver hypothesis identifier (monorepo#3536).
#
# Why: a hypothesis identifier (`H<n>`) was minted by reading the newest one in the store and adding
# one. Two runs of the same task that overlap both read the same newest identifier, so both minted
# `H80` on 2026-09-23, on one signature with two different baselines. Nothing fenced it, because the
# design assumed one run per task at a time.
#
# How: the identifier is claimed before it is written. The next number is one above the highest
# `H<n>` found in the headings of the stores the caller names and in the reservations directory, and
# it is taken by creating a directory of that name — an operation only one of two concurrent callers
# can win. The loser moves on to the next number. A reservation is never removed: a number that was
# handed out stays handed out, even when its run wrote nothing, so no later run can mint it again.
#
# Only heading lines are read, because running text is not reliable: one store packs its notes
# without spaces, so "H89 at 8/10" is stored as `H898/10` and reads as identifier 898. A hypothesis
# is opened under a heading that names it, so the headings hold every identifier. For a store that
# keeps identifiers anywhere else, state the highest one with --at-least.
#
# Usage:
#   hypothesis-id-reserve.sh --reservations <dir> --owner <token> --scan <file> [--scan <file>]...
#                            [--at-least <n>] [--first]
#
#   --reservations  directory holding one sub-directory per reserved identifier; created when absent
#   --owner         who reserves it (letters, digits, `.`, `_`, `-`), recorded beside the reservation
#   --scan          a markdown store whose headings name identifiers; repeat for every store, the
#                   sibling's included
#   --at-least      a number the caller knows is already used; the next identifier is above it
#   --first         allow `H1` when no store heading, reservation or --at-least names an identifier
#
# Exit codes:
#   0  reserved; the identifier is the only line on stdout
#   2  UNKNOWN — nothing was reserved: a usage error, an unreadable store, an unwritable reservations
#      directory, or no identifier found anywhere without --first. Never mint an identifier by hand
#      after an exit 2; the hypothesis waits for a run that can reserve one.

set -euo pipefail

die() { echo "hypothesis-id-reserve: $1" >&2; exit 2; }

reservations=""
owner=""
first=0
at_least=""
at_least_given=0
scans=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reservations) [ "$#" -ge 2 ] || die "--reservations needs a directory"; reservations=$2; shift 2 ;;
    --owner) [ "$#" -ge 2 ] || die "--owner needs a token"; owner=$2; shift 2 ;;
    --scan) [ "$#" -ge 2 ] || die "--scan needs a file"; scans+=("$2"); shift 2 ;;
    --at-least) [ "$#" -ge 2 ] || die "--at-least needs a number"; at_least=$2; at_least_given=1; shift 2 ;;
    --first) first=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$reservations" ] || die "--reservations is required"
[ "${#scans[@]}" -gt 0 ] || die "at least one --scan store is required"
case "$owner" in
  "") die "--owner is required" ;;
  *[!A-Za-z0-9._-]*) die "--owner may hold only letters, digits, '.', '_' and '-'" ;;
esac

if [ "$at_least_given" -eq 1 ]; then
  case "$at_least" in
    "" | *[!0-9]* | 0* | ???????*) die "--at-least takes a whole number from 1 to 999999" ;;
  esac
fi

# highest_in <text on stdin> — the highest H<n> that stands as a whole word, or nothing.
# Six digits bounds the arithmetic; a longer run of digits is not an identifier this store mints.
highest_in() {
  tr -c 'A-Za-z0-9_' '\n' | awk '
    /^H[0-9]+$/ && length($0) <= 7 { n = substr($0, 2) + 0; if (n > max) max = n; seen = 1 }
    END { if (seen) print max }'
}

# headings_of <file> — its markdown heading lines. grep finding none is an answer, not a failure.
headings_of() {
  local rc=0
  grep -E '^#{1,6}[[:space:]]' "$1" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
}

max=0
found=0
for store in "${scans[@]}"; do
  [ -f "$store" ] && [ -r "$store" ] || die "cannot read the store: $store"
  n=$(headings_of "$store" | highest_in) || die "could not scan the store: $store"
  if [ -n "$n" ]; then
    found=1
    if [ "$n" -gt "$max" ]; then max=$n; fi
  fi
done

mkdir -p "$reservations" 2>/dev/null || die "cannot create the reservations directory: $reservations"
[ -d "$reservations" ] && [ -w "$reservations" ] || die "cannot write the reservations directory: $reservations"
listing=$(ls -1 "$reservations") || die "cannot list the reservations directory: $reservations"
n=$(printf '%s\n' "$listing" | highest_in) || die "could not scan the reservations directory"
if [ -n "$n" ]; then
  found=1
  if [ "$n" -gt "$max" ]; then max=$n; fi
fi

if [ "$at_least_given" -eq 1 ]; then
  found=1
  if [ "$at_least" -gt "$max" ]; then max=$at_least; fi
fi

if [ "$found" -eq 0 ] && [ "$first" -ne 1 ]; then
  die "no identifier found in any store heading or reservation; pass --at-least <n>, or --first only when this really is the first"
fi

# Take the first free number above the highest. A concurrent caller that wins a number makes this
# mkdir fail with the directory present, and the loop moves on; any other failure is UNKNOWN.
attempt=0
while [ "$attempt" -lt 100 ]; do
  attempt=$((attempt + 1))
  id="H$((max + attempt))"
  if mkdir "$reservations/$id" 2>/dev/null; then
    if ! printf '%s\n' "$owner" > "$reservations/$id/owner"; then
      die "reserved $id but could not record its owner; treat $id as taken and do not use it"
    fi
    printf '%s\n' "$id"
    exit 0
  fi
  [ -d "$reservations/$id" ] || die "could not create the reservation $reservations/$id"
done
die "no free identifier within 100 above H$max"
