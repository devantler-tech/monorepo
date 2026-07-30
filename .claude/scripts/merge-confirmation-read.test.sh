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
# `mergeCommit` is part of the valid-field contract too — pin it, or the optional-field guidance could
# be dropped from the prose while every other assertion still passed.
#
# Assert the GUIDANCE, not the bare token. `mergeCommit` also occurs in the counter-example
# (`state,merged,mergedAt,mergeCommit`, the set being warned against), so a bare-token check is
# satisfied by the warning alone and would pass with the actual guidance deleted — verified by ablation.
assert_prose 'adding `mergedAt` or `mergeCommit` only when you need the timestamp or the squash sha' \
  "Merge policy does not give the mergeCommit/mergedAt optional-field guidance"
# The prescription must be a COMPLETE command, not a bare field list: field vocabularies are
# per-subcommand, so `gh search prs` rejects `mergedAt` and a loose field list can be misapplied.
assert_prose 'gh pr view <n> --repo devantler-tech/<repo> --json state,mergedAt' \
  "Merge policy prescribes a bare field list rather than the whole post-merge command"

# ── 2. the specific improvisation is named as invalid ──
assert_prose 'there is NO `merged` field' \
  "Merge policy does not state that \`merged\` is not a field — the measured improvisation"

# ── 3. the all-or-nothing property is stated at the point of use ──
assert_prose 'rejects the **whole** `--json` request when any single field is unknown' \
  "Merge policy does not state that one unknown field voids the entire --json read"

# ── 4. NEGATIVE CONTROL — no --json list in any definition surface may name a bare `merged` ─────────
#
# Word boundaries matter: `mergedAt`, `mergedBy` and `mergeCommit` are all VALID. Splitting each list on
# commas and comparing whole elements is what keeps this from being a substring check that either misses
# the defect or condemns the fix.
#
# DISCOVER surfaces; never enumerate. A hand-written list drifts the moment a definition file is added
# (the Cursor loader was already missing from one), and the drift is invisible because the control still
# reports success over the surfaces it does know about.
#
# NORMALISE before extracting. Four real formattings defeat a naive scan, each probed and confirmed:
#   * a hard WRAPPED list — only the head is seen (comma-continuation);
#   * a shell CONTINUATION — `--json \` then the fields on the next line, which has no `--json` prefix;
#   * the `=` and quoted argument forms — `gh` accepts `--json=a,b` (verified against the live API);
#   * the repository's ABBREVIATED form — `--json …mergeStateStatus,…`, where the ellipsis is outside
#     `[A-Za-z,]` so extraction stops dead and captures an EMPTY list.
# (The join is awk, not `tr`+`sed`: BSD sed ignores a `\001` escape, so that repair silently no-opped
# and the probe still evaded.)
normalise_and_extract() {           # $1 = file; emits one `--json <fields>` per line
  # ONE canonicalisation, not a rule per formatting. Eight distinct formattings were found evading a
  # shape-by-shape extractor on this PR — plain, `=`, quoted, wrapped after a comma, backslash
  # continuation, ellipsis elision, wrapped immediately after the flag, and a JSON `\n` escape — and
  # each patch only revealed the next one. Chasing shapes does not converge; canonicalising does.
  #
  # Code delimiters are NOT flattened: a backtick or quote must TERMINATE a field list, because
  # Markdown routinely follows an inline command with comma-led prose — ``--json comments`, merged PRs
  # …`` flattened to a space then collapsed across the comma yields `--json comments,merged`, a FALSE
  # POSITIVE on correct content (measured). An opening quote is absorbed only where it directly follows
  # `--json`, so the quoted argument form still parses.
  #
  # So flatten everything that can separate `--json` from its field list into a single space, then read
  # the fields. Order matters: comma/space collapse must precede the `--json` separator rule, or an
  # elision leaves `--json,field` and the extractor misses it (measured — it read 7/8 until reordered).
  # A JSON surface is DECODED with jq, never pattern-matched. Erasing `\uXXXX` is the wrong operation:
  # `\u006d` IS the letter `m`, so `--json state,\u006derged` decodes to `state,merged` and erasing the
  # escape hides exactly the field being looked for. Any escape form is handled correctly by decoding and
  # by nothing else, so `jq -r '.. | strings'` emits every decoded string value and the text pipeline runs
  # over those. Fails closed when jq cannot parse the file, rather than silently scanning it raw.
  # A comma is joined to what follows it ONLY across a line break. That is the one place a real field
  # list is ever split — `--json state,` then the rest on the next line — whereas a comma followed by a
  # space on the SAME line is prose, and `gh` could not receive it as one argument anyway. Collapsing
  # both alike is what made `--json state, merged PRs need no polling.` read as `--json state,merged`
  # and fail a VALID string. Markdown was already safe here because a backtick terminates the list; a
  # JSON surface has no delimiter to lean on, so the distinction has to be made from the line break
  # itself — which means joining BEFORE the whole file is flattened, not after.
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

# Emit a surface as plain text. A JSON surface is DECODED rather than pattern-matched, and the decoded
# text is PIPED rather than parked in a temp file: `normalise_and_extract` runs once per surface per
# scan, so a per-call `mktemp` that the single EXIT trap never removed left a scratch file holding
# decoded definition text behind on every run.
#
# NOTE: no `fail` here — this runs inside command substitution, so an `exit` would only leave the
# subshell and the script would carry on with an empty result (verified: a malformed JSON surface
# produced exit 0). The main-shell preflight below is what fails closed.
decode_surface() {
  case "$1" in
    # A scalar boundary is a HARD boundary. `jq -r ".. | strings"` emits one line per decoded
    # value, and the flattening below would otherwise weld the end of one value onto the start
    # of the next: {"label":"CLI option --json","description":"merged is not a valid field"}
    # is two unrelated fields that join into `--json merged`, failing a VALID definition
    # (reproduced). `%` is outside `[A-Za-z,]`, so it terminates a field list wherever it lands,
    # and the `--json` separator rule cannot absorb it — that rule eats only whitespace, `=`,
    # `,` and one opening quote.
    *.json) jq -r '.. | strings | ., "%"' "$1" 2>/dev/null || true ;;
    *)      cat "$1" ;;
  esac
}

