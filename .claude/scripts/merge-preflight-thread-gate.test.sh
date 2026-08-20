#!/usr/bin/env bash
#
# Guards the PRE-merge read in Merge policy against a blocker class its field list cannot observe.
#
# Why this needs enforcing rather than merely being correct once: `required_review_thread_resolution`
# is `true` on ALL ELEVEN portfolio repositories checked (2026-08-20: monorepo, platform, ksail,
# world-at-ruin, actions, agent-skills, agent-plugins, kyverno-policies, homebrew-tap, dotnet-template,
# go-template), so an unresolved review thread blocks a merge exactly like a failing required check.
# But NO `gh pr view --json` field carries thread-resolution state, so the prescribed preflight
# — number,isDraft,author,title,headRefOid,mergeStateStatus,statusCheckRollup — is structurally blind
# to it, and `mergeStateStatus` reports it only as a bare `BLOCKED`.
#
# That produces the exact signature documented exception (a) tells a run to DISMISS as staleness:
# `BLOCKED` while every check-run and status on the head is `success`/`skipped`. Measured live on
# monorepo#2927 at head cc7ac05b (2026-08-20): mergeable MERGEABLE, mergeStateStatus BLOCKED, 0 failing
# checks, 0 open code-scanning alerts repo-wide (unfiltered control), no CHANGES_REQUESTED — and 2
# unresolved `coderabbitai` threads. Promoted 05:59:20Z, still unmerged hours later.
#
# The pentad's zero-unresolved-threads item is evaluated BEFORE promotion, and every review lane
# re-reviews on each push, so a thread routinely arrives AFTER a PR is promoted (on #2927 the blocking
# review landed at 07:32:06Z, 93 minutes after `ready_for_review`). The final pre-merge read is the only
# gate left that could catch it, and it cannot.
#
# Guarded properties:
#   1. the mechanism is named, so a reader can verify the rule themselves;
#   2. a WORKING vocabulary for the thread read is prescribed (GraphQL — see 4);
#   3. exception (a) cannot swallow this class: unresolved threads are a real blocker, not staleness;
#   4. a merge refusal is DIAGNOSED before it is escalated as a maintainer blocker;
#   5. NEGATIVE CONTROL: no `gh pr view --json` list in ANY definition surface names a thread field.
#      `reviewThreads` is NOT a valid `gh pr view --json` field (verified against the live CLI), and
#      `--json` is all-or-nothing, so "helpfully" adding it to the preflight would void the ENTIRE
#      merge-evidence read — blinding the gate completely. This is the assertion with teeth: (1)-(4)
#      are prose and can be satisfied by wording, (5) constrains every future prescription.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "merge-preflight thread gate: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Scope prose assertions to the MERGE POLICY SECTION. Against the whole file each phrase passes as long
# as it survives anywhere — an example, a telemetry note — so a later edit could delete the instruction
# from its point of use while this job still reported the merge procedure guarded.
merge_policy="$(awk '
  /^### Merge policy/ { inside = 1; print; next }
  inside && /^### /   { exit }
  inside              { print }
' "${constitution}")"

# Fail closed if the section vanished or was renamed — otherwise every assertion below checks an empty
# string and passes vacuously, which is this control's own failure mode.
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

# ── 1. the mechanism is named ───────────────────────────────────────────────────────────────────────
assert_prose 'required_review_thread_resolution' \
  "Merge policy does not name the ruleset parameter that makes an unresolved thread block a merge"

# ── 2. a WORKING vocabulary is prescribed ───────────────────────────────────────────────────────────
# Assert the GraphQL shape, not a bare mention of threads: the whole lesson of the post-merge `merged`
# field is that an unprescribed read gets improvised into an invalid one.
assert_prose 'reviewThreads(first:100)' \
  "Merge policy does not prescribe the GraphQL reviewThreads read for pre-merge thread state"
assert_prose 'isResolved==false' \
  "Merge policy does not prescribe selecting UNRESOLVED threads — a bare thread count is not the gate"
# The invalid improvisation is named explicitly, exactly as `merged` is for the post-merge read.
assert_prose '`reviewThreads` is NOT a valid `gh pr view --json` field' \
  "Merge policy does not state that reviewThreads is not a gh pr view --json field"

# ── 3. exception (a) cannot swallow this class ──────────────────────────────────────────────────────
assert_prose 'real blocker, never staleness' \
  "Merge policy does not exclude unresolved threads from the BLOCKED-is-stale carve-out"

# ── 4. a refusal is diagnosed before it is escalated ────────────────────────────────────────────────
assert_prose 'DIAGNOSE the refusal before escalating' \
  "Merge policy does not require diagnosing a merge refusal before surfacing it to the maintainer"

# ── 5. NEGATIVE CONTROL — no `gh pr view --json` list may name a thread field ────────────────────────
#
# DISCOVER surfaces; never enumerate. A hand-written list drifts the moment a definition file is added,
# and the drift is invisible because the control still reports success over the surfaces it knows.
decode_surface() {
  case "$1" in
    # A scalar boundary is a HARD boundary: `jq -r '.. | strings'` emits one line per decoded value and
    # flattening would otherwise weld the end of one value onto the start of the next. `%` is outside
    # `[A-Za-z,]`, so it terminates a field list wherever it lands.
    *.json) jq -r '.. | strings | ., "%"' "$1" 2>/dev/null || true ;;
    *)      cat "$1" ;;
  esac
}

