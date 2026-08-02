#!/usr/bin/env bash
# Contract tests for worktree-cleanup.sh.
#
# Each test builds a scratch repo with a real remote and real worktrees, then asserts
# that a specific KEEP gate fires (or that a genuinely spent worktree is reaped).
# Every gate test is paired with the reaped-baseline case, so a test that passes only
# because the script reaps NOTHING cannot go unnoticed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-cleanup.sh"
CLAIM_SUT="$SCRIPT_DIR/worktree-claim.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# --- fixture ----------------------------------------------------------------------
# Builds: origin (bare) + repo with `main` pushed. Worktrees are added per-test.
make_repo() {
  local root; root=$(mktemp -d)
  root=$(cd "$root" && pwd -P)          # resolve /tmp -> /private/tmp on macOS
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/repo"
  git -C "$root/repo" config user.email t@t.t
  git -C "$root/repo" config user.name t
  echo base > "$root/repo/file.txt"
  git -C "$root/repo" add file.txt
  git -C "$root/repo" commit -qm base
  git -C "$root/repo" remote add origin "$root/origin.git"
  git -C "$root/repo" push -q origin main
  mkdir -p "$root/repo/.claude/worktrees"
  printf '%s' "$root"
}

# add_wt <root> <name> [pushed|unpushed]
add_wt() {
  local root=$1 name=$2 kind=${3:-pushed}
  # Status-checked, and stderr is kept on failure. A silently-failing fixture produces a
  # repo with no worktree, and a REAP-negative assertion then passes on nothing — the
  # exact hazard that let the staged-gitlink test go green against an empty porcelain.
  if ! git -C "$root/repo" worktree add -q -b "claude/$name" \
         "$root/repo/.claude/worktrees/$name" main; then
    printf 'FIXTURE FAILURE: worktree add %s\n' "$name" >&2
    return 1
  fi
  if [ "$kind" = unpushed ]; then
    echo change > "$root/repo/.claude/worktrees/$name/new.txt"
    git -C "$root/repo/.claude/worktrees/$name" add new.txt
    git -C "$root/repo/.claude/worktrees/$name" commit -qm "unpushed work"
  else
    git -C "$root/repo" push -q origin "claude/$name"
  fi
  # age it past the default threshold
  touch -t 202001010000 "$root/repo/.claude/worktrees/$name"
}

run() { # <root> [mode] -> stdout
  local root=$1 mode=${2:-dry-run}
  "$SUT" "$root/repo" "$root/manifest.tsv" "$mode" 24 2>&1
}

# --- baseline: a spent worktree IS reaped ------------------------------------------
# This is the control for every KEEP test below: if this ever stops reaping, a
# "KEEP fired" assertion elsewhere would pass vacuously.
t_reaps_spent() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "reaps a spent worktree (control)"
  else
    bad "reaps a spent worktree (control)" "$out"
  fi
  rm -rf "$root"
}

t_keeps_unpushed() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed          # control must still reap
  add_wt "$root" work unpushed
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*work .*unpushed commit' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a worktree with unpushed commits"
  else
    bad "KEEPs a worktree with unpushed commits" "$out"
  fi
  rm -rf "$root"
}

t_keeps_detached_orphan() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" orph pushed
  # commit, then detach onto that commit and delete the branch ref => orphan commit
  echo o > "$root/repo/.claude/worktrees/orph/o.txt"
  git -C "$root/repo/.claude/worktrees/orph" add o.txt
  git -C "$root/repo/.claude/worktrees/orph" commit -qm orphan
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/orph" rev-parse HEAD)
  git -C "$root/repo/.claude/worktrees/orph" checkout -q --detach "$sha"
  # committing + detaching bumped the dir mtime; re-age so the AGE gate cannot mask
  # the gate under test (it did exactly that before this line existed)
  touch -t 202001010000 "$root/repo/.claude/worktrees/orph"
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*orph .*unpushed commit' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a detached HEAD on an orphan commit"
  else
    bad "KEEPs a detached HEAD on an orphan commit" "$out"
  fi
  rm -rf "$root"
}

t_keeps_dirty() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" dirty pushed
  echo edited >> "$root/repo/.claude/worktrees/dirty/file.txt"   # modified TRACKED file
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*dirty .*uncommitted change' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a worktree with uncommitted tracked changes"
  else
    bad "KEEPs a worktree with uncommitted tracked changes" "$out"
  fi
  rm -rf "$root"
}

