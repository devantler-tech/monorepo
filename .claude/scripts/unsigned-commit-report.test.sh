#!/usr/bin/env bash
# Self-test for unsigned-commit-report.sh -- hermetic through the --input seam, no network.
set -uo pipefail
# Fixtures never write to the enclosing Actions job. The dedicated output case below supplies
# its own temporary summary and opts into annotations explicitly.
unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/unsigned-commit-report.sh"
[ -x "$CHECK" ] || { echo "FATAL: $CHECK is not executable" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTANCES="$TMP/instances.json"
cat >"$INSTANCES" <<'JSON'
{"version":1,"policyPublisher":"codex-local","instances":{
  "claude-local":{"namespace":"claude","authors":{"cli":"devantler","rest":"devantler","graphql":"devantler","search":"devantler"},"definitionAdapter":"claude","roles":["agentic-engineer","agent-improver"]},
  "codex-local":{"namespace":"codex","authors":{"cli":"devantler","rest":"devantler","graphql":"devantler","search":"devantler"},"definitionAdapter":"codex","roles":["agentic-engineer","agent-improver"]},
  "build-worker":{"namespace":"worker","authors":{"cli":"app/build-worker","rest":"build-worker[bot]","graphql":"build-worker","search":"app/build-worker"},"definitionAdapter":"local-runtime","roles":["agentic-engineer"]}
}}
JSON
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
run() { OUT="$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY "$CHECK" --instances "$INSTANCES" "$@" 2>&1)"; RC=$?; }
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
expect_out "a registered neutral namespace is classified" 'lane=worker$' --input "$TMP/signed.json" --head-ref worker/z-3
expect_out "an unregistered retired namespace is skipped" 'lane=none skipped=non-agent-head$' --input "$TMP/signed.json" --head-ref cursor/z-3
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
printf '{}\n[]\n' >"$TMP/multiple.json"
expect_rc "multiple JSON documents are UNKNOWN, not an empty report" 2 --input "$TMP/multiple.json"
expect_rc "a missing payload file is UNKNOWN(2)" 2 --input "$TMP/does-not-exist.json"
expect_rc "no mode at all is a usage error" 2
expect_rc "two modes at once is a usage error" 2 --input "$TMP/empty.json" --pr 1 --repo a/b
expect_rc "--pr without --repo is a usage error" 2 --pr 1
expect_rc "a non-numeric --pr is a usage error" 2 --pr x --repo a/b
expect_rc "a malformed --merged-since is a usage error" 2 --repo a/b --merged-since yesterday

# ------------------------------------------------------------------ 9. under GitHub Actions the finding is an annotation and the summary lands in the step summary
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$TMP/fixture-leak.md" run --input "$TMP/unsigned.json" --head-ref codex/y-2
if [ ! -e "$TMP/fixture-leak.md" ] && ! printf '%s\n' "$OUT" | grep -q '^::warning'; then
  ok "ordinary fixture calls do not emit Actions annotations or summaries"
else
  bad "ordinary fixture calls do not emit Actions annotations or summaries" "fixture output reached the Actions surface"
fi
: >"$TMP/summary.md"
OUT="$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$TMP/summary.md" "$CHECK" --instances "$INSTANCES" --input "$TMP/unsigned.json" --head-ref codex/y-2 2>&1)"; RC=$?
if printf '%s\n' "$OUT" | grep -q '^::warning title=Unsigned or unverifiable commit (N)::cccc3333 unsigned on codex/y-2'; then ok "a finding is a ::warning:: annotation under Actions"; else bad "a finding is a ::warning:: annotation under Actions" "out: $OUT"; fi
if ! printf '%s\n' "$OUT" | grep -q '^::error'; then ok "and never an ::error:: (non-blocking)"; else bad "and never an ::error:: (non-blocking)" "out: $OUT"; fi
if grep -q 'examined=2 signed=1 unsigned=1' "$TMP/summary.md" && grep -q '| N | `cccc3333` | unsigned | codex/y-2 |' "$TMP/summary.md"; then ok "the step summary carries the summary and the finding table"; else bad "the step summary carries the summary and the finding table" "$(cat "$TMP/summary.md")"; fi
[ "$RC" = 0 ] && ok "and the Actions run still exits 0" || bad "and the Actions run still exits 0" "rc=$RC"
# CONTROL: outside Actions no annotation is printed. The suite itself runs under Actions, where
# GITHUB_ACTIONS is already set, so the control must clear it explicitly or it tests nothing.
OUT="$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY "$CHECK" --instances "$INSTANCES" --input "$TMP/unsigned.json" --head-ref codex/y-2 2>&1)"; RC=$?
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
    i=0; while [ "$i" -lt "${FAKE_PRS:-0}" ]; do i=$((i + 1)); printf '%s\t%s/x-%s\t%s\t%s\n' "$i" "${FAKE_LANE:-claude}" "$i" "${FAKE_AUTHOR:-devantler}" "${FAKE_CROSS:-false}"; done
    # a fork PR whose branch merely LOOKS like lane work: wrong author, wrong head-repository owner
    i=0; while [ "$i" -lt "${FAKE_FOREIGN:-0}" ]; do i=$((i + 1)); printf '%s\tclaude/foreign-%s\tstranger\ttrue\n' "$((10000 + i))" "$i"; done ;;
  *"/commits"*)
    [ "${FAKE_COMMIT_READ_FAIL:-0}" = 0 ] || exit 98
    jq -n --argjson n "${FAKE_COMMITS:-0}" '[range($n) | {sha: ("c" + tostring), commit: {verification: {verified: true, reason: "valid"}}}]' ;;
  *"api repos/o/r/pulls/7"*)
    [ "${FAKE_PR_READ_FAIL:-0}" = 0 ] || exit 97
    if [ "${FAKE_PR_MISSING:-0}" = 1 ]; then printf '{}\n'
    elif [ "${!#}" = '.head.ref' ]; then printf '%s\n' "${FAKE_PR_HEAD:-claude/x-7}"
    else
      jq -n --arg head "${FAKE_PR_HEAD:-claude/x-7}" --arg owner "${FAKE_PR_OWNER:-o}" --arg repo "${FAKE_PR_REPO:-o/r}" --arg author "${FAKE_PR_AUTHOR:-devantler}" \
        '{head:{ref:$head,repo:{owner:{login:$owner},full_name:$repo}},user:{login:$author}}'
    fi ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
