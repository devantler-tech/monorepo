#!/usr/bin/env bash
#
# Self-test for branch-cleanup.sh MODE / manifest contract (monorepo#2252):
#   - apply mode records then deletes
#   - dry-run leaves the manifest byte-identical (the bug this issue closes)
#   - an unrecognised MODE exits non-zero
# Hermetic: local bare "origin" + stubbed `gh` on PATH. No network.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/branch-cleanup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "yes" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name${detail:+ — $detail}"
    fail=1
  fi
}

# Stub gh: open heads + PR evidence come from fixture files the test writes.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state=""; head=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) state="$2"; shift 2 ;;
    --head) head="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$state" == "open" && -n "$head" ]]; then
  if grep -Fxq "$head" "${OPEN_HEADS_FILE:-/dev/null}" 2>/dev/null; then
    echo 1
  else
    echo 0
  fi
  exit 0
fi
if [[ "$state" == "open" ]]; then
  cat "${OPEN_HEADS_FILE:-/dev/null}"
  exit 0
fi
if [[ "$state" == "all" ]]; then
  cat "${PR_EVIDENCE_FILE:-/dev/null}"
  exit 0
fi
echo "unexpected gh invocation" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# Build a clone with a local bare origin so `git fetch` / `git push` stay offline.
# CI runners have no default git identity — set one on the work clone before any commit.
bare="$tmp/origin.git"
work="$tmp/work"
git init --bare --quiet "$bare"
git clone --quiet "$bare" "$work"
git -C "$work" config user.email "branch-cleanup-test@example.com"
git -C "$work" config user.name "branch-cleanup-test"
git -C "$work" checkout -b main
git -C "$work" commit --allow-empty -m "main" >/dev/null
git -C "$work" push -u origin main >/dev/null
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

mk_spent_local() {
  local name="$1"
  git -C "$work" checkout -B "$name" main >/dev/null
  git -C "$work" commit --allow-empty -m "tip $name" >/dev/null
  # Push so the tip is reachable from a remote ref (local delete gate).
  git -C "$work" push -u origin "$name" >/dev/null
  git -C "$work" rev-parse "$name"
}

export OPEN_HEADS_FILE="$tmp/open_heads"
export PR_EVIDENCE_FILE="$tmp/pr_evidence"
: >"$OPEN_HEADS_FILE"
: >"$PR_EVIDENCE_FILE"

# --- 1. Unrecognised MODE exits non-zero ---------------------------------
out="$("$helper" "$work" "monorepo" "$tmp/m-bad" report 2>&1)" && rc=0 || rc=$?
report "unrecognised MODE exits 1" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "unrecognised MODE names the bad value" \
  "$(grep -Fq "got 'report'" <<<"$out" && echo yes || echo no)"

# --- 2. dry-run leaves the manifest byte-identical -----------------------
spent_sha=$(mk_spent_local "claude/spent-dry-run-2252")
git -C "$work" checkout main >/dev/null
# MERGED evidence matching the tip so the branch is eligible for deletion.
printf '%s\tMERGED\t%s\n' "claude/spent-dry-run-2252" "$spent_sha" >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest-dry"
printf 'seed-row\n' >"$manifest"
before=$(cksum "$manifest")
out="$("$helper" "$work" "monorepo" "$manifest" dry-run 2>&1)" && rc=0 || rc=$?
after=$(cksum "$manifest")
report "dry-run exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "dry-run leaves manifest byte-identical" \
  "$([[ "$before" == "$after" ]] && echo yes || echo no)" "before=$before after=$after"
report "dry-run still counts the would-delete locally" \
  "$(grep -qE 'local: -1[[:space:]]' <<<"$out" && echo yes || echo no)" "out=$out"
report "dry-run did not delete the local branch" \
  "$(git -C "$work" rev-parse --verify --quiet "refs/heads/claude/spent-dry-run-2252" >/dev/null && echo yes || echo no)"

# --- 3. apply mode records then deletes ----------------------------------
# Reuse the same spent branch (still present after dry-run).
manifest="$tmp/manifest-apply"
: >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" apply 2>&1)" && rc=0 || rc=$?
report "apply exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "apply deleted the local branch" \
  "$(git -C "$work" rev-parse --verify --quiet "refs/heads/claude/spent-dry-run-2252" >/dev/null && echo no || echo yes)"
report "apply recorded the local deletion sha in the manifest" \
  "$(grep -Fq $'monorepo\tlocal\tclaude/spent-dry-run-2252\t'"$spent_sha" "$manifest" && echo yes || echo no)"

if [[ "$fail" -ne 0 ]]; then
  echo "branch-cleanup MODE contract: FAILED"
  exit 1
fi
echo "branch-cleanup MODE contract: all assertions passed"
