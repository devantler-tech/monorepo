#!/usr/bin/env bash
#
# Self-test for board-add.sh — the point of that script is that it VERIFIES the
# Status landed rather than trusting an exit code, so the test that matters is
# the RED one: a board that silently keeps the old Status must make the script
# FAIL. A read-back guard nobody has watched fail is indistinguishable from no
# guard at all (measured 2026-07-19: 9 status-less items reached the board
# because a two-step add half-completed and still looked successful).
#
# All GitHub access is stubbed by a fake `gh` on PATH — no network, no live
# board touched. The stub is driven by env vars so one stub covers every case.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/board-add.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

check() { # check <name> <expected-exit> <actual-exit> [haystack] [needle]
  local name="$1" want="$2" got="$3" hay="${4:-}" needle="${5:-}"
  if [ "$want" != "$got" ]; then
    printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$want" "$got" >&2
    fail=$((fail + 1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$hay" | grep -qF "$needle"; then
    printf 'FAIL %s: output missing %q\n  got: %s\n' "$name" "$needle" "$hay" >&2
    fail=$((fail + 1)); return
  fi
  printf 'ok   %s\n' "$name"
  pass=$((pass + 1))
}

# ── the fake gh ────────────────────────────────────────────────────────────
# Behaviour knobs (env): STUB_PRIVATE, STUB_READBACK, STUB_ADD_ID, STUB_EDIT_RC
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2:-}" in
  "api graphql")  printf '%s\n' "${STUB_READBACK-📥 Backlog}" ;;
  "api repos"*|"api "*)
                  # repos/<o>/<r> visibility probe
                  printf '%s\n' "${STUB_PRIVATE:-false}" ;;
  "project view") [ "${STUB_FAIL_ON:-}" = "project view" ] && exit 1
                  printf '{"id":"PVT_test","number":5}\n' ;;
  "project field-list")
                  [ "${STUB_FAIL_ON:-}" = "project field-list" ] && exit 1
                  cat <<'JSON'
{"fields":[{"id":"PVTSSF_test","name":"Status","options":[
  {"id":"opt_done","name":"✅ Done"},
  {"id":"opt_ready","name":"🫴 Ready"},
  {"id":"opt_backlog","name":"📥 Backlog"}]}]}
JSON
                  ;;
  "project item-add")
                  [ "${STUB_FAIL_ON:-}" = "project item-add" ] && exit 1
                  # NOTE `-` not `:-`: the empty-id case is set-but-empty, and
                  # `:-` would substitute the default and silently skip the test.
                  printf '{"id":"%s"}\n' "${STUB_ADD_ID-PVTI_test}" ;;
  "project item-edit")
                  exit "${STUB_EDIT_RC:-0}" ;;
  *)              printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 99 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

URL="https://github.com/devantler-tech/example/issues/1"
run() { set +e; out=$("$script" "$@" 2>&1); rc=$?; set -e; }

# ── GREEN: the happy path actually succeeds ────────────────────────────────
STUB_READBACK="📥 Backlog" run "$URL"
check "green: default status verified" 0 "$rc" "$out" "[verified]"

STUB_READBACK="🫴 Ready" run "$URL" "🫴 Ready"
check "green: explicit status verified" 0 "$rc" "$out" "🫴 Ready"

# ── RED: the guard must FAIL when the board disagrees ──────────────────────
# This is the defect the script exists to catch: item-edit exits 0, the board
# still shows something else. Without this arm the read-back could be deleted
# and every test above would stay green.
STUB_READBACK="🧊 Icebox" run "$URL" "🫴 Ready"
check "RED: wrong status on board is caught" 2 "$rc" "$out" "read-back MISMATCH"

# The most dangerous shape: status never landed at all (empty read-back) —
# exactly the 9 status-less items measured on 2026-07-19.
STUB_READBACK="" run "$URL"
check "RED: absent status is caught" 2 "$rc" "$out" "read-back MISMATCH"

# ── OPERATIONAL failures keep exit 2 AND print a diagnostic ────────────────
# Under `set -euo pipefail` a failing gh aborts the assignment itself, so the
# script used to die before its own check ran: exit 1 (the code documented for
# USAGE errors) with stderr discarded, i.e. silent. Codex P2 on #2281, RED-proven
# before the fix. One arm per metadata lookup — the defect was a class of three,
# not one line.
for stage in "project view" "project field-list" "project item-add"; do
  STUB_FAIL_ON="$stage" run "$URL"
  check "operational failure in '$stage' → exit 2" 2 "$rc"
  check "operational failure in '$stage' → diagnostic" 2 "$rc" "$out" "board-add:"
done

# ── FAIL-CLOSED paths ──────────────────────────────────────────────────────
STUB_PRIVATE=true run "$URL"
check "private repo refused (public board)" 2 "$rc" "$out" "is PRIVATE"

STUB_EDIT_RC=1 run "$URL"
check "item-edit failure surfaces" 2 "$rc" "$out" "item-edit failed"

STUB_ADD_ID="" run "$URL"
check "empty item id surfaces" 2 "$rc" "$out" "no item id"

run "$URL" "Not A Status"
check "unknown status rejected with valid list" 1 "$rc" "$out" "unknown status"

run "ftp://example.com/nope"
check "non-issue URL rejected" 1 "$rc" "$out" "not an issue URL"

run
check "no args prints usage" 1 "$rc" "$out" "usage:"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
