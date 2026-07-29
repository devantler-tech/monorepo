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
  git -C "$root/repo" worktree add -q -b "claude/$name" \
      "$root/repo/.claude/worktrees/$name" main 2>/dev/null
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
  local branches; branches=$(awk -F'\t' '{print $2}' "$root/manifest.tsv" 2>/dev/null)
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
t_keeps_live_cwd
t_dry_run_writes_no_manifest_and_removes_nothing
t_apply_removes_and_records
t_rejects_bad_mode
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