t_ignores_tool_noise() {
  local root; root=$(make_repo)
  add_wt "$root" noisy pushed
  mkdir -p "$root/repo/.claude/worktrees/noisy/.codex" \
           "$root/repo/.claude/worktrees/noisy/.agents"
  echo x > "$root/repo/.claude/worktrees/noisy/.codex/x"
  echo y > "$root/repo/.claude/worktrees/noisy/.agents/y"
  # writing into the worktree bumped its mtime — re-age it past the threshold
  touch -t 202001010000 "$root/repo/.claude/worktrees/noisy"
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q '^REAP  .*noisy'; then
    ok "treats .codex/ and .agents/ as noise, not work"
  else
    bad "treats .codex/ and .agents/ as noise, not work" "$out"
  fi
  rm -rf "$root"
}

t_keeps_untracked_real_file() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" untracked pushed
  echo real > "$root/repo/.claude/worktrees/untracked/notes.md"
  touch -t 202001010000 "$root/repo/.claude/worktrees/untracked"
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*untracked .*uncommitted change' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs an untracked file outside the noise set"
  else
    bad "KEEPs an untracked file outside the noise set" "$out"
  fi
  rm -rf "$root"
}

t_keeps_young() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" fresh pushed
  touch "$root/repo/.claude/worktrees/fresh"          # now => younger than 24h
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*fresh .*age .*< 24h' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a worktree younger than min_age_hours"
  else
    bad "KEEPs a worktree younger than min_age_hours" "$out"
  fi
  rm -rf "$root"
}

t_keeps_active_ownership_claim() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" claimed pushed
  local w="$root/repo/.claude/worktrees/claimed"
  "$CLAIM_SUT" mark "$w" "codex-run-unique-123" >/dev/null
  touch -t 202001010000 "$w"
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*claimed .*active ownership claim' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a clean old worktree with an active ownership claim"
  else
    bad "KEEPs a clean old worktree with an active ownership claim" "$out"
  fi
  rm -rf "$root"
}

t_reaps_expired_ownership_claim() {
  local root; root=$(make_repo)
  add_wt "$root" expired-claim pushed
  local w="$root/repo/.claude/worktrees/expired-claim"
  "$CLAIM_SUT" mark "$w" "codex-run-expired-123" >/dev/null
  printf 'owner=codex-run-expired-123\ncreated_at=2020-01-01T00:00:00Z\n' >"$w/.claude-worktree-owner"
  touch -t 202001010000 "$w"
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q '^REAP  .*expired-claim'; then
    ok "allows an expired ownership claim to be reaped"
  else
    bad "allows an expired ownership claim to be reaped" "$out"
  fi
  rm -rf "$root"
}

t_keeps_active_claim_mutex() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" mutex-held pushed
  local w="$root/repo/.claude/worktrees/mutex-held" real hash ref blob now_utc
  real=$(cd "$w" && pwd -P)
  hash=$(printf '%s' "$real" | git -C "$w" hash-object --stdin)
  ref="refs/worktree/claim-locks/$hash"
  now_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  blob=$(printf 'pid=%s\ncreated_at=%s\n' "$$" "$now_utc" | git -C "$w" hash-object -w --stdin)
  git -C "$w" update-ref "$ref" "$blob"
  touch -t 202001010000 "$w"
  local out; out=$(run "$root" apply)
  if [ -d "$w" ] \
     && printf '%s' "$out" | grep -q 'KEEP .*mutex-held .*ownership mutex' \
     && [ ! -d "$root/repo/.claude/worktrees/spent" ]; then
    ok "KEEPs a worktree while its claim mutex is held"
  else
    bad "KEEPs a worktree while its claim mutex is held" "$out"
  fi
  rm -rf "$root"
}

t_keeps_live_cwd() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" live pushed
  ( cd "$root/repo/.claude/worktrees/live" && exec sleep 30 ) &
  local pid=$!
  sleep 1                                    # let the child establish its CWD
  local out; out=$(run "$root")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if printf '%s' "$out" | grep -q 'KEEP .*live .*live process CWD' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a worktree that is a live process CWD"
  else
    bad "KEEPs a worktree that is a live process CWD" "$out"
  fi
  rm -rf "$root"
}