stub() { PATH="$TMP/bin:$PATH" FAKE_PRS="$1" FAKE_COMMITS="$2" "$CHECK" --instances "$INSTANCES" "${@:3}" 2>&1; }
# Direct mode obtains provenance from the PR API even when --head-ref is supplied.
OUT="$(FAKE_PR_OWNER=contributor FAKE_COMMIT_READ_FAIL=1 stub 0 2 --pr 7 --repo o/r)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q 'examined=0 .*skipped=foreign-head'; then ok "direct PR mode skips a foreign head before reading commits"; else bad "direct PR mode skips a foreign head before reading commits" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(FAKE_PR_AUTHOR=contributor FAKE_COMMIT_READ_FAIL=1 stub 0 2 --pr 7 --repo o/r --head-ref claude/x-7)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q 'examined=0 .*skipped=foreign-author'; then ok "a supplied head ref does not replace the PR author lookup"; else bad "a supplied head ref does not replace the PR author lookup" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(FAKE_PR_READ_FAIL=1 stub 0 2 --pr 7 --repo o/r --head-ref claude/x-7)"; RC=$?
if [ "$RC" = 2 ]; then ok "failed PR metadata is UNKNOWN even with a supplied head ref"; else bad "failed PR metadata is UNKNOWN even with a supplied head ref" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(FAKE_PR_MISSING=1 stub 0 2 --pr 7 --repo o/r --head-ref claude/x-7)"; RC=$?
if [ "$RC" = 2 ]; then ok "missing PR provenance is UNKNOWN"; else bad "missing PR provenance is UNKNOWN" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(stub 0 2 --pr 7 --repo o/r)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=2 signed=2'; then ok "CONTROL: direct PR mode still reports our own branch"; else bad "CONTROL: direct PR mode still reports our own branch" "rc=$RC out=${OUT:0:200}"; fi
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
OUT="$(GITHUB_ACTIONS=1 "$CHECK" --instances "$INSTANCES" --input "$TMP/unsigned.json" --head-ref feature/thing 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! printf '%s\n' "$OUT" | grep -q '::warning'; then ok "and emits no annotation under Actions"; else bad "and emits no annotation under Actions" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: the same payload on an agent head is still classified (the N row and the warning)
OUT="$(GITHUB_ACTIONS=1 "$CHECK" --instances "$INSTANCES" --input "$TMP/unsigned.json" --head-ref codex/y-2 2>&1)"; RC=$?
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
  --input "$TMP/prov.json" --head-ref codex/foo --repo devantler-tech/monorepo --head-owner stranger --head-repo stranger/monorepo --pr-author stranger
