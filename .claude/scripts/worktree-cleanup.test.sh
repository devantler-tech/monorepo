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
  if grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q 'KEEP .*work .*unpushed commit' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q 'KEEP .*orph .*unpushed commit' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q 'KEEP .*dirty .*uncommitted change' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q '^REAP  .*noisy' <<<"$out"; then
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
  if grep -q 'KEEP .*untracked .*uncommitted change' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q 'KEEP .*fresh .*age .*< 24h' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
    ok "KEEPs a worktree younger than min_age_hours"
  else
    bad "KEEPs a worktree younger than min_age_hours" "$out"
  fi
  rm -rf "$root"
}


# #2831: the summary separates abandoned work (a KEEP no sweep will ever turn into a REAP)
# from trees that are only waiting to age out, so a growing unreapable pile is visible.
# Controls: a spent tree still reaps, and a YOUNG dirty tree is kept for its age, which is
# transient, so it must NOT count as stuck.
t_counts_stuck_work_separately() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  add_wt "$root" work unpushed
  add_wt "$root" dirty pushed
  echo edited >> "$root/repo/.claude/worktrees/dirty/file.txt"
  touch -t 202001010000 "$root/repo/.claude/worktrees/dirty"
  add_wt "$root" fresh pushed
  echo edited >> "$root/repo/.claude/worktrees/fresh/file.txt"
  touch "$root/repo/.claude/worktrees/fresh"
  local out; out=$(run "$root")
  if grep -q '^REAP  .*spent' <<<"$out" \
     && grep -q 'KEEP .*fresh .*age .*< 24h' <<<"$out" \
     && grep -q 'reaped=1 kept=3 stuck=2 ' <<<"$out" \
     && grep -q '2 of the kept worktree(s) hold abandoned work' <<<"$out"; then
    ok "counts abandoned work as stuck, apart from trees still ageing out"
  else
    bad "counts abandoned work as stuck, apart from trees still ageing out" "$out"
  fi
  rm -rf "$root"

  root=$(make_repo)
  add_wt "$root" spent pushed
  out=$(run "$root")
  if grep -q 'reaped=1 kept=0 stuck=0 ' <<<"$out" && ! grep -q 'abandoned work' <<<"$out"; then
    ok "reports stuck=0 and no salvage hint when nothing is stuck"
  else
    bad "reports stuck=0 and no salvage hint when nothing is stuck" "$out"
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
  if grep -q 'KEEP .*claimed .*active ownership claim' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q '^REAP  .*expired-claim' <<<"$out"; then
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
     && grep -q 'KEEP .*mutex-held .*ownership mutex' <<<"$out" \
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
  if grep -q 'KEEP .*live .*live process CWD' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -qF 'live process CWD' <<<"$out" \
     && ! grep -qF "REAP   $odd" <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q '^REAP  .*spent' <<<"$out" \
     && grep -q 'KEEP .*fresh .*age .*< 24h' <<<"$out" \
     && ! grep -qi 'unbound variable' <<<"$out"; then
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
  if grep -q 'KEEP .*held .*locked' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  if grep -q 'KEEP .*staged .*uncommitted change' <<<"$out"; then
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
  if grep -q 'KEEP .*parent .*uncommitted change' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
    ok "KEEPs a worktree that contains a nested worktree"
  else
    bad "KEEPs a worktree that contains a nested worktree" "$out"
  fi
  rm -rf "$root"
}

# add_sub_wt <root> <name> <sub-origin> — a pushed candidate worktree with an initialised,
# clean, fully-pushed submodule at `sub` that gitignores .claude/worktrees/ (the real
# ksail layout), plus a tracked .claude/scripts so a path-pattern detector would have
# something ordinary to misfire on. Every step is status-checked: a fixture that silently
# builds no submodule would let the KEEP assertion pass on nothing.
add_sub_wt() {
  local root=$1 name=$2 sub=$3 wt="$1/repo/.claude/worktrees/$2"
  add_wt "$root" "$name" pushed || return 1
  git -c protocol.file.allow=always clone -q "$sub" "$wt/sub" || return 1
  local subsha; subsha=$(git -C "$wt/sub" rev-parse HEAD) || return 1
  printf '[submodule "sub"]\n\tpath = sub\n\turl = %s\n' "$sub" > "$wt/.gitmodules"
  mkdir -p "$wt/.claude/scripts" && echo tracked > "$wt/.claude/scripts/keep.sh"
  git -C "$wt" add .gitmodules .claude/scripts/keep.sh &&
    git -C "$wt" update-index --add --cacheinfo "160000,$subsha,sub" &&
    git -C "$wt" commit -qm "add sub" &&
    git -C "$wt" push -q origin "claude/$name" || return 1
  touch -t 202001010000 "$wt"
}


