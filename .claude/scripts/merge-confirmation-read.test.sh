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
#   4. NEGATIVE CONTROL: no `--json` field list in ANY definition surface contains a bare `merged`, so
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

# Scope the prose assertions to the MERGE POLICY SECTION, not the whole contract. Against the whole
# file each assertion passes as long as its phrase survives anywhere — an example, a telemetry note, an
# unrelated section — so a later edit could delete the instruction from its point of use while the job
# still reported the merge procedure guarded. Requiring the phrases to co-occur inside the section is
# what ties the guard to the place the rule has to be.
merge_policy="$(awk '
  /^### Merge policy/ { inside = 1; print; next }
  inside && /^### /   { exit }
  inside              { print }
' "${constitution}")"

# Fail closed if the section vanished or was renamed — otherwise every assertion below would be
# checking an empty string and would pass vacuously, which is this control's own failure mode.
[ "$(printf '%s' "${merge_policy}" | wc -c)" -gt 500 ] ||
  fail "could not locate a '### Merge policy' section in AGENTS.md — assertions would be vacuous"

# Markdown prose is hard-wrapped, so a guarded sentence routinely spans two lines and exists on NO
# single line. Flatten once and match substrings against the flattened copy.
merge_policy_flat="$(printf '%s' "${merge_policy}" | tr '\n' ' ' | tr -s '[:space:]' ' ')"

assert_prose() {
  case "${merge_policy_flat}" in
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
# Scope: EVERY definition surface that prescribes a `gh --json` call, not just the contract. Measured
# 2026-07-29: AGENTS.md carries 5 such prescriptions, `portfolio-surveyor.md` carries 10 and the
# run-loop skill 2 — so an AGENTS.md-only control would have guarded a third of the real surface while
# reading as full coverage.
#
# The sources are hard-wrapped prose, so a long field list can WRAP across a line break. Scanning the
# raw file would then see only the head of the list and miss a `merged` sitting on the continuation
# line — the guard would silently stop guarding exactly when lists get long enough to matter (probed:
# it did evade before this join). Rejoin a line ending in a comma with the next line first. Only that
# exact shape is joined, never every ", ", so prose following a list can never be read as a field.
# (Done in awk, not `tr`+`sed`: BSD sed does not honour a `\001` escape in the pattern, so the
# separator trick silently no-ops and the probe still evades. Verified by re-running the wrap arm.)
# DISCOVER the surfaces; never enumerate them. A hand-written list drifts the moment a definition file
# is added — the Cursor loader was already missing from one — and the drift is invisible because the
# control still reports success over the surfaces it does know about. Every Markdown file under
# `.claude/` plus the contract is the definition set by construction.
scan_surfaces="$(
  printf '%s\n' "${constitution}"
  find "${repo_root}/.claude" -type f -name '*.md' 2>/dev/null | sort
)"

offenders=""
scanned=0
while IFS= read -r surface; do
  [ -r "${surface}" ] || continue          # a surface may legitimately not exist in every checkout
  scanned=$((scanned + 1))
  rejoined="$(awk '
    { line = $0; sub(/^[[:space:]]+/, "", line); hold = hold line
      if (hold ~ /,$/) next               # list continues on the next line — keep accumulating
      print hold; hold = "" }
    END { if (hold != "") print hold }
  ' "${surface}")"

  while IFS= read -r list; do
    # strip the `--json ` prefix, then take the field list up to the first space/backtick/quote
    fields="${list#--json }"
    fields="${fields%%[\` \"]*}"
    case ",${fields}," in
      *,merged,*) offenders="${offenders}  ${surface#"${repo_root}/"}: --json ${fields}"$'\n' ;;
    esac
    # Normalise the separator before extracting. `gh` accepts BOTH `--json a,b` and `--json=a,b`
    # (verified against the live API), and prose may quote the list — so `--json=state,merged`,
    # `--json "state,merged"` and `--json='state,merged'` are all reachable prescriptions that a
    # space-only extractor lets through. Collapse `=`, surrounding whitespace and an opening quote
    # into the single space form first.
    # Also normalise the repository's ABBREVIATED form. `SKILL.md` writes
    # `--json …mergeStateStatus,reviewDecision,…`; an ellipsis is outside `[A-Za-z,]` so extraction
    # stopped dead at it and captured an EMPTY field list, leaving anything after the ellipsis
    # unchecked (probed: a `merged` placed there evaded). Turn the elision into a comma so parsing
    # continues through the rest of the fragment.
  done < <(printf '%s\n' "${rejoined}" \
    | sed -E -e 's/--json[[:space:]]*=?[[:space:]]*["'"'"']?/--json /g' \
             -e 's/…/,/g' -e 's/\.\.\./,/g' \
    | grep -o -- '--json [A-Za-z,]*' | sort -u)
done <<EOF
${scan_surfaces}
EOF

# A silently-small scan set would make this control vacuous — the exact failure it exists to prevent.
[ "${scanned}" -ge 5 ] ||
  fail "negative control scanned only ${scanned} surface(s); the definition surfaces are missing or moved"

if [ -n "${offenders}" ]; then
  printf 'merge-confirmation read: FAIL — an invalid `merged` field is prescribed:\n%s' "${offenders}" >&2
  echo "  \`merged\` exists on none of gh pr view / gh pr list / gh search prs, and one unknown" >&2
  echo "  field voids the WHOLE request — use state / mergedAt / mergeCommit instead." >&2
  exit 1
fi

echo "merge-confirmation read: OK — post-merge read prescribed; no invalid \`merged\` field across ${scanned} definition surfaces"