t_keeps_live_cwd_in_subdir_with_regex_metachars() {
  # Regression: the descendant check once used the worktree path as a grep REGEX.
  # A name containing '[' made grep error, the check reported "no match", and a live
  # session working in a SUBDIRECTORY was eligible for reaping. Both properties are
  # pinned here — descendant CWD, and a name full of regex metacharacters.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  local odd='we[ird.na*me'
  git -C "$root/repo" worktree add -q -b "claude/odd" \
      "$root/repo/.claude/worktrees/$odd" main 2>/dev/null
  git -C "$root/repo" push -q origin "claude/odd"
  mkdir -p "$root/repo/.claude/worktrees/$odd/nested/deep"
  touch -t 202001010000 "$root/repo/.claude/worktrees/$odd"
  ( cd "$root/repo/.claude/worktrees/$odd/nested/deep" && exec sleep 30 ) &
  local pid=$!
  sleep 1
  local out; out=$(run "$root")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if printf '%s' "$out" | grep -qF 'live process CWD' \
     && ! printf '%s' "$out" | grep -qF "REAP   $odd" \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a live CWD in a SUBDIR of a regex-metachar-named worktree"
  else
    bad "KEEPs a live CWD in a SUBDIR of a regex-metachar-named worktree" "$out"
  fi
  rm -rf "$root"
}

t_age_gate_works_with_gnu_stat() {
  # Regression: mtime resolution used `stat -f %m || stat -c %Y`. GNU stat reads -f as
  # "filesystem status", so on Linux the first form SUCCEEDS with a `File: ...` block
  # instead of failing, the fallback never ran, and the age arithmetic died with
  # "File: unbound variable" — taking every gate down with it.
  # Shims a GNU-only stat (no -f support) so the contract is provable on any host.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" fresh pushed
  touch "$root/repo/.claude/worktrees/fresh"
  local shim="$root/shim"; mkdir -p "$shim"
  cat > "$shim/stat" <<'SHIM'
#!/usr/bin/env bash
# GNU-flavoured stat: -c %Y yields the real mtime, while -f is filesystem-status and
# SUCCEEDS with a `File: ...` block instead of failing. That combination is what broke
# the age gate on Linux.
# The real mtime is fetched flavour-agnostically so this shim runs on a BSD host too.
real_mtime() {
  /usr/bin/stat -c %Y "$1" 2>/dev/null && return 0
  /usr/bin/stat -f %m "$1" 2>/dev/null && return 0
  return 1
}
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%Y" ]; then real_mtime "$3"; exit $?; fi
if [ "${1:-}" = "-f" ]; then printf '  File: "%s"\n    ID: 0\n' "${3:-${2:-}}"; exit 0; fi
exit 1
SHIM
  chmod +x "$shim/stat"
  local out; out=$(PATH="$shim:$PATH" "$SUT" "$root/repo" "$root/manifest.tsv" dry-run 24 2>&1)
  if printf '%s' "$out" | grep -q '^REAP  .*spent' \
     && printf '%s' "$out" | grep -q 'KEEP .*fresh .*age .*< 24h' \
     && ! printf '%s' "$out" | grep -qi 'unbound variable'; then
    ok "age gate resolves mtime under GNU-style stat"
  else
    bad "age gate resolves mtime under GNU-style stat" "$out"
  fi
  rm -rf "$root"
}

t_keeps_locked() {
  # COVERAGE NOTE: this locks BEFORE the sweep starts, so it exercises the startup
  # snapshot. The mid-sweep re-check (is_locked_now, which stops --force overriding a
  # lock acquired while the sweep runs) is defense-in-depth against a real race and is
  # deliberately NOT claimed as covered here — ablating it leaves this test green.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" held pushed
  git -C "$root/repo" worktree lock "$root/repo/.claude/worktrees/held"
  local out; out=$(run "$root")
  git -C "$root/repo" worktree unlock "$root/repo/.claude/worktrees/held" 2>/dev/null
  if printf '%s' "$out" | grep -q 'KEEP .*held .*locked' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a locked worktree"
  else
    bad "KEEPs a locked worktree" "$out"
  fi
  rm -rf "$root"
}

