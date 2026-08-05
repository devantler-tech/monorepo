#!/usr/bin/env bash
#
# Self-test for branch-cleanup.sh — proves namespace parameterisation (monorepo#2298)
# and the MODE / manifest contract (monorepo#2252 / #2255):
#   - a live cursor/* branch whose OPEN PR is in the keep-set SURVIVES a cursor sweep
#   - a spent cursor/* branch with SHA-matched MERGED PR evidence is REAPED remotely
#   - local deletion stays claude-only (cursor sweep never deletes local refs)
#   - codex namespace is refused
#   - unrecognised MODE exits non-zero
#   - dry-run leaves the manifest byte-identical (and still reports would-delete counts)
#   - apply mode records then deletes
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

# These fixtures use a local bare "origin", which cannot be tied to a slug, so an
# apply-mode sweep refuses to run against them. Declaring the fixture explicitly
# is what keeps that refusal fail-closed in production while the offline tests
# still exercise the real deletion paths. Test 9 unsets it to prove the refusal.
export BRANCH_CLEANUP_ALLOW_UNVERIFIABLE_ORIGIN=1

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

# --- 7a. an OWNER-QUALIFIED slug must be diagnosable ----------------------
# <slug> is a BARE repo name; the helper prepends `devantler-tech/`. Passing the
# owner-qualified form — the shape `gh -R` takes everywhere, so the likely
# mistake — resolves to `devantler-tech/devantler-tech/<repo>` and is correctly
# refused. But the message printed the RAW argument next to the parsed origin,
# so for a slug whose repo half is right it rendered as a contradiction:
#   slug 'devantler-tech/x' does not match the checkout ... whose origin is 'devantler-tech/x'
# Identical strings, no stated reason — the reader cannot see that a second
# owner was prepended. The refusal must name the value actually COMPARED.
git -C "$slugwork" remote set-url origin "https://github.com/devantler-tech/does-not-exist-2531.git"
manifest="$tmp/manifest7a"
: >"$manifest"
out="$("$helper" "$slugwork" "devantler-tech/does-not-exist-2531" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "owner-qualified slug is refused (exit 2)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"
report "owner-qualified refusal names the RESOLVED slug, not just the raw argument" \
  "$(grep -q 'devantler-tech/devantler-tech/does-not-exist-2531' <<<"$out" && echo yes || echo no)" "out=$out"

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
# ":443/owner/repo" must reduce to "owner/repo"; a leaked port would make the
# parsed owner "443/devantler-tech", so a correct repository would be rejected.
# The slug is deliberately WRONG so the guard aborts and prints what it parsed:
# that asserts the port was stripped without letting the sweep reach the network.
git -C "$slugwork" remote set-url origin "https://github.com:443/devantler-tech/does-not-exist-2531.git"
manifest="$tmp/manifest7c"
: >"$manifest"
out="$("$helper" "$slugwork" "ksail" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "explicit port is stripped from the parsed origin" \
  "$(grep -qF "is 'devantler-tech/does-not-exist-2531'" <<<"$out" && echo yes || echo no)" "out=$out"

# --- 7d. credentials in the origin URL never reach the message -----------
# Userinfo can itself contain the host ("https://github.com:TOKEN@github.com/..."),
# so a parser that searched for the FIRST "github.com" would keep the token in
# the value it prints. The guard must report owner/repo only.
git -C "$slugwork" remote set-url origin \
  "https://github.com:s3kr3t-fixture-token@github.com/devantler-tech/does-not-exist-2531.git"
manifest="$tmp/manifest7d"
: >"$manifest"
out="$("$helper" "$slugwork" "ksail" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "credentialed origin is parsed to owner/repo, not the userinfo" \
  "$(grep -qF "is 'devantler-tech/does-not-exist-2531'" <<<"$out" && echo yes || echo no)" "out=$out"
report "credentialed origin never echoes the secret" \
  "$(grep -qF 's3kr3t-fixture-token' <<<"$out" && echo no || echo yes)"

# --- 7g. a credential in the QUERY never reaches the log -------------------
# A query/fragment can carry a token, and left attached it also defeats the .git
# strip — so the comparison fails and the mismatch message prints the token.
git -C "$slugwork" remote set-url origin \
  "https://github.com/devantler-tech/does-not-exist-2531.git?access_token=s3kr3t-query-token"
manifest="$tmp/manifest7g"
: >"$manifest"
out="$("$helper" "$slugwork" "ksail" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "a query-string credential never reaches the output" \
  "$(grep -qF 's3kr3t-query-token' <<<"$out" && echo no || echo yes)" "out=$out"
report "the query is stripped, leaving a clean owner/repo" \
  "$(grep -qF "is 'devantler-tech/does-not-exist-2531'" <<<"$out" && echo yes || echo no)" "out=$out"

