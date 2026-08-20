#!/usr/bin/env bash
#
# Guards the PRE-merge read in Merge policy against a blocker class its field list cannot observe.
#
# Why this needs enforcing rather than merely being correct once: `required_review_thread_resolution`
# is `true` on ALL NINETEEN portfolio repositories (2026-08-20: monorepo, platform, ksail,
# world-at-ruin, actions, agent-skills, agent-plugins, kyverno-policies, homebrew-tap, dotnet-template,
# go-template, platform-template, platform-tenant-template, provider-upjet-unifi, unifi, wedding-app,
# ascoachingogvaner, doggy-countdown, .github) — every repo in the Portfolio map, no exception — so an
# unresolved review thread blocks a merge exactly like a failing required check.
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
# The survey pentad DOES carry unresolved threads, so the gap is not that no thread check exists — it
# is that thread state comes only from a SNAPSHOT taken earlier in the run, while the fresh pre-merge
# read (which exists precisely for state that moves after that snapshot, and re-validates `title` for
# exactly that reason) omits it. Every review lane re-reviews on each push and can post at any moment:
# on #2927 the blocking review landed at 07:32:06Z, 93 minutes after `ready_for_review`. So a
# survey-time zero is not evidence at merge time, and the final read cannot supply one.
#
# Guarded properties:
#   1. the mechanism is named, so a reader can verify the rule themselves;
#   2. a WORKING vocabulary for the thread read is prescribed — GraphQL (see 5), and PAGINATED: a
#      first-page-only `reviewThreads(first:100)` under-counts a PR with >100 threads, so the gate's
#      single number can read 0 while unresolved threads remain;
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
assert_prose 'reviewThreads(first:100,after:$endCursor)' \
  "Merge policy does not prescribe the paginated GraphQL reviewThreads read for pre-merge thread state"
assert_prose 'isResolved==false' \
  "Merge policy does not prescribe selecting UNRESOLVED threads — a bare thread count is not the gate"
# PAGINATION is part of the working vocabulary, not tidiness: `reviewThreads(first:100)` alone returns
# one page, so a PR with >100 threads reports a PARTIAL count and this gate's single number can read 0
# while unresolved threads remain — the same "authoritative-looking but wrong read" the rule exists to
# prevent. Require both the cursor plumbing and the page-walk.
assert_prose 'pageInfo{hasNextPage endCursor}' \
  "Merge policy prescribes a thread read without the pageInfo cursor — a first-page-only count"
assert_prose 'gh api graphql --paginate' \
  "Merge policy prescribes a thread read that does not walk every page"
# FAIL-CLOSED is part of the vocabulary too. Without `pipefail` the prescribed pipeline prints the
# ALL-CLEAR value on a broken read: `false | jq -s '[.[]]|length'` emits 0 and exits 0 (reproduced), so
# an auth/network/API failure would satisfy the gate hardest exactly when it can see least.
assert_prose 'set -o pipefail' \
  "Merge policy prescribes a thread read whose pipeline can print 0 from a FAILED read"
assert_prose 'UNKNOWN, never as zero' \
  "Merge policy does not say a failed thread read is UNKNOWN rather than zero"
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
    *.json) jq -r '.. | strings | ., "%"' "$1" ;;
    *)      cat "$1" ;;
  esac
}

