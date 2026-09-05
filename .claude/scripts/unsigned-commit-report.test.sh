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
expect_out "a non-lane head is lane=none" 'lane=none$' --input "$TMP/signed.json" --head-ref feature/thing
expect_out "a lookalike prefix is not a lane" 'lane=none$' --input "$TMP/signed.json" --head-ref claudex/thing
expect_out "--lanes narrows the namespace set" 'lane=none$' --input "$TMP/signed.json" --head-ref claude/x --lanes codex

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
    i=0; while [ "$i" -lt "${FAKE_PRS:-0}" ]; do i=$((i + 1)); printf '%s\tclaude/x-%s\n' "$i" "$i"; done ;;
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
OUT="$(stub 3 2 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=6 signed=6 .* prs=3 lanes=claude lane=sweep$'; then ok "CONTROL: a lane below the cap sweeps every PR"; else bad "CONTROL: a lane below the cap sweeps every PR" "rc=$RC out=${OUT:0:200}"; fi
OUT="$(stub 0 0 --repo o/r --merged-since 2026-09-01 --lanes claude)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^examined=0 .* prs=0 '; then ok "CONTROL: an empty listing states prs=0"; else bad "CONTROL: an empty listing states prs=0" "rc=$RC out=${OUT:0:200}"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