t_keeps_staged_gitlink_update() {
  # A STAGED gitlink update lives only in this worktree's index — reaping the worktree
  # destroys it with no commit to recover from. Only unstaged drift (` M`) is noise.
  # Built with `update-index --cacheinfo` rather than `git submodule add`: the latter
  # depends on protocol.file.allow and silently produced NO submodule on the CI
  # runners, so the fixture emitted an empty porcelain and the test passed on nothing.
  # This form is hermetic and identical from the script's point of view.
  local root; root=$(make_repo)
  local sub="$root/sub.git"
  git init -q --bare "$sub"
  local seed; seed=$(mktemp -d)
  git init -q -b main "$seed/s"; git -C "$seed/s" config user.email t@t.t
  git -C "$seed/s" config user.name t
  echo one > "$seed/s/f"; git -C "$seed/s" add f; git -C "$seed/s" commit -qm one
  local subA; subA=$(git -C "$seed/s" rev-parse HEAD)
  echo two > "$seed/s/f"; git -C "$seed/s" commit -qam two
  local subB; subB=$(git -C "$seed/s" rev-parse HEAD)
  git -C "$seed/s" push -q "$sub" main

  add_wt "$root" staged pushed
  local wt="$root/repo/.claude/worktrees/staged"
  # A real, clean, fully-pushed submodule checkout at B — so the OLD code would judge
  # this gitlink to be mere drift and reap the worktree.
  git clone -q "$sub" "$wt/sub"
  # Parent tracks A and that commit is pushed; then stage the move to B.
  git -C "$wt" update-index --add --cacheinfo "160000,$subA,sub"
  git -C "$wt" commit -qm "track sub at A"
  git -C "$wt" push -q origin claude/staged
  git -C "$wt" update-index --cacheinfo "160000,$subB,sub"     # STAGED gitlink update
  touch -t 202001010000 "$wt"
  local st; st=$(git -C "$wt" status --porcelain | head -1)
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*staged .*uncommitted change'; then
    ok "KEEPs a STAGED submodule gitlink update"
  else
    bad "KEEPs a STAGED submodule gitlink update" "porcelain=[$st] $out"
  fi
  rm -rf "$root" "$seed"
}

t_reap_leaves_a_restorable_ref() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/spent" rev-parse HEAD)
  run "$root" apply >/dev/null
  if [ "$(git -C "$root/repo" rev-parse --verify --quiet "refs/reaped/$sha")" = "$sha" ]; then
    ok "reaping leaves refs/reaped/<sha> so the manifest SHA stays restorable"
  else
    bad "reaping leaves refs/reaped/<sha> so the manifest SHA stays restorable" \
        "$(git -C "$root/repo" for-each-ref refs/reaped)"
  fi
  rm -rf "$root"
}

t_keeps_parent_of_a_nested_worktree() {
  # `?? .claude/worktrees/` was in the ignore set, so a session worktree containing a
  # NESTED worktree read as clean — and reaping the parent recursively deleted the
  # nested one along with the only copy of its uncommitted work.
  local root; root=$(make_repo)
  # `.claude/` must be TRACKED for this to reproduce the real layout: with nothing
  # tracked under it git collapses the report to `?? .claude/`, and the fixture then
  # passes for the wrong reason (it did — the ablation caught it). The monorepo tracks
  # .claude/scripts, so a nested worktree really does surface as `?? .claude/worktrees/`.
  mkdir -p "$root/repo/.claude/scripts"
  echo tracked > "$root/repo/.claude/scripts/keep.sh"
  git -C "$root/repo" add .claude/scripts/keep.sh
  git -C "$root/repo" commit -qm "track .claude"
  git -C "$root/repo" push -q origin main
  add_wt "$root" spent pushed
  add_wt "$root" parent pushed
  local p="$root/repo/.claude/worktrees/parent"
  git -C "$root/repo" worktree add -q -b claude/nested "$p/.claude/worktrees/nested" main
  echo "sole copy" > "$p/.claude/worktrees/nested/precious.txt"
  touch -t 202001010000 "$p"
  local st; st=$(git -C "$p" status --porcelain)
  case "$st" in
    *".claude/worktrees/"*) ;;
    *) bad "KEEPs a worktree that contains a nested worktree" \
           "FIXTURE did not reproduce '?? .claude/worktrees/': [$st]"; rm -rf "$root"; return ;;
  esac
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*parent .*uncommitted change' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a worktree that contains a nested worktree"
  else
    bad "KEEPs a worktree that contains a nested worktree" "$out"
  fi
  rm -rf "$root"
}

t_aborts_when_the_manifest_cannot_be_written() {
  # A manifest failure is infrastructure, not a per-worktree verdict: it must abort with
  # a nonzero status, not keep the candidate and let the run report success.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  mkdir -p "$root/manifest.tsv"        # a DIRECTORY — the append can never succeed
  local out rc
  out=$("$SUT" "$root/repo" "$root/manifest.tsv" apply 24 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ -d "$root/repo/.claude/worktrees/spent" ]; then
    ok "aborts nonzero when the restore manifest cannot be written"
  else
    bad "aborts nonzero when the restore manifest cannot be written" "rc=$rc $out"
  fi
  rm -rf "$root"
}

