#!/usr/bin/env bash
# Self-test for unsigned-commit-report.sh -- hermetic through the --input seam, no network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/unsigned-commit-report.sh"
[ -x "$CHECK" ] || { echo "FATAL: $CHECK is not executable" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
run() { OUT="$("$CHECK" "$@" 2>&1)"; RC=$?; }
expect_rc() { # name rc args...
  local name="$1" want="$2"; shift 2; run "$@"
  if [ "$RC" = "$want" ]; then ok "$name"; else bad "$name" "expected rc=$want got rc=$RC; out: ${OUT:0:300}"; fi
}
expect_out() { # name pattern args...
  local name="$1" pat="$2"; shift 2; run "$@"
  if printf '%s\n' "$OUT" | grep -qE -- "$pat"; then ok "$name"; else bad "$name" "no match for /$pat/; out: ${OUT:0:300}"; fi
}
commit() { # sha verified reason
  printf '{"sha":"%s","commit":{"verification":{"verified":%s,"reason":"%s"}}}' "$1" "$2" "$3"
}

# ------------------------------------------------------------------ 1. all signed: exit 0, nothing reported, coverage stated
printf '[%s,%s]\n' "$(commit aaaa1111 true valid)" "$(commit bbbb2222 true valid)" >"$TMP/signed.json"
expect_rc "all-signed payload exits 0" 0 --input "$TMP/signed.json" --head-ref claude/x-1
expect_out "all-signed summary states coverage" '^examined=2 signed=2 unsigned=0 bad=0 unverifiable=0 head=claude/x-1 lane=claude$' --input "$TMP/signed.json" --head-ref claude/x-1
run --input "$TMP/signed.json" --head-ref claude/x-1
if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ]; then ok "all-signed output is the summary line alone"; else bad "all-signed output is the summary line alone" "out: $OUT"; fi

# ------------------------------------------------------------------ 2. THE CONTRACT: an unsigned commit is reported and does NOT fail
printf '[%s,%s]\n' "$(commit aaaa1111 true valid)" "$(commit cccc3333 false unsigned)" >"$TMP/unsigned.json"
expect_rc "an unsigned commit still exits 0 (non-blocking)" 0 --input "$TMP/unsigned.json" --head-ref codex/y-2
expect_out "the unsigned commit is reported as class N" '^N  cccc3333  unsigned  codex/y-2$' --input "$TMP/unsigned.json" --head-ref codex/y-2
expect_out "the summary counts it under unsigned=" 'examined=2 signed=1 unsigned=1 bad=0 unverifiable=0 head=codex/y-2 lane=codex' --input "$TMP/unsigned.json" --head-ref codex/y-2

# ------------------------------------------------------------------ 3. N is never conflated with B/E (AC 2)
printf '[%s,%s,%s,%s]\n' "$(commit d1 false unsigned)" "$(commit d2 false bad_email)" "$(commit d3 false invalid)" "$(commit d4 false unknown_key)" >"$TMP/mixed.json"
expect_out "bad_email is class E, not N" '^E  d2  bad_email' --input "$TMP/mixed.json"
expect_out "invalid is class B" '^B  d3  invalid' --input "$TMP/mixed.json"
expect_out "unknown_key is class E" '^E  d4  unknown_key' --input "$TMP/mixed.json"
expect_out "the three classes are counted separately" 'unsigned=1 bad=1 unverifiable=2' --input "$TMP/mixed.json"

# NEGATIVE CONTROL: the same four commits with `valid` reasons report nothing -- so case 3 is
# keying on the reason, not on the shape of the payload.
printf '[%s,%s,%s,%s]\n' "$(commit d1 true valid)" "$(commit d2 true valid)" "$(commit d3 true valid)" "$(commit d4 true valid)" >"$TMP/mixed-ok.json"
run --input "$TMP/mixed-ok.json"
if ! printf '%s\n' "$OUT" | grep -qE '^[NBE]  '; then ok "NEGATIVE CONTROL: valid reasons report no finding"; else bad "NEGATIVE CONTROL: valid reasons report no finding" "out: $OUT"; fi

