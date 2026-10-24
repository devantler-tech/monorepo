#!/usr/bin/env bash
#
# Guards the Claude lane's weekly pacing rule (monorepo#3623, monorepo#4116).
#
# Why this needs a guard. The Claude lane ran out of its shared weekly allowance before the reset in
# every week from 2026-09-12 to 2026-10-24; in the first week with two engineer entries it ran out
# after 5.3 days and 92 scheduled dispatches did no work. The cadence guide already said "a cap
# reached early is evidence to lower that lane's cadence", but no run read its usage, so nothing
# lowered it. The pacing rule is that missing read. It only works if the run that should yield finds
# it at the surface it always loads, so this test pins both halves:
#
#   1. AGENTS.md's every-run list names the read for `agentic-engineer-2` and links the guide section;
#   2. the guide section names the tool, the window, the threshold, the paced and UNKNOWN outcomes,
#      and keeps `daily-ai-assistant` unpaced, so rung 0 keeps an hourly run.
#
# Assertions are scoped to their section and fail closed when an anchor is missing: an empty
# extraction would satisfy every substring check.
#
# The needles are literal Markdown, backticks included, so they are single-quoted on purpose.
# shellcheck disable=SC2016

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agents="${repo_root}/AGENTS.md"
guide="${repo_root}/.claude/guides/cadence.md"

fail() {
  echo "weekly-pacing contract: FAIL — $*" >&2
  exit 1
}

# An unreadable input is UNKNOWN, not a contract finding (exit 2, per this directory's AGENTS.md).
unknown() {
  echo "weekly-pacing contract: UNKNOWN — $*" >&2
  exit 2
}

[ -r "${agents}" ] || unknown "cannot read ${agents}"
[ -r "${guide}" ] || unknown "cannot read ${guide}"

sentinel='@@END-ANCHOR-SEEN@@'

# extract <file> <start-regex> <end-regex>: the lines from the start anchor up to (not including) the
# end anchor, flattened to one line, with the sentinel appended only when the end anchor was seen.
extract() {
  awk -v s="${sentinel}" -v a="$2" -v b="$3" '
    !ins && $0 ~ a { ins = 1; print; next }
    ins && $0 ~ b  { print s; exit }
    ins            { print }
  ' "$1" | tr '\n' ' ' | tr -s ' '
}

# --- 1. AGENTS.md every-run list -------------------------------------------------------------------
run_list="$(extract "${agents}" 'Never edit a plugin cache[.] Every run:$' '^Read the [[]definition guide[]]')"
case "${run_list}" in *"${sentinel}"*) ;; *) fail "AGENTS.md every-run list: end anchor not found" ;; esac
[ "${#run_list}" -gt 200 ] || fail "AGENTS.md every-run list: extraction too short (${#run_list} B)"

for needle in \
  'A Claude `agentic-engineer-2` run first reads `get_usage` and ends when ahead of the week' \
  '(.claude/guides/cadence.md#weekly-pacing-claude-lane)'; do
  case "${run_list}" in *"${needle}"*) ;; *) fail "AGENTS.md every-run list lacks: ${needle}" ;; esac
done

# The read must come before the other every-run steps, or a paced run would already have spent them.
first_bullet="$(awk '/Never edit a plugin cache\. Every run:$/ { f = 1; next } f && /^- / { print; exit }' "${agents}")"
case "${first_bullet}" in
  '- A Claude `agentic-engineer-2` run first reads `get_usage`'*) ;;
  *) fail "the pacing read is not the first every-run bullet (first is: ${first_bullet})" ;;
esac

# --- 2. The guide section -------------------------------------------------------------------------
section="$(extract "${guide}" '^### Weekly pacing [(]Claude lane[)]$' '^### ')"
case "${section}" in *"${sentinel}"*) ;; *) fail "cadence guide: '### Weekly pacing (Claude lane)' section or its end not found" ;; esac
[ "${#section}" -gt 400 ] || fail "cadence guide: pacing section too short (${#section} B)"

for needle in \
  '**Every `agentic-engineer-2` run reads the weekly usage before anything else.**' \
  '`mcp__ccd_session_mgmt__get_usage` through ToolSearch' \
  '`Weekly · all models`' \
  '`percentUsed` and `resetsAt`' \
  '`100 × (7 days − (resetsAt − now)) / 7 days`' \
  '`percentUsed` is more than 5 points above the elapsed share' \
  '`weekly_pace=paced used=<percentUsed> elapsed=<share>`' \
  '`weekly_pace=normal used=<percentUsed> elapsed=<share>`' \
  '**A plan status other than `ok`, a missing window or a failed call** is UNKNOWN' \
  '`weekly_pace=UNKNOWN`, and run as usual' \
  'An unreadable reading never pauses the lane.' \
  '`daily-ai-assistant` is never paced'; do
  case "${section}" in *"${needle}"*) ;; *) fail "cadence guide pacing section lacks: ${needle}" ;; esac
done

# The allowance passage must point at the section, so "lower that lane's cadence" has its mechanism.
allowance="$(extract "${guide}" '^Both machine-local Agentic Engineer lanes are [*][*]scheduled[*][*]' '^### Weekly pacing')"
case "${allowance}" in *"${sentinel}"*) ;; *) fail "cadence guide: allowance passage or its end not found" ;; esac
case "${allowance}" in
  *'On Claude, [weekly pacing](#weekly-pacing-claude-lane) lowers the cadence while usage runs ahead of the week.'*) ;;
  *) fail "cadence guide allowance passage does not point at weekly pacing" ;;
esac

# Negative control: the same extraction must miss the section once it is removed from the guide, so
# a passing run above means the section was found, not that extract() matches anything.
control="$(awk '/^### Weekly pacing [(]Claude lane[)]$/ { skip = 1; next } skip && /^### / { skip = 0 } !skip' "${guide}" \
  | extract - '^### Weekly pacing [(]Claude lane[)]$' '^### ')"
case "${control}" in
  *"${sentinel}"*) fail "negative control: extraction still found the section after removing it" ;;
esac

echo "weekly-pacing contract: PASS"