normalise_and_extract() {           # $1 = file; emits one `--json <fields>` per line
  # ONE canonicalisation, not a rule per formatting. Code delimiters are NOT flattened: a backtick or
  # quote must TERMINATE a field list, or Markdown prose following an inline command joins across a
  # comma into a false positive. A comma is joined to what follows ONLY across a line break — that is
  # the one place a real field list is ever split. Whitespace AROUND COMMAS is collapsed last: the
  # extractor ends at any character outside `[A-Za-z,]`, so `--json "number, reviewThreads"` would
  # otherwise yield `--json number,` and the thread field would escape the control entirely. Collapsing
  # after the delimiter strip keeps the quote/backtick terminator intact, so prose that merely follows
  # an inline command across a comma still cannot join into a false positive.
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
             -e 's/[[:space:]]*,[[:space:]]*/,/g' \
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
spaced-after: gh pr view 1 --json "author, reviewThreads"
spaced-before: gh pr view 1 --json "mergedAt ,isResolved"
FIXTURE

cat > "${self_test_dir}/good.md" <<'FIXTURE'
the prescribed preflight: --json number,isDraft,author,title,headRefOid,mergeStateStatus,statusCheckRollup
the post-merge read: --json state,mergedAt
prose after a command: `--json comments`, reviewThreads are read over GraphQL instead
graphql is not a --json list: reviewThreads(first:100){nodes{isResolved}}
FIXTURE

bad_found="$(bad_lists_in "${self_test_dir}/bad.md" | grep -c . || true)"
[ "${bad_found}" -eq 7 ] ||
  fail "extractor self-test: caught ${bad_found}/7 planted bad forms — the control would scan vacuously"

good_found="$(bad_lists_in "${self_test_dir}/good.md" | grep -c . || true)"
[ "${good_found}" -eq 0 ] ||
  fail "extractor self-test: flagged ${good_found} VALID form(s) — the control would condemn correct content"

# ── 5b. scan the real definition surfaces ───────────────────────────────────────────────────────────
#
# The PINNED plugin definitions are consumed definition surfaces too — AGENTS.md classifies the
# plugin-authored agent files as version-controlled definition surfaces, and every run loads its role
# from them. Scanning only `AGENTS.md` and `.claude` leaves a gitlink advance free to reintroduce the
# exact blind spot this guard exists to close, with the guard still green.
#
# FAIL, never skip, when they are absent. `find` on a missing directory prints nothing and exits
# quietly, so an unpopulated submodule would make this addition a silent no-op — the vacuity the whole
# file is written against. The message names the fix, so the failure is actionable rather than a wall.
plugin_defs="${repo_root}/libraries/agent-plugins/plugins/agentic-engineering"
[ -d "${plugin_defs}" ] && [ -n "$(find "${plugin_defs}" -type f -name '*.md' 2>/dev/null | head -1)" ] ||
  fail "pinned plugin definitions are absent at ${plugin_defs}, so they cannot be scanned and an OK here would be vacuous
  populate them:  git -c 'url.https://github.com/.insteadOf=git@github.com:' submodule update --init libraries/agent-plugins"

offenders=""
scanned=0
while IFS= read -r surface; do
  [ -r "${surface}" ] || continue
  scanned=$((scanned + 1))
  # VALIDATE a JSON surface HERE, in the MAIN shell, before it is scanned. `bad_lists_in` reads its
  # input through process substitution (`< <(...)`), whose failure `set -e` does NOT catch — so a
  # `fail` inside the extraction chain leaves the loop with empty output and exit 0, and the surface is
  # counted as scanned while nothing was inspected. Reproduced: a malformed `.json` planted under
  # `.claude/` raised `scanned` from 28 to 29 and the control still reported OK. Validating in the main
  # shell is what makes the failure actually abort.
  case "${surface}" in
    *.json) jq empty "${surface}" >/dev/null 2>&1 ||
      fail "cannot decode JSON definition surface, so it cannot be scanned: ${surface}" ;;
  esac
  found="$(bad_lists_in "${surface}")"
  [ -n "${found}" ] && offenders="${offenders}${surface}:"$'\n'"${found}"
done < <(
  {
    printf '%s\n' "${constitution}"
    find "${repo_root}/.claude" -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null
    find "${plugin_defs}" -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null
  } | sort -u
)

[ "${scanned}" -gt 5 ] ||
  fail "only ${scanned} definition surface(s) discovered — the negative control would be vacuous"