# ------------------------------------------------------------------ 4. an unseen reason is E (unverifiable), never a pass
printf '[%s]\n' "$(commit e1 false some_future_reason)" >"$TMP/unseen.json"
expect_out "an unrecognised reason is class E" '^E  e1  some_future_reason' --input "$TMP/unseen.json"
# `verified:true` with a non-valid reason: the reason wins
printf '[%s]\n' "$(commit e2 true bad_email)" >"$TMP/contra.json"
expect_out "the reason outranks a contradictory verified flag" '^E  e2  bad_email' --input "$TMP/contra.json"

# ------------------------------------------------------------------ 5. a missing verification object is not silently a pass
printf '[{"sha":"f1","commit":{}}]\n' >"$TMP/noverif.json"
expect_out "a commit with no verification object is reported, reason=missing" '^E  f1  missing' --input "$TMP/noverif.json"

# ------------------------------------------------------------------ 6. coverage: the lane is stated, and a non-lane branch is lane=none
expect_out "a cursor/* head is lane=cursor" 'lane=cursor$' --input "$TMP/signed.json" --head-ref cursor/z-3
expect_out "a non-lane head is lane=none and skipped" '^examined=0 .* head=feature/thing lane=none skipped=non-agent-head$' --input "$TMP/signed.json" --head-ref feature/thing
expect_out "a lookalike prefix is not a lane" 'lane=none skipped=non-agent-head$' --input "$TMP/signed.json" --head-ref claudex/thing
expect_out "--lanes narrows the namespace set" 'lane=none skipped=non-agent-head$' --input "$TMP/signed.json" --head-ref claude/x --lanes codex

# ------------------------------------------------------------------ 7. an empty payload states it examined nothing
printf '[]\n' >"$TMP/empty.json"
expect_rc "an empty payload exits 0" 0 --input "$TMP/empty.json"
expect_out "an empty payload reports examined=0" '^examined=0 signed=0 unsigned=0' --input "$TMP/empty.json"

# ------------------------------------------------------------------ 8. UNKNOWN is exit 2, never 0
printf '{"not":"an array"}\n' >"$TMP/obj.json"
expect_rc "a non-array payload is UNKNOWN(2)" 2 --input "$TMP/obj.json"
expect_out "and says so" 'not a JSON array' --input "$TMP/obj.json"
printf 'nope\n' >"$TMP/nonjson.json"
expect_rc "an unparseable payload is UNKNOWN(2)" 2 --input "$TMP/nonjson.json"
expect_rc "a missing payload file is UNKNOWN(2)" 2 --input "$TMP/does-not-exist.json"
expect_rc "no mode at all is a usage error" 2
expect_rc "two modes at once is a usage error" 2 --input "$TMP/empty.json" --pr 1 --repo a/b
expect_rc "--pr without --repo is a usage error" 2 --pr 1
expect_rc "a non-numeric --pr is a usage error" 2 --pr x --repo a/b
expect_rc "a malformed --merged-since is a usage error" 2 --repo a/b --merged-since yesterday

