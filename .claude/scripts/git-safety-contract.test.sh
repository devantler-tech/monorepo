#!/usr/bin/env bash
#
# Guards the *Git safety* section's ban/alternative pair.
#
# Why this needs a guard at all. The runtime denies `git reset --hard` and the contract bans it, but
# for a long time neither said how to do the thing runs legitimately need: put a freshly-created
# maint worktree onto a PR's head commit. A prohibition with no named alternative does not stop the
# behaviour — it relocates the instruction somewhere unreviewed. Here it landed in durable memory,
# which came to prescribe `fetch` + `reset --hard FETCH_HEAD`, so every *compliant* run reached for a
# command that could never execute. Measured across one day's session corpus: 3-4 denied calls over
# three separate ticks, a standing share of the lane's permission-denial signature.
#
# The failure is worse than one wasted call. A denied COMPOUND call rolls the whole chain back, so
# the `fetch` never runs either; the follow-up then fails on a missing `FETCH_HEAD` and reads like a
# broken gitdir rather than a refusal, and the run diagnoses the wrong thing.
#
# BOTH HALVES ARE PINNED, and that is the point of this file rather than an accident of thoroughness.
# Asserting only that the alternative is named would pass a future edit that "simplifies" the section
# by keeping the alternative and dropping the prohibition — which converts a documentation fix into a
# guardrail loosening, silently, with a green test. Asserting only the ban would let the alternative
# be dropped again and re-open the vacuum this file exists to close. Neither assertion is redundant.
#
# Assertions are scoped to the Git safety section itself, not the whole file. A whole-file check is a
# scope hole: the phrases below appear in the memory/loader prose elsewhere in this repository, so a
# file-wide match would pass while the operative section said nothing.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "git safety contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY the Git safety section, then flatten it. Flattening matters because every sentence
# below wraps across source lines, so a fragment spanning a line break would never match and the
# test would be always-red regardless of the contract's content.
if ! section="$(
  awk '
    /^### Git safety$/                              { ins = 1; next }
    ins && /^\*\*Worktree hygiene is SCHEDULED/     { found_end = 1; exit }
    ins                                              { print }
    END                                              { if (!found_end) exit 42 }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"; then
  fail "could not find the 'Worktree hygiene is SCHEDULED' end anchor after '### Git safety' — refusing an unscoped whole-file assertion"
fi

[ -n "${section}" ] ||
  fail "could not locate the '### Git safety' section — the extraction anchor moved, so every assertion below would be vacuous"

# Report the scoped size for diagnostics only. End-anchor detection above, not a content-size proxy,
# is the guard against runaway extraction; legitimate additions therefore cannot trip a false
# "missing anchor" failure.
section_words="$(printf '%s' "${section}" | wc -w | tr -d ' ')"

