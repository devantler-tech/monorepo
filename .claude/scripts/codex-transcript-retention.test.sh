#!/usr/bin/env bash
# Contract tests for codex-transcript-retention.sh (monorepo#4136).
#
# Every case runs against a fixture Codex home and a fake open-file lister, so no assertion
# depends on, or touches, the real ~/.codex of the machine running the tests. The properties
# that matter most are the fail-closed ones: a file still open, a file not shaped like a
# transcript, a symbolic link, a young file and an unreadable open-file list must all survive.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="${script_dir}/codex-transcript-retention.sh"

pass=0
failures=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

fixture=$(mktemp -d) || { printf 'cannot create a fixture directory\n' >&2; exit 2; }
test_run_completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf -- "$fixture"
  if [ "${test_run_completed}" != 1 ]; then
    echo "codex-transcript-retention.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT
# Physical path: on macOS mktemp answers under /var, which is /private/var, and a real lsof
# names open files by the physical path.
fixture=$(cd -P -- "$fixture" && pwd -P) || exit 2

home="$fixture/codex"
bin="$fixture/bin"
mkdir -p "$home/sessions/2026/09/01" "$home/archived_sessions" "$bin"

# age <path> <days> sets a file's modification time that many days back.
age() {
  local stamp
  stamp=$(date -v-"$2"d +%Y%m%d%H%M 2>/dev/null || date -d "$2 days ago" +%Y%m%d%H%M)
  touch -h -t "$stamp" "$1"
}

# fake_lsof <path>... writes an lsof that reports exactly these paths as open.
fake_lsof() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "p1\\n"\n'
    for p in "$@"; do printf 'printf "n%%s\\n" %q\n' "$p"; done
  } > "$bin/lsof"
  chmod +x "$bin/lsof"
}

seed() {
  rm -rf -- "$home/sessions" "$home/archived_sessions"
  mkdir -p "$home/sessions/2026/09/01" "$home/archived_sessions"
  old_live="$home/sessions/2026/09/01/rollout-2026-09-01T00-00-00-old.jsonl"
  old_arch="$home/archived_sessions/rollout-2026-09-01T00-00-00-old.jsonl.zst"
  young_arch="$home/archived_sessions/rollout-2026-10-14T00-00-00-young.jsonl.zst"
  open_arch="$home/archived_sessions/rollout-2026-09-02T00-00-00-open.jsonl.zst"
  other="$home/archived_sessions/notes-old.txt"
  spaced="$home/archived_sessions/rollout-2026-09-03 spaced.jsonl"
  for f in "$old_live" "$old_arch" "$young_arch" "$open_arch" "$other" "$spaced"; do
    printf 'x\n' > "$f"
  done
  link="$home/archived_sessions/rollout-2026-09-04T00-00-00-link.jsonl"
  ln -s "$old_arch" "$link"
  for f in "$old_live" "$old_arch" "$open_arch" "$other" "$spaced" "$link"; do age "$f" 30; done
  age "$young_arch" 2
}

run() { # [args...] -> sets out, rc
  out=$(CODEX_TRANSCRIPT_RETENTION_HOME="$home" CODEX_TRANSCRIPT_RETENTION_LSOF="$bin/lsof" \
    bash "$impl" "$@" 2>&1)
  rc=$?
}

printf 'codex-transcript-retention.sh contract tests\n'

# --- dry-run removes nothing --------------------------------------------------------
seed
fake_lsof "$open_arch"
run dry-run 14
if [ "$rc" = 0 ] && [ -e "$old_live" ] && [ -e "$old_arch" ] && grep -q 'would remove=3' <<<"$out"; then
  ok 'dry-run counts the three old, closed transcripts and deletes nothing'
else
  bad 'dry-run' "rc=$rc out=$out"
fi

# --- apply removes exactly the old, closed transcripts ------------------------------
run apply 14
if [ "$rc" = 0 ] && [ ! -e "$old_live" ] && [ ! -e "$old_arch" ] && [ ! -e "$spaced" ]; then
  ok 'apply removes old closed transcripts in sessions/ and archived_sessions/, spaces included'