t_no_reaped_row_when_removal_is_aborted_after_recording() {
  # The durability rule writes the manifest row BEFORE deleting, but several gates can
  # still abort after that point. A row alone must therefore not read as "removed":
  # here the worktree is LOCKED between the pre-record gates and the removal, so the
  # run must leave a `pending` row and NO `reaped` row, and the directory must survive.
  # The failure must land AFTER record(), so an early KEEP gate cannot be what makes
  # this pass — a read-only parent directory lets every gate succeed and then makes the
  # removal itself fail. Asserting the `pending` row EXISTS is what rules out the
  # vacuous case where the worktree never reached record() at all.
  local root; root=$(make_repo)
  add_wt "$root" stuck pushed
  chmod a-w "$root/repo/.claude/worktrees"          # entries can no longer be unlinked
  local rc
  "$SUT" "$root/repo" "$root/manifest.tsv" apply 24 >/dev/null 2>&1; rc=$?
  chmod u+w "$root/repo/.claude/worktrees"
  local pending_rows reaped_rows
  pending_rows=$(awk -F'\t' '$5=="pending"' "$root/manifest.tsv" 2>/dev/null | wc -l | tr -d ' ')
  reaped_rows=$(awk -F'\t' '$5=="reaped"' "$root/manifest.tsv" 2>/dev/null | wc -l | tr -d ' ')
  # rc must be NON-ZERO: a removal that fails after every gate passed is an
  # infrastructure failure, not an ordinary KEEP, and must not report a healthy sweep.
  if [ -d "$root/repo/.claude/worktrees/stuck" ] && [ "$rc" -ne 0 ] \
     && [ "${pending_rows:-0}" -eq 1 ] && [ "${reaped_rows:-0}" -eq 0 ]; then
    ok "a removal that fails after all gates exits non-zero, leaving 'pending' only"
  else
    bad "a removal that fails after all gates exits non-zero, leaving 'pending' only" \
        "rc=$rc dir=$([ -d "$root/repo/.claude/worktrees/stuck" ] && echo present || echo GONE) pending=$pending_rows reaped=$reaped_rows [$(cat "$root/manifest.tsv" 2>/dev/null)]"
  fi
  rm -rf "$root"
}

t_completion_write_failure_after_removal_is_loud() {
  # The completion record can fail AFTER the directory is gone, which would otherwise
  # leave a real deletion looking like an aborted attempt.
  #
  # SCOPE — what this forces and what it does not. record() appends with a shell
  # redirect and then VERIFIES with grep -qxF; only the verification is shimmable from
  # outside (the append is a builtin redirect, and permission tricks cannot be timed
  # between the pending and completion writes). So this drives the completion record to
  # FAIL and asserts the property that matters operationally: the run exits non-zero
  # with the directory gone, so a real deletion can never pass silently as an abort.
  # The narrower "append physically lost" variant is covered by the documented
  # reconciliation rule (pending + absent path == deleted), not by this test.
  local root; root=$(make_repo)
  add_wt "$root" gone pushed
  local shim="$root/shim"; mkdir -p "$shim"
  cat > "$shim/grep" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *"	reaped") exit 1 ;; esac      # tab-reaped: the completion verify only
done
exec /usr/bin/grep "$@"
SHIM
  chmod +x "$shim/grep"
  local rc
  PATH="$shim:$PATH" "$SUT" "$root/repo" "$root/manifest.tsv" apply 24 >/dev/null 2>&1; rc=$?
  local pending_rows reaped_rows
  pending_rows=$(awk -F'\t' '$5=="pending"' "$root/manifest.tsv" 2>/dev/null | wc -l | tr -d ' ')
  reaped_rows=$(awk -F'\t' '$5=="reaped"' "$root/manifest.tsv" 2>/dev/null | wc -l | tr -d ' ')
  # Directory gone + a durable `pending` row + NON-ZERO exit. The pending row must be
  # present: without it the deletion would be entirely unrecorded, which is the state
  # the pre-delete durability rule exists to prevent.
  if [ ! -d "$root/repo/.claude/worktrees/gone" ] && [ "$rc" -ne 0 ] \
     && [ "${pending_rows:-0}" -eq 1 ]; then
    ok "a failed completion record after removal exits non-zero and stays reconcilable"
  else
    bad "a failed completion record after removal exits non-zero and stays reconcilable" \
        "rc=$rc dir=$([ -d "$root/repo/.claude/worktrees/gone" ] && echo present || echo GONE) pending=$pending_rows reaped=$reaped_rows"
  fi
  rm -rf "$root"
}