assert_section() {
  case "${section}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

# 1. THE BAN SURVIVES. This is the half that keeps the file from becoming a loosening: without it,
#    an edit that drops the prohibition and keeps only the alternative passes green.
assert_section "Never \`git reset --hard\`" \
  "the Git safety section no longer bans \`git reset --hard\` — naming a safer alternative must never come at the cost of dropping the prohibition itself"

# 2. THE ALTERNATIVE IS NAMED, with the flag that makes it safe. \`checkout\` alone is not the
#    prescription: it is \`--detach\` onto an explicit commit that reproduces the banned form's
#    outcome, and a bare branch checkout would not.
assert_section 'git --no-replace-objects -C <wt> checkout --no-overwrite-ignore --detach <sha>' \
  "the Git safety section does not name \`git --no-replace-objects -C <wt> checkout --no-overwrite-ignore --detach <sha>\` as the permitted way to put a worktree on a specific commit, so replacement refs can substitute a different tree for the reviewed commit"

# 2c. THE INDEX-HIDDEN-EDIT CHECK. \`status --porcelain\` omits any tracked file carrying
#     \`assume-unchanged\` or \`skip-worktree\`, so an empty status is NOT proof the tree is clean.
#     Fixture-verified: empty status, then a successful checkout that carried a foreign edit onto the
#     target. \`worktree-cleanup.sh\` already makes this check, so the contract asking for less than
#     its own tooling does would be an inconsistency as well as a hole.
assert_section "Run \`git -C <wt> status --porcelain\` as its own call; require exit 0 and empty output" \
  "the Git safety section no longer requires a successful, empty \`status --porcelain\` probe — a failed status command must not be accepted as a clean worktree"
assert_section "Run \`(set -o pipefail; git -C <wt> ls-files -v | awk '\$1 ~ /^[a-z]\$/ || \$1 == \"S\"')\`; require the whole command to exit 0 and print nothing" \
  "the Git safety section no longer binds the complete \`ls-files -v\` index-flag command to both a successful pipeline and empty output — a failed Git probe must not be accepted as a clean index"

# 2d. THE SUBMODULE DETECTION RULE. `--detach` moves the superproject only, so on a gitlink-changing
#     PR the run is NOT on the reviewed code — fixture-verified, with nothing but a bare " M <sub>" to
#     show for it. In a monorepo largely made of submodule bumps that is the common case, and the
#     failure is silent, so the contract must at minimum require DETECTING it before evaluation.
assert_section "Run \`git -C <wt> submodule status --recursive\` and require it to exit 0 and every output line to begin with a space" \
  "the Git safety section no longer requires a successful recursive submodule-status probe whose every line carries Git's clean leading-space marker — a stale, absent, nested, or unmerged submodule could be evaluated as reviewed code"

# 2e. AND THE WARNING AGAINST THE OBVIOUS "FIX". `--recurse-submodules` is the natural thing to reach
#     for once 2d is stated, and it is UNSAFE in this repo's mandated linked-worktree flow: measured,
#     it can write a `mod/.git` pointing at a nonexistent gitdir and exit 128, cannot fetch a target
#     gitlink absent locally, silently skips a submodule the target introduces, and does not propagate
#     its ignored-file protection. Without this assertion a later editor closes 2d's gap by adding the
#     flag — reintroducing every one of those, with a rule that looks more complete than before.
assert_section "Do NOT reach for \`--recurse-submodules\`" \
  "the Git safety section no longer prohibits recursive checkout — the obvious workaround can corrupt linked-worktree submodule gitdirs, partially switch the tree, and overwrite ignored submodule work"
assert_section '[#2833](https://github.com/devantler-tech/monorepo/issues/2833)' \
  "the Git safety section no longer points at the follow-up issue for safe submodule detaching — without it the stated hazard reads as unsolved-and-unowned, and the next editor is likely to 'fix' it with \`--recurse-submodules\`, which is measurably unsafe in this repo's linked-worktree flow"

# 2b. THE PR-HEAD ASSOCIATION. \`<sha>\` is deliberately the general placeholder — it is this
#     contract's convention (27 backticked commands use it, against 1 for \`<headRefOid>\`), and the
#     rule covers any commit, not only a PR head. But the motivating case IS the PR head, so the
#     value's identity must be stated or the prescription is unactionable exactly where it is most
#     needed. Naming \`headRefOid\` also ties this to the commit *Merge policy* pins, which is what
#     makes "the worktree you evaluated" and "the commit you merged" the same claim.
assert_section "When that commit is a PR's head, \`<sha>\` is its **\`headRefOid\`**" \
  "the Git safety section no longer identifies a PR head's \`<sha>\` as its \`headRefOid\` — without it the prescription is unactionable in its motivating case, and the worktree you evaluate is no longer tied to the commit Merge policy pins"

# 3. THE SEPARATE-CALLS REQUIREMENT. Chaining the fetch and the checkout is what turns a refusal into
#    a misdiagnosis, so the prescription is incomplete without it — this is the measured second-order
#    cost, not a style preference.
assert_section 'SEPARATE calls' \
  "the Git safety section does not require the fetch and the checkout to be issued as separate calls — a denied compound call rolls back the fetch too, and the follow-up then fails on a missing FETCH_HEAD in a way that reads like a broken gitdir rather than a refusal"

# 4. THE CLEANLINESS PRECONDITION. This is the operative safety rule and the one most likely to be
#    "simplified" away, because the abort LOOKS like it already covers the case. It does not.
#    Measured on a two-commit fixture: `checkout --detach` aborts only when the dirty path DIFFERS
#    between HEAD and the target; when the path is identical in both commits git carries the edit
#    along and SUCCEEDS, landing on the target with another writer's uncommitted work in the tree and
#    nothing in the output saying so. An earlier draft of this contract claimed the abort was
#    unconditional — that claim was false and is exactly what this assertion prevents recurring.
assert_section 'git -C <wt> status --porcelain' \
  "the Git safety section no longer requires the worktree to be verified clean before detaching — the abort is only a partial backstop (it fires only when the dirty path differs between HEAD and target), so without this precondition a run can silently detach over another instance's uncommitted work"

# 4b. AND THE REASON THE BACKSTOP IS PARTIAL. Assertion 4 pins the rule; this pins the justification.
#     Without it a later editor sees a cleanliness check guarding a command they believe always
#     aborts, reasonably concludes it is redundant, and removes it.
assert_section 'partial backstop' \
  "the Git safety section no longer explains that the abort is only a partial backstop — a reader who believes \`checkout --detach\` always refuses a dirty worktree will read the cleanliness precondition as redundant and drop it"

# 5. POST-SWITCH RESIDUE. A target that removes an initialized submodule can leave its directory
#    behind while `submodule status --recursive` emits nothing. Re-run tracked cleanliness and use a
#    read-only `clean -ndx` dry-run so stale untracked or ignored repositories cannot be evaluated as
#    part of a commit that removed them.
assert_section "After detaching, repeat \`git -C <wt> status --porcelain\`" \
  "the Git safety section no longer repeats the tracked-worktree cleanliness check after detaching — checkout can leave residue that did not exist at the pre-check"
assert_section "Run \`git -C <wt> clean -ndx\` as its own read-only call; require exit 0 and empty output" \
  "the Git safety section no longer rejects stale untracked or ignored residue after detaching — a removed initialized submodule can survive outside the reviewed tree while submodule status passes vacuously"

echo "git safety contract: OK (${section_words} words scoped)"
