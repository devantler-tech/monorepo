#!/usr/bin/env bash
#
# Guards the POST-merge confirmation read in Merge policy.
#
# Why this needs enforcing rather than merely being correct once: `Merge policy` prescribed the
# PRE-merge evidence read but named nothing for the read immediately AFTER `gh pr merge`. Unprescribed,
# runs improvised the field the mental model suggests — `merged` — which exists on none of
# `gh pr view`, `gh pr list`, `gh search prs`. And the cost is not one missing value: `gh` rejects the
# ENTIRE `--json` request when any single field is unknown, so the common
# `state,merged,mergedAt,mergeCommit` set returns *nothing* and the run cannot tell whether its own
# merge landed — blind at the top of the work-selection ladder.
#
# Measured 2026-07-29 over monorepo sessions, counted by DISTINCT SESSIONS (an occurrence count is not
# a frequency): `Unknown JSON field: "merged"` in 23/204 sessions (11.3%) after 2026-07-27T10:23Z, up
# from 8/211 (3.8%) before it. Normalised against own PRs merged in each window (250 pre / 205 post)
# the rate still rises 0.032 -> 0.112 per merge (~3.5x), so it is not a base-rate artifact of the
# densified cadence.
#
# Guarded properties:
#   1. Merge policy names the post-merge confirmation read, with a vocabulary that actually works;
#   2. it states that `merged` is not a field — the specific improvisation measured;
#   3. it states the all-or-nothing property of `--json`, at the point of use;
#   4. NEGATIVE CONTROL: no `--json` field list anywhere in the contract contains a bare `merged`, so
#      the invalid field cannot be reintroduced by a later edit. This is the assertion with teeth —
#      (1)-(3) can be satisfied by prose, (4) constrains every future prescription.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "merge-confirmation read: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Markdown prose is hard-wrapped, so a guarded sentence routinely spans two lines and exists on NO
# single line. Flatten once and match substrings against the flattened copy.
constitution_flat="$(tr '\n' ' ' < "${constitution}" | tr -s '[:space:]' ' ')"

assert_prose() {
  case "${constitution_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

# ── 1. the post-merge confirmation read is named, with a working vocabulary ──
assert_prose 'Confirming the merge landed' \
  "Merge policy does not name the post-merge confirmation read — the unprescribed step runs improvise"
assert_prose '--json state,mergedAt' \
  "Merge policy does not prescribe a valid post-merge read (state,mergedAt)"

# ── 2. the specific improvisation is named as invalid ──
assert_prose 'there is NO `merged` field' \
  "Merge policy does not state that \`merged\` is not a field — the measured improvisation"

# ── 3. the all-or-nothing property is stated at the point of use ──
assert_prose 'rejects the **whole** `--json` request when any single field is unknown' \
  "Merge policy does not state that one unknown field voids the entire --json read"

# ── 4. NEGATIVE CONTROL — no --json list in the contract may contain a bare `merged` ───────────────
# Word-boundary matters here: `mergedAt`, `mergedBy` and `mergeCommit` are all VALID and must not be
# flagged. Splitting each prescribed list on commas and comparing whole elements is what keeps this
# from becoming a substring check that either misses the defect or condemns the fix.
#
# The contract is hard-wrapped prose, so a long field list can WRAP across a line break. Scanning the
# raw file would then see only the head of the list and miss a `merged` sitting on the continuation
# line — the guard would silently stop guarding exactly when lists get long enough to matter (probed:
# it did evade before this join). Rejoin a line ending in a comma with the next line first. Only that
# exact shape is joined, never every ", ", so prose following a list can never be read as a field.
# (Done in awk, not `tr`+`sed`: BSD sed does not honour a `\001` escape in the pattern, so the
# separator trick silently no-ops and the probe still evades. Verified by re-running the wrap arm.)
rejoined="$(awk '
  { line = $0; sub(/^[[:space:]]+/, "", line); hold = hold line
    if (hold ~ /,$/) next                 # list continues on the next line — keep accumulating
    print hold; hold = "" }
  END { if (hold != "") print hold }
' "${constitution}")"

offenders=""
while IFS= read -r list; do
  # strip the `--json ` prefix, then take the field list up to the first space/backtick/quote
  fields="${list#--json }"
  fields="${fields%%[\` \"]*}"
  case ",${fields}," in
    *,merged,*) offenders="${offenders}  --json ${fields}"$'\n' ;;
  esac
done < <(printf '%s\n' "${rejoined}" | grep -o -- '--json [A-Za-z,]*' | sort -u)

if [ -n "${offenders}" ]; then
  printf 'merge-confirmation read: FAIL — contract prescribes an invalid `merged` field:\n%s' "${offenders}" >&2
  echo "  \`merged\` exists on none of gh pr view / gh pr list / gh search prs, and one unknown" >&2
  echo "  field voids the WHOLE request — use state / mergedAt / mergeCommit instead." >&2
  exit 1
fi

echo "merge-confirmation read: OK — post-merge read prescribed, no invalid \`merged\` field in any --json list"