# ------------------------------------------------------------------ 9. under GitHub Actions the finding is an annotation and the summary lands in the step summary
: >"$TMP/summary.md"
OUT="$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$TMP/summary.md" "$CHECK" --input "$TMP/unsigned.json" --head-ref codex/y-2 2>&1)"; RC=$?
if printf '%s\n' "$OUT" | grep -q '^::warning title=Unsigned or unverifiable commit (N)::cccc3333 unsigned on codex/y-2'; then ok "a finding is a ::warning:: annotation under Actions"; else bad "a finding is a ::warning:: annotation under Actions" "out: $OUT"; fi
if ! printf '%s\n' "$OUT" | grep -q '^::error'; then ok "and never an ::error:: (non-blocking)"; else bad "and never an ::error:: (non-blocking)" "out: $OUT"; fi
if grep -q 'examined=2 signed=1 unsigned=1' "$TMP/summary.md" && grep -q '| N | `cccc3333` | unsigned | codex/y-2 |' "$TMP/summary.md"; then ok "the step summary carries the summary and the finding table"; else bad "the step summary carries the summary and the finding table" "$(cat "$TMP/summary.md")"; fi
[ "$RC" = 0 ] && ok "and the Actions run still exits 0" || bad "and the Actions run still exits 0" "rc=$RC"
# CONTROL: outside Actions no annotation is printed. The suite itself runs under Actions, where
# GITHUB_ACTIONS is already set, so the control must clear it explicitly or it tests nothing.
OUT="$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY "$CHECK" --input "$TMP/unsigned.json" --head-ref codex/y-2 2>&1)"; RC=$?
if ! printf '%s\n' "$OUT" | grep -q '^::warning'; then ok "CONTROL: no annotation outside Actions"; else bad "CONTROL: no annotation outside Actions" "out: $OUT"; fi

# ------------------------------------------------------------------ 10. the two listing caps fail CLOSED (stubbed gh)
#
# Both `gh` reads have a hard ceiling -- `pulls/<n>/commits` lists at most 250 commits, and the
# merged-PR listing is capped by --limit -- so a set that reaches the cap may be incomplete while
# `examined=` reads as the whole. A stub `gh` on PATH returns exactly the row counts asked for, so
# these cases need no network and pin the guard against silent regression.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)
    i=0; while [ "$i" -lt "${FAKE_PRS:-0}" ]; do i=$((i + 1)); printf '%s\tclaude/x-%s\tdevantler\to\n' "$i" "$i"; done
    # a fork PR whose branch merely LOOKS like lane work: wrong author, wrong head-repository owner
    i=0; while [ "$i" -lt "${FAKE_FOREIGN:-0}" ]; do i=$((i + 1)); printf '%s\tclaude/foreign-%s\tstranger\tforkowner\n' "$((10000 + i))" "$i"; done ;;
  *"/commits"*)
    jq -n --argjson n "${FAKE_COMMITS:-0}" '[range($n) | {sha: ("c" + tostring), commit: {verification: {verified: true, reason: "valid"}}}]' ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