# Report every `--json` list in $1 that names a bare `merged`.
bad_lists_in() {
  local list fields out=""
  while IFS= read -r list; do
    fields="${list#--json }"
    fields="${fields%%[\` \"]*}"
    case ",${fields}," in
      *,merged,*) out="${out}--json ${fields}"$'\n' ;;
    esac
  done < <(normalise_and_extract "$1")
  printf '%s' "${out}"
}

# ── 4a. SELF-TEST THE EXTRACTOR FIRST — otherwise this whole control is vacuous ─────────────────────
# `scanned` counts readable FILES, not successfully parsed field lists. So if the extraction pattern
# ever stops matching, every surface yields nothing, no offender is found, and the control prints OK
# over all 24 surfaces while detecting nothing at all. Verified: replacing the pattern with one that
# matches nothing left a real `merged` in AGENTS.md completely undetected, exit 0.
#
# So exercise the extractor against committed fixtures before trusting it on the real surfaces. Every
# BAD form must be caught and every VALID form must pass; a broken extractor now fails HERE.
self_test_dir="$(mktemp -d)"
trap 'rm -rf "${self_test_dir}"' EXIT

# Each form pairs `merged` with a DIFFERENT valid field on purpose. The extractor ends in `sort -u`
# (correct for the real scan — identical prescriptions should dedupe), so fixtures that normalise to the
# same string would collapse and the count would under-report detection that is actually working.
cat > "${self_test_dir}/bad.md" <<'FIXTURE'
plain:      `gh pr view <n> --json state,merged,mergedAt`
equals:     `gh pr view <n> --json=merged,additions`
dquoted:    `gh pr view <n> --json "merged,assignees"`
squoted:    `gh pr view <n> --json='merged,author'`
spaced-eq:  `gh pr view <n> --json  =  merged,body`
ellipsis:   `gh pr view <n> --json …mergeStateStatus,merged,closed`
wrapped:    `gh pr view <n> --json state,
merged,comments`
continued:  gh pr view <n> --json \
  merged,commits
wrap-after-flag: `gh pr view <n> --json
state,merged,body`
json-escape: "bootstrapPrompt": "gh pr view <n> --json\nstate,merged,author"
FIXTURE

