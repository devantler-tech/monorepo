#!/usr/bin/env bash
# Contract tests for disk-preflight.sh.
#
# A fake `df` first on PATH replays a chosen report, so every verdict is provable on any host
# and no assertion depends on how full the machine running the tests happens to be. The
# property that matters most is the fail-closed one: every way the measurement can fail must
# exit 2, never 0 — a run treats only a clean 0 as room for heavy work.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="${script_dir}/disk-preflight.sh"

pass=0; failures=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

fixture=$(mktemp -d) || { printf 'cannot create a fixture directory\n' >&2; exit 2; }
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/vol"

GB=1048576   # KB per GB

# fake_df <available-kb> — a POSIX df report whose data line has a space in the filesystem
# name, so a parser reading columns by position would take the wrong one.
fake_df() {
  cat > "$fixture/bin/df" <<EOF
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'map auto home   500000000 100000000 %s    17%%    /Volumes/Data\n' "$1"
EOF
  chmod +x "$fixture/bin/df"
}

# fake_df_raw <script body> — a df that does something else entirely.
fake_df_raw() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$fixture/bin/df"
  chmod +x "$fixture/bin/df"
}

run() { # [args...] -> sets out, rc
  out=$(PATH="$fixture/bin:$PATH" bash "$impl" "$@" 2>&1); rc=$?
}

printf 'disk-preflight.sh contract tests\n'

# --- verdicts ---------------------------------------------------------------------
fake_df $((25 * GB))
run 20 "$fixture/vol"
if [ "$rc" -eq 0 ] && grep -q 'OK — 25 GB free on the volume holding' <<<"$out" \
   && grep -q '(threshold 20 GB)' <<<"$out"; then
  ok "enough free space exits 0 and prints the free GB and the threshold"
else
  bad "enough free space exits 0 and prints the free GB and the threshold" "rc=$rc $out"
fi

fake_df $((20 * GB))
run 20 "$fixture/vol"
if [ "$rc" -eq 0 ]; then ok "exactly the threshold is enough"
else bad "exactly the threshold is enough" "rc=$rc $out"; fi

fake_df $((20 * GB - 1))
run 20 "$fixture/vol"
if [ "$rc" -eq 1 ] && grep -q 'LOW — 19 GB free' <<<"$out"; then
  ok "one KB under the threshold exits 1"
else
  bad "one KB under the threshold exits 1" "rc=$rc $out"
fi

# --- the threshold ----------------------------------------------------------------
fake_df $((15 * GB))
run "" "$fixture/vol"
if [ "$rc" -eq 1 ] && grep -q '(threshold 20 GB)' <<<"$out"; then
  ok "the threshold defaults to 20 GB"
else
  bad "the threshold defaults to 20 GB" "rc=$rc $out"
fi

out=$(PATH="$fixture/bin:$PATH" DISK_PREFLIGHT_MIN_FREE_GB=10 bash "$impl" "" "$fixture/vol" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '(threshold 10 GB)' <<<"$out"; then
  ok "DISK_PREFLIGHT_MIN_FREE_GB overrides the default"
else
  bad "DISK_PREFLIGHT_MIN_FREE_GB overrides the default" "rc=$rc $out"
fi

out=$(PATH="$fixture/bin:$PATH" DISK_PREFLIGHT_MIN_FREE_GB=10 bash "$impl" 16 "$fixture/vol" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '(threshold 16 GB)' <<<"$out"; then
  ok "an argument overrides the environment"
else
  bad "an argument overrides the environment" "rc=$rc $out"
fi

run 08 "$fixture/vol"
if [ "$rc" -eq 0 ] && grep -q '(threshold 8 GB)' <<<"$out"; then
  ok "a leading zero is read as decimal, not octal"
else
  bad "a leading zero is read as decimal, not octal" "rc=$rc $out"
fi

for arg in abc -5 1.5 12345678; do
  run "$arg" "$fixture/vol"
  if [ "$rc" -eq 2 ] && grep -q 'UNKNOWN' <<<"$out"; then
    ok "a malformed threshold ($arg) exits 2"
  else
    bad "a malformed threshold ($arg) exits 2" "rc=$rc $out"
  fi
done

# --- fail closed: every failed or unreadable measurement is 2 ----------------------
fake_df_raw 'echo "df: cannot stat" >&2; exit 1'
run 20 "$fixture/vol"
if [ "$rc" -eq 2 ] && grep -q 'df failed' <<<"$out"; then ok "a failing df exits 2"
else bad "a failing df exits 2" "rc=$rc $out"; fi

fake_df_raw 'exit 0'
run 20 "$fixture/vol"
if [ "$rc" -eq 2 ]; then ok "an empty df report exits 2"
else bad "an empty df report exits 2" "rc=$rc $out"; fi

fake_df_raw 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x - - - - /\n"'
run 20 "$fixture/vol"
if [ "$rc" -eq 2 ] && grep -q 'cannot parse' <<<"$out"; then ok "an unparseable df report exits 2"
else bad "an unparseable df report exits 2" "rc=$rc $out"; fi

fake_df_raw 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/a 9 1 99999999999 1%% /\n/dev/b 9 1 99999999999 1%% /x\n"'
run 20 "$fixture/vol"
if [ "$rc" -eq 2 ]; then ok "a report with more than one data line exits 2"
else bad "a report with more than one data line exits 2" "rc=$rc $out"; fi

fake_df_raw 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/a 9 1 99999999999999999999 1%% /\n"'
run 20 "$fixture/vol"
if [ "$rc" -eq 2 ]; then ok "an implausibly large free figure exits 2 instead of wrapping"
else bad "an implausibly large free figure exits 2 instead of wrapping" "rc=$rc $out"; fi

# #3681 review: a name that itself looks like the columns must not be read as the columns.
fake_df_raw 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\nmap 1 2 999999999 1%% /name 500000000 499000000 1024 99%% /\n"'
run 20 "$fixture/vol"
if [ "$rc" -eq 2 ] && grep -q "ambiguous" <<<"$out"; then ok "a data line with two column runs exits 2"
else bad "a data line with two column runs exits 2" "rc=$rc $out"; fi

# #3681 review: an abort after the measurement (here the verdict cannot be written) is
# UNKNOWN, never the 1 that errexit would otherwise report as a LOW verdict.
fake_df $((25 * GB))
out=$(PATH="$fixture/bin:$PATH" bash "$impl" 20 "$fixture/vol" 2>&1 >&-); rc=$?
if [ "$rc" -eq 2 ] && grep -q "aborted before finishing" <<<"$out"; then ok "a verdict that cannot be written exits 2"
else bad "a verdict that cannot be written exits 2" "rc=$rc $out"; fi

fake_df $((25 * GB))
run 20 "$fixture/does-not-exist"
if [ "$rc" -eq 2 ] && grep -q 'not a directory' <<<"$out"; then ok "a missing path exits 2"
else bad "a missing path exits 2" "rc=$rc $out"; fi

run 20 "$fixture/vol" extra
if [ "$rc" -eq 2 ]; then ok "an extra argument exits 2"
else bad "an extra argument exits 2" "rc=$rc $out"; fi

# --- the real df: the default path is this checkout's volume -----------------------
out=$(bash "$impl" 0 2>&1); rc=$?
repo_root=$(cd "$script_dir/../.." && pwd -P)
if [ "$rc" -eq 0 ] && grep -qF "volume holding $repo_root (threshold 0 GB)" <<<"$out"; then
  ok "with the real df, the default path is the checkout and a 0 GB threshold passes"
else
  bad "with the real df, the default path is the checkout and a 0 GB threshold passes" "rc=$rc $out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