stub() { PATH="$TMP/bin:$PATH" FAKE_PRS="$1" FAKE_COMMITS="$2" "$CHECK" "${@:3}" 2>&1; }
OUT="$(stub 3 250 --pr 7 --repo o/r --head-ref claude/x-7)"; RC=$?
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'at the 250-commit endpoint cap'; then ok "a PR at the 250-commit cap is UNKNOWN, not a partial count"; else bad "a PR at the 250-commit cap is UNKNOWN, not a partial count" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(stub 3 249 --pr 7 --repo o/r --head-ref claude/x-7)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=249 signed=249'; then ok "CONTROL: one below the commit cap reports the full set"; else bad "CONTROL: one below the commit cap reports the full set" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(stub 1000 1 --repo o/r --merged-since 2026-09-01)"; RC=$?
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'at the 1000-PR cap'; then ok "a lane at the merged-PR cap is UNKNOWN, not a partial sweep"; else bad "a lane at the merged-PR cap is UNKNOWN, not a partial sweep" "rc=$RC out=${OUT:0:200}"; fi
# Foreign results consume the same search limit as lane-owned PRs. Filtering them first must not
# hide a truncated listing: one own plus 999 foreign results still reaches the 1000-result cap.
OUT="$(FAKE_FOREIGN=999 stub 1 2 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'at the 1000-PR cap'; then ok "foreign results count toward the merged-PR completeness cap"; else bad "foreign results count toward the merged-PR completeness cap" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(FAKE_FOREIGN=998 stub 1 2 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=2 signed=2 .* prs=1 foreign=998 '; then ok "CONTROL: mixed provenance below the listing cap remains complete"; else bad "CONTROL: mixed provenance below the listing cap remains complete" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(stub 3 2 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=6 signed=6 .* prs=3 foreign=0 lanes=claude lane=sweep$'; then ok "CONTROL: a lane below the cap sweeps every PR"; else bad "CONTROL: a lane below the cap sweeps every PR" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(stub 0 0 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=0 .* prs=0 '; then ok "CONTROL: an empty listing states prs=0"; else bad "CONTROL: an empty listing states prs=0" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 11. a non-agent head is SKIPPED: no classification, no annotation
# The CI job runs on every pull request; the report is scoped to agent branches. Classifying a
# feature/* head produced an agent-lane warning for a commit the report never claimed to cover.
expect_rc "an unsigned commit on a non-agent head exits 0" 0 --input "$TMP/unsigned.json" --head-ref feature/thing
run --input "$TMP/unsigned.json" --head-ref feature/thing
if ! printf '%s\n' "$OUT" | grep -q '^N  ' && printf '%s\n' "$OUT" | grep -qE '^examined=0 signed=0 unsigned=0 bad=0 unverifiable=0 head=feature/thing lane=none skipped=non-agent-head$'; then ok "a non-agent head classifies nothing and states the skip"; else bad "a non-agent head classifies nothing and states the skip" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(GITHUB_ACTIONS=1 "$CHECK" --input "$TMP/unsigned.json" --head-ref feature/thing 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! printf '%s\n' "$OUT" | grep -q '::warning'; then ok "and emits no annotation under Actions"; else bad "and emits no annotation under Actions" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: the same payload on an agent head is still classified (the N row and the warning)
OUT="$(GITHUB_ACTIONS=1 "$CHECK" --input "$TMP/unsigned.json" --head-ref codex/y-2 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^N  cccc3333' && printf '%s\n' "$OUT" | grep -q '::warning'; then ok "CONTROL: an agent head is still classified and annotated"; else bad "CONTROL: an agent head is still classified and annotated" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: no head ref at all (the hermetic seam) still classifies -- unknown is not the same as non-agent
expect_out "CONTROL: a payload with no head ref is still classified" '^N  cccc3333' --input "$TMP/unsigned.json"

# ------------------------------------------------------------------ 12. the sweep NAMES its targets even when everything is signed
# A clean sweep that identifies neither the PRs nor the SHAs it examined cannot be audited; the target
# lines are what let a reader re-derive `examined=` from the PR list.
OUT="$(stub 3 2 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^T  o/r#[0-9]*  claude/x-[0-9]*  commits=2  ')" = 3 ] && printf '%s\n' "$OUT" | grep -q '^T  o/r#2  claude/x-2  commits=2  c0 c1$'; then ok "the sweep prints one target line per PR with its examined SHAs"; else bad "the sweep prints one target line per PR with its examined SHAs" "rc=$RC out=${OUT:0:300}"; fi
# CONTROL: --pr mode prints no target line (the head is already named in the summary)
OUT="$(stub 3 2 --pr 7 --repo o/r --head-ref claude/x-7)"; RC=$?
if [ "$RC" = 0 ] && ! printf '%s\n' "$OUT" | grep -q '^T  '; then ok "CONTROL: --pr mode prints no target line"; else bad "CONTROL: --pr mode prints no target line" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 13. --input honours the commit cap (CI now feeds the reporter a payload, tokenless)
jq -n '[range(250) | {sha: ("c" + tostring), commit: {verification: {verified: true, reason: "valid"}}}]' >"$TMP/cap.json"
expect_rc "an --input payload at the 250-commit cap is UNKNOWN" 2 --input "$TMP/cap.json" --head-ref claude/x-1
jq -n '[range(249) | {sha: ("c" + tostring), commit: {verification: {verified: true, reason: "valid"}}}]' >"$TMP/cap-1.json"
expect_out "CONTROL: one below the cap reports the full set" '^examined=249 signed=249' --input "$TMP/cap-1.json" --head-ref claude/x-1