expect_out "an author that is not the lane's writer identity is skipped as foreign" 'examined=0 .*skipped=foreign-author' \
  --input "$TMP/prov.json" --head-ref codex/foo --repo devantler-tech/monorepo --head-owner devantler-tech --head-repo devantler-tech/monorepo --pr-author stranger
# CONTROL: the same payload with our own provenance IS classified -- so the two cases above key on
# provenance rather than on the payload or the branch name.
expect_out "CONTROL: our own head and writer identity is still classified" '^N  1111111111' \
  --input "$TMP/prov.json" --head-ref codex/foo --repo devantler-tech/monorepo --head-repo devantler-tech/monorepo --head-owner devantler-tech --pr-author devantler
# CONTROL: absent provenance still classifies -- unknown is the hermetic seam, not a refusal.
expect_out "CONTROL: no provenance supplied still classifies" '^N  1111111111' \
  --input "$TMP/prov.json" --head-ref codex/foo
for head_repo in devantler-tech/monorepo stranger/fork; do
  run --input "$TMP/prov.json" --repo devantler-tech/monorepo --head-repo "$head_repo" --pr-author stranger
  if [ "$RC" = 2 ] && grep -q 'UNKNOWN' <<<"$OUT" && ! grep -q '^N  ' <<<"$OUT"; then
    ok "supplied provenance with absent branch is UNKNOWN for $head_repo"
  else
    bad "supplied provenance with absent branch is UNKNOWN for $head_repo" "rc=$RC out=$OUT"
  fi
done
run --input "$TMP/prov.json" --head-ref '' --repo devantler-tech/monorepo --head-repo devantler-tech/monorepo --pr-author devantler
if [ "$RC" = 2 ] && grep -q 'UNKNOWN' <<<"$OUT"; then ok "explicitly empty authoritative branch is UNKNOWN"; else bad "explicitly empty authoritative branch is UNKNOWN" "rc=$RC out=$OUT"; fi
expect_out "CONTROL: payload-only classification remains available" '^N  1111111111' --input "$TMP/prov.json"

# ------------------------------------------------------------------ 17. configured API spellings, and only those
expect_out "REST input accepts the registered neutral writer" '^N  1111111111' \
  --input "$TMP/prov.json" --head-ref worker/foo --repo devantler-tech/monorepo --head-repo devantler-tech/monorepo --head-owner devantler-tech --pr-author 'build-worker[bot]'
for spelling in build-worker app/build-worker stranger 'build-worker[bot]-forged'; do
  expect_out "REST input refuses foreign or wrong-surface author $spelling" 'skipped=foreign-author' \
    --input "$TMP/prov.json" --head-ref worker/foo --repo devantler-tech/monorepo --head-owner devantler-tech --head-repo devantler-tech/monorepo --pr-author "$spelling"