cat > "${self_test_dir}/good.md" <<'FIXTURE'
`gh pr view <n> --json state,mergedAt,mergedBy,mergeCommit`
`gh pr view <n> --json=state,mergedAt`
`gh pr view <n> --json "mergedAt,mergeCommit"`
`gh pr view <n> --json='mergedBy,additions'`
`gh pr view <n> --json …mergeStateStatus,reviewDecision`
`gh pr view <n> --json state,
mergedAt,mergeCommit`
gh pr view <n> --json \
  state,mergedAt
`gh pr view <n> --json
state,mergedAt,closed`
prose: run it, then confirm the merged state separately
boundary: see `gh pr view <n> --json comments`, merged PRs need no polling
boundary2: `gh pr view <n> --json state`, and merged ones are done
FIXTURE

# JSON surfaces are decoded, so the escape forms that matter live in a JSON fixture — `\u0020` as the
# separator and `\u006d` as the letter `m` inside the field name itself. In Markdown these are literal
# text and not a threat, which is why they are not in bad.md.
cat > "${self_test_dir}/bad.json" <<'FIXTURE'
{"prompts":[
  "gh pr view <n> --json\u0020state,merged,closed",
  "gh pr view <n> --json state,\u006derged,mergedAt"
]}
FIXTURE

cat > "${self_test_dir}/good.json" <<'FIXTURE'
{"prompts":[
  "gh pr view <n> --json state,mergedAt,mergeCommit",
  "gh pr view <n> --json\u0020state,mergedAt",
  "gh pr view <n> --json state,\nmergedAt,mergeCommit",
  "Run gh pr view <n> --json state, merged PRs need no polling.",
  "Read gh pr view <n> --json mergedAt, merged work is already done.",
  "CLI option --json",
  "merged is not a valid field"
]}
FIXTURE

json_bad_caught="$(bad_lists_in "${self_test_dir}/bad.json" | grep -c . || true)"
[ "${json_bad_caught}" -ge 2 ] ||
  fail "extractor self-test: caught only ${json_bad_caught}/2 escaped JSON forms — JSON decoding is not working, so a \\uXXXX-escaped field would pass"

json_good_flagged="$(bad_lists_in "${self_test_dir}/good.json" | grep -c . || true)"
[ "${json_good_flagged}" -eq 0 ] ||
  fail "extractor self-test: flagged ${json_good_flagged} valid JSON form(s)"

bad_caught="$(bad_lists_in "${self_test_dir}/bad.md" | grep -c . || true)"
[ "${bad_caught}" -ge 10 ] ||
  fail "extractor self-test: caught only ${bad_caught}/10 known-bad \`--json\` forms — the negative control is not working, so its OK would be meaningless"

good_flagged="$(bad_lists_in "${self_test_dir}/good.md" | grep -c . || true)"
[ "${good_flagged}" -eq 0 ] ||
  fail "extractor self-test: flagged ${good_flagged} VALID form(s) as invalid — mergedAt/mergedBy/mergeCommit must never be reported"

# ── 4b. now run the validated extractor over the real definition surfaces ───────────────────────────
# Markdown AND JSON. `.claude/plugin-consumption/agentic-engineering.desired-state.json` is a named
# definition surface (AGENTS.md) and carries executable `bootstrapPrompt` strings, so a prescription can
# live there with no Markdown involved.
#
# `.claude/scripts/*.sh` is deliberately NOT scanned, and the reason is not oversight: this very test
# file contains invalid forms as SELF-TEST FIXTURES, so scanning shell would make the control fail on
# itself. The risk profile also differs — a script with a bad `--json` fails loudly the first time it
# runs, whereas a bad PROSE prescription silently misleads every agent that reads it, which is what this
# control is for.
scan_surfaces="$(
  printf '%s\n' "${constitution}"
  find "${repo_root}/.claude" -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null | sort
)"

# PREFLIGHT, in the main shell: every JSON surface must actually parse. This cannot live inside
# `normalise_and_extract`, which runs inside command substitution where `exit` only leaves the subshell.
# An unparseable surface must fail the run, never be scanned as an empty string.
while IFS= read -r surface; do
  case "${surface}" in
    *.json)
      [ -r "${surface}" ] || continue
      jq empty "${surface}" >/dev/null 2>&1 ||
        fail "JSON surface ${surface#"${repo_root}/"} does not parse — refusing to scan it, since an unparseable surface would silently contribute nothing and hide any escaped field"
      ;;
  esac
