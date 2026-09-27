#!/usr/bin/env bash
# Self-test for bash-parse-guard.sh (monorepo#3172).
#
# Every "must flag" fixture has a twin that differs only in the syntax error, so a control
# that passes for the wrong reason cannot hide a broken check. The parse check is ablated once
# (a copy of the guard with `bash -n` replaced by `true`) to prove the flagged fixture depends
# on it. The repository-wide sweep is a separate CI step.
#
# The test also RECORDS, without asserting, what a script with the common cleanup trap exits
# with when it dies on a parse error under whichever bash runs it. CI runs this on
# ubuntu-latest (bash 5) and macos-latest (bash 3.2), so the log of each leg is the
# per-version measurement #3172 asks for. It does ASSERT that the completion-sentinel shape
# (`ci-job-wiring.sh`) fails closed on a parse error, since that holds on both.
# Fixture text quotes shell syntax on purpose; it must not expand here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/bash-parse-guard.sh"
tmp="$(mktemp -d)"
bash_parse_guard_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$bash_parse_guard_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "bash-parse-guard.test: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; fails=$((fails + 1)); }
check() { # <name> <condition-result yes|no> [detail]
  if [ "$2" = yes ]; then pass "$1"; else fail "$1${3:+ — $3}"; fi
}

echo "BASH_VERSION=${BASH_VERSION}"

# A fixture repository; prints its path.
mkrepo() {
  local dir="$tmp/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '%s' "$dir"
}

# Write $3.. as lines into $1/$2 and stage it.
addf() {
  local dir="$1" rel="$2"
  shift 2
  mkdir -p "$dir/$(dirname "$rel")"
  printf '%s\n' "$@" >"$dir/$rel"
  git -C "$dir" add -- "$rel"
}

# Run the guard over one directory; sets $out and $rc.
run() {
  rc=0
  out="$("$BASH" "${GUARD:-$guard}" "$1" 2>&1)" || rc=$?
}

# The motivating shape: a doubled `case … in` after the cleanup trap is installed.
broken=('#!/usr/bin/env bash' 'set -euo pipefail' 'tmp="$(mktemp -d)"' "trap 'rm -rf \"\$tmp\"' EXIT"
  'case "${1:-}" in' 'case "${1:-}" in' '  *) echo ok ;;' 'esac')
# Its twin: identical except the duplicated line.
parses=('#!/usr/bin/env bash' 'set -euo pipefail' 'tmp="$(mktemp -d)"' "trap 'rm -rf \"\$tmp\"' EXIT"
  'case "${1:-}" in' '  *) echo ok ;;' 'esac')

echo "guard behaviour"

r="$(mkrepo clean)"
addf "$r" tools/check.test.sh "${parses[@]}"
run "$r"
check "a parseable tracked script passes" "$([ "$rc" -eq 0 ] && [[ "$out" == *"all 1 tracked script(s) parse"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo broken)"
addf "$r" tools/check.test.sh "${broken[@]}"
run "$r"
check "an unparseable tracked .sh is a finding naming the file" \
  "$([ "$rc" -eq 1 ] && [[ "$out" == *"tools/check.test.sh does not parse"* ]] && echo yes || echo no)" "rc=$rc: $out"
check "the finding carries bash's own message" \
  "$([[ "$out" == *"syntax error"* ]] && echo yes || echo no)" "$out"

r="$(mkrepo broken-bash-ext)"
addf "$r" lib/helpers.bash "${broken[@]}"
run "$r"
check "an unparseable tracked .bash is a finding" \
  "$([ "$rc" -eq 1 ] && [[ "$out" == *"lib/helpers.bash does not parse"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo spaced)"
addf "$r" "a dir/my script.sh" "${broken[@]}"
addf "$r" ok.sh "${parses[@]}"
run "$r"
check "a path with spaces is read whole, and only the broken file is reported" \
  "$([ "$rc" -eq 1 ] && [[ "$out" == *"a dir/my script.sh does not parse"* ]] && [[ "$out" == *"1 of 2 tracked"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo other-ext)"