done
jq '.instances["build-worker"].namespace = "none"' "$INSTANCES" >"$TMP/none-instances.json"
expect_out "a registered namespace named none is classified" '^N  1111111111' \
  --input "$TMP/prov.json" --instances "$TMP/none-instances.json" --head-ref none/work \
  --repo devantler-tech/monorepo --head-repo devantler-tech/monorepo --pr-author 'build-worker[bot]'
OUT="$(FAKE_LANE=worker FAKE_AUTHOR=app/build-worker stub 1 2 --repo o/r --merged-since 2026-09-01 --lanes worker)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=2 signed=2 .*prs=1 foreign=0'; then ok "CLI sweep accepts the registered neutral writer"; else bad "CLI sweep accepts the registered neutral writer" "rc=$RC out=$OUT"; fi
OUT="$(FAKE_LANE=worker FAKE_AUTHOR='build-worker[bot]' stub 1 2 --repo o/r --merged-since 2026-09-01 --lanes worker)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=0 .*prs=0 foreign=1'; then ok "CLI sweep refuses the REST spelling"; else bad "CLI sweep refuses the REST spelling" "rc=$RC out=$OUT"; fi
OUT="$(FAKE_PR_REPO=o/fork FAKE_COMMIT_READ_FAIL=1 stub 0 2 --pr 7 --repo o/r)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q 'skipped=foreign-head'; then ok "direct PR excludes a same-owner sibling repository"; else bad "direct PR excludes a same-owner sibling repository" "rc=$RC out=$OUT"; fi
expect_rc "owner-only payload provenance cannot establish the head repository" 2 --input "$TMP/prov.json" --head-ref codex/foo --repo devantler-tech/monorepo --head-owner devantler-tech --pr-author devantler
expect_out "same-owner fork is excluded by full repository provenance" 'skipped=foreign-head' \
  --input "$TMP/prov.json" --head-ref worker/foo --repo devantler-tech/monorepo --head-owner devantler-tech --head-repo devantler-tech/fork --pr-author 'build-worker[bot]'
expect_rc "--lanes cannot register an unknown namespace" 2 --input "$TMP/prov.json" --head-ref unknown/foo --lanes unknown
expect_rc "missing registry is UNKNOWN" 2 --input "$TMP/prov.json" --instances "$TMP/missing-instances.json"
expect_out "missing registry explicitly states UNKNOWN" 'UNKNOWN' --input "$TMP/prov.json" --instances "$TMP/missing-instances.json"
for mutation in '.version = 2' '.instances = {}' '.instances["build-worker"].namespace = "codex"' '.instances["build-worker"].authors.rest = ""' '.policyPublisher = "missing"'; do
  jq "$mutation" "$INSTANCES" >"$TMP/bad-instances.json"
  expect_rc "malformed registry fails closed: $mutation" 2 --input "$TMP/prov.json" --instances "$TMP/bad-instances.json"
done

