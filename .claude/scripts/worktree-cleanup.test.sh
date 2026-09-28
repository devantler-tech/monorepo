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

# age_tree <path> — backdate a path to 2020. For a worktree, every entry in it and the
# admin index and HEAD reflog too: salvage measures age from the newest work, not the
# directory alone.
age_tree() {
  local p admin f
  for p in "$@"; do
    if [ -d "$p" ] && admin=$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null) \
       && [ "$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$p" && pwd -P)" ]; then
      find "$p" -mindepth 1 -exec touch -h -t 202001010000 {} + 2>/dev/null
      for f in "$admin/index" "$admin/logs/HEAD"; do [ -e "$f" ] && touch -t 202001010000 "$f"; done
    fi
    touch -t 202001010000 "$p"
  done
}

# Salvage age counts a path's ctime (#3642), and `touch` cannot backdate a ctime, so every
# fixture's ctime is "now". This `stat` shim, first on PATH for the whole file, reports a
# ctime query (`-c %Z` / `-f %c`) as the path's mtime, which makes age_tree's backdating
# cover ctime too. A path listed in $CTIME_FRESH (one per line) reports its real ctime,
# which is how a test says "this inode changed just now". Every other query passes through.
REAL_STAT=$(command -v stat)
CTIME_SHIM_DIR=$(mktemp -d)
CTIME_FRESH="$CTIME_SHIM_DIR/fresh"
: > "$CTIME_FRESH"
trap 'rm -rf "$CTIME_SHIM_DIR"' EXIT
cat > "$CTIME_SHIM_DIR/stat" <<EOF
#!/usr/bin/env bash
path="\${!#}"
if grep -qxF -- "\$path" '$CTIME_FRESH'; then exec '$REAL_STAT' "\$@"; fi
args=()
for a in "\$@"; do
  case "\$a" in %Z) args+=(%Y) ;; %c) args+=(%m) ;; *) args+=("\$a") ;; esac
done
exec '$REAL_STAT' "\${args[@]}"
EOF
chmod +x "$CTIME_SHIM_DIR/stat"
export PATH="$CTIME_SHIM_DIR:$PATH"

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
  age_tree "$root/repo/.claude/worktrees/$name"
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
  age_tree "$root/repo/.claude/worktrees/orph"
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
  age_tree "$root/repo/.claude/worktrees/noisy"
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
  age_tree "$root/repo/.claude/worktrees/untracked"
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
  age_tree "$root/repo/.claude/worktrees/dirty"
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
  age_tree "$w"
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
  age_tree "$w"
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
  age_tree "$w"
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
  age_tree "$root/repo/.claude/worktrees/$odd"
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
  age_tree "$wt"
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
  age_tree "$p"
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
  age_tree "$wt"
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
  age_tree "$p"

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
  age_tree "$junk"
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
  age_tree "$b"
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
  age_tree "$root/repo/.claude/worktrees/hushed"
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
  age_tree "$p"
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
  age_tree "$p/.claude/worktrees/nested3" "$p"
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
  age_tree "$w"
  local out; out=$(run "$root")
  if grep -q 'KEEP .*reflog .*reflog or pseudo-ref holds commit' <<<"$out" \
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
  age_tree "$w"
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
  age_tree "$wt"
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
  age_tree "$root/repo/.claude/worktrees/work"
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
  # A later sweep may still get the evidence, so this keep is not stuck (#2831).
  if grep -q ' stuck=0 ' <<<"$out"; then
    ok "does not count a keep on unavailable PR evidence as stuck"
  else
    bad "does not count a keep on unavailable PR evidence as stuck" "$out"
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
  age_tree "$wt"
  github_origin "$root"
  printf 'MERGED\t%s\n' "$(git -C "$wt" rev-parse HEAD)" > "$root/gh-out"
  local shim; shim=$(gh_shim "$root") || { bad "gh shim setup" "FIXTURE: shim not executable"; rm -rf "$root"; return; }
  local out; out=$(run_gh "$root" "$shim")
  if grep -q 'KEEP .*rewound .*reflog or pseudo-ref holds commit' <<<"$out"; then
    ok "KEEPs a merged branch whose reflog holds a commit outside the PR"
  else
    bad "KEEPs a merged branch whose reflog holds a commit outside the PR" "$out"
  fi
  rm -rf "$root"
}


# --- salvage (#2831) ------------------------------------------------------------------
run_salvage() { # <root> <mode> <salvage_age_hours> -> stdout
  "$SUT" "$1/repo" "$1/manifest.tsv" "$2" 24 "$3" 2>&1
}

# abandoned_wt <root> <name> — every kind of work salvage must preserve: an unpushed
# commit, a reflog-only commit, a staged edit, a different unstaged edit on top of it, a
# deletion and an untracked file. Prints nothing; the fixture is asserted by the tests.
abandoned_wt() {
  local root=$1 name=$2 wt
  add_wt "$root" "$name" unpushed || return 1
  wt="$root/repo/.claude/worktrees/$name"
  echo lost > "$wt/lost.txt"; git -C "$wt" add lost.txt; git -C "$wt" commit -qm "reflog only"
  git -C "$wt" reset -q --hard HEAD~1                  # that commit now lives only in the reflog
  echo staged > "$wt/file.txt"; git -C "$wt" add file.txt
  echo unstaged > "$wt/file.txt"                       # working tree differs from the index
  rm -f "$wt/new.txt"                                # an unstaged deletion
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
}

t_salvage_is_off_by_default() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed
  abandoned_wt "$root" aband || { bad "salvage is off by default" "FIXTURE"; rm -rf "$root"; return; }
  local out; out=$("$SUT" "$root/repo" "$root/manifest.tsv" apply 24 2>&1)
  if grep -q 'KEEP .*aband ' <<<"$out" && [ -d "$root/repo/.claude/worktrees/aband" ] \
     && grep -q '^REAPED .*spent' <<<"$out" \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "salvage is off by default: abandoned work stays a KEEP"
  else
    bad "salvage is off by default: abandoned work stays a KEEP" "$out"
  fi
  rm -rf "$root"
}

t_salvage_dry_run_reports_and_writes_nothing() {
  local root; root=$(make_repo)
  abandoned_wt "$root" aband || { bad "salvage dry-run" "FIXTURE"; rm -rf "$root"; return; }
  local before; before=$(find "$root/repo/.git/objects" -type f | wc -l)
  local out; out=$(run_salvage "$root" dry-run 1)
  local after; after=$(find "$root/repo/.git/objects" -type f | wc -l)
  if grep -q '^SALVAGE .*aband ' <<<"$out" && grep -q 'salvaged=1 ' <<<"$out" \
     && [ -d "$root/repo/.claude/worktrees/aband" ] && [ ! -e "$root/manifest.tsv" ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ] && [ "$before" = "$after" ]; then
    ok "salvage dry-run reports SALVAGE and writes no ref, object or manifest"
  else
    bad "salvage dry-run reports SALVAGE and writes no ref, object or manifest" "objects $before->$after $out"
  fi
  rm -rf "$root"
}