normalise_and_extract() {           # $1 = file; emits one `--json <fields>` per line
  # ONE canonicalisation, not a rule per formatting. Code delimiters are NOT flattened: a backtick or
  # quote must TERMINATE a field list, or Markdown prose following an inline command joins across a
  # comma into a false positive. A comma is joined to what follows ONLY across a line break — that is
  # the one place a real field list is ever split.
  decode_surface "$1" \
    | sed -E -e 's/\\[nrt]/ /g' -e 's/\\/ /g' \
    | awk '{
        line = $0; sub(/[[:space:]]+$/, "", line)
        if (NR > 1 && buf ~ /,$/) { sub(/^[[:space:]]+/, "", line); buf = buf line }
        else { if (NR > 1) print buf; buf = line }
      } END { if (NR > 0) print buf }' \
    | tr '\n' ' ' \
    | sed -E -e 's/…/,/g' -e 's/\.\.\./,/g' \
             -e 's/[[:space:]]+/ /g' \
             -e 's/--json[[:space:]]*[=,]*[[:space:]]*[`"'"'"']?[[:space:]]*/--json /g' \
    | grep -o -- '--json [A-Za-z,]*' | sort -u
}

# Report every `--json` list in $1 that names a thread field. Whole-element comparison, not substring:
# a future valid field could legitimately contain these as a prefix.
bad_lists_in() {
  local list fields out=""
  while IFS= read -r list; do
    fields="${list#--json }"
    fields="${fields%%[\` \"]*}"
    case ",${fields}," in
      *,reviewThreads,*|*,isResolved,*) out="${out}--json ${fields}"$'\n' ;;
    esac
  done < <(normalise_and_extract "$1")
  printf '%s' "${out}"
}

# ── 5a. SELF-TEST THE EXTRACTOR FIRST — otherwise this whole control is vacuous ─────────────────────
# `scanned` counts readable FILES, not successfully parsed field lists. If the extraction pattern ever
# stops matching, every surface yields nothing, no offender is found, and the control prints OK over
# every surface while detecting nothing at all. So exercise it against fixtures before trusting it.
self_test_dir="$(mktemp -d)"
trap 'rm -rf "${self_test_dir}"' EXIT

# Each BAD form pairs the offending field with a DIFFERENT valid field on purpose: the extractor ends in
# `sort -u`, so fixtures normalising to the same string would collapse and under-report detection.
cat > "${self_test_dir}/bad.md" <<'FIXTURE'
plain: gh pr view 1 --json number,reviewThreads
equals: gh pr view 1 --json=isDraft,reviewThreads
quoted: gh pr view 1 --json "title,reviewThreads"
wrapped: gh pr view 1 --json headRefOid,
  reviewThreads
elided: gh pr view 1 --json …,isResolved
FIXTURE

cat > "${self_test_dir}/good.md" <<'FIXTURE'
the prescribed preflight: --json number,isDraft,author,title,headRefOid,mergeStateStatus,statusCheckRollup
the post-merge read: --json state,mergedAt
prose after a command: `--json comments`, reviewThreads are read over GraphQL instead
graphql is not a --json list: reviewThreads(first:100){nodes{isResolved}}
FIXTURE

bad_found="$(bad_lists_in "${self_test_dir}/bad.md" | grep -c . || true)"
[ "${bad_found}" -eq 5 ] ||
  fail "extractor self-test: caught ${bad_found}/5 planted bad forms — the control would scan vacuously"

good_found="$(bad_lists_in "${self_test_dir}/good.md" | grep -c . || true)"
[ "${good_found}" -eq 0 ] ||
  fail "extractor self-test: flagged ${good_found} VALID form(s) — the control would condemn correct content"

# ── 5b. scan the real definition surfaces ───────────────────────────────────────────────────────────
offenders=""
scanned=0
while IFS= read -r surface; do
  [ -r "${surface}" ] || continue
  scanned=$((scanned + 1))
  found="$(bad_lists_in "${surface}")"
  [ -n "${found}" ] && offenders="${offenders}${surface}:"$'\n'"${found}"
done < <(
  {
    printf '%s\n' "${constitution}"
    find "${repo_root}/.claude" -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null
  } | sort -u
)

[ "${scanned}" -gt 5 ] ||
  fail "only ${scanned} definition surface(s) discovered — the negative control would be vacuous"

if [ -n "${offenders}" ]; then
  printf 'merge-preflight thread gate: FAIL — a thread field is prescribed in a `gh pr view --json` list.\n' >&2
  printf '`--json` is all-or-nothing, so this voids the ENTIRE merge-evidence read:\n%s' "${offenders}" >&2
  exit 1
fi

echo "merge-preflight thread gate: OK — 5 properties held; negative control scanned ${scanned} surfaces."