# --- 7h. file:// is NOT a GitHub origin ------------------------------------
# git treats file:// as a LOCAL transport, so `file://github.com/devantler-tech/x`
# resolves to /devantler-tech/x on disk. Accepting it as GitHub would sweep a
# local repository against GitHub's PR evidence. It must read as unverifiable —
# which dry-run tolerates and apply refuses.
git -C "$slugwork" remote set-url origin "file://github.com/devantler-tech/does-not-exist-2531"
manifest="$tmp/manifest7h"
: >"$manifest"
out="$(env -u BRANCH_CLEANUP_ALLOW_UNVERIFIABLE_ORIGIN \
        "$helper" "$slugwork" "does-not-exist-2531" "$manifest" apply claude 2>&1)" && rc=0 || rc=$?
report "a file:// origin is not accepted as GitHub (apply refused)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"
report "the file:// refusal is the unverifiable-origin one, not a slug match" \
  "$(grep -qF 'no GitHub origin' <<<"$out" && echo yes || echo no)" "out=$out"

# NOTE — the repository-root check compares filesystem identity (`-ef`) rather
# than strings, so two spellings of one directory cannot abort a valid sweep.
# There is deliberately NO assertion for it: on this host `cd "$cased" && pwd -P`
# returns the canonical on-disk casing, so the caller's casing never survives to
# diverge from git's, and every candidate test passed against the OLD string
# compare too. An assertion that cannot fail is worse than none — it reads as
# proof. `-ef` ships as a correctness improvement, unproven by test.
git -C "$slugwork" remote set-url origin "https://github.com/devantler-tech/does-not-exist-2531.git"

# --- 7e. a diverging PUSH destination is refused ---------------------------
# The keep-set is fetched from the fetch url, but `git push origin --delete`
# writes to the push url. With `remote.origin.pushurl` set they are different
# repositories, so a fetch-url-only check would authorise deletions in a repo the
# evidence never described. Fetch url matches the slug here, so ONLY the push url
# can trigger the refusal.
git -C "$slugwork" remote set-url origin "https://github.com/devantler-tech/does-not-exist-2531.git"
git -C "$slugwork" remote set-url --push origin "https://github.com/devantler-tech/some-other-repo.git"
manifest="$tmp/manifest7e"
: >"$manifest"
out="$("$helper" "$slugwork" "does-not-exist-2531" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "a diverging push destination is refused (exit 2)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"
report "the refusal names the push destination, not the fetch origin" \
  "$(grep -qF 'push destination' <<<"$out" && grep -qF 'some-other-repo' <<<"$out" && echo yes || echo no)" "out=$out"

# --- 7f. a pushInsteadOf rewrite is refused too ----------------------------
# `pushInsteadOf` redirects the push without touching either configured url, and
# `get-url --push --all` is what resolves it — so the same check must catch it.
git -C "$slugwork" remote set-url --push --delete "https://github.com/devantler-tech/some-other-repo.git" 2>/dev/null \
  || git -C "$slugwork" config --unset-all remote.origin.pushurl 2>/dev/null || true
git -C "$slugwork" config url."https://github.com/somewhere-else/".pushInsteadOf "https://github.com/devantler-tech/"
manifest="$tmp/manifest7f"
: >"$manifest"
out="$("$helper" "$slugwork" "does-not-exist-2531" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "a pushInsteadOf rewrite is refused (exit 2)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"
report "the pushInsteadOf refusal names the rewritten destination" \
  "$(grep -qF 'somewhere-else' <<<"$out" && echo yes || echo no)" "out=$out"
git -C "$slugwork" config --unset url."https://github.com/somewhere-else/".pushInsteadOf

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

# --- 9. an unverifiable origin FAILS CLOSED for a destructive sweep -------
# Check (a) proves the tree is a repository root, but a non-GitHub origin ties it
# to no slug — while the keep-set is still fetched for devantler-tech/<slug>. A
# wrong slug there deletes local branches outright and CLOSES the PR of any
# remote one, so apply mode must refuse unless a fixture declares itself.
# Every other test exports the fixture variable, so this one drops it.
: >"$OPEN_HEADS_FILE"
: >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest9"
: >"$manifest"
out="$(env -u BRANCH_CLEANUP_ALLOW_UNVERIFIABLE_ORIGIN \
        "$helper" "$work" "monorepo" "$manifest" apply claude 2>&1)" && rc=0 || rc=$?
report "apply against an unverifiable origin is refused (exit 2)" \
  "$([[ ${rc:-0} -eq 2 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"
report "the refusal names the unverifiable origin, not a slug mismatch" \
  "$(grep -qF 'no GitHub origin' <<<"$out" && echo yes || echo no)" "out=$out"
report "the refusal happened before any sweep output" \
  "$(grep -q 'ns=claude' <<<"$out" && echo no || echo yes)" "out=$out"