addf "$r" ok.sh "${parses[@]}"
addf "$r" notes.txt "${broken[@]}"
run "$r"
check "a file that is not .sh or .bash is not parsed" "$([ "$rc" -eq 0 ] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo untracked)"
addf "$r" ok.sh "${parses[@]}"
printf '%s\n' "${broken[@]}" >"$r/scratch.sh"
run "$r"
check "an untracked script is outside the contract" "$([ "$rc" -eq 0 ] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo empty)"
addf "$r" README.md '# nothing to parse'
run "$r"
check "a sweep that finds no script is UNKNOWN, never clean" \
  "$([ "$rc" -eq 2 ] && [[ "$out" == *"nothing was checked"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo missing)"
addf "$r" ok.sh "${parses[@]}"
addf "$r" gone.sh "${broken[@]}"
rm "$r/gone.sh"
run "$r"
check "a tracked script missing from the working tree is UNKNOWN, never skipped" \
  "$([ "$rc" -eq 2 ] && [[ "$out" == *"gone.sh: tracked but not present"* ]] && echo yes || echo no)" "rc=$rc: $out"

mkdir -p "$tmp/not-a-repo"
run "$tmp/not-a-repo"
check "a directory that is not a repository is UNKNOWN" "$([ "$rc" -eq 2 ] && echo yes || echo no)" "rc=$rc: $out"

rc=0
out="$("$BASH" "$guard" a b 2>&1)" || rc=$?
check "extra arguments are a usage error" "$([ "$rc" -eq 2 ] && [[ "$out" == *usage:* ]] && echo yes || echo no)" "rc=$rc: $out"

# Ablation: with the parse check neutralised, the broken fixture must stop being flagged.
# If it were still flagged, the finding above would not depend on `bash -n`.
sed 's/"\$BASH" -n -- "\$file"/true/' "$guard" >"$tmp/ablated.sh"
if grep -q 'BASH" -n' "$tmp/ablated.sh" || ! grep -q '  if ! true 2>' "$tmp/ablated.sh"; then
  fail "ablation did not land: the parse call was not replaced"
else
  GUARD="$tmp/ablated.sh" run "$tmp/broken"
  check "ablation: without bash -n the broken fixture passes, so the finding depends on it" \
    "$([ "$rc" -eq 0 ] && echo yes || echo no)" "rc=$rc: $out"
fi

echo "parse error at runtime (bash ${BASH_VERSION})"

# Recorded, not asserted: which status each trap shape leaves after a parse error.
printf '%s\n' '#!/usr/bin/env bash' 'case x in' 'case x in' '  *) : ;;' 'esac' >"$tmp/A-no-trap.sh"
printf '%s\n' "${broken[@]}" >"$tmp/B-cleanup-trap.sh"
printf '%s\n' '#!/usr/bin/env bash' "trap 'false' EXIT" 'case x in' 'case x in' '  *) : ;;' 'esac' >"$tmp/C-failing-trap.sh"
for f in A-no-trap B-cleanup-trap C-failing-trap; do
  frc=0
  "$BASH" "$tmp/$f.sh" >/dev/null 2>&1 || frc=$?
  echo "  measured $f: exit $frc"
done

# Asserted: the completion-sentinel shape exits non-zero whatever $? the trap is handed.
cat >"$tmp/sentinel.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$finished" != 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
case "${1:-}" in
case "${1:-}" in
  *) echo ok ;;
esac
finished=1
EOF
src=0
"$BASH" "$tmp/sentinel.sh" >/dev/null 2>&1 || src=$?
check "the completion-sentinel trap shape fails closed on a parse error" "$([ "$src" -ne 0 ] && echo yes || echo no)" "exit $src"
# Control: the same shape without the syntax error finishes cleanly, so the non-zero above is the parse error.
awk 'BEGIN{seen=0} $0=="case \"${1:-}\" in"{ if (seen++) next } {print}' "$tmp/sentinel.sh" >"$tmp/sentinel-ok.sh"
okrc=0
"$BASH" "$tmp/sentinel-ok.sh" >/dev/null 2>&1 || okrc=$?
check "control: the sentinel shape without the error exits 0" "$([ "$okrc" -eq 0 ] && echo yes || echo no)" "exit $okrc"

echo
if [ "$fails" -gt 0 ]; then
  echo "bash-parse-guard.test: $fails failure(s)" >&2
  exit 1
fi
bash_parse_guard_test_finished=1
echo "bash-parse-guard.test: all checks passed"