# ------------------------------------------------------------------ 18. release-flag wiring and expiry
# These assertions check workflow wiring, not expression evaluation. Actions compares strings
# without case sensitivity, so `TRUE` enables the job too. Both-state behavior must be evaluated
# with the Actions expression engine or an actual workflow, never a Bash replacement for it.
CI_YAML="$HERE/../../.github/workflows/ci.yaml"
if [ -r "$CI_YAML" ]; then
  gate="$(awk '/^  report-unsigned-commits:/ { injob = 1; next } injob && /^    if: / { sub(/^    if: /, ""); print; exit } injob && /^  [a-z]/ { exit }' "$CI_YAML")"
  case "$gate" in
    *"vars.UNSIGNED_COMMIT_REPORT == 'true'"*) ok "the reporting job retains the release-variable condition" ;;
    *) bad "the reporting job retains the release-variable condition" "gate=$gate" ;;
  esac
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

  # Execute the workflow's actual report-step shell, with no Actions expression
  # emulation and no authenticated operations. The old base has no registry;
  # both fixtures contain a conflicting PR-head registry and a poisoned PR-head
  # reporter, so neither can accidentally satisfy the trusted-base contract.
  CI_RUN="$(awk '
    /^  report-unsigned-commits:/ { injob = 1; next }
    injob && /^  [a-z]/ { exit }
    injob && /^      - name: Report unsigned commits on this pull request$/ { instep = 1; next }
    instep && /^        run: \|$/ { inrun = 1; next }
    inrun && /^          / { sub(/^          /, ""); print; next }
    inrun && /^[[:space:]]*$/ { next }
    inrun { exit }
  ' "$CI_YAML")"
  if [ -n "$CI_RUN" ] && bash -n <<<"$CI_RUN"; then
    CI_FIX="$TMP/ci-step"
    mkdir -p "$CI_FIX/bin" "$CI_FIX/temp" "$CI_FIX/trusted-base/.claude/scripts" \
      "$CI_FIX/trusted-base/.claude/plugin-consumption" "$CI_FIX/.claude/scripts" \
      "$CI_FIX/.claude/plugin-consumption"
    cp "$TMP/prov.json" "$CI_FIX/temp/pr-commits.json"
    jq '.instances["build-worker"].authors.rest = "forged-writer"' "$INSTANCES" \
      >"$CI_FIX/.claude/plugin-consumption/agent-instances.json"
    cat >"$CI_FIX/.claude/scripts/unsigned-commit-report.sh" <<'SH'
#!/usr/bin/env bash
printf 'UNTRUSTED_REPORTER_EXECUTED\n' >"$CI_EXEC_MARKER"
exit 93
SH
    cat >"$CI_FIX/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'UNEXPECTED_FORGE_CALL\n' >"$CI_FORGE_MARKER"
exit 94
SH
    chmod +x "$CI_FIX/bin/gh"
    # Run the real reporter from a detached path behind a transparent wrapper.
    # Its default registry path does not exist there, so successful reporting
    # also proves the workflow forwards --instances explicitly.
    cp "$CHECK" "$CI_FIX/real-reporter.sh"
    cat >"$CI_FIX/trusted-base/.claude/scripts/unsigned-commit-report.sh" <<'SH'