t_never_touches_an_unregistered_directory() {
  # An ordinary directory under .claude/worktrees/ is NOT a worktree. Having no .git
  # file, every `git -C` call walks up to the main checkout, whose clean+pushed state
  # made it look eligible — and the rm -rf fallback would delete its contents.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  local junk="$root/repo/.claude/worktrees/not-a-worktree"
  mkdir -p "$junk"; echo "important" > "$junk/data.txt"
  touch -t 202001010000 "$junk"
  local out; out=$(run "$root" apply)
  if [ -f "$junk/data.txt" ] \
     && printf '%s' "$out" | grep -q 'KEEP .*not-a-worktree .*not a registered worktree'; then
    ok "never deletes an unregistered directory under the worktree root"
  else
    bad "never deletes an unregistered directory under the worktree root" \
        "data=$([ -f "$junk/data.txt" ] && echo present || echo GONE) $out"
  fi
  rm -rf "$root"
}

t_keeps_files_hidden_by_index_flags() {
  # `git status` cannot see edits to assume-unchanged / skip-worktree files, so a
  # worktree holding only such edits reads as clean and would be reaped.
  # BOTH bits are covered: ls-files -v marks assume-unchanged lowercase and
  # skip-worktree uppercase `S`, and a lowercase-only pattern missed the latter.
  local root; root=$(make_repo)
  local flag pass_all=1
  for flag in assume-unchanged skip-worktree; do
    add_wt "$root" spent pushed
    add_wt "$root" "hidden-$flag" pushed
    local h="$root/repo/.claude/worktrees/hidden-$flag"
    git -C "$h" update-index "--$flag" file.txt
    echo "edited invisibly" >> "$h/file.txt"
    local out; out=$(run "$root")
    if ! printf '%s' "$out" | grep -q "KEEP .*hidden-$flag .*assume-unchanged" \
       || ! printf '%s' "$out" | grep -q '^REAP  .*spent'; then
      pass_all=0
      bad "KEEPs a worktree whose edits are hidden by index flags ($flag)" "$out"
    fi
    rm -rf "$root"; root=$(make_repo)
  done
  [ "$pass_all" -eq 1 ] && ok "KEEPs worktrees hidden by BOTH assume-unchanged and skip-worktree"
  rm -rf "$root"
}

t_index_flag_gate_survives_a_large_index() {
  # The gate was `printf ... | grep -q`. grep -q exits at its FIRST match, printf then
  # takes SIGPIPE, and under `set -o pipefail` the pipeline reports failure — so the
  # condition evaluated FALSE and the gate silently failed open. It only manifests once
  # ls-files -v output exceeds the pipe buffer, which the small fixtures never did.
  # This builds a large index with the flagged file sorted FIRST, so grep matches early
  # and leaves a lot of unread output behind it.
  local root; root=$(make_repo)
  add_wt "$root" bigidx pushed
  local b="$root/repo/.claude/worktrees/bigidx"
  mkdir -p "$b/bulk"
  ( cd "$b" && for i in $(seq 1 3000); do
      printf 'x\n' > "bulk/padding-file-with-a-longish-name-$i.txt"
    done )
  # The flagged path must sort FIRST. ls-files -v emits in index (path) order, so a
  # match on line 1 is what makes grep -q exit early and hand printf a SIGPIPE with
  # most of the output still unread — flagging a late-sorting path (file.txt sorts
  # after bulk/) lets grep drain the whole stream and reproduces nothing.
  printf 'flagged\n' > "$b/000-flagged.txt"
  git -C "$b" add -A >/dev/null 2>&1
  git -C "$b" commit -qm "bulk" >/dev/null 2>&1
  git -C "$b" push -q origin claude/bigidx >/dev/null 2>&1
  git -C "$b" update-index --skip-worktree 000-flagged.txt
  echo "invisible edit" >> "$b/000-flagged.txt"
  touch -t 202001010000 "$b"
  local bytes; bytes=$(git -C "$b" ls-files -v | wc -c | tr -d ' ')
  local out; out=$(run "$root")
  if [ "${bytes:-0}" -lt 65536 ]; then
    bad "index-flag gate survives a large index" "FIXTURE too small: ls-files -v = ${bytes}B (<64K pipe buffer)"
  elif printf '%s' "$out" | grep -q 'KEEP .*bigidx .*assume-unchanged'; then
    ok "index-flag gate survives a large index (${bytes}B of ls-files output)"
  else
    bad "index-flag gate survives a large index" "bytes=$bytes $(printf '%s' "$out" | grep bigidx)"
  fi
  rm -rf "$root"
}