else
  bad 'apply removes old transcripts' "rc=$rc out=$out"
fi
if [ -e "$young_arch" ]; then ok 'a transcript younger than the age line is kept'; else bad 'young kept' "$out"; fi
if [ -e "$open_arch" ]; then ok 'a transcript a process holds open is kept'; else bad 'open kept' "$out"; fi
if grep -q 'kept_open=1' <<<"$out"; then ok 'the open transcript is reported as kept_open'; else bad 'kept_open count' "$out"; fi
if [ -e "$other" ]; then ok 'a file not named like a transcript is kept'; else bad 'non-transcript kept' "$out"; fi
if [ -L "$link" ]; then ok 'a symbolic link is never removed'; else bad 'symlink kept' "$out"; fi

# --- a home reached through a linked parent still recognises open files ------------
seed
fake_lsof "$open_arch"
ln -s "$fixture" "$fixture.alias"
out=$(CODEX_TRANSCRIPT_RETENTION_HOME="$fixture.alias/codex" CODEX_TRANSCRIPT_RETENTION_LSOF="$bin/lsof" \
  bash "$impl" apply 14 2>&1)
rc=$?
rm -f "$fixture.alias"
if [ "$rc" = 0 ] && [ -e "$open_arch" ] && [ ! -e "$old_arch" ]; then
  ok 'through a linked parent path, an open transcript (named by its physical path) is kept'
else
  bad 'linked parent path keeps open file' "rc=$rc out=$out"
fi

# --- an unreadable open-file list removes nothing -----------------------------------
seed
printf '#!/usr/bin/env bash\nexit 3\n' > "$bin/lsof"
chmod +x "$bin/lsof"
run apply 14
if [ "$rc" = 2 ] && [ -e "$old_live" ] && [ -e "$old_arch" ] && grep -q 'UNKNOWN' <<<"$out"; then
  ok 'a failed open-file list exits 2 and removes nothing'
else
  bad 'failed lsof fails closed' "rc=$rc out=$out"
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/lsof"
run apply 14
if [ "$rc" = 2 ] && [ -e "$old_arch" ]; then
  ok 'an empty open-file list exits 2 and removes nothing'
else
  bad 'empty lsof fails closed' "rc=$rc out=$out"
fi

# --- a root that is a symbolic link is refused --------------------------------------
seed
fake_lsof
mv "$home/archived_sessions" "$fixture/elsewhere"
ln -s "$fixture/elsewhere" "$home/archived_sessions"
run apply 14
if [ "$rc" = 2 ] && [ -e "$fixture/elsewhere/rollout-2026-09-01T00-00-00-old.jsonl.zst" ]; then
  ok 'a symlinked archived_sessions root is refused and nothing in it is removed'
else
  bad 'symlinked root refused' "rc=$rc out=$out"
fi
rm -f "$home/archived_sessions"
rm -rf "$fixture/elsewhere"

# --- usage errors ------------------------------------------------------------------
for args in 'apply 6' 'apply 0' 'apply 08x' 'apply 123456' 'delete 14'; do
  # shellcheck disable=SC2086 # Each case is two words on purpose.
  run $args
  if [ "$rc" = 2 ]; then ok "rejects: $args"; else bad "rejects: $args" "rc=$rc out=$out"; fi
done
seed
fake_lsof
run apply 014
if [ "$rc" = 0 ] && [ ! -e "$old_arch" ]; then
  ok 'a leading zero is read as decimal (014 = 14 days), not octal'
else
  bad 'leading zero decimal' "rc=$rc out=$out"
fi

# --- no Codex home is a clean no-op -------------------------------------------------
out=$(CODEX_TRANSCRIPT_RETENTION_HOME="$fixture/absent" CODEX_TRANSCRIPT_RETENTION_LSOF="$bin/lsof" \
  bash "$impl" apply 14 2>&1)
rc=$?
if [ "$rc" = 0 ] && grep -q 'no Codex home' <<<"$out"; then
  ok 'a host without a Codex home exits 0 and says so'
else
  bad 'absent home' "rc=$rc out=$out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$failures"
test_run_completed=1
[ "$failures" -eq 0 ]