# ------------------------------------------------------------------ 14. a fork PR with a lane-looking branch is NOT lane work
# `head:claude/` matches branch NAMES across forks; a stranger's `claude/x` would be counted as Claude-lane
# work and corrupt the incidence. Provenance is the exact writer identity plus the base repository owner.
OUT="$(FAKE_FOREIGN=1 stub 3 2 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=6 signed=6 .* prs=3 foreign=1 lanes=claude lane=sweep$' && ! printf '%s\n' "$OUT" | grep -q '^T  o/r#10001 '; then ok "a foreign-provenance PR is excluded from the sweep and counted as foreign=1"; else bad "a foreign-provenance PR is excluded from the sweep and counted as foreign=1" "rc=$RC out=${OUT:0:300}"; fi
# CONTROL: without the foreign row the same sweep reports foreign=0
OUT="$(stub 3 2 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q ' prs=3 foreign=0 '; then ok "CONTROL: an all-own sweep reports foreign=0"; else bad "CONTROL: an all-own sweep reports foreign=0" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 15. a repeated lane name is refused, never double-counted
OUT="$(stub 3 2 --repo o/r --merged-since 2026-09-01 --lanes claude,claude)"; RC=$?
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'repeats'; then ok "--lanes with a repeated name is UNKNOWN (usage error), not a doubled count"; else bad "--lanes with a repeated name is UNKNOWN (usage error), not a doubled count" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(stub 3 2 --repo o/r --merged-since 2026-09-01 --lanes claude,codex)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: distinct lane names still sweep"; else bad "CONTROL: distinct lane names still sweep" "rc=$RC out=${OUT:0:200}"; fi


# ------------------------------------------------------------------ 16. the PER-PR path checks provenance, not just the branch NAME
# The sweep has always required the lane's writer identity on a head in this repository's owner. The
# per-PR path did not: an external fork opening a PR from `codex/foo` was classified as agent-lane
# work, so the report warned about a stranger's commits under our lane's name. The skip reason is
# named rather than folded into `non-agent-head`, because "not an agent branch" and "not our
# repository" are different facts about coverage.
printf '%s' "[$(commit 1111111111111111111111111111111111111111 false unsigned)]" >"$TMP/prov.json"
expect_out "a fork head is skipped as foreign, not classified" 'examined=0 .*skipped=foreign-head' \
  --input "$TMP/prov.json" --head-ref codex/foo --repo devantler-tech/monorepo --head-owner stranger
expect_out "an author that is not the lane's writer identity is skipped as foreign" 'examined=0 .*skipped=foreign-author' \
  --input "$TMP/prov.json" --head-ref codex/foo --repo devantler-tech/monorepo --head-owner devantler-tech --pr-author stranger
# CONTROL: the same payload with our own provenance IS classified -- so the two cases above key on
# provenance rather than on the payload or the branch name.
expect_out "CONTROL: our own head and writer identity is still classified" '^N  1111111111' \
  --input "$TMP/prov.json" --head-ref codex/foo --repo devantler-tech/monorepo --head-owner devantler-tech --pr-author devantler
# CONTROL: absent provenance still classifies -- unknown is the hermetic seam, not a refusal.
expect_out "CONTROL: no provenance supplied still classifies" '^N  1111111111' \
  --input "$TMP/prov.json" --head-ref codex/foo

# ------------------------------------------------------------------ 17. the Cursor App's DECLARED spellings, and only those
# Measured 2026-09-06 on actions#1054: `gh pr list --json author` returns `app/cursor`, REST
# `user.login` returns `cursor[bot]`, and the bare `cursor` is GraphQL-only -- a surface this
# reporter never reads. Accepting bare `cursor` matched no App PR while admitting any ordinary
# account with that login, which is the provenance check inverted.
expect_out "the bare cursor login is not the App and is refused" 'skipped=foreign-author' \
  --input "$TMP/prov.json" --head-ref cursor/foo --repo devantler-tech/monorepo --head-owner devantler-tech --pr-author cursor