t_keeps_untracked_when_showUntrackedFiles_is_no() {
  # status.showUntrackedFiles=no would otherwise hide authored untracked files entirely.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" hushed pushed
  git -C "$root/repo" config status.showUntrackedFiles no
  echo "only copy" > "$root/repo/.claude/worktrees/hushed/notes.md"
  touch -t 202001010000 "$root/repo/.claude/worktrees/hushed"
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*hushed .*uncommitted change'; then
    ok "KEEPs untracked files even under status.showUntrackedFiles=no"
  else
    bad "KEEPs untracked files even under status.showUntrackedFiles=no" "$out"
  fi
  rm -rf "$root"
}

t_keeps_parent_of_nested_worktree_even_when_ignored() {
  # The untracked-directory signal is defeated by a .gitignore covering
  # .claude/worktrees/ — status then emits nothing at all for the nested worktree, and
  # reaping the parent would recursively delete it. The registered-worktree list is the
  # authoritative signal and owes nothing to ignore rules.
  local root; root=$(make_repo)
  printf '.claude/worktrees/\n' > "$root/repo/.gitignore"
  git -C "$root/repo" add .gitignore
  git -C "$root/repo" commit -qm "ignore worktrees"
  git -C "$root/repo" push -q origin main
  add_wt "$root" spent pushed
  add_wt "$root" parent2 pushed
  local p="$root/repo/.claude/worktrees/parent2"
  git -C "$root/repo" worktree add -q -b claude/nested2 "$p/.claude/worktrees/nested2" main
  echo "sole copy" > "$p/.claude/worktrees/nested2/precious.txt"
  touch -t 202001010000 "$p"
  # Prove the fixture really does hide it from status, or the test proves nothing.
  local st; st=$(git -C "$p" status --porcelain --untracked-files=all)
  local out; out=$(run "$root")
  if [ -n "$st" ]; then
    bad "KEEPs a parent whose nested worktree is hidden by .gitignore" \
        "FIXTURE did not hide it: [$st]"
  elif printf '%s' "$out" | grep -q 'KEEP .*parent2 .*contains a registered worktree'; then
    ok "KEEPs a parent whose nested worktree is hidden by .gitignore"
  else
    bad "KEEPs a parent whose nested worktree is hidden by .gitignore" "$out"
  fi
  rm -rf "$root"
}

t_keeps_worktree_with_orphaned_reflog_commit() {
  # HEAD can be remotely reachable while the reflog still holds an earlier UNPUSHED
  # commit (commit, then reset back to the pushed one). The per-worktree reflog dies
  # with the directory, so that commit's only reference goes with it.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" reflog pushed
  local w="$root/repo/.claude/worktrees/reflog"
  echo "work in progress" > "$w/wip.txt"
  git -C "$w" add wip.txt
  git -C "$w" commit -qm "unpushed wip"
  local lost; lost=$(git -C "$w" rev-parse HEAD)
  git -C "$w" reset -q --hard HEAD~1          # HEAD back to the pushed commit
  touch -t 202001010000 "$w"
  local out; out=$(run "$root")
  if printf '%s' "$out" | grep -q 'KEEP .*reflog .*reflog holds commit' \
     && printf '%s' "$out" | grep -q '^REAP  .*spent'; then
    ok "KEEPs a worktree whose reflog holds an otherwise-unreachable commit"
  else
    bad "KEEPs a worktree whose reflog holds an otherwise-unreachable commit" \
        "lost=$lost $out"
  fi
  rm -rf "$root"
}

