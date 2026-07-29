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
t_age_gate_works_with_gnu_stat
t_keeps_locked
t_keeps_staged_gitlink_update
t_reap_leaves_a_restorable_ref
t_keeps_live_cwd
t_keeps_live_cwd_in_subdir_with_regex_metachars
t_dry_run_writes_no_manifest_and_removes_nothing
t_apply_removes_and_records
t_rejects_bad_mode
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
