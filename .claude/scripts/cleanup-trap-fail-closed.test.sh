#!/usr/bin/env bash
# Proves the canonical cleanup-trap shape fails CLOSED when a script aborts on a
# parameter-expansion error under `set -u`, and records what the naive shape does
# on whatever bash is running.
#
# Why this exists (monorepo#3414): the idiom almost every script here uses —
#
#     set -euo pipefail
#     tmp="$(mktemp -d)"
#     trap 'rm -rf "$tmp"' EXIT
#
# reports the script's status as the EXIT trap's own status for exactly one
# failure class: the `set -u` abort. A successful `rm` then becomes a clean pass.
# That class is the one that fires on an input nobody anticipated, which is when
# a guard most needs to fail closed. `$?` cannot recover it — read inside the
# trap it is already 0 for this class.
#
# The canonical shape is the one `ci-job-wiring.sh` already uses: a completion
# sentinel set on the last line, so reaching the end is the ONLY way a zero
# status leaves the script.
#
# This test runs on the CI matrix (ubuntu-latest = bash 5, macos-latest =
# bash 3.2) so the per-version behaviour is measured rather than assumed.
set -euo pipefail

# The system shell is Bash 3.2 on macOS and Bash 5 on Linux, independent of PATH.
if [ "$BASH" != /bin/bash ]; then
  exec /bin/bash "$0" "$@"
fi

tmp="$(mktemp -d)"
cleanup_trap_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$cleanup_trap_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "cleanup-trap-fail-closed.test: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; fails=$((fails + 1)); }

echo "shell: $("$BASH" --version | head -1)"
echo "BASH_VERSION=${BASH_VERSION:-unknown}"
echo

# ---------------------------------------------------------------------------
# Fixtures. In BOTH, the fatal error is injected AFTER the trap line — injecting
# it before is vacuous, because the trap is not installed yet and the status
# propagates with or without the fix.
# ---------------------------------------------------------------------------

# The naive shape, exactly as it appears across the script tree.
cat > "$tmp/naive.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
case "${1:-}" in
  unbound) echo "${DELIBERATELY_UNSET_VAR}" ;;
  clean)   : ;;
  seterr)  false ;;
  code)    exit 3 ;;
esac
EOF

# The canonical shape: the completion sentinel `ci-job-wiring.sh` uses.
cat > "$tmp/canonical.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
echo "$tmp" > "${CLEANUP_TRAP_TEST_TMPDIR_RECORD:-/dev/null}"
canonical_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$canonical_finished" != 1 ] && [ "$rc" -eq 0 ]; then # ABLATE-HERE
    echo "canonical: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
case "${1:-}" in
  unbound) echo "${DELIBERATELY_UNSET_VAR}" ;;
  clean)   : ;;
  seterr)  false ;;
  code)    exit 3 ;;
esac
canonical_finished=1
EOF

chmod +x "$tmp/naive.sh" "$tmp/canonical.sh"