t_keeps_worktree_with_operation_in_progress() {
  # A worktree mid-rebase holds that operation's state only in its own admin dir, so
  # reaping it destroys work no commit or reflog accounts for.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" rebasing pushed
  local w="$root/repo/.claude/worktrees/rebasing"
  # Build a genuine conflicting rebase rather than faking the marker file.
  echo one > "$w/file.txt"; git -C "$w" commit -qam "side"
  git -C "$w" branch -q other main
  git -C "$w" checkout -q other
  echo two > "$w/file.txt"; git -C "$w" commit -qam "other side"
  git -C "$w" rebase "claude/rebasing" >/dev/null 2>&1 || true   # expected to conflict
  local gd; gd=$(git -C "$w" rev-parse --absolute-git-dir 2>/dev/null)
  touch -t 202001010000 "$w"
  local out; out=$(run "$root")
  if [ ! -e "$gd/rebase-merge" ] && [ ! -e "$gd/rebase-apply" ]; then
    bad "KEEPs a worktree with a git operation in progress" \
        "FIXTURE produced no rebase state in $gd"
  elif printf '%s' "$out" | grep -q 'KEEP .*rebasing .*operation in progress'; then
    ok "KEEPs a worktree with a git operation in progress"
  else
    bad "KEEPs a worktree with a git operation in progress" "$out"
  fi
  rm -rf "$root"
}

t_dry_run_writes_no_manifest_and_removes_nothing() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  run "$root" dry-run >/dev/null
  if [ ! -e "$root/manifest.tsv" ] && [ -d "$root/repo/.claude/worktrees/spent" ]; then
    ok "dry-run writes no manifest and removes nothing"
  else
    bad "dry-run writes no manifest and removes nothing" \
        "manifest=$([ -e "$root/manifest.tsv" ] && echo yes || echo no) dir=$([ -d "$root/repo/.claude/worktrees/spent" ] && echo present || echo GONE)"
  fi
  rm -rf "$root"
}

t_apply_removes_and_records() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" work unpushed
  run "$root" apply >/dev/null
  # NB: compare the exact tab-delimited BRANCH field. A substring grep is unusable
  # here: every manifest path contains '.claude/worktrees/', which contains BOTH
  # '/work' and 'claude/work' — so a naive grep reports the spared branch as recorded.
  # only 'reaped' rows count as removals — a 'pending' row may be an aborted attempt
  local branches; branches=$(awk -F'\t' '$5=="reaped"{print $2}' "$root/manifest.tsv" 2>/dev/null)
  if [ ! -d "$root/repo/.claude/worktrees/spent" ] \
     && [ -d "$root/repo/.claude/worktrees/work" ] \
     && printf '%s\n' "$branches" | grep -qxF 'claude/spent' \
     && ! printf '%s\n' "$branches" | grep -qxF 'claude/work'; then
    ok "apply removes the spent worktree, records it, and spares the unpushed one"
  else
    bad "apply removes the spent worktree, records it, and spares the unpushed one" \
        "$(ls "$root/repo/.claude/worktrees" 2>/dev/null; cat "$root/manifest.tsv" 2>/dev/null)"
  fi
  rm -rf "$root"
}

t_rejects_bad_mode() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  run "$root" alpply >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -d "$root/repo/.claude/worktrees/spent" ]; then
    ok "rejects an invalid MODE without deleting anything"
  else
    bad "rejects an invalid MODE without deleting anything" "rc=$rc"
  fi
  rm -rf "$root"
}

printf 'worktree-cleanup.sh contract tests\n'
t_reaps_spent
t_keeps_unpushed
t_keeps_detached_orphan
t_keeps_dirty
t_ignores_tool_noise
t_keeps_untracked_real_file
t_keeps_young
t_keeps_active_ownership_claim
t_reaps_expired_ownership_claim
t_keeps_active_claim_mutex
t_age_gate_works_with_gnu_stat
t_keeps_locked
t_keeps_staged_gitlink_update
t_reap_leaves_a_restorable_ref
t_keeps_live_cwd
t_keeps_live_cwd_in_subdir_with_regex_metachars
t_keeps_parent_of_a_nested_worktree
t_aborts_when_the_manifest_cannot_be_written
t_no_reaped_row_when_removal_is_aborted_after_recording
t_completion_write_failure_after_removal_is_loud
t_never_touches_an_unregistered_directory
t_keeps_files_hidden_by_index_flags
t_index_flag_gate_survives_a_large_index
t_keeps_untracked_when_showUntrackedFiles_is_no
t_keeps_parent_of_nested_worktree_even_when_ignored
t_keeps_worktree_with_orphaned_reflog_commit
t_keeps_worktree_with_operation_in_progress
t_dry_run_writes_no_manifest_and_removes_nothing
t_apply_removes_and_records
t_rejects_bad_mode
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