# dry-run over the SAME unverifiable origin still runs — the refusal is scoped to
# destruction, so the guard cannot be satisfied merely by the variable existing.
manifest="$tmp/manifest9b"
: >"$manifest"
out="$(env -u BRANCH_CLEANUP_ALLOW_UNVERIFIABLE_ORIGIN \
        "$helper" "$work" "monorepo" "$manifest" dry-run claude 2>&1)" && rc=0 || rc=$?
report "dry-run over the same unverifiable origin is unaffected" \
  "$([[ ${rc:-0} -eq 0 ]] && echo yes || echo no)" "rc=${rc:-0} out=$out"

# --- 10. Unrecognised MODE exits non-zero (monorepo#2252) ------------------
out="$("$helper" "$work" "monorepo" "$tmp/m-bad" report 2>&1)" && rc=0 || rc=$?
report "unrecognised MODE exits 1" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "unrecognised MODE names the bad value" \
  "$(grep -Fq "got 'report'" <<<"$out" && echo yes || echo no)"

# Explicit empty MODE must also abort — ${4:-apply} would silently treat "" as
# apply and delete; ${4-apply} only defaults when the arg is omitted.
out="$("$helper" "$work" "monorepo" "$tmp/m-empty" "" 2>&1)" && rc=0 || rc=$?
report "empty MODE exits 1" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "empty MODE names the empty value" \
  "$(grep -Fq "got ''" <<<"$out" && echo yes || echo no)"

# --- 11. dry-run leaves the manifest byte-identical (monorepo#2252) --------
# Spent claude/* tip reachable from remote + SHA-matched MERGED evidence so it
# is eligible for local AND remote delete counting under the default (claude)
# namespace.
spent_local_sha=$(mk_remote_branch "claude/spent-dry-run-2252")
git -C "$work" checkout main >/dev/null
: >"$OPEN_HEADS_FILE"
printf '%s\tMERGED\t%s\n' "claude/spent-dry-run-2252" "$spent_local_sha" >"$PR_EVIDENCE_FILE"
manifest="$tmp/manifest-dry"
printf 'seed-row\n' >"$manifest"
before=$(cksum "$manifest")
out="$("$helper" "$work" "monorepo" "$manifest" dry-run 2>&1)" && rc=0 || rc=$?
after=$(cksum "$manifest")
report "MODE dry-run exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "dry-run leaves manifest byte-identical" \
  "$([[ "$before" == "$after" ]] && echo yes || echo no)" "before=$before after=$after"
report "dry-run still counts the would-delete locally" \
  "$(grep -qE 'local: -1[[:space:]]' <<<"$out" && echo yes || echo no)" "out=$out"
report "dry-run still counts the would-delete remotely" \
  "$(grep -qE 'remote: -1[[:space:]]' <<<"$out" && echo yes || echo no)" "out=$out"
report "dry-run did not delete the local branch" \
  "$(git -C "$work" rev-parse --verify --quiet "refs/heads/claude/spent-dry-run-2252" >/dev/null && echo yes || echo no)"
report "dry-run did not delete the remote ref" \
  "$(git -C "$bare" show-ref --verify --quiet "refs/heads/claude/spent-dry-run-2252" && echo yes || echo no)"

# --- 12. apply mode records then deletes (monorepo#2252) -------------------
# Reuse the same spent branch (still present after dry-run).
manifest="$tmp/manifest-apply"
: >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" apply 2>&1)" && rc=0 || rc=$?
report "MODE apply exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc out=$out"
report "apply deleted the local branch" \
  "$(git -C "$work" rev-parse --verify --quiet "refs/heads/claude/spent-dry-run-2252" >/dev/null && echo no || echo yes)"
report "apply deleted the remote ref" \
  "$(git -C "$bare" show-ref --verify --quiet "refs/heads/claude/spent-dry-run-2252" && echo no || echo yes)"
report "apply recorded the local deletion sha in the manifest" \
  "$(grep -Fq $'monorepo\tlocal\tclaude/spent-dry-run-2252\t'"$spent_local_sha" "$manifest" && echo yes || echo no)"
report "apply recorded the remote deletion sha and MERGED status" \
  "$(grep -Fq $'monorepo\tremote\tclaude/spent-dry-run-2252\t'"$spent_local_sha"$'\tMERGED' "$manifest" && echo yes || echo no)"


# Silence unused-var lint for the open_sha we only needed for push tip creation.
: "$open_sha" "$local_sha"