status_of() { # <script> <arg>
  local rc=0
  "$BASH" "$1" "$2" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# ---------------------------------------------------------------------------
# 1. MEASUREMENT (monorepo#3414 acceptance criterion 1). Printed, not asserted:
#    the whole point is to learn what THIS bash does. Asserting a value here
#    would make the test fail on a bash that does not carry the defect, which is
#    the very outcome we are trying to find out about.
# ---------------------------------------------------------------------------
naive_unbound="$(status_of "$tmp/naive.sh" unbound)"
echo "MEASUREMENT naive shape, \`set -u\` abort after the trap line: exit ${naive_unbound}"
if [ "$naive_unbound" -eq 0 ]; then
  echo "MEASUREMENT verdict: this bash IS affected — the naive trap masks the abort as a clean pass."
else
  echo "MEASUREMENT verdict: this bash is NOT affected — the naive trap propagates exit ${naive_unbound}."
fi
echo

# The census excludes scripts without errexit only while that shape preserves aborts.
sed 's/^set -euo pipefail$/set -uo pipefail/' "$tmp/naive.sh" > "$tmp/no-errexit.sh"
chmod +x "$tmp/no-errexit.sh"
if ! grep -qx 'set -uo pipefail' "$tmp/no-errexit.sh"; then
  fail "no-errexit control did not remove errexit"
elif [ "$(status_of "$tmp/no-errexit.sh" unbound)" -eq 0 ]; then
  fail "without errexit, the naive trap also masks the abort — excluding it would be unsafe"
else
  pass "without errexit, an abort already reports failure"
fi

# Control: the same abort with NO trap at all must be non-zero on every bash.
# If this ever reported 0, the fixture would not be aborting and every result
# above and below it would be vacuous.
cat > "$tmp/notrap.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
echo "${DELIBERATELY_UNSET_VAR}"
EOF
chmod +x "$tmp/notrap.sh"
notrap_unbound="$(status_of "$tmp/notrap.sh" unbound)"
echo "control: same abort with no trap installed: exit ${notrap_unbound}"
if [ "$notrap_unbound" -ne 0 ]; then
  pass "control — the fixture really does abort, so the measurement above is about the trap"
else
  fail "control — the fixture did not abort; every other result here is vacuous"
fi
echo

# ---------------------------------------------------------------------------
# 2. THE INVARIANT (acceptance criteria 2 and 4). This IS asserted, on every
#    bash: the canonical shape must never report a clean pass for an abort.
# ---------------------------------------------------------------------------
echo "canonical shape:"
canonical_unbound="$(status_of "$tmp/canonical.sh" unbound)"
if [ "$canonical_unbound" -ne 0 ]; then
  pass "\`set -u\` abort after the trap line reports failure (exit ${canonical_unbound})"
else
  fail "\`set -u\` abort after the trap line reported a CLEAN PASS — the shape does not fail closed"
fi

# The sentinel must not break the statuses that already worked, or scripts
# converted to this shape would start lying in the other direction.
for arm in "clean 0" "seterr 1" "code 3"; do
  name="${arm%% *}"; want="${arm##* }"
  got="$(status_of "$tmp/canonical.sh" "$name")"
  if [ "$got" = "$want" ]; then
    pass "${name} arm still exits ${want}"
  else
    fail "${name} arm exits ${got}, expected ${want}"
  fi
done

# The trap must still do its actual job.
record="$tmp/canonical-tmpdir"
CLEANUP_TRAP_TEST_TMPDIR_RECORD="$record" "$BASH" "$tmp/canonical.sh" unbound >/dev/null 2>&1 || true
inner="$(cat "$record" 2>/dev/null || echo)"
if [ -n "$inner" ] && [ ! -d "$inner" ]; then
  pass "cleanup still removed the temporary directory on the aborting path"
elif [ -z "$inner" ]; then
  fail "could not record the inner temporary directory — cleanup claim unverified"
else
  fail "cleanup leaked ${inner} on the aborting path"
fi
echo

# ---------------------------------------------------------------------------
# 3. ABLATION. Removing ONLY the sentinel must reproduce the fail-open — but
#    only on a bash that showed the defect in step 1. On an unaffected bash
#    there is nothing to reproduce, and asserting otherwise would be a false
#    failure rather than a finding.
# ---------------------------------------------------------------------------
echo "ablation (sentinel removed, trap kept):"
if [ "$naive_unbound" -eq 0 ]; then
  sed 's|.*# ABLATE-HERE|  if false; then|' \
    "$tmp/canonical.sh" > "$tmp/ablated.sh"
  chmod +x "$tmp/ablated.sh"
  if ! grep -q 'if false; then' "$tmp/ablated.sh"; then
    fail "ablation did not apply — the edit matched nothing, so the result below proves nothing"
  else
    ablated_unbound="$(status_of "$tmp/ablated.sh" unbound)"
    if [ "$ablated_unbound" -eq 0 ]; then
      pass "removing the sentinel restores the fail-open (exit 0) — the sentinel is what fixes it"
    else
      fail "ablation still exits ${ablated_unbound}; the sentinel is not the operative difference"
    fi
  fi
else
  echo "  skip  this bash does not carry the defect, so there is no fail-open to reproduce"
fi
echo

# ---------------------------------------------------------------------------
# 4. CONVERTED SCRIPTS (acceptance criterion 3). Every script listed here uses
#    the canonical shape. For each, a copy of the REAL script gets a `set -u`
#    abort injected on the line right after its `trap <handler> EXIT`, and the
#    copy must not exit 0. A reach marker written just before the abort proves
#    the copy got that far, so a script that stops earlier (a usage error, a
#    missing input) can never pass vacuously. On a bash that carries the defect
#    the copy must also report through the sentinel, which is what proves the
#    sentinel, and not some earlier failure, turned the abort into a failure.
#    A syntax-aware census requires every tracked errexit/EXIT-trap script to
#    have an injection case or a reviewed exception (monorepo#4114).
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
mkdir -p "$tmp/converted/projects" "$tmp/converted/backups" \
  "$tmp/converted/plugins/marketplaces/devantler-plugins"
git init -q "$tmp/converted/lockrepo"
printf 'memory line\n' > "$tmp/converted/memory.md"
printf 'replacement line\n' > "$tmp/converted/replacement.md"
printf '{"scheduledTasks":[{"id":"alpha","enabled":true,"lastRunAt":1,"createdAt":0,"cronExpression":"0 * * * *"}]}\n' \
  > "$tmp/converted/store.json"

# <script>|<arguments that reach the trap>|<optional backstop text or exit:status>
converted_scripts="
cleanup-trap-fail-closed.test.sh|
bash-parse-guard.sh|$repo_root
bot-pr-adaptation-push.sh|
business-site-publication.test.sh||exit:2
ci-job-wiring.sh|$repo_root/.github/workflows/ci.yaml
ci-macos-batches.test.sh|
contract-test-invocation.sh|$repo_root/.github/workflows/ci.yaml $script_dir
disk-preflight.sh|
gnu-only-syntax-guard.sh|
maintainer-comment-candidates.sh|
pr-worktree-holder.sh|--input -|exit:2
required-gate-completeness.sh|--input -|exit:2
sibling-lane-watch.sh|
silent-scheduled-workflows.sh|
security-advisory-sweep.sh|
worktree-inventory-classify.sh|--inventory $tmp/converted/memory.md|exit:2
worktree-inventory-merged-check.sh|$tmp/converted|exit:2
worktree-lane-sweep.sh|
business-site-ci.test.sh|
memory-backup.sh|
memory-hygiene.sh|
automation-memory-read.sh|--file $tmp/converted/memory.md
automation-memory-read.test.sh|
memory-rewrite.sh|--file $tmp/converted/memory.md --from $tmp/converted/replacement.md --backup-dir $tmp/converted/backups
hypothesis-id-reserve.test.sh|
review-lane-health.sh|--now 1
test-partitions.sh|--suite $tmp/canonical.sh|exit:2
test-partitions.test.sh|
review-no-gate-guard.sh|
claude-lane-liveness.sh|--store $tmp/converted/store.json --projects $tmp/converted/projects
renovate-dashboard-drift.sh|
pr-ownership-disclosure.sh|--input -
comment-disclosure-drift.sh|--input -
python-ban-guard.sh|$repo_root
board-archive.sh|
blocked-label-blocker-line.sh|
board-add.sh|
pr-body-contract.sh|check --repo devantler-tech/monorepo --body-file $tmp/converted/memory.md
plugin-definition-refresh.sh|--cli /usr/bin/true --repo-root $tmp/converted --gitlink 0000000000000000000000000000000000000000 --plugins-root $tmp/converted/plugins
safe-clone.sh|devantler-tech/monorepo $tmp/converted/clone-destination
shared-checkout-freshness.sh|
worktree-claim.sh|check $tmp/converted/absent-worktree cleanup-trap-test
branch-op-lock.sh|run $tmp/converted/lockrepo -- true
agent-issue-board-sweep.sh|--author cleanup-trap-test
claude-dispatch-rate.sh|--task alpha --since 1970-01-02T00:00:00Z --until 1970-01-02T06:00:00Z --now-epoch 172800 --store $tmp/converted/store.json --projects $tmp/converted/projects
board-add.test.sh|
board-archive.test.sh|
branch-cleanup.test.sh|
ci-aggregate-contract.test.sh|
flow-scorecard.test.sh|
memory-backup.test.sh|
memory-rewrite.test.sh|
platform-live-health.test.sh|
python-ban-guard-build-surfaces.test.sh|
python-ban-guard-command-surfaces.test.sh|
python-ban-guard-symlinks.test.sh|
python-ban-guard-wrappers.test.sh|
python-ban-guard.test.sh|
review-lane-health.test.sh|
safe-clone.test.sh|
unsigned-push-guard.test.sh|
blocked-label-blocker-line.test.sh|
claude-dispatch-rate.test.sh|
codex-lane-liveness.test.sh|
inference-routing-contract.test.sh|
prod-kube-context.test.sh|
claude-lane-liveness.test.sh|
submodule-agents-drift.test.sh|
inference-routing-scorecard.test.sh|
release-exemption-identity-currency.test.sh|
submodule-pin-currency.test.sh|
unsigned-commit-report.test.sh|
ci-job-wiring.test.sh|
pipefail-grep-guard.test.sh|
skill-owner.test.sh|
silent-scheduled-workflows.test.sh|
security-advisory-sweep.test.sh|
claude-task-live-runs.test.sh|
delivered-open-candidates.test.sh|
lane-draft-count.test.sh|
portfolio-surveyor.test.sh|
product-value-contract.test.sh|
review-request-comment.test.sh|
self-review-contract.test.sh|
sibling-lane-watch.test.sh|
squash-closing-keywords.test.sh|
surveyor-hook-dispatch.test.sh|
work-priority-ladder.test.sh|
bot-pr-adaptation-push.test.sh|
disclosure-drift-sweep.test.sh|
disk-preflight.test.sh|
gh-json-read.test.sh|
run-affected-tests.test.sh|
shared-checkout-freshness.test.sh|
bugbot-request-marker.test.sh|
coderabbit-summary-verdict.test.sh|
coderabbit-comment-verdict.test.sh|
coderabbit-review-verdict.test.sh|
local-review-verdict.test.sh|
managed-run-streak.test.sh|
pr-unresolved-threads.test.sh|
review-no-gate-guard.test.sh|
portfolio-map-drift.test.sh|
review-request-lock.test.sh|
agent-claim.test.sh|
agent-issue-board-sweep.test.sh|
branch-op-lock.test.sh|
claim-lease-timeline-contract.test.sh|
dotfile-glob-fanout-contract.test.sh|
plugin-definition-currency.test.sh|
submodule-init.test.sh|
worktree-claim.test.sh|
worktree-submodule-inventory.test.sh|
worktree-inventory-merged-check.test.sh|
worktree-inventory-classify.test.sh|
agent-claim-sweep.test.sh|
bash-parse-guard.test.sh|
comment-disclosure-drift.test.sh|
contract-test-invocation.test.sh|
gnu-only-syntax-guard.test.sh|
maintainer-comment-candidates.test.sh|
pr-ownership-disclosure.test.sh|
pr-worktree-holder.test.sh|
required-gate-completeness.test.sh|
kata-measure-date.test.sh|
pr-body-contract.test.sh|
provider-neutral-agents-contract.test.sh|
claim-pr-findings-contract.test.sh|
improver-role-disclosure-contract.test.sh|
merge-confirmation-read.test.sh|
merge-preflight-thread-gate.test.sh|
drifted-lane-escalation-contract.test.sh|
retired-rule-survivors-contract.test.sh|
review-provider-loop-contract.test.sh|
agent-instructions-layout-contract.test.sh|
worktree-lane-sweep.test.sh|
plugin-definition-refresh.test.sh|
surveyor-vocabulary-coverage.test.sh|
build-cache-reclaim.test.sh|
codex-transcript-retention.sh|dry-run 14
codex-transcript-retention.test.sh|
codex-worktree-retention.sh|dry-run 7
codex-worktree-retention.test.sh|
worktree-cleanup.test.sh|--run-cases $tmp/converted/memory.md $tmp/converted/cleanup-receipt
worktree-cleanup-all.test.sh|--run-cases $tmp/converted/memory.md $tmp/converted/orchestrator-receipt
agent-role-delivery-contract.test.sh|
maintainer-digest.sh|
maintainer-digest.test.sh|
fix-hint-contract.test.sh|
"

# This trap is installed only inside a real submodule synchronization transaction.
# The generic pre-trap harness must not perform those checkouts merely to reach it.
# Exceptions remain explicit reviewed obligations, not evidence of an injected abort.
excepted_scripts='submodule-init.sh|The --sync handler is installed after Git/submodule transactions; reaching it needs its dedicated isolation fixtures rather than the generic pre-trap harness.
worktree-claim.sh:2|origin_redirects is a process-substitution probe whose caller requires its final checked marker; an abort without the marker is refused independently of exit status. The generic harness cannot reach this nested Git probe.
branch-op-lock.test.sh:2|This subshell deliberately installs a marker-writing trap to test preservation of the caller trap; the enclosing test checks the marker rather than trusting subshell exit status.
branch-op-lock.test.sh:3|This subshell deliberately installs an ancestor marker trap to test that an inner shell leaves it dormant; the enclosing test checks marker timing rather than trusting subshell exit status.'
printf '%s\n' "$converted_scripts" > "$tmp/injected"
# The second handler is exercised by the lifted spend fixture below, after the first-trap loop.
printf '%s\n' 'agent-role-delivery-contract.test.sh:2|Lifted spend handler injected below.' >> "$tmp/injected"
printf '%s\n' "$excepted_scripts" > "$tmp/exceptions"
go -C "$script_dir/cleanup-trap-census-go" test ./...
go -C "$script_dir/cleanup-trap-census-go" build -o "$tmp/census" .
"$tmp/census" --root "$repo_root" --covered "$tmp/injected" --exceptions "$tmp/exceptions"

echo "converted scripts (\`set -u\` abort injected after the trap line):"
while IFS='|' read -r name args backstop; do
  [ -n "$name" ] || continue
  src="$script_dir/$name"
  if [ ! -f "$src" ]; then
    fail "${name}: listed as converted but not found at ${src}"
    continue
  fi
  trap_line="$(grep -n -E '^[[:space:]]*trap .+ EXIT$' "$src" | head -1 | cut -d: -f1 || true)"
  if [ -z "$trap_line" ]; then
    fail "${name}: no EXIT trap line to inject after — the cleanup shape is missing"
    continue
  fi
  # Each copy gets its own directory with sibling links for relative sources. One ln invocation
  # avoids thousands of process starts. Unlink only this script's private link before writing
  # its copy, so no write can follow a link into a real script.
  run_dir="$tmp/converted/$name.d"
  mkdir "$run_dir"
  copy="$run_dir/$name"
  ln -s "$script_dir"/*.sh "$run_dir/"
  [ -L "$copy" ] || { fail "${name}: fixture link missing"; continue; }
  rm "$copy"
  {
    head -n "$trap_line" "$src"
    # shellcheck disable=SC2016 # Written literally into the copy, expanded when it runs.
    printf '%s\n' 'printf reached > "$CLEANUP_TRAP_TEST_REACHED"' ': "${CLEANUP_TRAP_TEST_UNSET_VAR}"'
    tail -n "+$((trap_line + 1))" "$src"
  } > "$copy"
  chmod +x "$copy"
  reached="$tmp/converted/$name.reached"
  rm -f "$reached"
  rc=0
  # Word splitting of $args is intended: it is a fixed argument list with no spaces inside a word.
  # shellcheck disable=SC2086
  err="$(cd "$tmp/converted" && env -u CLEANUP_TRAP_TEST_UNSET_VAR CLEANUP_TRAP_TEST_REACHED="$reached" \
    "$BASH" "$copy" $args 2>&1 >/dev/null)" || rc=$?
  if [ ! -f "$reached" ]; then
    fail "${name}: the copy stopped before its trap line (exit ${rc}), so this result proves nothing: ${err}"
  elif [ "$rc" -eq 0 ]; then
    fail "${name}: a \`set -u\` abort after the trap line reported a CLEAN PASS"
  elif [ "$naive_unbound" -eq 0 ]; then
    case "$backstop" in
      exit:*)
        if [ "$rc" != "${backstop#exit:}" ]; then
          fail "${name}: abort exited ${rc}, expected its explicit backstop status ${backstop#exit:}"
        else
          pass "${name}: the reached abort reports its explicit backstop status ${rc}"
        fi
        ;;
      *)
        if ! grep -Fq -- "${backstop:-aborted before}" <<<"$err"; then
          fail "${name}: exit ${rc}, but not through the sentinel on a bash that masks the abort: ${err}"
        else
          pass "${name}: the abort reports failure (exit ${rc})"
        fi
        ;;
    esac
  else
    pass "${name}: the abort reports failure (exit ${rc})"
  fi
done <<EOF
$converted_scripts
EOF
echo

# The injection above stops agent-role-delivery-contract.test.sh at its first trap, long before
# its spend cases start. Those run in a subshell with a handler of their own, so that handler is
# lifted out of the real script and run with the same abort placed right after its trap line.
echo "nested handler (agent-role-delivery-contract.test.sh, the spend cases subshell):"
nested_src="$script_dir/agent-role-delivery-contract.test.sh"
# shellcheck disable=SC2016 # A literal pattern for the script's own text, not an expansion.
nested_setup="$(sed -n '/^  spend_tmp="\$(mktemp -d)"$/,/^  trap spend_cleanup EXIT$/p' "$nested_src")"
if ! grep -q '^  trap spend_cleanup EXIT$' <<<"$nested_setup"; then
  fail "agent-role-delivery-contract.test.sh: the spend cases handler was not found, so it is not proven"
else
  nested="$tmp/nested-spend.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '('
    printf '%s\n' "$nested_setup"
    # shellcheck disable=SC2016 # Written literally into the fixture, expanded when it runs.
    printf '%s\n' '  printf reached > "$CLEANUP_TRAP_TEST_REACHED"' '  : "${CLEANUP_TRAP_TEST_UNSET_VAR}"' \
      '  spend_cases_finished=1' ')' 'echo "all assertions passed"'
  } > "$nested"
  chmod +x "$nested"
  reached="$tmp/nested-spend.reached"
  rm -f "$reached"
  rc=0
  err="$(env -u CLEANUP_TRAP_TEST_UNSET_VAR CLEANUP_TRAP_TEST_REACHED="$reached" "$BASH" "$nested" 2>&1 >/dev/null)" || rc=$?
  if [ ! -f "$reached" ]; then
    fail "spend cases handler: the fixture stopped before its trap line (exit ${rc}), so this result proves nothing: ${err}"
  elif [ "$rc" -eq 0 ]; then
    fail "spend cases handler: a \`set -u\` abort inside the subshell reported a CLEAN PASS"
  elif [ "$naive_unbound" -eq 0 ] && ! grep -q 'aborted before' <<<"$err"; then
    fail "spend cases handler: exit ${rc}, but not through the sentinel on a bash that masks the abort: ${err}"
  else
    pass "spend cases handler: the abort reports failure (exit ${rc})"
  fi
fi
echo

if [ "$fails" -ne 0 ]; then
  echo "cleanup-trap-fail-closed.test: ${fails} assertion(s) failed" >&2
  exit 1
fi
echo "cleanup-trap-fail-closed.test: all assertions passed"
cleanup_trap_test_finished=1
