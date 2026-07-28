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

# --- 6. repo_path that is not its own git toplevel is REFUSED -------------
# monorepo#2531: an uninitialised submodule directory is empty, so `cd` succeeds
# and git resolves UPWARD to the parent repository. The sweep then deletes from
# the parent's tree while the keep-set is fetched for <slug> — the safety
# contract's central promise evaluated against the wrong repository.
mkdir -p "$work/applications/uninitialised-submodule"
: >"$OPEN_HEADS_FILE"
: >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest6"
: >"$manifest"
out="$("$helper" "$work/applications/uninitialised-submodule" "ksail" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "path that resolves upward to a parent repo is refused (exit 2)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"
report "refusal names the repository-root mismatch" \
  "$(grep -qi 'repository root' <<<"$out" && echo yes || echo no)" "out=$out"
report "refusal happened before any sweep output" \
  "$(grep -q 'ns=claude' <<<"$out" && echo no || echo yes)" "out=$out"

# --- 7. slug that disagrees with the checkout's origin is REFUSED ---------
# Same defect class, caught by the other half: the tree IS its own toplevel, but
# it is not the repository the keep-set will be fetched for. Origin is a
# non-existent GitHub repo so that a REGRESSION fails fast at the fetch instead
# of pulling a real repository over the network.
slugwork="$tmp/slugwork"
git clone --quiet "$bare" "$slugwork"
git -C "$slugwork" remote set-url origin "https://github.com/devantler-tech/does-not-exist-2531.git"
manifest="$tmp/manifest7"
: >"$manifest"
out="$("$helper" "$slugwork" "ksail" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "slug that disagrees with origin is refused (exit 2)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"
report "slug refusal names both the slug and the origin repo" \
  "$(grep -q 'ksail' <<<"$out" && grep -q 'does-not-exist-2531' <<<"$out" && echo yes || echo no)" "out=$out"

# --- 7b. an UPPERCASE GitHub host must not slip past the identity check ---
# Hostnames are case-insensitive, so a case-sensitive host match would leave
# origin unparsed and skip the slug comparison entirely — a silent bypass.
git -C "$slugwork" remote set-url origin "https://GitHub.com/devantler-tech/does-not-exist-2531.git"
manifest="$tmp/manifest7b"
: >"$manifest"
out="$("$helper" "$slugwork" "ksail" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "uppercase-host origin is still identity-checked (exit 2)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"

# --- 7c. an explicit port must NOT be read as part of the owner -----------
# ":443/owner/repo" must reduce to "owner/repo". If the port leaked into the
# comparison the guard would REJECT a correct repository. Slug matches the
# origin here, so a correct parse passes the guard and fails later at the fetch
# (exit 1) — proving the guard let it through without needing the network.
git -C "$slugwork" remote set-url origin "https://github.com:443/devantler-tech/does-not-exist-2531.git"
manifest="$tmp/manifest7c"
: >"$manifest"
out="$("$helper" "$slugwork" "does-not-exist-2531" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "explicit port does not falsely reject a matching repo (not exit 2)" \
  "$([[ ${rc:-0} -ne 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"

# --- 8. a non-GitHub origin still runs (hermetic clones must keep working) -
# The origin-vs-slug half can only compare when origin parses as a GitHub
# owner/repo. A local bare origin cannot, so it is skipped there — the
# toplevel half above still covers the silent walk-upward class.
: >"$OPEN_HEADS_FILE"
: >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest8"
: >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "non-GitHub origin does not trip the slug guard" \
  "$([[ ${rc:-0} -eq 0 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"

# Silence unused-var lint for the open_sha we only needed for push tip creation.
: "$open_sha" "$local_sha"

if [[ "$fail" -ne 0 ]]; then
  echo "branch-cleanup contract: FAILED"
  exit 1
fi
echo "branch-cleanup contract: all assertions passed"