t_salvage_apply_preserves_every_kind_of_work() {
  local root; root=$(make_repo)
  add_wt "$root" spent pushed                       # control: an ordinary reap still happens
  abandoned_wt "$root" aband || { bad "salvage apply" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/aband"
  local head; head=$(git -C "$wt" rev-parse HEAD)
  local lost; lost=$(git -C "$wt" rev-parse 'HEAD@{1}')
  local out; out=$(run_salvage "$root" apply 1)
  local base; base=$(git -C "$root/repo" for-each-ref --format='%(refname)' 'refs/salvaged/*/head' | sed 's#/head$##')
  local problems=""
  [ -e "$wt" ] && problems="$problems worktree-still-present"
  grep -q '^SALVAGED .*aband .*refs/salvaged/' <<<"$out" || problems="$problems no-SALVAGED-line"
  grep -q '^REAPED .*spent' <<<"$out" || problems="$problems control-not-reaped"
  [ -n "$base" ] || problems="$problems no-salvage-ref"
  [ "$(git -C "$root/repo" rev-parse "$base/head" 2>/dev/null)" = "$head" ] || problems="$problems head"
  [ "$(git -C "$root/repo" rev-parse "$base/reflog/$lost" 2>/dev/null)" = "$lost" ] || problems="$problems reflog"
  [ "$(git -C "$root/repo" show "$base/index:file.txt" 2>/dev/null)" = staged ] || problems="$problems index"
  [ "$(git -C "$root/repo" show "$base/worktree:file.txt" 2>/dev/null)" = unstaged ] || problems="$problems worktree-edit"
  [ "$(git -C "$root/repo" show "$base/worktree:untracked.txt" 2>/dev/null)" = draft ] || problems="$problems untracked"
  git -C "$root/repo" cat-file -e "$base/worktree:new.txt" 2>/dev/null && problems="$problems deletion-lost"
  grep -q "salvaged=$base" "$root/manifest.tsv" 2>/dev/null || problems="$problems manifest"
  # The documented restore works: a new worktree at head plus the working-tree commit.
  local rs="$root/restore"
  # The documented sequence, exactly as the script header states it.
  if git -C "$root/repo" worktree add -q --detach "$rs" "$base/head" 2>/dev/null \
     && git -C "$rs" read-tree "$base/index" 2>/dev/null \
     && git -C "$rs" restore --source="$base/worktree" --worktree -- . 2>/dev/null; then
    [ "$(cat "$rs/untracked.txt" 2>/dev/null)" = draft ] && [ "$(cat "$rs/file.txt")" = unstaged ] \
      || problems="$problems restore-content"
    [ ! -e "$rs/new.txt" ] || problems="$problems restore-kept-a-deleted-file"
    [ "$(git -C "$rs" show :file.txt 2>/dev/null)" = staged ] || problems="$problems restore-index"
  else
    problems="$problems restore-failed"
  fi
  if [ -z "$problems" ]; then
    ok "salvage apply preserves commits, reflog, index, edits, deletions and untracked files, then reaps"
  else
    bad "salvage apply preserves commits, reflog, index, edits, deletions and untracked files, then reaps" "$problems :: $out"
  fi
  rm -rf "$root"
}

t_salvage_respects_its_age() {
  local root; root=$(make_repo)
  abandoned_wt "$root" aband || { bad "salvage age" "FIXTURE"; rm -rf "$root"; return; }
  local out; out=$(run_salvage "$root" apply 9999999)     # older than 2020, younger than this
  if grep -q 'KEEP .*aband .*unpushed commit' <<<"$out" && grep -q 'stuck=1 ' <<<"$out" \
     && [ -d "$root/repo/.claude/worktrees/aband" ]; then
    ok "salvage waits for salvage_age_hours; a younger stuck tree stays a KEEP"
  else
    bad "salvage waits for salvage_age_hours; a younger stuck tree stays a KEEP" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_an_embedded_repository() {
  local root; root=$(make_repo)
  add_wt "$root" emb pushed
  local wt="$root/repo/.claude/worktrees/emb"
  git init -q "$wt/inner"; echo x > "$wt/inner/x"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -Eq 'KEEP .*emb .*(nested repository|submodule repositories)' <<<"$out" && [ -f "$wt/inner/x" ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "salvage KEEPs untracked content git would record as an embedded repository"
  else
    bad "salvage KEEPs untracked content git would record as an embedded repository" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_oversized_work() {
  local root; root=$(make_repo)
  add_wt "$root" big pushed
  local wt="$root/repo/.claude/worktrees/big"
  head -c 20480 /dev/zero > "$wt/blob.bin"
  age_tree "$wt"
  local out; out=$(WORKTREE_SALVAGE_MAX_KB=8 run_salvage "$root" apply 1)
  if grep -q 'KEEP .*big .*more than 8 KB' <<<"$out" && [ -f "$wt/blob.bin" ]; then
    ok "salvage KEEPs a tree with more changed data than the salvage cap"
  else
    bad "salvage KEEPs a tree with more changed data than the salvage cap" "$out"
  fi
  rm -rf "$root"
}

# submodule_wt <root> <name> <dirty|staged> — a worktree whose submodule holds work
# salvage cannot capture. Hermetic form, as in t_keeps_staged_gitlink_update.
submodule_wt() {
  local root=$1 name=$2 kind=$3 sub seed subA subB wt
  sub="$root/sub.git"; [ -d "$sub" ] || git init -q --bare "$sub"
  seed="$root/seed-$name"
  git init -q -b main "$seed"; git -C "$seed" config user.email t@t.t; git -C "$seed" config user.name t
  echo one > "$seed/f"; git -C "$seed" add f; git -C "$seed" commit -qm one; subA=$(git -C "$seed" rev-parse HEAD)
  echo two > "$seed/f"; git -C "$seed" commit -qam two; subB=$(git -C "$seed" rev-parse HEAD)
  git -C "$seed" push -q "$sub" main
  add_wt "$root" "$name" pushed || return 1
  wt="$root/repo/.claude/worktrees/$name"
  git clone -q "$sub" "$wt/sub"
  git -C "$wt" update-index --add --cacheinfo "160000,$subA,sub"
  git -C "$wt" commit -qm "track sub at A"; git -C "$wt" push -q origin "claude/$name"
  if [ "$kind" = staged ]; then
    git -C "$wt" update-index --cacheinfo "160000,$subB,sub"
  else
    echo dirty >> "$wt/sub/f"                        # uncommitted work inside the submodule
  fi
  age_tree "$wt"
}

t_salvage_keeps_submodule_work() {
  local root; root=$(make_repo)
  if ! { submodule_wt "$root" subdirty dirty && submodule_wt "$root" substaged staged; }; then
    bad "salvage keeps submodule work" "FIXTURE"; rm -rf "$root"; return
  fi
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*subdirty .*in a submodule (cannot be salvaged)' <<<"$out" \
     && grep -q 'KEEP .*substaged .*in a submodule (cannot be salvaged)' <<<"$out" \
     && [ "$(tail -1 "$root/repo/.claude/worktrees/subdirty/sub/f")" = dirty ] \
     && [ -d "$root/repo/.claude/worktrees/substaged" ]; then
    ok "salvage KEEPs dirty and staged submodule work it cannot capture"
  else
    bad "salvage KEEPs dirty and staged submodule work it cannot capture" "$out"
  fi
  rm -rf "$root"
}

t_salvage_rejects_a_bad_age() {
  local root; root=$(make_repo)
  local out rc; out=$(run_salvage "$root" dry-run 1x); rc=$?
  if [ "$rc" -eq 2 ] && grep -q 'salvage_age_hours must be a non-negative integer' <<<"$out"; then
    ok "rejects a non-numeric salvage_age_hours"
  else
    bad "rejects a non-numeric salvage_age_hours" "rc=$rc $out"
  fi
  rm -rf "$root"
}


t_salvage_keeps_work_written_after_the_snapshot() {
  # The snapshot is taken under the mutex, but a process whose CWD is outside the worktree
  # can still write into it before the removal. The lsof shim does exactly that on its
  # third call: the first is the initial scan, the second the pre-snapshot re-check, the
  # third the post-snapshot re-check that must compare the tree against the snapshot.
  local name="salvage KEEPs work written after its snapshot"
  local root; root=$(make_repo)
  abandoned_wt "$root" aband || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/aband"
  local real_lsof; real_lsof=$(command -v lsof) || real_lsof=
  [ -n "$real_lsof" ] || { bad "$name" "FIXTURE: no lsof"; rm -rf "$root"; return; }
  local shim="$root/shim" count="$root/lsof-calls"; mkdir -p "$shim"
  cat > "$shim/lsof" <<SHIM
#!/usr/bin/env bash
n=\$(( \$(cat "$count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$count"
[ "\$n" -eq 3 ] && echo "written late" > "$wt/late.txt"
exec "$real_lsof" "\$@"
SHIM
  chmod +x "$shim/lsof"
  local out; out=$(PATH="$shim:$PATH" run_salvage "$root" apply 1)
  if [ ! -e "$wt/late.txt" ]; then
    bad "$name" "late file missing (never written, or deleted): $out"
  elif grep -q 'KEEP .*aband .*changed after the salvage snapshot' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_oversized_staged_only_work() {
  # A staged addition whose working-tree copy matches the index is invisible to
  # `ls-files -m -o`, yet the salvage index ref would make its blob permanent.
  local root; root=$(make_repo)
  add_wt "$root" bigstaged pushed
  local wt="$root/repo/.claude/worktrees/bigstaged"
  head -c 20480 /dev/zero > "$wt/blob.bin"; git -C "$wt" add blob.bin
  age_tree "$wt"
  local out; out=$(WORKTREE_SALVAGE_MAX_KB=8 run_salvage "$root" apply 1)
  if grep -q 'KEEP .*bigstaged .*more than 8 KB' <<<"$out" && [ -f "$wt/blob.bin" ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "salvage KEEPs a tree whose STAGED-only data exceeds the salvage cap"
  else
    bad "salvage KEEPs a tree whose STAGED-only data exceeds the salvage cap" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_submodule_work_at_a_quoted_path() {
  # Porcelain C-quotes a non-ASCII path, and a quoted submodule path fails the `.git`
  # lookup — so its uncommitted files were treated as salvageable, then deleted.
  local name="salvage KEEPs dirty submodule work at a path porcelain would quote"
  local root; root=$(make_repo)
  local sub="$root/subq.git" seed="$root/seedq" subA wt
  git init -q --bare -b main "$sub"; git init -q -b main "$seed"
  git -C "$seed" config user.email t@t.t; git -C "$seed" config user.name t
  echo one > "$seed/f"; git -C "$seed" add f; git -C "$seed" commit -qm one
  subA=$(git -C "$seed" rev-parse HEAD); git -C "$seed" push -q "$sub" main
  add_wt "$root" subq pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  wt="$root/repo/.claude/worktrees/subq"
  git clone -q "$sub" "$wt/süb"
  git -C "$wt" update-index --add --cacheinfo "160000,$subA,süb"
  git -C "$wt" commit -qm "track süb"; git -C "$wt" push -q origin claude/subq
  echo dirty >> "$wt/süb/f"
  age_tree "$wt"
  # Control: the fixture really produces a QUOTED porcelain path.
  local plain; plain=$(git -C "$wt" status --porcelain --ignore-submodules=none)
  if ! grep -q '"' <<<"$plain"; then
    bad "$name" "FIXTURE: porcelain did not quote the path"; rm -rf "$root"; return
  fi
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*subq .*in a submodule (cannot be salvaged)' <<<"$out" \
     && [ "$(tail -1 "$wt/süb/f" 2>/dev/null)" = dirty ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_namespaces_are_unique_per_worktree() {
  # Two nested worktrees share a basename and a HEAD. The date shim pins the salvage
  # timestamp, so both are salvaged "in the same second" deterministically.
  local name="salvage gives same-basename, same-HEAD worktrees distinct namespaces"
  local root; root=$(make_repo)
  local p1 p2 real_date shim
  add_wt "$root" pa pushed; add_wt "$root" pb pushed
  p1="$root/repo/.claude/worktrees/pa"; p2="$root/repo/.claude/worktrees/pb"
  if ! git -C "$root/repo" worktree add -q -b claude/dupa "$p1/.claude/worktrees/dup" main \
     || ! git -C "$root/repo" worktree add -q -b claude/dupb "$p2/.claude/worktrees/dup" main; then
    bad "$name" "FIXTURE: nested worktree add failed"; rm -rf "$root"; return
  fi
  git -C "$root/repo" push -q origin claude/dupa claude/dupb
  echo first > "$p1/.claude/worktrees/dup/work.txt"
  echo second > "$p2/.claude/worktrees/dup/work.txt"
  age_tree "$p1/.claude/worktrees/dup" "$p2/.claude/worktrees/dup" "$p1" "$p2"
  real_date=$(command -v date); shim="$root/shim"; mkdir -p "$shim"
  cat > "$shim/date" <<SHIM
#!/usr/bin/env bash
[ "\$*" = "-u +%Y%m%dT%H%M%SZ" ] && { echo 20200101T000000Z; exit 0; }
exec "$real_date" "\$@"
SHIM
  chmod +x "$shim/date"
  local out; out=$(PATH="$shim:$PATH" run_salvage "$root" apply 1)
  local bases; bases=$(git -C "$root/repo" for-each-ref --format='%(refname)' 'refs/salvaged/*/head' | sed 's#/head$##')
  local contents="" b
  while IFS= read -r b; do
    [ -n "$b" ] && contents="$contents $(git -C "$root/repo" show "$b/worktree:work.txt" 2>/dev/null)"
  done <<<"$bases"
  if [ "$(grep -c . <<<"$bases")" -eq 2 ] && grep -qw first <<<"$contents" \
     && grep -qw second <<<"$contents" \
     && [ ! -e "$p1/.claude/worktrees/dup" ] && [ ! -e "$p2/.claude/worktrees/dup" ]; then
    ok "$name"
  else
    bad "$name" "bases=[$bases] contents=[$contents] :: $out"
  fi
  rm -rf "$root"
}

# lsof_hook_shim <root> <call-number> <command> — prints a PATH dir whose lsof runs
# <command> on its <call-number>th invocation, then defers to the real lsof. Call 1 is
# the initial scan, 2 the pre-snapshot re-check, 3 the post-snapshot re-check.
lsof_hook_shim() {
  local root=$1 n=$2 cmd=$3 real_lsof shim="$1/shim" count="$1/lsof-calls"
  real_lsof=$(command -v lsof) || return 1
  mkdir -p "$shim"
  cat > "$shim/lsof" <<SHIM
#!/usr/bin/env bash
n=\$(( \$(cat "$count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$count"
[ "\$n" -eq $n ] && { $cmd; }
exec "$real_lsof" "\$@"
SHIM
  chmod +x "$shim/lsof"
  printf '%s' "$shim"
}

t_salvage_keeps_submodule_work_at_a_newline_path() {
  # -z output is NUL-delimited, but a path holding a newline would still be cut in two
  # once the records are read line by line, hiding the submodule behind a truncated path.
  local name="salvage KEEPs a worktree whose changed path holds a newline"
  local root; root=$(make_repo)
  local sub="$root/subn.git" seed="$root/seedn" subA wt sp=$'sub\nline'
  git init -q --bare -b main "$sub"; git init -q -b main "$seed"
  git -C "$seed" config user.email t@t.t; git -C "$seed" config user.name t
  echo one > "$seed/f"; git -C "$seed" add f; git -C "$seed" commit -qm one
  subA=$(git -C "$seed" rev-parse HEAD); git -C "$seed" push -q "$sub" main
  add_wt "$root" subn pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  wt="$root/repo/.claude/worktrees/subn"
  git clone -q "$sub" "$wt/$sp"
  git -C "$wt" update-index --add --cacheinfo "160000,$subA,$sp"
  git -C "$wt" commit -qm "track a newline submodule"; git -C "$wt" push -q origin claude/subn
  echo dirty >> "$wt/$sp/f"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*subn .*classify status' <<<"$out" \
     && [ "$(tail -1 "$wt/$sp/f" 2>/dev/null)" = dirty ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

# clean_submodule_wt <root> <name> — an old worktree with ordinary salvageable work (an
# untracked file) and an initialised submodule clean at its recorded gitlink, registered
# only in .gitmodules. Its submodule repository is at <worktree>/sub.
clean_submodule_wt() {
  local root=$1 name=$2 sub="$1/sub-$2.git" seed="$1/seed-$2" subA wt
  git init -q --bare -b main "$sub"; git init -q -b main "$seed"
  git -C "$seed" config user.email t@t.t; git -C "$seed" config user.name t
  echo one > "$seed/f"; git -C "$seed" add f; git -C "$seed" commit -qm one
  subA=$(git -C "$seed" rev-parse HEAD); git -C "$seed" push -q "$sub" main
  add_wt "$root" "$name" pushed || return 1
  wt="$root/repo/.claude/worktrees/$name"
  git clone -q "$sub" "$wt/sub"
  git -C "$wt/sub" config user.email t@t.t; git -C "$wt/sub" config user.name t
  git -C "$wt" update-index --add --cacheinfo "160000,$subA,sub"
  printf '[submodule "sub"]\n\tpath = sub\n\turl = %s\n' "$sub" > "$wt/.gitmodules"
  git -C "$wt" add .gitmodules
  git -C "$wt" commit -qm "track sub"; git -C "$wt" push -q origin "claude/$name"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
}

t_salvage_keeps_a_submodule_reflog_only_commit() {
  # The submodule is back at its recorded gitlink, so the parent's status has no entry
  # for it, but its reflog holds the only reference to a commit it made and reset away.
  local name="salvage KEEPs a submodule whose reflog holds the only copy of a commit"
  local root; root=$(make_repo)
  clean_submodule_wt "$root" subr || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subr" base lost
  base=$(git -C "$wt/sub" rev-parse HEAD)
  echo two >> "$wt/sub/f"; git -C "$wt/sub" commit -qam "only in the reflog"
  lost=$(git -C "$wt/sub" rev-parse HEAD)
  git -C "$wt/sub" reset -q --hard "$base"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -Eq 'KEEP .*subr .*(nested repository|submodule repositories)' <<<"$out" \
     && git -C "$wt/sub" cat-file -e "$lost" 2>/dev/null \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_branch_only_commit() {
  # A commit reachable only from a local submodule branch never touches HEAD's reflog.
  local name="salvage KEEPs a submodule whose local branch holds the only copy of a commit"
  local root; root=$(make_repo)
  clean_submodule_wt "$root" subb || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subb" tree side
  tree=$(git -C "$wt/sub" rev-parse 'HEAD^{tree}')
  side=$(git -C "$wt/sub" commit-tree "$tree" -p HEAD -m "only on a local branch")
  git -C "$wt/sub" update-ref refs/heads/side "$side"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -Eq 'KEEP .*subb .*(nested repository|submodule repositories)' <<<"$out" \
     && [ "$(git -C "$wt/sub" rev-parse refs/heads/side 2>/dev/null)" = "$side" ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_repository_created_after_the_snapshot() {
  # An ignored repository initialised after the snapshot changes nothing the snapshot
  # comparisons can see, and the removal would delete it with its commit.
  local name="salvage KEEPs a worktree that gained an ignored repository after the snapshot"
  local root; root=$(make_repo)
  add_wt "$root" latere pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/latere" shim
  printf 'late/\n' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  shim=$(lsof_hook_shim "$root" 3 "git init -q '$wt/late' && git -C '$wt/late' -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m late") \
    || { bad "$name" "FIXTURE: no lsof"; rm -rf "$root"; return; }
  local out; out=$(PATH="$shim:$PATH" run_salvage "$root" apply 1)
  if [ ! -d "$wt/late/.git" ]; then
    bad "$name" "late repository missing: $out"
  elif grep -q 'KEEP .*latere .*nested repository.*after the salvage snapshot' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_reflog_commit_made_after_the_snapshot() {
  # A commit made and reset away after the snapshot leaves HEAD, index and tree exactly as
  # snapshotted, so only a reflog comparison can see it.
  local name="salvage KEEPs a worktree that gained a reflog-only commit after its snapshot"
  local root; root=$(make_repo)
  abandoned_wt "$root" aband || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/aband" shim
  shim=$(lsof_hook_shim "$root" 3 "git -C '$wt' commit -qm late >/dev/null 2>&1 && git -C '$wt' reset -q --soft HEAD~1") \
    || { bad "$name" "FIXTURE: no lsof"; rm -rf "$root"; return; }
  local out; out=$(PATH="$shim:$PATH" run_salvage "$root" apply 1)
  local late; late=$(git -C "$wt" rev-parse 'HEAD@{1}' 2>/dev/null)
  if [ ! -d "$wt" ]; then
    bad "$name" "worktree removed: $out"
  elif [ "$(git -C "$wt" log -1 --format=%s "$late" 2>/dev/null)" != late ]; then
    bad "$name" "FIXTURE: no late reflog commit: $out"
  elif grep -q 'KEEP .*aband .*reflog-only commit appeared after the salvage snapshot' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_rechecks_its_cap_under_the_mutex() {
  # Data written between the first blocker check and the snapshot must still meet the cap.
  local name="salvage re-applies its size cap immediately before the snapshot"
  local root; root=$(make_repo)
  abandoned_wt "$root" aband || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/aband" shim
  # Backdated (with its directory, which dates the fixture's deleted path), so the
  # pre-snapshot age re-check passes and the cap is what must catch it.
  shim=$(lsof_hook_shim "$root" 2 "head -c 20480 /dev/zero > '$wt/late.bin' && touch -t 202001010000 '$wt/late.bin' '$wt'") \
    || { bad "$name" "FIXTURE: no lsof"; rm -rf "$root"; return; }
  local out; out=$(PATH="$shim:$PATH" WORKTREE_SALVAGE_MAX_KB=8 run_salvage "$root" apply 1)
  if grep -q 'KEEP .*aband .*more than 8 KB' <<<"$out" && [ -f "$wt/late.bin" ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_dry_run_keeps_a_conflicted_index() {
  # Conflict entries with no operation marker left (MERGE_HEAD removed): the index cannot
  # be written as a tree, so apply could never salvage it and dry-run must not promise to.
  local name="salvage dry-run KEEPs an index holding unmerged entries"
  local root; root=$(make_repo)
  add_wt "$root" conflicted pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/conflicted" a b
  a=$(printf 'ours\n' | git -C "$wt" hash-object -w --stdin)
  b=$(printf 'theirs\n' | git -C "$wt" hash-object -w --stdin)
  git -C "$wt" rm -q --cached file.txt
  printf '100644 %s 1\tfile.txt\n100644 %s 2\tfile.txt\n100644 %s 3\tfile.txt\n' "$a" "$a" "$b" \
    | git -C "$wt" update-index --index-info
  [ -n "$(git -C "$wt" ls-files -u)" ] || { bad "$name" "FIXTURE: no unmerged entries"; rm -rf "$root"; return; }
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*conflicted .*unmerged' <<<"$out" && ! grep -q '^SALVAGE .*conflicted' <<<"$out" \
     && grep -q 'salvaged=0 ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_preserves_ignored_tracked_paths() {
  # A force-added ignored file edited after staging, and a `rm --cached` file now ignored:
  # `add -A` from HEAD skips both, so their working-tree bytes would die with the removal.
  local name="salvage captures the working-tree bytes of every tracked path, ignored or not"
  local root; root=$(make_repo)
  add_wt "$root" ign pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/ign"
  printf 'forced.log\nfile.txt\n' > "$wt/.gitignore"
  echo v1 > "$wt/forced.log"; git -C "$wt" add -f forced.log
  echo v2 > "$wt/forced.log"                           # newer, unstaged bytes
  echo edited > "$wt/file.txt"; git -C "$wt" rm -q --cached file.txt
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  local base; base=$(git -C "$root/repo" for-each-ref --format='%(refname)' 'refs/salvaged/*/head' | sed 's#/head$##')
  local problems=""
  [ -n "$base" ] || problems="$problems no-salvage-ref"
  [ "$(git -C "$root/repo" show "$base/index:forced.log" 2>/dev/null)" = v1 ] || problems="$problems staged-forced"
  [ "$(git -C "$root/repo" show "$base/worktree:forced.log" 2>/dev/null)" = v2 ] || problems="$problems unstaged-forced"
  [ "$(git -C "$root/repo" show "$base/worktree:file.txt" 2>/dev/null)" = edited ] || problems="$problems rm-cached"
  [ ! -e "$wt" ] || problems="$problems not-reaped"
  if [ -z "$problems" ]; then ok "$name"; else bad "$name" "$problems :: $out"; fi
  rm -rf "$root"
}

t_salvage_leaves_untracked_tool_noise_out() {
  # #3641: a large untracked `.codex/` cache beside one real edit must neither be made
  # permanent by the salvage ref nor push the tree over the cap. A tracked `.agents/` file
  # is still work: its edit and a tracked deletion there are both captured. A nested
  # `sub/.codex/` is not the top-level noise directory, so it is captured too.
  local name="salvage leaves untracked .codex/.agents noise out and keeps tracked files there"
  local root; root=$(make_repo)
  add_wt "$root" noisy pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/noisy"
  mkdir -p "$wt/.agents" "$wt/sub/.codex"
  echo v1 > "$wt/.agents/tracked"; echo v1 > "$wt/.agents/doomed"
  git -C "$wt" add .agents; git -C "$wt" commit -qm "track .agents"
  git -C "$wt" push -q origin "claude/noisy"
  mkdir -p "$wt/.codex/cache"
  head -c 20480 /dev/zero > "$wt/.codex/cache/blob.bin"    # over the 8 KB cap on its own
  echo scratch > "$wt/.agents/untracked"
  echo v2 > "$wt/.agents/tracked"                          # tracked edit under the noise dir
  rm -f "$wt/.agents/doomed"                               # tracked deletion there
  echo nested > "$wt/sub/.codex/keep"
  echo real > "$wt/real.txt"                               # the one real edit
  age_tree "$wt"
  local out; out=$(WORKTREE_SALVAGE_MAX_KB=8 run_salvage "$root" apply 1)
  local base; base=$(git -C "$root/repo" for-each-ref --format='%(refname)' 'refs/salvaged/*/head' | sed 's#/head$##')
  local problems=""
  [ -n "$base" ] || problems="$problems no-salvage-ref"
  [ "$(git -C "$root/repo" show "$base/worktree:real.txt" 2>/dev/null)" = real ] || problems="$problems real-edit"
  [ "$(git -C "$root/repo" show "$base/worktree:.agents/tracked" 2>/dev/null)" = v2 ] || problems="$problems tracked-agents-edit"
  git -C "$root/repo" cat-file -e "$base/worktree:.agents/doomed" 2>/dev/null && problems="$problems tracked-deletion-lost"
  [ "$(git -C "$root/repo" show "$base/worktree:sub/.codex/keep" 2>/dev/null)" = nested ] || problems="$problems nested-codex"
  git -C "$root/repo" cat-file -e "$base/worktree:.codex/cache/blob.bin" 2>/dev/null && problems="$problems cache-captured"
  git -C "$root/repo" cat-file -e "$base/worktree:.agents/untracked" 2>/dev/null && problems="$problems agents-noise-captured"
  [ ! -e "$wt" ] || problems="$problems not-reaped"
  if [ -z "$problems" ]; then ok "$name"; else bad "$name" "$problems :: $out"; fi
  rm -rf "$root"
}

t_salvage_keeps_file_shaped_noise_names() {
  # Only the CONTENTS of the noise directories are noise. An untracked FILE named `.codex`
  # and a symlink named `.agents` are authored work, so both must reach the salvage ref
  # before the removal deletes them.
  local name="salvage captures a file or symlink named like a noise directory"
  local root; root=$(make_repo)
  add_wt "$root" named pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/named"
  echo notes > "$wt/.codex"
  ln -s file.txt "$wt/.agents"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  local base; base=$(git -C "$root/repo" for-each-ref --format='%(refname)' 'refs/salvaged/*/head' | sed 's#/head$##')
  local problems=""
  [ -n "$base" ] || problems="$problems no-salvage-ref"
  [ "$(git -C "$root/repo" show "$base/worktree:.codex" 2>/dev/null)" = notes ] || problems="$problems file-lost"
  [ "$(git -C "$root/repo" cat-file -p "$base/worktree:.agents" 2>/dev/null)" = file.txt ] || problems="$problems symlink-lost"
  [ ! -e "$wt" ] || problems="$problems not-reaped"
  if [ -z "$problems" ]; then ok "$name"; else bad "$name" "$problems :: $out"; fi
  rm -rf "$root"
}

t_salvage_reports_why_a_snapshot_failed() {
  # A staged submodule-to-file replacement makes the snapshot's gitlinks differ from HEAD's.
  # The reason is set inside snapshot_tree and must reach the KEEP line, not be lost.
  local name="salvage names the snapshot failure instead of a blank reason"
  local root; root=$(make_repo)
  local r="$root/repo" sub
  sub=$(git -C "$r" rev-parse HEAD)
  git -C "$r" update-index --add --cacheinfo "160000,$sub,sub"
  git -C "$r" commit -qm "add a gitlink"; git -C "$r" push -q origin main
  add_wt "$root" subfile pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$r/.claude/worktrees/subfile"
  git -C "$wt" rm -q --cached sub; rm -rf "$wt/sub"
  echo now-a-file > "$wt/sub"; git -C "$wt" add sub
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*subfile .*not salvaged: [^ ]' <<<"$out" && [ -f "$wt/sub" ] \
     && ! grep -q 'not salvaged: *$' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

# admin_sub_wt <root> <name> — a pushed worktree whose submodule was added with
# `git submodule add`, so its repository lives in the worktree's admin modules/ dir.
admin_sub_wt() {
  local root=$1 name=$2 wt="$1/repo/.claude/worktrees/$2"
  git init -q -b main "$root/subsrc" && echo one > "$root/subsrc/f" \
    && git -C "$root/subsrc" add f && git -C "$root/subsrc" -c user.email=t@t.t -c user.name=t commit -qm one || return 1
  add_wt "$root" "$name" pushed || return 1
  git -C "$wt" -c protocol.file.allow=always submodule add -q "$root/subsrc" sub >/dev/null 2>&1 || return 1
  git -C "$wt" commit -qm "add sub" && git -C "$wt" push -q origin "claude/$name" || return 1
  [ -d "$(git -C "$wt" rev-parse --absolute-git-dir)/modules/sub" ] || return 1
  git -C "$wt/sub" config user.email t@t.t && git -C "$wt/sub" config user.name t
}

t_salvage_keeps_a_removed_submodules_local_commit() {
  # The gitlink is gone from the index, but the submodule repository stays in the admin
  # directory the removal deletes, holding a commit no remote has.
  local name="salvage KEEPs a removed submodule's repository that holds a local-only commit"
  local root; root=$(make_repo)
  git init -q -b main "$root/subsrc" && echo one > "$root/subsrc/f" \
    && git -C "$root/subsrc" add f && git -C "$root/subsrc" -c user.email=t@t.t -c user.name=t commit -qm one \
    && add_wt "$root" subgone pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subgone"
  # Added and removed before any parent commit: neither HEAD nor the index has a gitlink.
  git -C "$wt" -c protocol.file.allow=always submodule add -q "$root/subsrc" sub >/dev/null 2>&1 \
    || { bad "$name" "FIXTURE: submodule add"; rm -rf "$root"; return; }
  echo two >> "$wt/sub/f"; git -C "$wt/sub" -c user.email=t@t.t -c user.name=t commit -qam "local only"
  git -C "$wt" rm -qf sub
  [ -d "$(git -C "$wt" rev-parse --absolute-git-dir)/modules/sub" ] \
    || { bad "$name" "FIXTURE: no retained submodule repository"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -Eq 'KEEP .*subgone .*(nested repository|submodule repositories)' <<<"$out" && [ -d "$wt" ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_hidden_index_edit_in_a_submodule() {
  local name="salvage KEEPs a submodule with an edit hidden by assume-unchanged"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subhide || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subhide"
  git -C "$wt/sub" update-index --assume-unchanged f; echo hidden >> "$wt/sub/f"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -Eq 'KEEP .*subhide .*(nested repository|submodule repositories)' <<<"$out" && grep -q hidden "$wt/sub/f" \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_beside_even_a_clean_admin_submodule() {
  # Salvage covers single-repository worktrees only: even a clean, remote-reachable
  # submodule keeps the worktree, so no submodule state has to be classified at all.
  local name="salvage KEEPs a worktree whose only other repository is a clean submodule"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subok || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subok"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*subok .*submodule repositories' <<<"$out" && [ -d "$wt" ] \
     && ! grep -q '^SALVAGED .*subok ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_per_worktree_ref() {
  local name="salvage KEEPs a commit held only by a per-worktree ref"
  local root; root=$(make_repo)
  add_wt "$root" wtref pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/wtref" c
  c=$(git -C "$wt" commit-tree 'HEAD^{tree}' -p HEAD -m wip) && git -C "$wt" update-ref refs/worktree/wip "$c" \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*wtref .*per-worktree refs' <<<"$out" && [ -d "$wt" ] \
     && [ "$(git -C "$wt" rev-parse refs/worktree/wip)" = "$c" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_an_intent_to_add_entry() {
  local name="salvage KEEPs an intent-to-add index entry"
  local root; root=$(make_repo)
  add_wt "$root" ita pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/ita"
  echo new > "$wt/later.txt"; git -C "$wt" add -N later.txt
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*ita .*intent-to-add' <<<"$out" && ! grep -q '^SALVAGE .*ita ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_dry_run_refuses_an_unsnappable_gitlink_change() {
  local name="salvage dry-run KEEPs a submodule replaced by a file (apply could not snapshot it)"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subdry || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subdry"
  rm -rf "$wt/sub"; echo now-a-file > "$wt/sub"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subdry .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subdry ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_hidden_edit_in_an_embedded_submodule() {
  # The submodule keeps its repository in an embedded .git directory, not the admin dir.
  local name="salvage KEEPs a hidden-index edit in a submodule with an embedded .git"
  local root; root=$(make_repo)
  clean_submodule_wt "$root" subemb || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subemb"
  [ -d "$wt/sub/.git" ] || { bad "$name" "FIXTURE: .git is not a directory"; rm -rf "$root"; return; }
  git -C "$wt/sub" update-index --assume-unchanged f; echo hidden >> "$wt/sub/f"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -Eq 'KEEP .*subemb .*(nested repository|submodule repositories)' <<<"$out" && grep -q hidden "$wt/sub/f" \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_unlisted_git_state() {
  # A sequencer left between cherry-picks carries no operation marker; the admin-dir
  # whitelist refuses it because the salvage refs cannot carry it.
  local name="salvage dry-run KEEPs a worktree whose git state holds a sequencer"
  local root; root=$(make_repo)
  add_wt "$root" seq pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/seq" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  mkdir -p "$admin/sequencer" && echo "pick deadbeef x" > "$admin/sequencer/todo"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*seq .*holds sequencer' <<<"$out" && ! grep -q '^SALVAGE .*seq ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_filtered_path() {
  local name="salvage dry-run KEEPs a changed path with a clean filter"
  local root; root=$(make_repo)
  add_wt "$root" filt pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/filt"
  echo '*.secret filter=strip' > "$wt/.gitattributes"
  git -C "$wt" config filter.strip.clean 'grep -v PRIVATE'
  printf 'public\nPRIVATE line\n' > "$wt/notes.secret"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*filt .*filter or conversion' <<<"$out" && ! grep -q '^SALVAGE .*filt ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_mid_bisect() {
  # A clean bisect in a submodule: status is clean and every commit is on a remote, but
  # the submodule repository the removal deletes holds the bisect state.
  local name="salvage KEEPs a worktree whose submodule is mid-bisect"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subbis || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subbis"
  git -C "$wt/sub" bisect start >/dev/null 2>&1 || { bad "$name" "FIXTURE: bisect start"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subbis .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subbis ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_when_file_modes_are_ignored() {
  local name="salvage dry-run KEEPs a worktree whose repository ignores file modes"
  local root; root=$(make_repo)
  add_wt "$root" nomode pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/nomode"
  git -C "$wt" config core.fileMode false
  chmod +x "$wt/file.txt"; echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*nomode .*core.fileMode=false' <<<"$out" && ! grep -q '^SALVAGE .*nomode ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_ignorecase_blocks_only_on_a_case_sensitive_filesystem() {
  # core.ignoreCase=true loses a case-only rename only where the filesystem distinguishes
  # case. The test asserts whichever branch this machine's filesystem exercises.
  local name="salvage refuses core.ignoreCase=true only on a case-sensitive filesystem"
  local root; root=$(make_repo)
  add_wt "$root" icase pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/icase" sensitive=yes
  git -C "$wt" config core.ignoreCase true
  echo draft > "$wt/untracked.txt"
  [ -e "$wt/UNTRACKED.TXT" ] && sensitive=no
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if { [ "$sensitive" = yes ] && grep -q 'KEEP .*icase .*core.ignoreCase=true' <<<"$out" \
         && ! grep -q '^SALVAGE .*icase ' <<<"$out"; } \
     || { [ "$sensitive" = no ] && grep -q '^SALVAGE .*icase ' <<<"$out"; }; then
    ok "$name (case-sensitive=$sensitive)"
  else
    bad "$name (case-sensitive=$sensitive)" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_that_ignores_file_modes() {
  local name="salvage KEEPs a worktree whose submodule ignores file modes"
  local root; root=$(make_repo)
  admin_sub_wt "$root" submode || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/submode"
  git -C "$wt/sub" config core.fileMode false; chmod +x "$wt/sub/f"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*submode .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*submode ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_preserves_a_commit_only_fetch_head_names() {
  # FETCH_HEAD sits in the admin directory the removal deletes and is not a reflog.
  local name="salvage preserves a commit only FETCH_HEAD names"
  local root; root=$(make_repo)
  add_wt "$root" fetched pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/fetched" c admin
  c=$(git -C "$wt" commit-tree 'HEAD^{tree}' -p HEAD -m fetched) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s\t\tbranch '"'"'gone'"'"' of origin\n' "$c" > "$admin/FETCH_HEAD"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*fetched ' <<<"$out" && [ ! -e "$wt" ] \
     && [ -n "$(git -C "$root/repo" for-each-ref --format='%(objectname)' "refs/salvaged/*/reflog/$c")" ]; then
    ok "$name"
  else
    bad "$name" "$out :: $(git -C "$root/repo" for-each-ref refs/salvaged)"
  fi
  rm -rf "$root"
}

t_pseudo_ref_only_commit_alone_triggers_salvage() {
  # Nothing else in the tree asks for salvage: the FETCH_HEAD commit is the only thing to
  # lose, so it must start the salvage (or keep the worktree) on its own.
  local name="a commit only FETCH_HEAD names triggers salvage with no other change"
  local root; root=$(make_repo)
  add_wt "$root" fetchonly pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/fetchonly" c admin
  c=$(git -C "$wt" commit-tree 'HEAD^{tree}' -p HEAD -m fetched) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s\t\tbranch '"'"'gone'"'"' of origin\n' "$c" > "$admin/FETCH_HEAD"
  age_tree "$wt"
  local off; off=$(run_salvage "$root" dry-run 0)
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*fetchonly .*pseudo-ref holds commit' <<<"$off" \
     && grep -q '^SALVAGED .*fetchonly ' <<<"$out" && [ ! -e "$wt" ] \
     && [ -n "$(git -C "$root/repo" for-each-ref --format='%(objectname)' "refs/salvaged/*/reflog/$c")" ]; then
    ok "$name"
  else
    bad "$name" "off: $off :: apply: $out :: $(git -C "$root/repo" for-each-ref refs/salvaged)"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_bare_repository_without_refs() {
  # A bare repository whose empty refs/ was lost still holds packed-refs and objects.
  local name="salvage KEEPs a worktree holding a bare repository whose refs/ is missing"
  local root; root=$(make_repo)
  add_wt "$root" norefs pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/norefs"
  { git init -q --bare "$wt/unique.git" && rm -rf "$wt/unique.git/refs"; } \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  printf 'unique.git/\n' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*norefs .*nested repository' <<<"$out" && [ -f "$wt/unique.git/HEAD" ] \
     && ! grep -q '^SALVAGED .*norefs' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

# pseudo_tag_wt <root> <name> -> a clean, pushed worktree whose FETCH_HEAD names an annotated
# tag object on its pushed HEAD; prints the tag object's id.
pseudo_tag_wt() {
  local root=$1 name=$2 wt admin tag
  add_wt "$root" "$name" pushed || return 1
  wt="$root/repo/.claude/worktrees/$name"
  tag=$(printf 'object %s\ntype commit\ntag only-fetched\ntagger t <t@t.t> 0 +0000\n\nmessage\n' \
    "$(git -C "$wt" rev-parse HEAD)" | git -C "$wt" hash-object -t tag -w --stdin) || return 1
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s\t\ttag '"'"'only-fetched'"'"' of origin\n' "$tag" > "$admin/FETCH_HEAD"
  age_tree "$wt"
  printf '%s\n' "$tag"
}

t_a_pseudo_ref_only_tag_keeps_a_clean_worktree() {
  local name="a tag object only FETCH_HEAD names keeps a clean pushed worktree"
  local root; root=$(make_repo)
  pseudo_tag_wt "$root" tagonly >/dev/null || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*tagonly .*only reference to a tag object' <<<"$out" \
     && [ -d "$root/repo/.claude/worktrees/tagonly" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_a_pseudo_ref_tag_a_ref_holds_does_not_keep() {
  # Control: once a ref names the tag object, the admin directory is not its only reference.
  local name="a FETCH_HEAD tag object that a ref also names does not keep the worktree"
  local root; root=$(make_repo)
  local tag; tag=$(pseudo_tag_wt "$root" tagheld) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  git -C "$root/repo" update-ref refs/tags/only-fetched "$tag" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local out; out=$(run_salvage "$root" dry-run 0)
  if grep -q '^REAP  .*tagheld' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_a_fresh_tracked_edit_in_an_old_worktree_is_not_salvaged() {
  # Editing a tracked file does not touch the worktree directory's mtime, so the directory
  # alone would make this edit look years old and salvage it at once.
  local name="a fresh edit to a tracked file in an old worktree is kept, not salvaged"
  local root; root=$(make_repo)
  add_wt "$root" freshedit pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/freshedit"
  age_tree "$wt"
  local dir_m; dir_m=$(stat -f %m "$wt" 2>/dev/null || stat -c %Y "$wt")
  echo "edited just now" > "$wt/file.txt"
  local after; after=$(stat -f %m "$wt" 2>/dev/null || stat -c %Y "$wt")
  [ "$dir_m" = "$after" ] || { bad "$name" "FIXTURE: editing a tracked file moved the directory mtime"; rm -rf "$root"; return; }
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*freshedit .*uncommitted change' <<<"$out" && ! grep -q '^SALVAGED .*freshedit' <<<"$out" \
     && [ "$(cat "$wt/file.txt")" = "edited just now" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_a_fresh_chmod_in_an_old_worktree_is_not_salvaged() {
  # `chmod +x` moves ctime, never mtime, so an mtime-only age reads it as years old (#3642).
  local name="a fresh chmod of an old edit is kept, not salvaged"
  local root; root=$(make_repo)
  add_wt "$root" freshmode pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/freshmode"
  echo "old edit" > "$wt/file.txt"
  chmod +x "$wt/file.txt"
  age_tree "$wt"
  # Control: with the chmod reported as old too, the same tree IS salvage-eligible.
  local ctl; ctl=$(run_salvage "$root" dry-run 1)
  grep -q '^SALVAGE .*freshmode' <<<"$ctl" \
    || { bad "$name" "FIXTURE: the aged tree is not salvage-eligible :: $ctl"; rm -rf "$root"; return; }
  printf '%s\n' "$wt/file.txt" > "$CTIME_FRESH"
  local out; out=$(run_salvage "$root" apply 1)
  : > "$CTIME_FRESH"
  if grep -q 'KEEP .*freshmode .*uncommitted change' <<<"$out" && ! grep -q '^SALVAGED .*freshmode' <<<"$out" \
     && [ -x "$wt/file.txt" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_staging_old_bytes_in_an_old_worktree_is_not_salvaged() {
  # `git add` of bytes that are already old moves no file time, only the index (#3642).
  local name="staging old bytes just now is kept, not salvaged"
  local root; root=$(make_repo)
  add_wt "$root" freshstage pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/freshstage"
  echo "old edit" > "$wt/file.txt"
  age_tree "$wt"
  local admin; admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  local before; before=$("$REAL_STAT" -f %m "$wt/file.txt" 2>/dev/null || "$REAL_STAT" -c %Y "$wt/file.txt")
  git -C "$wt" add file.txt
  local after; after=$("$REAL_STAT" -f %m "$wt/file.txt" 2>/dev/null || "$REAL_STAT" -c %Y "$wt/file.txt")
  [ "$before" = "$after" ] || { bad "$name" "FIXTURE: git add moved the file mtime"; rm -rf "$root"; return; }
  local out; out=$(run_salvage "$root" apply 1)
  if ! grep -q 'KEEP .*freshstage .*uncommitted change' <<<"$out" || grep -q '^SALVAGED .*freshstage' <<<"$out" \
     || [ "$(git -C "$wt" show :file.txt 2>/dev/null)" != "old edit" ]; then
    bad "$name" "$out"; rm -rf "$root"; return
  fi
  # Control: once the staging is old as well, the same tree IS salvage-eligible. This
  # also proves the sweep's own reads above left the index mtime where it was.
  touch -t 202001010000 "$admin/index"
  local ctl; ctl=$(run_salvage "$root" dry-run 1)
  if grep -q '^SALVAGE .*freshstage' <<<"$ctl"; then
    ok "$name"
  else
    bad "$name" "control: an old staged edit is not salvage-eligible :: $ctl"
  fi
  rm -rf "$root"
}

t_the_sweep_never_rewrites_a_worktree_index() {
  # age_tree leaves the index's cached stat data stale, so a status that may write would
  # refresh the index and turn its mtime into "work done now" (#3642).
  local name="the sweep's own reads never rewrite a worktree's index"
  local root; root=$(make_repo)
  add_wt "$root" noidx pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/noidx"
  echo "old edit" > "$wt/file.txt"; git -C "$wt" add file.txt
  age_tree "$wt"
  local admin; admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  local before; before=$("$REAL_STAT" -f %m "$admin/index" 2>/dev/null || "$REAL_STAT" -c %Y "$admin/index")
  local out; out=$(run_salvage "$root" dry-run 1)
  local after; after=$("$REAL_STAT" -f %m "$admin/index" 2>/dev/null || "$REAL_STAT" -c %Y "$admin/index")
  if [ "$before" = "$after" ] && grep -q '^SALVAGE .*noidx' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "index mtime $before -> $after :: $out"
  fi
  rm -rf "$root"
}

t_a_referenced_pseudo_ref_tag_does_not_block_salvage() {
  # A tag object a durable ref also holds survives the admin directory, so it must not
  # block salvaging an unrelated abandoned edit.
  local name="a FETCH_HEAD tag object a ref also holds does not block salvage"
  local root; root=$(make_repo)
  local tag; tag=$(pseudo_tag_wt "$root" tagsalv) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/tagsalv"
  git -C "$root/repo" update-ref refs/tags/only-fetched "$tag" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*tagsalv ' <<<"$out" && [ ! -e "$wt" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_a_missing_fetch_head_object_does_not_keep_a_clean_worktree() {
  # An object the store no longer holds has nothing left to lose, so a stale FETCH_HEAD
  # naming one must not strand a clean, pushed worktree as stuck on every sweep.
  local name="a FETCH_HEAD naming a pruned object does not keep a clean pushed worktree"
  local root; root=$(make_repo)
  add_wt "$root" stalefh pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/stalefh" admin gone
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  gone=0123456789abcdef0123456789abcdef01234567
  git -C "$wt" cat-file -e "$gone" 2>/dev/null && { bad "$name" "FIXTURE: object exists"; rm -rf "$root"; return; }
  printf '%s\t\tbranch '"'"'gone'"'"' of origin\n' "$gone" > "$admin/FETCH_HEAD"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 0)
  if grep -q '^REAP  .*stalefh' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_a_not_for_merge_fetch_head_commit_does_not_keep_a_clean_worktree() {
  # A plain `git fetch` records every other remote branch's tip as not-for-merge. One from
  # a squash-merged, deleted branch is reachable from no remote, but it is not this
  # worktree's work: with salvage off, a clean pushed worktree must still reap.
  local name="a not-for-merge FETCH_HEAD commit does not keep a clean pushed worktree"
  local root; root=$(make_repo)
  add_wt "$root" nfm pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/nfm" admin c
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  c=$(git -C "$wt" commit-tree -m "another branch" "$(git -C "$wt" rev-parse 'HEAD^{tree}')") \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  printf '%s\tnot-for-merge\tbranch '"'"'gone'"'"' of origin\n' "$c" > "$admin/FETCH_HEAD"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 0)
  if grep -q '^REAP  .*nfm' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  # Control: the same commit on a merge-eligible line is this worktree's and keeps it.
  printf '%s\t\tbranch '"'"'gone'"'"' of origin\n' "$c" > "$admin/FETCH_HEAD"
  age_tree "$wt"
  out=$(run_salvage "$root" dry-run 0)
  if grep -q '^KEEP.*nfm.*reachable from nowhere else' <<<"$out"; then
    ok "$name (control: merge-eligible entry keeps)"
  else
    bad "$name (control: merge-eligible entry keeps)" "$out"
  fi
  rm -rf "$root"
}

t_new_work_during_the_sweep_resets_the_salvage_age() {
  # A candidate that qualifies by its old unpushed commit alone must not be salvaged and
  # removed when fresh work appears after the initial scan: the lsof shim writes a new
  # untracked file from inside the pre-snapshot re-check's live-process read.
  local name="new work during the sweep resets the salvage age"
  local root; root=$(make_repo)
  add_wt "$root" fresh unpushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local p="$root/repo/.claude/worktrees/fresh"
  age_tree "$p"
  local real_lsof; real_lsof=$(command -v lsof) || real_lsof=
  if [ -z "$real_lsof" ]; then
    bad "$name" "FIXTURE: no lsof on PATH to pass through to"; rm -rf "$root"; return
  fi
  local shim="$root/shim" flag="$root/lsof-calls"; mkdir -p "$shim"
  cat > "$shim/lsof" <<SHIM
#!/usr/bin/env bash
# First call is the initial snapshot; every later one is a pre-removal re-check.
if [ -e "$flag" ] && [ ! -e "$p/today.txt" ]; then echo today > "$p/today.txt"; fi
: > "$flag"
exec "$real_lsof" "\$@"
SHIM
  chmod +x "$shim/lsof"
  local out; out=$(PATH="$shim:$PATH" run_salvage "$root" apply 1)
  if [ ! -e "$p/today.txt" ]; then
    bad "$name" "FIXTURE: the shim never wrote the new file, or it was deleted: $out"
  elif grep -q '^KEEP  *fresh .*work changed during the sweep' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_inherited_git_location_variables_do_not_redirect_the_sweep() {
  # A caller's GIT_DIR / GIT_INDEX_FILE must not decide which repository the sweep reads.
  local name="inherited GIT_DIR and GIT_INDEX_FILE do not change the sweep's verdicts"
  local root; root=$(make_repo)
  abandoned_wt "$root" inherit || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local clean redirected
  clean=$(run_salvage "$root" dry-run 1 | grep -v '^worktree-cleanup: ')
  redirected=$(GIT_DIR="$root/origin.git" GIT_INDEX_FILE="$root/bogus.index" \
    run_salvage "$root" dry-run 1 | grep -v '^worktree-cleanup: ')
  if [ -n "$clean" ] && [ "$clean" = "$redirected" ]; then
    ok "$name"
  else
    bad "$name" "clean: $clean :: redirected: $redirected"
  fi
  rm -rf "$root"
}

t_salvage_preserves_the_old_side_of_a_reflog_entry() {
  # A truncated reflog whose oldest entry is `unpushed -> HEAD`: the unpushed commit is named
  # only on the OLD side, which `reflog show` never prints.
  local name="salvage preserves a commit named only on the old side of a reflog entry"
  local root; root=$(make_repo)
  add_wt "$root" oldside pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/oldside" c head admin
  c=$(git -C "$wt" commit-tree 'HEAD^{tree}' -p HEAD -m lost) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  head=$(git -C "$wt" rev-parse HEAD); admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s %s t <t@t.t> 1577836800 +0000\treset: moving to HEAD\n' "$c" "$head" > "$admin/logs/HEAD"
  local shown; shown=$(git -C "$wt" reflog show --format=%H HEAD) || { bad "$name" "FIXTURE: reflog unreadable"; rm -rf "$root"; return; }
  if grep -q "$c" <<<"$shown"; then
    bad "$name" "FIXTURE: reflog show already prints the old side"; rm -rf "$root"; return
  fi
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*oldside ' <<<"$out" && [ ! -e "$wt" ] \
     && [ -n "$(git -C "$root/repo" for-each-ref --format='%(objectname)' "refs/salvaged/*/reflog/$c")" ]; then
    ok "$name"
  else
    bad "$name" "$out :: $(git -C "$root/repo" for-each-ref refs/salvaged)"
  fi
  rm -rf "$root"
}

t_salvage_keeps_an_ignored_embedded_repository() {
  # git's own listing never shows an ignored directory, so only a filesystem walk finds it.
  local name="salvage KEEPs a worktree holding an ignored embedded repository"
  local root; root=$(make_repo)
  add_wt "$root" ignrepo pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/ignrepo"
  mkdir -p "$wt/vendor/lib" && git init -q "$wt/vendor/lib" \
    && git -C "$wt/vendor/lib" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m only-here \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  printf 'vendor/\n' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
  if [ -n "$(git -C "$wt" ls-files -o --exclude-standard vendor)" ]; then
    bad "$name" "FIXTURE: vendor/ is not ignored"; rm -rf "$root"; return
  fi
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*ignrepo .*nested repository' <<<"$out" && [ -d "$wt/vendor/lib/.git" ] \
     && ! grep -q '^SALVAGED .*ignrepo' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_an_ignored_bare_repository() {
  # A bare repository has no .git entry; its own layout is what marks it.
  local name="salvage KEEPs a worktree holding an ignored bare repository"
  local root; root=$(make_repo)
  add_wt "$root" bare pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/bare"
  git init -q --bare "$wt/unique.git" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  printf 'unique.git/\n' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*bare .*nested repository' <<<"$out" && [ -f "$wt/unique.git/HEAD" ] \
     && ! grep -q '^SALVAGED .*bare' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_bare_repository_with_a_symlinked_object_store() {
  # Git resolves a bare repository whose objects/ is a symlink, so the layout check must see
  # the symlink too, or the removal deletes the repository's refs and object store.
  local name="salvage KEEPs a worktree holding a bare repository whose objects/ is a symlink"
  local root; root=$(make_repo)
  add_wt "$root" symbare pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/symbare"
  { git init -q --bare "$wt/unique.git" && mv "$wt/unique.git/objects" "$wt/store" \
      && ln -s ../store "$wt/unique.git/objects" \
      && git --git-dir="$wt/unique.git" rev-parse --git-dir >/dev/null; } \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  printf 'unique.git/\nstore/\n' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*symbare .*nested repository' <<<"$out" && [ -f "$wt/unique.git/HEAD" ] \
     && ! grep -q '^SALVAGED .*symbare' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_an_unknown_admin_log() {
  local name="salvage KEEPs a worktree whose admin logs/ holds more than the HEAD reflog"
  local root; root=$(make_repo)
  add_wt "$root" oddlog pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/oddlog" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  echo note > "$admin/logs/custom"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*oddlog .*logs/ holds more than the HEAD reflog' <<<"$out" && [ -f "$admin/logs/custom" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_a_fifo_fetch_head_keeps_without_blocking() {
  # Reading a FIFO blocks for a writer; the sweep must refuse it instead of hanging.
  local name="a FIFO FETCH_HEAD keeps the worktree without blocking the sweep"
  local root; root=$(make_repo)
  add_wt "$root" fifofh pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/fifofh" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  mkfifo "$admin/FETCH_HEAD" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  age_tree "$wt"
  local out pid i=0
  run_salvage "$root" dry-run 1 > "$root/out.txt" & pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; : > "$admin/FETCH_HEAD" & sleep 1; bad "$name" "sweep blocked on the FIFO"; rm -rf "$root"; return
  fi
  out=$(cat "$root/out.txt")
  if grep -q 'KEEP .*fifofh .*cannot read or classify the HEAD reflog, ORIG_HEAD or FETCH_HEAD' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_non_mutex_ref_in_the_claim_lock_namespace() {
  local name="salvage KEEPs a hand-made ref under the claim-lock namespace"
  local root; root=$(make_repo)
  add_wt "$root" lockns pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/lockns" c
  c=$(git -C "$wt" commit-tree 'HEAD^{tree}' -p HEAD -m only-here) \
    && git -C "$wt" update-ref refs/worktree/claim-locks/manual "$c" \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if ! grep -q 'KEEP .*lockns .*claim-locks/manual is not an ownership mutex' <<<"$out" || [ ! -d "$wt" ]; then
    bad "$name" "manual: $out"; rm -rf "$root"; return
  fi
  # A hash-named sibling whose blob merely looks like a lock payload is not this mutex.
  local h b
  git -C "$wt" update-ref -d refs/worktree/claim-locks/manual
  h=$(printf 'elsewhere' | git -C "$wt" hash-object --stdin)
  b=$(printf 'pid=1\n' | git -C "$wt" hash-object -w --stdin)
  git -C "$wt" update-ref "refs/worktree/claim-locks/$h" "$b" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  age_tree "$wt"
  out=$(run_salvage "$root" apply 1)
  if grep -q "KEEP .*lockns .*claim-locks/$h is not an ownership mutex" <<<"$out" && [ -d "$wt" ]; then
    ok "$name"
  else
    bad "$name" "sibling hash: $out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_tag_object_in_the_head_reflog() {
  # rev-list would peel the tag to its (remote-reachable) commit and the tag would be lost.
  local name="salvage KEEPs a worktree whose HEAD reflog names an annotated tag"
  local root; root=$(make_repo)
  add_wt "$root" rltag pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/rltag" t head admin
  t=$(git -C "$wt" mktag <<EOF
object $(git -C "$wt" rev-parse HEAD)
type commit
tag only-here
tagger t <t@t.t> 1577836800 +0000

signed words
EOF
) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  head=$(git -C "$wt" rev-parse HEAD); admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s %s t <t@t.t> 1577836800 +0000\tcheckout: odd\n' "$t" "$head" >> "$admin/logs/HEAD"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*rltag .*cannot read or classify the HEAD reflog' <<<"$out" && [ -d "$wt" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_a_fifo_mutex_ref_keeps_without_blocking() {
  local name="a FIFO at the ownership-mutex ref path keeps the worktree without blocking"
  local root; root=$(make_repo)
  add_wt "$root" fifomx pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/fifomx" admin h
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  h=$(printf '%s' "$wt" | git -C "$wt" hash-object --stdin)
  mkdir -p "$admin/refs/worktree/claim-locks" && mkfifo "$admin/refs/worktree/claim-locks/$h" \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local pid i=0
  run_salvage "$root" dry-run 1 > "$root/out.txt" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; : > "$admin/refs/worktree/claim-locks/$h" & sleep 1
    bad "$name" "sweep blocked on the FIFO"; rm -rf "$root"; return
  fi
  if grep -q '^SALVAGE .*fifomx ' "$root/out.txt"; then
    bad "$name" "$(cat "$root/out.txt")"
  elif grep -q 'KEEP .*fifomx ' "$root/out.txt"; then
    ok "$name"
  else
    bad "$name" "$(cat "$root/out.txt")"
  fi
  rm -rf "$root"
}

t_salvage_preserves_commit_editmsg() {
  # A hook-rejected commit leaves its drafted message only in COMMIT_EDITMSG.
  local name="salvage preserves the bytes of COMMIT_EDITMSG"
  local root; root=$(make_repo)
  add_wt "$root" editmsg pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/editmsg" admin blob
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf 'feat: a message a hook rejected\n\nwith a body\n' > "$admin/COMMIT_EDITMSG"
  blob=$(git -C "$wt" hash-object "$admin/COMMIT_EDITMSG")
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*editmsg ' <<<"$out" && [ ! -e "$wt" ] \
     && [ "$(git -C "$root/repo" for-each-ref --format='%(objectname)' 'refs/salvaged/*/commit-editmsg')" = "$blob" ]; then
    ok "$name"
  else
    bad "$name" "$out :: $(git -C "$root/repo" for-each-ref refs/salvaged)"
  fi
  rm -rf "$root"
}

t_salvage_preserves_config_worktree() {
  local name="salvage preserves the bytes of config.worktree"
  local root; root=$(make_repo)
  add_wt "$root" wtcfg pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/wtcfg" admin blob
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '[user]\n\tname = only-here\n' > "$admin/config.worktree"
  blob=$(git -C "$wt" hash-object "$admin/config.worktree")
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*wtcfg ' <<<"$out" && [ ! -e "$wt" ] \
     && [ "$(git -C "$root/repo" for-each-ref --format='%(objectname)' 'refs/salvaged/*/config-worktree')" = "$blob" ]; then
    ok "$name"
  else
    bad "$name" "$out :: $(git -C "$root/repo" for-each-ref refs/salvaged)"
  fi
  rm -rf "$root"
}

t_salvage_caps_an_oversized_commit_editmsg() {
  local name="salvage counts COMMIT_EDITMSG toward the size cap"
  local root; root=$(make_repo)
  add_wt "$root" bigmsg pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/bigmsg" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  head -c 20480 /dev/zero | tr '\0' 'm' > "$admin/COMMIT_EDITMSG"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(WORKTREE_SALVAGE_MAX_KB=8 run_salvage "$root" apply 1)
  if grep -q 'KEEP .*bigmsg .*more than 8 KB' <<<"$out" && [ -d "$wt" ] \
     && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_redirected_gitfile() {
  # The gitfile names another worktree's admin: every check would read the decoy.
  local name="salvage KEEPs a worktree whose gitfile names another worktree's admin"
  local root; root=$(make_repo)
  add_wt "$root" decoy pushed && add_wt "$root" redir pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/redir" other
  other=$(git -C "$root/repo/.claude/worktrees/decoy" rev-parse --absolute-git-dir)
  printf 'gitdir: %s\n' "$other" > "$wt/.git"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt" "$root/repo/.claude/worktrees/decoy"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q '^SALVAGE .*redir ' <<<"$out"; then
    bad "$name" "$out"
  elif grep -q 'KEEP .*redir ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_deleted_intent_to_add_entry() {
  # `git add -N` then `rm`: the worktree diff calls it D, but the index entry remains.
  local name="salvage dry-run KEEPs an intent-to-add entry whose file was deleted"
  local root; root=$(make_repo)
  add_wt "$root" itadel pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/itadel"
  echo planned > "$wt/planned.txt"; git -C "$wt" add -N planned.txt; rm "$wt/planned.txt"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*itadel .*intent-to-add' <<<"$out" && ! grep -q '^SALVAGE .*itadel ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_finds_an_admin_repository_at_a_newline_path() {
  # A retained submodule repository whose path holds a newline must not be split and skipped.
  local name="salvage KEEPs an admin-dir submodule repository at a newline path"
  local root; root=$(make_repo)
  add_wt "$root" nlrepo pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/nlrepo" admin g t c
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  g="$admin/modules/we"$'\n'"ird"
  git init -q --bare "$g" && t=$(git --git-dir="$g" mktree < /dev/null) \
    && c=$(git --git-dir="$g" -c user.email=t@t.t -c user.name=t commit-tree "$t" -m local) \
    && git --git-dir="$g" update-ref refs/heads/main "$c" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*nlrepo .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*nlrepo ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_an_edit_a_filter_hides_from_status() {
  # The clean filter maps the local edit back to the committed bytes, so status and the
  # cached diff never list the path; its attributes must still be seen.
  local name="salvage dry-run KEEPs a tracked path whose filter hides its edit"
  local root; root=$(make_repo)
  add_wt "$root" hidfilt pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/hidfilt"
  git -C "$wt" config filter.pub.clean 'sed s/secret/public/'
  git -C "$wt" config filter.pub.smudge cat
  echo '*.txt filter=pub' > "$wt/.gitattributes"
  echo public > "$wt/notes.txt"; git -C "$wt" add .gitattributes notes.txt && git -C "$wt" commit -qm notes \
    && git -C "$wt" push -q origin claude/hidfilt || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo secret > "$wt/notes.txt"
  [ -z "$(git -C "$wt" status --porcelain notes.txt)" ] || { bad "$name" "FIXTURE: edit is visible"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.md"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*hidfilt .*filter or conversion' <<<"$out" && ! grep -q '^SALVAGE .*hidfilt ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_finds_an_admin_repository_with_a_symlinked_head() {
  local name="salvage KEEPs an admin-dir repository whose HEAD is a symbolic link"
  local root; root=$(make_repo)
  add_wt "$root" symhead pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/symhead" admin g t c
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  g="$admin/modules/legacy"
  git init -q --bare -b main "$g" && t=$(git --git-dir="$g" mktree < /dev/null) \
    && c=$(git --git-dir="$g" -c user.email=t@t.t -c user.name=t commit-tree "$t" -m local) \
    && git --git-dir="$g" update-ref refs/heads/main "$c" \
    && rm "$g/HEAD" && ln -s refs/heads/main "$g/HEAD" \
    && [ "$(git --git-dir="$g" rev-parse HEAD)" = "$c" ] || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*symhead .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*symhead ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_handles_a_basename_with_a_space() {
  local name="salvage apply succeeds for a worktree whose basename holds a space"
  local root; root=$(make_repo)
  local wt="$root/repo/.claude/worktrees/has space"
  git -C "$root/repo" worktree add -q -b claude/spc "$wt" main && git -C "$wt" push -q origin claude/spc \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*has space' <<<"$out" && [ ! -e "$wt" ] \
     && [ "$(git -C "$root/repo" for-each-ref --format='%(refname)' 'refs/salvaged/*/worktree' | grep -c 'has_space')" = 1 ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_when_a_pseudo_ref_commit_is_unreadable() {
  # An object the store holds but cannot peel to a commit is state salvage cannot carry.
  # (A MISSING object is different: it has nothing left to lose, and does not block.)
  local name="salvage KEEPs a worktree whose FETCH_HEAD names an object that is not a commit"
  local root; root=$(make_repo)
  add_wt "$root" badfetch pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/badfetch" admin blob
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  blob=$(printf 'not a commit\n' | git -C "$wt" hash-object -w --stdin) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  printf '%s\t\tbranch x of origin\n' "$blob" > "$admin/FETCH_HEAD"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q 'KEEP .*badfetch .*cannot read or classify the HEAD reflog, ORIG_HEAD or FETCH_HEAD' <<<"$out" && [ -d "$wt" ] && ! grep -q '^SALVAGED .*badfetch' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_annotated_tag() {
  # The tag's target commit is on a remote, so a commit-only check passes, but the tag
  # object (its message) exists only in the repository the removal deletes.
  local name="salvage KEEPs a submodule repository holding an annotated tag"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subtag || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subtag"
  git -C "$wt/sub" tag -a v-local -m "only here" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subtag .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subtag ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_filter_hidden_edit_in_a_submodule() {
  # The submodule's clean filter maps its local edit back to the committed bytes, so its
  # status is empty and only its attributes reveal that the checkout holds unrecorded bytes.
  local name="salvage KEEPs a submodule whose filter hides an edit from status"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subfilt || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subfilt"
  echo 'f filter=pub' > "$root/sub-attrs"
  git -C "$wt/sub" config core.attributesFile "$root/sub-attrs"
  git -C "$wt/sub" config filter.pub.clean 'sed s/uno/one/'
  git -C "$wt/sub" config filter.pub.smudge cat
  echo uno > "$wt/sub/f"   # same size as the committed bytes, so status must run the filter
  [ -z "$(git -C "$wt/sub" status --porcelain)" ] || { bad "$name" "FIXTURE: edit is visible"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -Eq 'KEEP .*subfilt .*(nested repository|submodule repositories)' <<<"$out" \
     && [ "$(cat "$wt/sub/f")" = uno ] && [ -z "$(git -C "$root/repo" for-each-ref refs/salvaged)" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_rechecks_conversion_settings_after_the_snapshot() {
  # core.fileMode=false plus a mode change after the snapshot leaves status, the index and
  # the re-snapshot identical, so only re-reading the configuration can see the change.
  local name="salvage KEEPs a worktree whose conversion settings changed after the snapshot"
  local root; root=$(make_repo)
  abandoned_wt "$root" latemode || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/latemode" shim
  shim=$(lsof_hook_shim "$root" 3 "git -C '$wt' config core.fileMode false && chmod +x '$wt/file.txt'") \
    || { bad "$name" "FIXTURE: no lsof"; rm -rf "$root"; return; }
  local out; out=$(PATH="$shim:$PATH" run_salvage "$root" apply 1)
  if [ ! -x "$wt/file.txt" ]; then
    bad "$name" "mode change missing (never made, or worktree removed): $out"
  elif grep -q 'KEEP .*latemode .*core.fileMode=false.*after the salvage snapshot' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_with_a_custom_hook() {
  # A hook someone wrote lives only in the submodule repository the removal deletes. Any
  # submodule repository keeps the worktree, customized or not.
  local name="salvage KEEPs a submodule repository holding a customized hook or info file"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subhook || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subhook" g
  g=$(git -C "$wt/sub" rev-parse --absolute-git-dir)
  mkdir -p "$g/hooks"; printf '#!/bin/sh\nexit 0\n' > "$g/hooks/pre-commit"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if ! grep -Eq 'KEEP .*subhook .*(nested repository|submodule repositories)' <<<"$out" || grep -q '^SALVAGE .*subhook ' <<<"$out"; then
    bad "$name" "hook: $out"; rm -rf "$root"; return
  fi
  rm -f "$g/hooks/pre-commit"; mkdir -p "$g/info"; echo '*.local' >> "$g/info/exclude"   # an exclude rule holds no work: allowed
  echo 'f -text' > "$g/info/attributes"
  out=$(run_salvage "$root" dry-run 1)
  if ! grep -Eq 'KEEP .*subhook .*(nested repository|submodule repositories)' <<<"$out" || grep -q '^SALVAGE .*subhook ' <<<"$out"; then
    bad "$name" "attributes: $out"; rm -rf "$root"; return
  fi
  rm -f "$g/info/attributes"
  out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*subhook .*submodule repositories' <<<"$out" && ! grep -q '^SALVAGE .*subhook ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "plain submodule: $out"
  fi
  rm -rf "$root"
}

t_salvage_judges_a_conversion_by_its_bytes() {
  # `eol=lf` on a file that holds no CR stores it byte for byte, so salvage proceeds; the
  # same file with CRLF endings would be stored without its CRs, so salvage refuses.
  local name="salvage refuses only a conversion that would change the stored bytes"
  local root; root=$(make_repo)
  add_wt "$root" eolwt pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/eolwt"
  echo '*.sh text eol=lf' > "$wt/.gitattributes"; printf 'echo hi\n' > "$wt/a.sh"
  git -C "$wt" add .gitattributes a.sh && git -C "$wt" commit -qm eol \
    && git -C "$wt" push -q origin claude/eolwt || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if ! grep -q '^SALVAGE .*eolwt ' <<<"$out"; then
    bad "$name" "lossless control: $out"; rm -rf "$root"; return
  fi
  printf 'echo hi\r\n' > "$wt/a.sh"
  age_tree "$wt"
  out=$(run_salvage "$root" dry-run 1)
  if ! grep -q 'KEEP .*eolwt .*conversion that changes its bytes' <<<"$out" || grep -q '^SALVAGE .*eolwt ' <<<"$out"; then
    bad "$name" "CRLF: $out"; rm -rf "$root"; return
  fi
  # No attribute is enumerated, so one the check does not name still counts: the legacy
  # `crlf` attribute converts CRLF with text and eol both unspecified.
  printf 'echo hi\n' > "$wt/a.sh"; printf 'x\r\n' > "$wt/legacy.bat"
  echo '*.bat crlf' > "$wt/.git-info-attrs"
  git -C "$wt" config core.attributesFile "$wt/.git-info-attrs"
  age_tree "$wt"
  out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*eolwt .*conversion that changes its bytes' <<<"$out" && ! grep -q '^SALVAGE .*eolwt ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "legacy crlf: $out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_populated_uninitialised_submodule_directory() {
  # A worktree added from a branch with a gitlink leaves the submodule uninitialised; files
  # dropped into that directory are invisible to status and would die with the removal.
  local name="salvage KEEPs a worktree whose uninitialised submodule directory holds files"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subsrcwt || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/uninit"
  git -C "$root/repo" worktree add -q -b claude/uninit "$wt" claude/subsrcwt \
    && git -C "$wt" push -q origin claude/uninit || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  [ -d "$wt/sub" ] && [ ! -e "$wt/sub/.git" ] || { bad "$name" "FIXTURE: submodule initialised"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if ! grep -q '^SALVAGE .*uninit ' <<<"$out"; then
    bad "$name" "empty control: $out"; rm -rf "$root"; return
  fi
  echo stray > "$wt/sub/stray.txt"
  [ -z "$(git -C "$wt" status --porcelain sub)" ] || { bad "$name" "FIXTURE: stray file visible"; rm -rf "$root"; return; }
  age_tree "$wt"
  out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*uninit .*uninitialised submodule directory sub is not empty' <<<"$out" && ! grep -q '^SALVAGE .*uninit ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_an_admin_submodule_with_an_external_checkout() {
  # The removal deletes the repository in the admin directory; a checkout outside the
  # worktree would survive it with a .git file pointing at nothing.
  local name="salvage KEEPs an admin submodule repository whose checkout is outside the worktree"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subext || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subext" g
  g=$(git -C "$wt/sub" rev-parse --absolute-git-dir)
  cp -R "$g" "${g%/sub}/other" && mkdir -p "$root/external/co" \
    && git --git-dir="${g%/sub}/other" config core.worktree "$root/external/co" \
    && cp "$wt/sub/f" "$root/external/co/f" \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  # Clean, so nothing but its location can block it.
  [ -z "$(git --git-dir="${g%/sub}/other" --work-tree="$root/external/co" status --porcelain 2>&1)" ] \
    || { bad "$name" "FIXTURE: external checkout is not clean"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subext .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subext ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_tag_only_fetch_head_names() {
  # The tag's target commit is on a remote, so the peeled commit passes, but the tag object
  # FETCH_HEAD names is referenced nowhere else and dies with the submodule repository.
  local name="salvage KEEPs a submodule whose FETCH_HEAD names an annotated tag"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subftag || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subftag" g t
  g=$(git -C "$wt/sub" rev-parse --absolute-git-dir)
  git -C "$wt/sub" tag -a v-fetched -m "only here" && t=$(git -C "$wt/sub" rev-parse v-fetched) \
    && git -C "$wt/sub" tag -d v-fetched >/dev/null || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  printf '%s\t\ttag '"'"'v-fetched'"'"' of origin\n' "$t" > "$g/FETCH_HEAD"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subftag .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subftag ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_checkout_it_cannot_enter() {
  # An admin-dir submodule repository whose checkout exists but cannot be entered must not
  # read as "no checkout"; one whose checkout is gone keeps the worktree too.
  local name="salvage KEEPs an admin submodule repository whose checkout cannot be entered"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subenter || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subenter" g
  g=$(git -C "$wt/sub" rev-parse --absolute-git-dir)
  cp -R "$g" "${g%/sub}/other" && mkdir -p "$root/locked/co" \
    && git --git-dir="${g%/sub}/other" config core.worktree "$root/locked/co" \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  chmod 000 "$root/locked"
  if [ -x "$root/locked" ]; then
    chmod 755 "$root/locked"; bad "$name" "FIXTURE: chmod 000 did not revoke search (root?)"; rm -rf "$root"; return
  fi
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  chmod 755 "$root/locked"
  if ! grep -Eq 'KEEP .*subenter .*(nested repository|submodule repositories)' <<<"$out" \
     || grep -q '^SALVAGE .*subenter ' <<<"$out"; then
    bad "$name" "locked: $out"; rm -rf "$root"; return
  fi
  git --git-dir="${g%/sub}/other" config core.worktree "$root/gone/co"
  out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*subenter .*submodule repositories' <<<"$out" && ! grep -q '^SALVAGE .*subenter ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "absent checkout: $out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_special_file_without_reading_it() {
  # A FIFO standing where a tracked file was would block any read of its contents forever.
  local name="salvage KEEPs a worktree holding a FIFO, without blocking on it"
  local root; root=$(make_repo)
  add_wt "$root" fifowt pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/fifowt"
  rm -f "$wt/file.txt" && mkfifo "$wt/file.txt" || { bad "$name" "FIXTURE: mkfifo"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*fifowt .*file.txt is a special file' <<<"$out" && ! grep -q '^SALVAGE .*fifowt ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_tag_only_the_worktree_fetch_head_names() {
  # The tag's target commit is on a remote, but the tag object has no other reference.
  local name="salvage KEEPs a worktree whose FETCH_HEAD names an annotated tag"
  local root; root=$(make_repo)
  add_wt "$root" wtftag pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/wtftag" admin t
  git -C "$wt" -c user.email=t@t.t -c user.name=t tag -a v-fetched -m "only here" \
    && t=$(git -C "$wt" rev-parse v-fetched) && git -C "$wt" tag -d v-fetched >/dev/null \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s\t\ttag '"'"'v-fetched'"'"' of origin\n' "$t" > "$admin/FETCH_HEAD"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*wtftag .*FETCH_HEAD names a tag' <<<"$out" && ! grep -q '^SALVAGE .*wtftag ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_unclassified_content_under_admin_modules() {
  # An interrupted clone under modules/ has objects but no HEAD, so a HEAD search skips it.
  local name="salvage KEEPs a worktree whose admin modules/ holds a repository without HEAD"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subpart || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subpart" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if ! grep -q 'KEEP .*subpart .*submodule repositories' <<<"$out"; then
    bad "$name" "clean submodule: $out"; rm -rf "$root"; return
  fi
  mkdir -p "$admin/modules/partial/objects/ab" && echo blob > "$admin/modules/partial/objects/ab/cdef"
  age_tree "$wt"
  out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subpart .*(nested repository|submodule repositories)' <<<"$out" \
     && ! grep -q '^SALVAGE .*subpart ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_double_dot_admin_entry() {
  # `*` and `.[!.]*` both skip a name starting with two dots.
  local name="salvage KEEPs a worktree whose admin directory holds a ..-prefixed entry"
  local root; root=$(make_repo)
  add_wt "$root" dotdot pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/dotdot" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  echo keep > "$admin/..unique-metadata"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*dotdot .*holds \.\.unique-metadata' <<<"$out" && ! grep -q '^SALVAGE .*dotdot ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_tag_only_a_reflog_names() {
  # The branch now points at a commit, but its reflog still names the tag object it held.
  local name="salvage KEEPs a submodule whose reflog is the only reference to a tag object"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subrltag || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subrltag" t
  git -C "$wt/sub" tag -a v-reflog -m "only here" && t=$(git -C "$wt/sub" rev-parse v-reflog) \
    && git -C "$wt/sub" update-ref --create-reflog refs/tags/held "$t" \
    && git -C "$wt/sub" update-ref refs/tags/held HEAD \
    && git -C "$wt/sub" tag -d v-reflog >/dev/null \
    && grep -q "^[0-9a-f]* $t " "$(git -C "$wt/sub" rev-parse --absolute-git-dir)/logs/refs/tags/held" \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subrltag .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subrltag ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_resolve_undo_entries() {
  # A resolved conflict whose merge was quit keeps its stages only as resolve-undo data.
  local name="salvage KEEPs a worktree whose index holds resolve-undo entries"
  local root; root=$(make_repo)
  add_wt "$root" reuc pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/reuc"
  git -C "$wt" config user.email t@t.t; git -C "$wt" config user.name t
  git -C "$wt" checkout -q -b side && echo side > "$wt/file.txt" && git -C "$wt" commit -qam side \
    && git -C "$wt" checkout -q claude/reuc && echo ours > "$wt/file.txt" && git -C "$wt" commit -qam ours \
    && git -C "$wt" push -q origin claude/reuc side \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  git -C "$wt" merge -q side >/dev/null 2>&1
  echo resolved > "$wt/file.txt"; git -C "$wt" add file.txt; git -C "$wt" merge --quit
  [ -n "$(git -C "$wt" ls-files --resolve-undo)" ] && [ -z "$(git -C "$wt" ls-files -u)" ] \
    || { bad "$name" "FIXTURE: no resolve-undo"; rm -rf "$root"; return; }
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*reuc .*resolve-undo entries' <<<"$out" && ! grep -q '^SALVAGE .*reuc ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_symlinked_per_worktree_ref() {
  local name="salvage KEEPs a worktree whose per-worktree ref is a symlink"
  local root; root=$(make_repo)
  add_wt "$root" symref pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/symref" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  mkdir -p "$admin/refs/worktree" && git -C "$wt" rev-parse HEAD > "$root/ref-target" \
    && ln -s "$root/ref-target" "$admin/refs/worktree/linked" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -q 'KEEP .*symref .*per-worktree refs exist' <<<"$out" && ! grep -q '^SALVAGE .*symref ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_module_repository_whose_head_is_a_directory() {
  local name="salvage KEEPs an admin modules/ repository whose HEAD is not a file"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subhd || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subhd" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  mkdir -p "$admin/modules/broken/HEAD" "$admin/modules/broken/objects/ab" && echo blob > "$admin/modules/broken/objects/ab/cd"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subhd .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subhd ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_resolve_undo_entries_in_a_submodule() {
  local name="salvage KEEPs a worktree whose submodule index holds resolve-undo entries"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subreuc || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local sub="$root/repo/.claude/worktrees/subreuc/sub" wt="$root/repo/.claude/worktrees/subreuc"
  # Both branches are pushed, and the conflict is resolved back to HEAD, so the submodule is
  # clean, fully pushed and at its gitlink: only the resolve-undo data is left to lose.
  git -C "$sub" checkout -q -b side && echo side > "$sub/f" && git -C "$sub" commit -qam side \
    && git -C "$sub" checkout -q -b ours main && echo ours > "$sub/f" && git -C "$sub" commit -qam ours \
    && git -C "$sub" push -q origin side ours && git -C "$sub" fetch -q origin \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  git -C "$sub" merge -q side >/dev/null 2>&1
  git -C "$sub" checkout -q HEAD -- f 2>/dev/null; git -C "$sub" add f; git -C "$sub" merge --quit
  git -C "$wt" add sub && git -C "$wt" commit -qm "sub at ours" && git -C "$wt" push -q origin claude/subreuc \
    || { bad "$name" "FIXTURE: gitlink"; rm -rf "$root"; return; }
  [ -n "$(git -C "$sub" ls-files --resolve-undo)" ] && [ -z "$(git -C "$sub" status --porcelain)" ] \
    || { bad "$name" "FIXTURE: no resolve-undo or not clean"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subreuc .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subreuc ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_preserves_an_uppercase_fetch_head_commit() {
  # Git resolves an uppercase object id, so the pseudo-ref still protects the commit.
  local name="salvage preserves a commit FETCH_HEAD names in uppercase"
  local root; root=$(make_repo)
  add_wt "$root" upfetch pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/upfetch" c admin
  c=$(git -C "$wt" commit-tree 'HEAD^{tree}' -p HEAD -m fetched) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s\t\tbranch x of origin\n' "$(printf '%s' "$c" | tr 'a-f' 'A-F')" > "$admin/FETCH_HEAD"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*upfetch ' <<<"$out" \
     && [ -n "$(git -C "$root/repo" for-each-ref --format='%(objectname)' "refs/salvaged/*/reflog/$c")" ]; then
    ok "$name"
  else
    bad "$name" "$out :: $(git -C "$root/repo" for-each-ref refs/salvaged)"
  fi
  rm -rf "$root"
}

t_salvage_handles_a_very_long_basename() {
  # A basename near the 255-byte component limit must not produce a ref git cannot create.
  local name="salvage applies for a worktree with a very long basename"
  local root; root=$(make_repo)
  local long; long=$(printf 'w%.0s' $(seq 1 220))
  add_wt "$root" "$long" pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/$long"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED ' <<<"$out" && [ ! -e "$wt" ]; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_submodule_replace_ref() {
  # Both commits are on a remote, but the replacement mapping lives only in the ref name.
  local name="salvage KEEPs a submodule holding a ref outside heads, tags and remotes"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subrepl || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subrepl" h
  h=$(git -C "$wt/sub" rev-parse HEAD)
  # A custom namespace stands in for refs/replace: replacing a commit with itself loops.
  git -C "$wt/sub" update-ref refs/keep/pinned "$h" || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subrepl .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subrepl ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_whitelisted_admin_name_of_the_wrong_type() {
  local name="salvage KEEPs a worktree whose admin modules is a file, not a directory"
  local root; root=$(make_repo)
  add_wt "$root" modfile pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/modfile" admin
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  echo unique > "$admin/modules"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*modfile .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*modfile ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_tag_a_symlinked_submodule_reflog_names() {
  local name="salvage KEEPs a submodule whose symlinked reflog names a tag object"
  local root; root=$(make_repo)
  admin_sub_wt "$root" subrlsym || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subrlsym" t g
  g=$(git -C "$wt/sub" rev-parse --absolute-git-dir)
  git -C "$wt/sub" tag -a v-reflog -m "only here" && t=$(git -C "$wt/sub" rev-parse v-reflog) \
    && git -C "$wt/sub" update-ref --create-reflog refs/tags/held "$t" \
    && git -C "$wt/sub" update-ref refs/tags/held HEAD && git -C "$wt/sub" tag -d v-reflog >/dev/null \
    && mv "$g/logs/refs/tags/held" "$root/held.log" && ln -s "$root/held.log" "$g/logs/refs/tags/held" \
    || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subrlsym .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subrlsym ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_keeps_a_staged_blob_in_a_checkout_less_submodule_repository() {
  # The checkout is gone with the gitlink, but the retained repository's index still holds a
  # staged blob no commit references.
  local name="salvage KEEPs a removed submodule repository whose index holds a staged change"
  local root; root=$(make_repo)
  git init -q -b main "$root/subsrc" && echo one > "$root/subsrc/f" \
    && git -C "$root/subsrc" add f && git -C "$root/subsrc" -c user.email=t@t.t -c user.name=t commit -qm one \
    && add_wt "$root" subidx pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/subidx" g
  git -C "$wt" -c protocol.file.allow=always submodule add -q "$root/subsrc" sub >/dev/null 2>&1 \
    || { bad "$name" "FIXTURE: submodule add"; rm -rf "$root"; return; }
  g=$(git -C "$wt/sub" rev-parse --absolute-git-dir)
  echo staged > "$wt/sub/g" && git -C "$wt/sub" add g
  git -C "$wt" rm -qf sub
  [ -d "$g" ] && [ ! -e "$wt/sub" ] || { bad "$name" "FIXTURE: repository not retained"; rm -rf "$root"; return; }
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" dry-run 1)
  if grep -Eq 'KEEP .*subidx .*(nested repository|submodule repositories)' <<<"$out" && ! grep -q '^SALVAGE .*subidx ' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "$out"
  fi
  rm -rf "$root"
}

t_salvage_reads_an_unterminated_fetch_head_line() {
  local name="salvage preserves a commit named on an unterminated last FETCH_HEAD line"
  local root; root=$(make_repo)
  add_wt "$root" noeol pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local wt="$root/repo/.claude/worktrees/noeol" c admin
  c=$(git -C "$wt" commit-tree 'HEAD^{tree}' -p HEAD -m fetched) || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  admin=$(git -C "$wt" rev-parse --absolute-git-dir)
  printf '%s\t\tbranch x of origin' "$c" > "$admin/FETCH_HEAD"
  echo draft > "$wt/untracked.txt"
  age_tree "$wt"
  local out; out=$(run_salvage "$root" apply 1)
  if grep -q '^SALVAGED .*noeol ' <<<"$out" \
     && [ -n "$(git -C "$root/repo" for-each-ref --format='%(objectname)' "refs/salvaged/*/reflog/$c")" ]; then
    ok "$name"
  else
    bad "$name" "$out :: $(git -C "$root/repo" for-each-ref refs/salvaged)"
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
t_salvage_is_off_by_default
t_salvage_dry_run_reports_and_writes_nothing
t_salvage_apply_preserves_every_kind_of_work
t_salvage_respects_its_age
t_salvage_keeps_an_embedded_repository
t_salvage_keeps_oversized_work
t_salvage_keeps_submodule_work
t_salvage_rejects_a_bad_age
t_salvage_keeps_work_written_after_the_snapshot
t_salvage_keeps_oversized_staged_only_work
t_salvage_keeps_submodule_work_at_a_quoted_path
t_salvage_namespaces_are_unique_per_worktree
t_salvage_keeps_submodule_work_at_a_newline_path
t_salvage_keeps_a_submodule_reflog_only_commit
t_salvage_keeps_a_submodule_branch_only_commit
t_salvage_keeps_a_repository_created_after_the_snapshot
t_salvage_keeps_a_reflog_commit_made_after_the_snapshot
t_salvage_rechecks_its_cap_under_the_mutex
t_salvage_dry_run_keeps_a_conflicted_index
t_salvage_preserves_ignored_tracked_paths
t_salvage_leaves_untracked_tool_noise_out
t_salvage_keeps_file_shaped_noise_names
t_salvage_reports_why_a_snapshot_failed
t_salvage_keeps_a_removed_submodules_local_commit
t_salvage_keeps_a_hidden_index_edit_in_a_submodule
t_salvage_keeps_beside_even_a_clean_admin_submodule
t_salvage_keeps_a_per_worktree_ref
t_salvage_keeps_an_intent_to_add_entry
t_salvage_dry_run_refuses_an_unsnappable_gitlink_change
t_salvage_keeps_a_hidden_edit_in_an_embedded_submodule
t_salvage_keeps_unlisted_git_state
t_salvage_keeps_a_filtered_path
t_salvage_keeps_a_submodule_mid_bisect
t_salvage_keeps_when_file_modes_are_ignored
t_salvage_ignorecase_blocks_only_on_a_case_sensitive_filesystem
t_salvage_keeps_a_submodule_that_ignores_file_modes
t_salvage_preserves_a_commit_only_fetch_head_names
t_salvage_keeps_a_deleted_intent_to_add_entry
t_salvage_finds_an_admin_repository_at_a_newline_path
t_salvage_keeps_an_edit_a_filter_hides_from_status
t_salvage_finds_an_admin_repository_with_a_symlinked_head
t_salvage_handles_a_basename_with_a_space
t_salvage_keeps_when_a_pseudo_ref_commit_is_unreadable
t_salvage_keeps_a_submodule_annotated_tag
t_salvage_keeps_a_filter_hidden_edit_in_a_submodule
t_salvage_rechecks_conversion_settings_after_the_snapshot
t_salvage_keeps_a_submodule_with_a_custom_hook
t_salvage_keeps_a_submodule_tag_only_fetch_head_names
t_salvage_keeps_a_submodule_checkout_it_cannot_enter
t_salvage_judges_a_conversion_by_its_bytes
t_salvage_keeps_a_populated_uninitialised_submodule_directory
t_salvage_keeps_an_admin_submodule_with_an_external_checkout
t_salvage_keeps_a_special_file_without_reading_it
t_salvage_keeps_a_tag_only_the_worktree_fetch_head_names
t_salvage_keeps_unclassified_content_under_admin_modules
t_salvage_keeps_a_double_dot_admin_entry
t_salvage_keeps_a_submodule_tag_only_a_reflog_names
t_salvage_keeps_resolve_undo_entries
t_salvage_keeps_a_symlinked_per_worktree_ref
t_salvage_keeps_a_module_repository_whose_head_is_a_directory
t_salvage_keeps_resolve_undo_entries_in_a_submodule
t_salvage_preserves_an_uppercase_fetch_head_commit
t_salvage_handles_a_very_long_basename
t_salvage_keeps_a_submodule_replace_ref
t_salvage_keeps_a_whitelisted_admin_name_of_the_wrong_type
t_salvage_keeps_a_tag_a_symlinked_submodule_reflog_names
t_salvage_keeps_a_staged_blob_in_a_checkout_less_submodule_repository
t_salvage_reads_an_unterminated_fetch_head_line
t_pseudo_ref_only_commit_alone_triggers_salvage
t_a_missing_fetch_head_object_does_not_keep_a_clean_worktree
t_a_not_for_merge_fetch_head_commit_does_not_keep_a_clean_worktree
t_new_work_during_the_sweep_resets_the_salvage_age
t_a_referenced_pseudo_ref_tag_does_not_block_salvage
t_a_fresh_tracked_edit_in_an_old_worktree_is_not_salvaged
t_a_fresh_chmod_in_an_old_worktree_is_not_salvaged
t_staging_old_bytes_in_an_old_worktree_is_not_salvaged
t_the_sweep_never_rewrites_a_worktree_index
t_salvage_keeps_a_bare_repository_without_refs
t_a_pseudo_ref_only_tag_keeps_a_clean_worktree
t_a_pseudo_ref_tag_a_ref_holds_does_not_keep
t_inherited_git_location_variables_do_not_redirect_the_sweep
t_salvage_preserves_the_old_side_of_a_reflog_entry
t_salvage_keeps_an_ignored_embedded_repository
t_salvage_keeps_an_ignored_bare_repository
t_salvage_keeps_a_bare_repository_with_a_symlinked_object_store
t_salvage_keeps_an_unknown_admin_log
t_a_fifo_fetch_head_keeps_without_blocking
t_salvage_keeps_a_non_mutex_ref_in_the_claim_lock_namespace
t_salvage_keeps_a_tag_object_in_the_head_reflog
t_a_fifo_mutex_ref_keeps_without_blocking
t_salvage_preserves_commit_editmsg
t_salvage_preserves_config_worktree
t_salvage_caps_an_oversized_commit_editmsg
t_salvage_keeps_a_redirected_gitfile
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