if [ -n "${offenders}" ]; then
  printf 'merge-preflight thread gate: FAIL — a thread field is prescribed in a `gh pr view --json` list.\n' >&2
  printf '`--json` is all-or-nothing, so this voids the ENTIRE merge-evidence read:\n%s' "${offenders}" >&2
  exit 1
fi

ASSERTED=$(grep -c '^assert_prose ' "${BASH_SOURCE[0]}")
echo "merge-preflight thread gate: OK — ${ASSERTED} prose properties held; negative control scanned ${scanned} surfaces."

# ── 6. THIS JOB'S OWN CI WIRING — five edits, and a job can ship with four ──────────────────────────
#
# Wiring a contract test into `ci.yaml` takes FIVE edits. Drop the `changes` output and
# `needs.changes.outputs.…` is empty, so the `if:` never matches and the job SKIPS SILENTLY. Drop it
# from the `status` job's `needs:`/`job-results:` and it runs and prints OK while its failures no
# longer gate the required check. In every one of those cases this script still exits 0 — it cannot
# detect its own disconnection unless it looks. `merge-confirmation-read.test.sh` guards the identical
# five-point mode for the same reason; this is that pattern, not a new idea.
workflow="${repo_root}/.github/workflows/ci.yaml"
# FAIL, never skip: `ci.yaml` is a fixed path, so guarding these with `if [ -r … ]` would turn a
# missing workflow into a silent pass — the exact vacuity this file exists to prevent.
[ -r "${workflow}" ] ||
  fail "ci.yaml is missing or unreadable at ${workflow} — this job's own wiring cannot be verified, so an OK here would be vacuous"

for spec in \
  '            merge-preflight-thread-gate:|paths-filter entry' \
  '      merge-preflight-thread-gate: ${{ steps.filter.outputs.merge-preflight-thread-gate }}|changes-job outputs declaration (its absence makes the job skip silently)' \
  '  test-merge-preflight-thread-gate:|job definition' \
  '      - test-merge-preflight-thread-gate|status job needs: entry (its absence stops the job gating the merge)' \
  '            ${{ needs.test-merge-preflight-thread-gate.result }}|status job job-results entry'; do
  line="${spec%%|*}"; what="${spec#*|}"
  grep -qxF -- "${line}" "${workflow}" ||
    fail "ci.yaml is missing this job's ${what} — the guard would not gate"
done

# The scan of the pinned plugin definitions only happens if CI populates that submodule. Without the
# init step the job fails closed rather than passing vacuously, but it fails on EVERY run — so assert
# the step is wired, and the failure names the cause instead of leaving a red job to be diagnosed.
#
# SCOPED TO THIS JOB'S BLOCK, deliberately. A whole-file grep is vacuous here: the delivery-contract
# job carries the identical init line, so the assertion would pass with this job's step deleted — and
# it passed against the revision that predates this step entirely. Slice the block, then look inside it.
job_block=$(awk '/^  test-merge-preflight-thread-gate:$/{f=1;next} f&&/^  [a-z]/{exit} f' "${workflow}")
[ -n "${job_block}" ] ||
  fail "could not locate the test-merge-preflight-thread-gate job block in ci.yaml — its wiring cannot be verified"
printf '%s\n' "${job_block}" | grep -qF -- 'submodule update --init libraries/agent-plugins' ||
  fail "this job does not initialise libraries/agent-plugins — the pinned plugin definitions could not be scanned"

# The filter must cover every surface the scan discovers, or an edit to an unlisted one skips the job.
for trigger in \
  "              - 'AGENTS.md'" \
  "              - '.claude/**/*.md'" \
  "              - '.claude/**/*.json'" \
  "              - '.claude/scripts/merge-preflight-thread-gate.test.sh'" \
  "              - 'libraries/agent-plugins'" \
  "              - '.gitmodules'" \
  "              - '.github/workflows/ci.yaml'"; do
  grep -qxF -- "${trigger}" "${workflow}" ||
    fail "ci.yaml filter is missing ${trigger# *} — an edit there would not run this guard"
done