t_keeps_submodule_owned_worktree_created_during_the_sweep() {
  # #2588 review: the initial scan is not enough. A submodule-owned worktree created
  # after it — and before removal — must still stop the reap. The lsof shim creates it
  # from inside the pre-removal re-check's own live-process read, i.e. strictly after
  # the initial scan saw the candidate as clean.
  local name="KEEPs a submodule-owned worktree created during the sweep"
  local root; root=$(make_repo)
  local seed; seed=$(mktemp -d)
  git init -q -b main "$seed/s" && git -C "$seed/s" config user.email t@t.t &&
    git -C "$seed/s" config user.name t
  printf '.claude/worktrees/\n' > "$seed/s/.gitignore"
  git -C "$seed/s" add .gitignore && git -C "$seed/s" commit -qm base
  git init -q --bare -b main "$root/sub.git" && git -C "$seed/s" push -q "$root/sub.git" main

  add_wt "$root" spent pushed                        # control: plain spent worktree
  if ! add_sub_wt "$root" late "$root/sub.git"; then
    bad "$name" "FIXTURE: build failed"; rm -rf "$root" "$seed"; return
  fi
  local p="$root/repo/.claude/worktrees/late"
  local nested="$p/sub/.claude/worktrees/subwt"

  local real_lsof; real_lsof=$(command -v lsof) || real_lsof=
  if [ -z "$real_lsof" ]; then
    bad "$name" "FIXTURE: no lsof on PATH to pass through to"; rm -rf "$root" "$seed"; return
  fi
  local shim="$root/shim" flag="$root/lsof-calls"; mkdir -p "$shim"
  cat > "$shim/lsof" <<SHIM
#!/usr/bin/env bash
# First call is the initial snapshot; every later one is a pre-removal re-check.
if [ -e "$flag" ] && [ ! -e "$nested" ]; then
  git -C "$p/sub" worktree add -q -b wip "$nested" main >/dev/null 2>&1 &&
    echo "sole copy" > "$nested/precious.txt"
fi
: > "$flag"
exec "$real_lsof" "\$@"
SHIM
  chmod +x "$shim/lsof"

  local out; out=$(PATH="$shim:$PATH" "$SUT" "$root/repo" "$root/manifest.tsv" apply 24 2>&1)
  if [ ! -e "$nested/precious.txt" ]; then
    bad "$name" "FIXTURE: the shim never created the nested worktree, or it was deleted: $out"
  elif grep -q '^KEEP  *late .*submodule-owned worktree appeared during the sweep (sub/\.claude/worktrees/subwt)' <<<"$out" \
     && [ -d "$p" ] && [ ! -d "$root/repo/.claude/worktrees/spent" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root" "$seed"
}

t_keeps_parent_of_a_submodule_owned_worktree() {
  # #2588: the nested-worktree gate reads the PARENT repo's registered list, so a
  # worktree registered to an initialised SUBMODULE inside the candidate was invisible,
  # and reaping the candidate deleted it with the only copy of its uncommitted work.
  local root; root=$(make_repo)
  local seed; seed=$(mktemp -d)
  git init -q -b main "$seed/s" && git -C "$seed/s" config user.email t@t.t &&
    git -C "$seed/s" config user.name t
  printf '.claude/worktrees/\n' > "$seed/s/.gitignore"
  git -C "$seed/s" add .gitignore && git -C "$seed/s" commit -qm base
  git init -q --bare -b main "$root/sub.git" && git -C "$seed/s" push -q "$root/sub.git" main

  add_wt "$root" spent pushed                        # control: plain spent worktree
  if ! add_sub_wt "$root" subctl "$root/sub.git" ||  # control: submodule, no nested wt
     ! add_sub_wt "$root" subown "$root/sub.git"; then
    bad "KEEPs a worktree that contains a submodule-owned worktree" "FIXTURE: build failed"
    rm -rf "$root" "$seed"; return
  fi
  local p="$root/repo/.claude/worktrees/subown"
  local nested="$p/sub/.claude/worktrees/subwt"
  git -C "$p/sub" worktree add -q -b wip "$nested" main || {
    bad "KEEPs a worktree that contains a submodule-owned worktree" "FIXTURE: nested add failed"
    rm -rf "$root" "$seed"; return; }
  echo "sole copy" > "$nested/precious.txt"
  touch -t 202001010000 "$p"

  # Preconditions that keep the test honest (see #2588's acceptance criteria): the
  # parent repo must NOT know the nested worktree, or the existing gate would pass this;
  # and the candidate must read clean, or an earlier gate would mask the one under test.
  local nested_real; nested_real=$(cd "$nested" && pwd -P)
  local registered; registered=$(git -C "$root/repo" worktree list --porcelain)
  if grep -qF "$nested_real" <<<"$registered"; then
    bad "KEEPs a worktree that contains a submodule-owned worktree" \
        "FIXTURE: parent repo registers the nested worktree — the old gate would pass"
    rm -rf "$root" "$seed"; return
  fi
  local st; st=$(git -C "$p" status --porcelain)
  if [ -n "$st" ]; then
    bad "KEEPs a worktree that contains a submodule-owned worktree" \
        "FIXTURE: candidate is not clean, an earlier gate would mask this one: [$st]"
    rm -rf "$root" "$seed"; return
  fi

  local out; out=$(run "$root")
  if grep -q '^KEEP  *subown .*submodule-owned worktree (sub/\.claude/worktrees/subwt)' <<<"$out" \
     && grep -q '^REAP  *subctl ' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
    ok "KEEPs a worktree that contains a submodule-owned worktree"
  else
    bad "KEEPs a worktree that contains a submodule-owned worktree" "$out"
  fi
  rm -rf "$root" "$seed"
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
     && grep -q 'KEEP .*not-a-worktree .*not a registered worktree' <<<"$out"; then
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
    if ! grep -q "KEEP .*hidden-$flag .*assume-unchanged" <<<"$out" \
       || ! grep -q '^REAP  .*spent' <<<"$out"; then
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
  elif grep -q 'KEEP .*bigidx .*assume-unchanged' <<<"$out"; then
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
  if grep -q 'KEEP .*hushed .*uncommitted change' <<<"$out"; then
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
  elif grep -q 'KEEP .*parent2 .*contains a registered worktree' <<<"$out"; then
    ok "KEEPs a parent whose nested worktree is hidden by .gitignore"
  else
    bad "KEEPs a parent whose nested worktree is hidden by .gitignore" "$out"
  fi
  rm -rf "$root"
}

t_reaps_a_spent_nested_worktree() {
  # A session worktree can itself hold worktrees at <session>/.claude/worktrees/<name> —
  # the agent write-boundary hook requires that placement — and the candidate loop used to
  # be a single-level glob over WT_ROOT, so those were evaluated by NO sweep at any age.
  # They accumulated without bound AND pinned their parent through the
  # "contains a registered worktree" gate, leaking the pair permanently.
  local root; root=$(make_repo)
  add_wt "$root" spent pushed            # control must still reap
  add_wt "$root" parent3 pushed
  local p="$root/repo/.claude/worktrees/parent3"
  git -C "$root/repo" worktree add -q -b claude/nested3 \
    "$p/.claude/worktrees/nested3" main || {
      bad "reaps a spent NESTED worktree" "FIXTURE: nested worktree add failed"
      rm -rf "$root"; return; }
  git -C "$root/repo" push -q origin claude/nested3
  touch -t 202001010000 "$p/.claude/worktrees/nested3" "$p"
  local out; out=$(run "$root")
  # The label is WT_ROOT-relative, so the nested path is what identifies it: two nested
  # worktrees under different parents share a basename.
  # The parent must be KEPT, but the REASON is deliberately not asserted: without a
  # .gitignore the untracked `?? .claude/worktrees/` trips the uncommitted-changes gate
  # first, and that gate runs before the registered-worktree gate. Which one fires is
  # t_keeps_parent_of_a_nested_worktree's subject; this test is about the child being
  # enumerated at all.
  if grep -q '^REAP  *parent3/\.claude/worktrees/nested3 ' <<< "$out" \
     && grep -q '^KEEP  *parent3 ' <<< "$out" \
     && grep -q '^REAP  .*spent' <<< "$out"; then
    ok "reaps a spent NESTED worktree while keeping its parent"
  else
    bad "reaps a spent NESTED worktree while keeping its parent" "$out"
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
  if grep -q 'KEEP .*reflog .*reflog holds commit' <<<"$out" \
     && grep -q '^REAP  .*spent' <<<"$out"; then
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
  elif grep -q 'KEEP .*rebasing .*operation in progress' <<<"$out"; then
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
     && grep -qxF 'claude/spent' <<<"$branches" \
     && ! grep -qxF 'claude/work' <<<"$branches"; then
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

# --- squash-merged branches (#2678) ------------------------------------------------
# Under squash-merge a merged branch's own commits are never ancestors of main, and the
# remote branch is deleted after merge, so the graph test reports them "unpushed"
# forever. Only a MERGED/CLOSED PR whose recorded head equals the worktree's HEAD proves
# they are redundant. These fixtures point origin at a GitHub-shaped URL AFTER pushing
# (the script never talks to the network) and shim `gh` to return canned PR evidence.

# add_merged_wt <root> <name> — a branch that was pushed, then had its remote branch
# deleted and pruned, exactly as a squash-merged PR branch looks locally.
add_merged_wt() {
  local root=$1 name=$2
  add_wt "$root" "$name" unpushed || return 1
  local wt="$root/repo/.claude/worktrees/$name"
  git -C "$wt" push -q origin "claude/$name" || return 1
  git -C "$wt" push -q origin --delete "claude/$name" || return 1
  touch -t 202001010000 "$wt"
}

# gh_shim <root> — an OPEN-only query prints the Nth line of $root/gh-open for its Nth call
# (a count; "0" when absent), so a PR can reopen between two queries. Otherwise `gh` prints $root/gh-out (TSV state<TAB>headRefOid per line), or
# fails when $root/gh-fail exists. Every invocation's argv is appended to $root/gh-args.
gh_shim() {
  local root=$1 shim="$1/ghshim"; mkdir -p "$shim"
  cat > "$shim/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$root/gh-args"
[ -e "$root/gh-fail" ] && { echo "HTTP 502" >&2; exit 1; }
[ -e "$root/gh-hang" ] && sleep 30
case "\$*" in
  *"--state open"*)
    n=\$(( \$(cat "$root/gh-open-calls" 2>/dev/null || echo 0) + 1 ))
    echo "\$n" > "$root/gh-open-calls"
    line=\$(sed -n "\${n}p" "$root/gh-open" 2>/dev/null)
    echo "\${line:-0}"; exit 0 ;;
esac
[ -e "$root/gh-out" ] && cat "$root/gh-out"
exit 0
SHIM
  chmod +x "$shim/gh" || return 1
  printf '%s' "$shim"
}

github_origin() { git -C "$1/repo" remote set-url origin https://github.com/devantler-tech/fixture.git; }

run_gh() { # <root> <shim> -> stdout
  PATH="$2:$PATH" "$SUT" "$1/repo" "$1/manifest.tsv" dry-run 24 2>&1
}

t_reaps_squash_merged_worktree() {
  local root; root=$(make_repo)
  add_merged_wt "$root" merged || { bad "reaps a squash-merged worktree" "FIXTURE"; rm -rf "$root"; return; }
  add_wt "$root" work unpushed
  # add_wt commits identical content in the same second, so without a distinct commit
  # `work` would share `merged`'s SHA and inherit its evidence.
  echo distinct > "$root/repo/.claude/worktrees/work/distinct.txt"
  git -C "$root/repo/.claude/worktrees/work" add distinct.txt
  git -C "$root/repo/.claude/worktrees/work" commit -qm distinct
  touch -t 202001010000 "$root/repo/.claude/worktrees/work"
  github_origin "$root"
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/merged" rev-parse HEAD)
  printf 'MERGED\t%s\n' "$sha" > "$root/gh-out"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q '^REAP  .*merged' <<<"$out" \
     && grep -q 'KEEP .*work ' <<<"$out" \
     && grep -q -- '--repo devantler-tech/fixture .*--head claude/merged' "$root/gh-args"; then
    ok "reaps a squash-merged worktree whose PR head equals HEAD"
  else
    bad "reaps a squash-merged worktree whose PR head equals HEAD" "$out // $(cat "$root/gh-args" 2>/dev/null)"
  fi
  rm -rf "$root"
}

t_keeps_merged_branch_when_pr_head_differs() {
  local root; root=$(make_repo)
  add_merged_wt "$root" moved || { bad "keeps on PR head mismatch" "FIXTURE"; rm -rf "$root"; return; }
  github_origin "$root"
  printf 'MERGED\t%s\n' 0123456789abcdef0123456789abcdef01234567 > "$root/gh-out"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q 'KEEP .*moved .*unpushed commit' <<<"$out"; then
    ok "KEEPs a merged branch whose current HEAD is not the PR's recorded head"
  else
    bad "KEEPs a merged branch whose current HEAD is not the PR's recorded head" "$out"
  fi
  rm -rf "$root"
}

t_keeps_branch_with_open_pr() {
  local root; root=$(make_repo)
  add_merged_wt "$root" live || { bad "keeps with open PR" "FIXTURE"; rm -rf "$root"; return; }
  github_origin "$root"
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/live" rev-parse HEAD)
  printf 'OPEN\t%s\nCLOSED\t%s\n' "$sha" "$sha" > "$root/gh-out"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q 'KEEP .*live .*unpushed commit' <<<"$out"; then
    ok "KEEPs a branch that still has an OPEN PR"
  else
    bad "KEEPs a branch that still has an OPEN PR" "$out"
  fi
  rm -rf "$root"
}

t_keeps_when_pr_query_fails() {
  local root; root=$(make_repo)
  add_merged_wt "$root" blind || { bad "keeps on gh failure" "FIXTURE"; rm -rf "$root"; return; }
  github_origin "$root"
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/blind" rev-parse HEAD)
  printf 'MERGED\t%s\n' "$sha" > "$root/gh-out"; : > "$root/gh-fail"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q 'KEEP .*blind .*unpushed commit.*PR evidence unavailable' <<<"$out"; then
    ok "KEEPs (fail closed) when the PR query fails"
  else
    bad "KEEPs (fail closed) when the PR query fails" "$out"
  fi
  rm -rf "$root"
}

t_keeps_when_pr_query_hangs() {
  local root; root=$(make_repo)
  add_merged_wt "$root" stalled || { bad "keeps on a hung PR query" "FIXTURE"; rm -rf "$root"; return; }
  github_origin "$root"
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/stalled" rev-parse HEAD)
  printf 'MERGED\t%s\n' "$sha" > "$root/gh-out"; : > "$root/gh-hang"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local start out elapsed
  start=$(date +%s)
  out=$(WORKTREE_CLEANUP_GH_DEADLINE=1 run_gh "$root" "$shim")
  elapsed=$(( $(date +%s) - start ))
  if grep -q 'KEEP .*stalled .*PR evidence unavailable: query exceeded 1s' <<<"$out" \
     && [ "$elapsed" -lt 20 ]; then
    ok "KEEPs (fail closed) when the PR query outlives its deadline"
  else
    bad "KEEPs (fail closed) when the PR query outlives its deadline" "elapsed=${elapsed}s $out"
  fi
  rm -rf "$root"
}

t_keeps_branch_whose_open_pr_is_beyond_history() {
  local root; root=$(make_repo)
  add_merged_wt "$root" crowded || { bad "keeps an open PR beyond history" "FIXTURE"; rm -rf "$root"; return; }
  github_origin "$root"
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/crowded" rev-parse HEAD)
  # History shows only the MERGED row (an older OPEN PR fell past its cap); the OPEN
  # query still sees one.
  printf 'MERGED\t%s\n' "$sha" > "$root/gh-out"; echo 1 > "$root/gh-open"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q 'KEEP .*crowded .*unpushed commit' <<<"$out"; then
    ok "KEEPs a branch whose OPEN PR the capped history query would miss"
  else
    bad "KEEPs a branch whose OPEN PR the capped history query would miss" "$out"
  fi
  rm -rf "$root"
}

t_keeps_when_pr_reopens_before_removal() {
  local root; root=$(make_repo)
  add_merged_wt "$root" reopened || { bad "keeps on PR reopen before removal" "FIXTURE"; rm -rf "$root"; return; }
  github_origin "$root"
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/reopened" rev-parse HEAD)
  # First OPEN query: none. The re-check under the mutex: one — the PR reopened.
  printf 'MERGED\t%s\n' "$sha" > "$root/gh-out"; printf '0\n1\n' > "$root/gh-open"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(PATH="$shim:$PATH" "$SUT" "$root/repo" "$root/manifest.tsv" apply 24 2>&1)
  if [ -d "$root/repo/.claude/worktrees/reopened" ]  && grep -q 'KEEP .*reopened .*PR evidence no longer holds' <<<"$out"; then
    ok "KEEPs a worktree whose PR reopened between the evidence query and removal"
  else
    bad "KEEPs a worktree whose PR reopened between the evidence query and removal" "$out"
  fi
  rm -rf "$root"
}

t_records_merged_pr_head_evidence() {
  local root; root=$(make_repo)
  add_merged_wt "$root" landed || { bad "records merged-pr-head evidence" "FIXTURE"; rm -rf "$root"; return; }
  github_origin "$root"
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/landed" rev-parse HEAD)
  printf 'MERGED\t%s\n' "$sha" > "$root/gh-out"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(PATH="$shim:$PATH" "$SUT" "$root/repo" "$root/manifest.tsv" apply 24 2>&1)
  local row; row=$(grep -F "$sha" "$root/manifest.tsv" 2>/dev/null)
  if [ ! -e "$root/repo/.claude/worktrees/landed" ] \
     && grep -q 'merged-pr-head;no-live-process' <<<"$row" \
     && ! grep -q 'reachable-from-remote' <<<"$row"; then
    ok "records a squash-merged reap as merged-pr-head, not reachable-from-remote"
  else
    bad "records a squash-merged reap as merged-pr-head, not reachable-from-remote" "row=$row // $out"
  fi
  rm -rf "$root"
}

t_keeps_merged_branch_on_non_github_origin() {
  local root; root=$(make_repo)
  add_merged_wt "$root" local || { bad "keeps on non-GitHub origin" "FIXTURE"; rm -rf "$root"; return; }
  local sha; sha=$(git -C "$root/repo/.claude/worktrees/local" rev-parse HEAD)
  printf 'MERGED\t%s\n' "$sha" > "$root/gh-out"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q 'KEEP .*local .*unpushed commit' <<<"$out" && [ ! -e "$root/gh-args" ]; then
    ok "KEEPs, without querying, when origin is not a devantler-tech GitHub repo"
  else
    bad "KEEPs, without querying, when origin is not a devantler-tech GitHub repo" "$out"
  fi
  rm -rf "$root"
}

t_keeps_merged_branch_with_orphaned_reflog_commit() {
  local root; root=$(make_repo)
  add_wt "$root" rewound unpushed || { bad "keeps merged+orphan reflog" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/rewound"
  # A commit that is then reset away: it lives only in this worktree's reflog.
  echo lost > "$wt/lost.txt"; git -C "$wt" add lost.txt; git -C "$wt" commit -qm lost
  git -C "$wt" reset -q --hard HEAD~1
  # Both pushes are the fixture: without them the branch was never pushed-then-deleted, and
  # an earlier gate could produce the expected KEEP on its own.
  if ! { git -C "$wt" push -q origin claude/rewound && git -C "$wt" push -q origin --delete claude/rewound; }; then
    bad "keeps merged+orphan reflog" "FIXTURE: push-then-delete failed"; rm -rf "$root"; return
  fi
  touch -t 202001010000 "$wt"
  github_origin "$root"
  printf 'MERGED\t%s\n' "$(git -C "$wt" rev-parse HEAD)" > "$root/gh-out"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q 'KEEP .*rewound .*HEAD reflog holds commit' <<<"$out"; then
    ok "KEEPs a merged branch whose reflog holds a commit outside the PR"
  else
    bad "KEEPs a merged branch whose reflog holds a commit outside the PR" "$out"
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
t_counts_stuck_work_separately
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
t_keeps_parent_of_a_submodule_owned_worktree
t_keeps_submodule_owned_worktree_created_during_the_sweep
t_aborts_when_the_manifest_cannot_be_written
t_no_reaped_row_when_removal_is_aborted_after_recording
t_completion_write_failure_after_removal_is_loud
t_never_touches_an_unregistered_directory
t_keeps_files_hidden_by_index_flags
t_index_flag_gate_survives_a_large_index
t_keeps_untracked_when_showUntrackedFiles_is_no
t_keeps_parent_of_nested_worktree_even_when_ignored
t_reaps_a_spent_nested_worktree
t_keeps_worktree_with_orphaned_reflog_commit
t_keeps_worktree_with_operation_in_progress
t_dry_run_writes_no_manifest_and_removes_nothing
t_apply_removes_and_records
t_rejects_bad_mode
t_reaps_squash_merged_worktree
t_keeps_merged_branch_when_pr_head_differs
t_keeps_branch_with_open_pr
t_keeps_when_pr_query_fails
t_keeps_when_pr_query_hangs
t_records_merged_pr_head_evidence
t_keeps_branch_whose_open_pr_is_beyond_history
t_keeps_when_pr_reopens_before_removal
t_keeps_merged_branch_on_non_github_origin
t_keeps_merged_branch_with_orphaned_reflog_commit
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