#!/usr/bin/env bash
printf 'TRUSTED_REPORTER_EXECUTED\n' >"$CI_EXEC_MARKER"
exec bash "$CI_REAL_REPORTER" "$@"
SH
    ci_step() { # actual or deliberately ablated shell, optional head repository
      rm -f "$CI_FIX/reporter-called" "$CI_FIX/forge-called"
      OUT="$(cd "$CI_FIX" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
        -u GITHUB_ENTERPRISE_TOKEN -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY \
        PATH="$CI_FIX/bin:$PATH" RUNNER_TEMP="$CI_FIX/temp" \
        CI_EXEC_MARKER="$CI_FIX/reporter-called" CI_FORGE_MARKER="$CI_FIX/forge-called" \
        CI_REAL_REPORTER="$CI_FIX/real-reporter.sh" GITHUB_REPOSITORY=devantler-tech/monorepo \
        HEAD_REF=worker/change HEAD_OWNER=devantler-tech \
        HEAD_REPO="${2:-devantler-tech/monorepo}" PR_AUTHOR='build-worker[bot]' \
        bash --noprofile --norc -eo pipefail -c "$1" 2>&1)"; RC=$?
      if [ -e "$CI_FIX/forge-called" ]; then bad "CI report step never calls the forge" "$OUT"; fi
    }
    old_base_ok() { [ "$RC" = 0 ] && grep -q 'UNKNOWN.*trusted base' <<<"$OUT" && [ ! -e "$CI_FIX/reporter-called" ]; }
    current_base_ok() { [ "$RC" = 0 ] && grep -q '^N  1111111111' <<<"$OUT" && grep -q '^TRUSTED_REPORTER_EXECUTED$' "$CI_FIX/reporter-called"; }

    ci_step "$CI_RUN"
    if old_base_ok; then ok "CI old base reports UNKNOWN without executing either reporter or the PR registry"; else bad "CI old base reports UNKNOWN without executing either reporter or the PR registry" "rc=$RC out=$OUT"; fi
    # Mutation control: removing the compatibility guard must break that exact
    # outcome, even though the real reporter also returns an UNKNOWN diagnostic.
    CI_NO_GUARD="$(awk '/^if \[\[ ! -r / { skip = 1; next } skip && /^fi$/ { skip = 0; next } !skip' <<<"$CI_RUN")"
    ci_step "$CI_NO_GUARD"
    if [ "$CI_NO_GUARD" != "$CI_RUN" ] && ! old_base_ok; then ok "CONTROL: the old-base assertion catches removal of the compatibility guard"; else bad "CONTROL: the old-base assertion catches removal of the compatibility guard" "rc=$RC out=$OUT"; fi

    cp "$INSTANCES" "$CI_FIX/trusted-base/.claude/plugin-consumption/agent-instances.json"
    ci_step "$CI_RUN"
    if current_base_ok; then ok "CI current base executes the trusted reporter with its explicit registry"; else bad "CI current base executes the trusted reporter with its explicit registry" "rc=$RC out=$OUT"; fi
    CI_PR_REGISTRY="$(sed 's|--instances trusted-base/|--instances |' <<<"$CI_RUN")"
    ci_step "$CI_PR_REGISTRY"
    if [ "$CI_PR_REGISTRY" != "$CI_RUN" ] && ! current_base_ok; then ok "CONTROL: the current-base assertion catches use of the PR-head registry"; else bad "CONTROL: the current-base assertion catches use of the PR-head registry" "rc=$RC out=$OUT"; fi
    CI_PR_REPORTER="$(sed 's|bash trusted-base/|bash |' <<<"$CI_RUN")"
    ci_step "$CI_PR_REPORTER"
    if [ "$CI_PR_REPORTER" != "$CI_RUN" ] && ! current_base_ok; then ok "CONTROL: the current-base assertion catches execution of the PR-head reporter"; else bad "CONTROL: the current-base assertion catches execution of the PR-head reporter" "rc=$RC out=$OUT"; fi
    ci_step "$CI_RUN" devantler-tech/sibling-fork
    if [ "$RC" = 0 ] && grep -q 'skipped=foreign-head' <<<"$OUT"; then ok "CI forwards full head repository provenance and excludes same-owner forks"; else bad "CI forwards full head repository provenance and excludes same-owner forks" "rc=$RC out=$OUT"; fi
    printf '{}\n' >"$CI_FIX/trusted-base/.claude/plugin-consumption/agent-instances.json"
    ci_step "$CI_RUN"
    if [ "$RC" = 2 ] && grep -q 'instance registry.*UNKNOWN' <<<"$OUT"; then ok "CI malformed trusted registry stays UNKNOWN instead of falling back to the PR registry"; else bad "CI malformed trusted registry stays UNKNOWN instead of falling back to the PR registry" "rc=$RC out=$OUT"; fi
  else
    bad "the workflow report-step shell is present and executable" "missing or malformed report run block"
  fi
else
  bad "the workflow is readable for the flag-state assertions" "missing $CI_YAML"
fi

# The flag is a RELEASE flag, so it is short-lived by contract: monorepo#3229 owns activating it and
# then removing both the variable and the condition. This assertion is the forcing function -- from
# the expiry it fails, so the flag cannot quietly become permanent debt. Removing the flag means
# removing this case in the same change.
#
# `date -u +%Y%m%d` is the one spelling BSD and GNU agree on; every relative-date form differs.
flag_expiry=20261031
today="$(date -u +%Y%m%d)"
if [ "$today" -lt "$flag_expiry" ]; then ok "the UNSIGNED_COMMIT_REPORT release flag has not passed its expiry"; else bad "the UNSIGNED_COMMIT_REPORT release flag has not passed its expiry" "today=$today expiry=$flag_expiry -- activate then remove the flag per monorepo#3229"; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
