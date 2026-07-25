#!/usr/bin/env bash
#
# Self-test for branch-cleanup.sh — proves namespace parameterisation (monorepo#2298):
#   - a live cursor/* branch whose OPEN PR is in the keep-set SURVIVES a cursor sweep
#   - a spent cursor/* branch with SHA-matched MERGED PR evidence is REAPED remotely
#   - local deletion stays claude-only (cursor sweep never deletes local refs)
#   - codex namespace is refused
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
# Args vary; key on --state and --head.
state=""; head=""; json=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) state="$2"; shift 2 ;;
    --head) head="$2"; shift 2 ;;
    --json) json="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$state" == "open" && -n "$head" ]]; then
  # Per-branch open recheck: length 0 unless head is listed in OPEN_HEADS.
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

mk_remote_branch() {
  local name="$1"
  git -C "$work" checkout -B "$name" main >/dev/null
  git -C "$work" commit --allow-empty -m "tip $name" >/dev/null
  git -C "$work" push -u origin "$name" >/dev/null
  git -C "$work" rev-parse "$name"
}

# --- 1. Open-PR cursor branch survives ------------------------------------
open_sha=$(mk_remote_branch "cursor/open-pr-survives-2298")
git -C "$work" checkout main >/dev/null
export OPEN_HEADS_FILE="$tmp/open_heads"
export PR_EVIDENCE_FILE="$tmp/pr_evidence"
printf '%s\n' "cursor/open-pr-survives-2298" >"$OPEN_HEADS_FILE"
# Even MERGED evidence must not override an OPEN keep — but we give OPEN only.
: >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest1"
: >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" apply cursor 2>&1)" && rc=0 || rc=$?
report "cursor sweep with open PR exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "open cursor/* remote ref still exists" \
  "$(git -C "$bare" show-ref --verify --quiet "refs/heads/cursor/open-pr-survives-2298" && echo yes || echo no)"
report "open-PR survival wrote no remote deletion to manifest" \
  "$(grep -q $'\tremote\tcursor/open-pr-survives-2298\t' "$manifest" && echo no || echo yes)"

# --- 2. Spent cursor/* with SHA-matched MERGED evidence is reaped ---------
spent_sha=$(mk_remote_branch "cursor/spent-merged-2298")
git -C "$work" checkout main >/dev/null
: >"$OPEN_HEADS_FILE"
# gh --jq already shapes rows as name\tstate\toid — stub emits that shape directly.
printf '%s\tMERGED\t%s\n' "cursor/spent-merged-2298" "$spent_sha" >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest2"
: >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" apply cursor 2>&1)" && rc=0 || rc=$?
report "cursor sweep of spent branch exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "spent cursor/* remote ref was deleted" \
  "$(git -C "$bare" show-ref --verify --quiet "refs/heads/cursor/spent-merged-2298" && echo no || echo yes)"
report "manifest recorded the remote deletion sha" \
  "$(grep -Fq $'monorepo\tremote\tcursor/spent-merged-2298\t'"$spent_sha"$'\tMERGED' "$manifest" && echo yes || echo no)"

# --- 3. cursor sweep does not delete local refs ---------------------------
# Create a local-only cursor branch (no remote) — cursor namespace must leave local alone.
git -C "$work" checkout -B "cursor/local-only-2298" main >/dev/null
git -C "$work" commit --allow-empty -m "local only" >/dev/null
git -C "$work" checkout main >/dev/null
local_sha=$(git -C "$work" rev-parse "cursor/local-only-2298")
: >"$OPEN_HEADS_FILE"
: >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest3"
: >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" apply cursor 2>&1)" && rc=0 || rc=$?
report "cursor sweep leaves local-only cursor/* intact" \
  "$(git -C "$work" rev-parse --verify --quiet "refs/heads/cursor/local-only-2298" >/dev/null && echo yes || echo no)"
report "cursor sweep wrote no local deletion for that branch" \
  "$(grep -q $'\tlocal\tcursor/local-only-2298\t' "$manifest" && echo no || echo yes)"

# --- 4. codex namespace refused -------------------------------------------
out="$("$helper" "$work" "monorepo" "$tmp/m4" apply codex 2>&1)" && rc=0 || rc=$?
report "codex namespace is refused (exit 2)" "$([[ $rc -eq 2 ]] && echo yes || echo no)" "rc=$rc"
report "codex refusal names the sibling ownership" \
  "$(grep -qi 'codex' <<<"$out" && echo yes || echo no)"

# --- 5. default namespace still lists claude locally (smoke) --------------
# Ensure invoking without namespace arg does not error on an empty claude set.
: >"$OPEN_HEADS_FILE"
: >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest5"
: >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" dry-run 2>&1)" && rc=0 || rc=$?
report "default (claude) dry-run exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "default dry-run reports ns=claude" \
  "$(grep -q 'ns=claude' <<<"$out" && echo yes || echo no)"

# Silence unused-var lint for the open_sha we only needed for push tip creation.
: "$open_sha" "$local_sha"

if [[ "$fail" -ne 0 ]]; then
  echo "branch-cleanup contract: FAILED"
  exit 1
fi
echo "branch-cleanup contract: all assertions passed"