done <<EOF
${scan_surfaces}
EOF

offenders=""
scanned=0
lists_seen=0
while IFS= read -r surface; do
  [ -r "${surface}" ] || continue          # a surface may legitimately not exist in every checkout
  scanned=$((scanned + 1))
  lists_seen=$(( lists_seen + $(normalise_and_extract "${surface}" | grep -c . || true) ))
  while IFS= read -r bad; do
    [ -n "${bad}" ] && offenders="${offenders}  ${surface#"${repo_root}/"}: ${bad}"$'\n'
  done < <(bad_lists_in "${surface}")
done <<EOF
${scan_surfaces}
EOF

# A silently-small scan set, or one that parsed no field lists at all, would make this vacuous.
[ "${scanned}" -ge 5 ] ||
  fail "negative control scanned only ${scanned} surface(s); the definition surfaces are missing or moved"
[ "${lists_seen}" -ge 5 ] ||
  fail "negative control extracted only ${lists_seen} \`--json\` field list(s) from ${scanned} surfaces; the extractor is probably broken"

# ── 5. THIS JOB'S OWN CI WIRING — a guard that does not gate is not a guard ──────────────────────────
# Wiring a contract test into `ci.yaml` takes FIVE edits, and this job shipped with four: the
# `changes` job's `outputs:` declaration was missing, so `needs.changes.outputs.…` was empty, the `if:`
# was never true, and the job reported `skipping` on every run while passing locally. Worse, dropping it
# from the `status` job's `needs:`/`job-results:` would let it run and print OK while its failures no
# longer gated the required aggregate check. Assert all five here so this test guards its own wiring.
workflow="${repo_root}/.github/workflows/ci.yaml"
# FAIL, never skip. `ci.yaml` is a fixed path; guarding these assertions with `if [ -r ... ]` meant a
# renamed or unreadable workflow bypassed all five and still printed OK — the same vacuous-success mode
# 4a and the scanned/lists_seen floors exist to prevent, reintroduced in the fix for it.
[ -r "${workflow}" ] ||
  fail "ci.yaml is missing or unreadable at ${workflow} — this job's own wiring cannot be verified, so an OK here would be vacuous"
for wiring in \
  '            merge-confirmation-read:|paths-filter entry' \
  '      merge-confirmation-read: ${{ steps.filter.outputs.merge-confirmation-read }}|changes-job outputs declaration (its absence makes the job skip silently)' \
  '  test-merge-confirmation-read:|job definition' \
  '      - test-merge-confirmation-read|status job needs: entry (its absence stops the job gating the merge)' \
  '            ${{ needs.test-merge-confirmation-read.result }}|status job job-results entry'; do
  needle="${wiring%%|*}"; what="${wiring#*|}"
  grep -Fqx -- "${needle}" "${workflow}" ||
    fail "ci.yaml is missing this job's ${what} — the guard would not gate"
done
# the filter must cover every surface the scan discovers, or a change to an unlisted one skips the job
# Both the discovery globs AND the three explicit trigger paths. Dropping `AGENTS.md` alone left the
# control green while a merge-policy edit no longer ran the guard at all — the globs are not sufficient.
for trigger in \
  "              - 'AGENTS.md'" \
  "              - '.claude/**/*.md'" \
  "              - '.claude/**/*.json'" \
  "              - '.claude/scripts/merge-confirmation-read.test.sh'" \
  "              - '.github/workflows/ci.yaml'"; do
  grep -Fqx -- "${trigger}" "${workflow}" ||
    fail "ci.yaml filter is missing ${trigger# *} — an edit there would not run this guard"
done
if [ -n "${offenders}" ]; then
  printf 'merge-confirmation read: FAIL — an invalid `merged` field is prescribed:\n%s' "${offenders}" >&2
  echo "  \`merged\` exists on none of gh pr view / gh pr list / gh search prs, and one unknown" >&2
  echo "  field voids the WHOLE request — use state / mergedAt / mergeCommit instead." >&2
  exit 1
fi

echo "merge-confirmation read: OK — self-test caught ${bad_caught}/10 markdown + ${json_bad_caught}/2 escaped-JSON bad forms, flagged ${good_flagged}+${json_good_flagged} valid; no invalid \`merged\` field in ${lists_seen} --json list(s) across ${scanned} surfaces"