# --- 13. the pre-delete worktree re-check must survive a realistic list -----
# monorepo#2674. The local delete loop re-reads `git worktree list --porcelain`
# immediately before `update-ref -d`, to catch a worktree that claimed the
# branch AFTER the keep-set snapshot. That predicate was a pipeline ending in
# `grep -Fxq`, and this script runs under `pipefail`: grep exits at the matching
# line, the still-writing `printf` takes SIGPIPE (141), and pipefail reports 141
# as the pipeline status — so a branch that IS checked out reads as checked out
# NOWHERE and gets deleted, leaving that worktree on a dangling HEAD.
#
# It is a SIZE-dependent failure, which is why it survived review: the predicate
# is correct for a one- or two-entry list and wrong from about five entries up.
# A `git` shim on PATH returns the real enumeration for the keep-set snapshot
# and a larger, later one for the re-check — exactly the race the re-check
# exists to cover, and the only way to isolate it from the primary keep-set.
wt_shim_dir="$tmp/wtshim"; mkdir -p "$wt_shim_dir"
real_git=$(command -v git)
cat >"$tmp/bin/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "worktree" ] && [ "\$2" = "list" ] && [ -n "\${WT_SHIM_STATE:-}" ]; then
  # The counter file is TRUNCATED (not written to 0) between arms, so the first
  # read yields the empty string — and \`[ "" -ge 1 ]\` is not merely false in
  # bash, it prints "integer expression expected" to stderr. That stderr is
  # captured into the assertion's \$out, where it would sit next to a genuine
  # failure message and read like part of it. Default it explicitly.
  n=\$(cat "\$WT_SHIM_STATE" 2>/dev/null || echo 0); n=\${n:-0}
  echo \$((n+1)) >"\$WT_SHIM_STATE"
  if [ "\$n" -ge 1 ] && [ -s "\${WT_SHIM_INJECT:-/nonexistent}" ]; then
    cat "\$WT_SHIM_INJECT"; exit 0
  fi
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$tmp/bin/git"

# A worktree list of realistic size. The target branch sits near the FRONT,
# as a real match usually does — that is what leaves the writer with work to do.
mk_wt_list() {   # $1 = branch to include ("" for none)
  local target="$1" i
  printf 'worktree %s\nHEAD %s\nbranch refs/heads/main\n\n' "$work" "$(git -C "$work" rev-parse main)"
  [ -n "$target" ] && printf 'worktree %s/live\nHEAD %s\nbranch refs/heads/%s\n\n' "$tmp" "$(git -C "$work" rev-parse main)" "$target"
  for i in $(seq 1 40); do
    printf 'worktree %s/.claude/worktrees/sess-%s\nHEAD %s\nbranch refs/heads/claude/other-session-%s\n\n' \
      "$work" "$i" "$(git -C "$work" rev-parse main)" "$i"
  done
}

# ARM 1 — the guard: branch IS in the later list, so it must be KEPT.
wt_sha=$(mk_remote_branch "claude/wt-reclaim-2674")
git -C "$work" checkout main >/dev/null
: >"$OPEN_HEADS_FILE"
printf '%s\tMERGED\t%s\n' "claude/wt-reclaim-2674" "$wt_sha" >"$PR_EVIDENCE_FILE"
export WT_SHIM_STATE="$wt_shim_dir/count" WT_SHIM_INJECT="$wt_shim_dir/list"
: >"$WT_SHIM_STATE"; mk_wt_list "claude/wt-reclaim-2674" >"$WT_SHIM_INJECT"
manifest="$tmp/manifest-2674a"; : >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" apply 2>&1)" && rc=0 || rc=$?
report "worktree re-check keeps a branch claimed after the snapshot (#2674)" \
  "$($real_git -C "$work" rev-parse --verify --quiet "refs/heads/claude/wt-reclaim-2674" >/dev/null && echo yes || echo no)" \
  "rc=$rc out=$out"

# ARM 2 — control: same shim, same size, branch ABSENT from the later list, so
# the branch SHOULD be deleted. Without this, a harness that never deletes
# anything would pass arm 1 vacuously.
ctl_sha=$(mk_remote_branch "claude/wt-control-2674")
git -C "$work" checkout main >/dev/null
printf '%s\tMERGED\t%s\n' "claude/wt-control-2674" "$ctl_sha" >"$PR_EVIDENCE_FILE"
: >"$WT_SHIM_STATE"; mk_wt_list "" >"$WT_SHIM_INJECT"
manifest="$tmp/manifest-2674b"; : >"$manifest"
out="$("$helper" "$work" "monorepo" "$manifest" apply 2>&1)" && rc=0 || rc=$?
report "control: an unclaimed branch is still deleted at the same list size (#2674)" \
  "$($real_git -C "$work" rev-parse --verify --quiet "refs/heads/claude/wt-control-2674" >/dev/null && echo no || echo yes)" \
  "rc=$rc out=$out"
unset WT_SHIM_STATE WT_SHIM_INJECT
rm -f "$tmp/bin/git"

if [[ "$fail" -ne 0 ]]; then
  echo "branch-cleanup contract: FAILED"
  exit 1
fi
echo "branch-cleanup contract: all assertions passed"