for spelling in app/cursor "cursor[bot]"; do
  expect_out "CONTROL: the declared spelling $spelling is accepted" '^N  1111111111' \
    --input "$TMP/prov.json" --head-ref cursor/foo --repo devantler-tech/monorepo --head-owner devantler-tech --pr-author "$spelling"
done

# ------------------------------------------------------------------ 18. the release flag is tested in BOTH states, and expires
# *Feature-flag-first delivery*: a flagged feature is tested with the flag on AND off. The gate is a
# workflow condition, so the assertion is made against the condition itself: it must name the
# variable and require exactly `true`, so any other value -- unset, empty, `TRUE`, `1` -- leaves the
# job skipped. A wiring regression that dropped either half would otherwise leave reporting
# permanently active or permanently skipped while this suite stayed green.
CI_YAML="$HERE/../../.github/workflows/ci.yaml"
if [ -r "$CI_YAML" ]; then
  gate="$(awk '/^  report-unsigned-commits:/ { injob = 1; next } injob && /^    if: / { sub(/^    if: /, ""); print; exit } injob && /^  [a-z]/ { exit }' "$CI_YAML")"
  # The condition as a two-state function of the variable: `true` runs, everything else skips.
  flag_state() { # <value> -> runs|skips
    case "$gate" in
      *"vars.UNSIGNED_COMMIT_REPORT == 'true'"*) [ "$1" = true ] && printf runs || printf skips ;;
      *) printf 'unparsed' ;;
    esac
  }
  if [ "$(flag_state true)" = runs ]; then ok "flag ON: the reporting job runs"; else bad "flag ON: the reporting job runs" "gate=$gate"; fi
  for off in "" false TRUE 1 true-ish; do
    if [ "$(flag_state "$off")" = skips ]; then ok "flag OFF ('${off}'): the reporting job is skipped"; else bad "flag OFF ('${off}'): the reporting job is skipped" "gate=$gate"; fi
  done
  # The other conjunct: the job is scoped to pull requests, so a push to main never reports.
  case "$gate" in
    *"github.event_name == 'pull_request'"*) ok "the reporting job is scoped to pull_request events" ;;
    *) bad "the reporting job is scoped to pull_request events" "gate=$gate" ;;
  esac
  # And the provenance the per-PR path needs must actually be wired, or case 16 guards a path CI
  # never takes.
  step="$(awk '/^  report-unsigned-commits:/ { injob = 1 } injob && /unsigned-commit-report\.sh/ { found = 1 } injob && /^  [a-z]/ && !/report-unsigned-commits/ { exit } END { print found + 0 }' "$CI_YAML")"
  wired=0
  grep -q -- '--head-owner "\$HEAD_OWNER"' "$CI_YAML" && grep -q -- '--pr-author "\$PR_AUTHOR"' "$CI_YAML" && wired=1
  if [ "$step" = 1 ] && [ "$wired" = 1 ]; then ok "CI passes the pull request's provenance to the reporter"; else bad "CI passes the pull request's provenance to the reporter" "step=$step wired=$wired"; fi
else
  bad "the workflow is readable for the flag-state assertions" "missing $CI_YAML"
fi

# The flag is a RELEASE flag, so it is short-lived by contract: monorepo#3212 owns activating it and
# then removing both the variable and the condition. This assertion is the forcing function -- from
# the expiry it fails, so the flag cannot quietly become permanent debt. Removing the flag means
# removing this case in the same change.
#
# `date -u +%Y%m%d` is the one spelling BSD and GNU agree on; every relative-date form differs.
flag_expiry=20261031
today="$(date -u +%Y%m%d)"
if [ "$today" -lt "$flag_expiry" ]; then ok "the UNSIGNED_COMMIT_REPORT release flag has not passed its expiry"; else bad "the UNSIGNED_COMMIT_REPORT release flag has not passed its expiry" "today=$today expiry=$flag_expiry -- activate then remove the flag per monorepo#3212"; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
