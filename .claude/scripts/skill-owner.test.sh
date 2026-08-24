#!/usr/bin/env bash
# Behavioural proof for `skill-owner.sh`.
#
# The defect it exists for is not "the command errors" — it is that the command's failure LOOKED
# like an answer. An unpopulated submodule produced no ownership rows and no error, and "no rows"
# was then read as "nothing is synced", which is the inverse of the truth. So the assertions here
# are mostly about the FAIL-CLOSED direction: what the helper must refuse to say when it cannot
# establish ownership.
#
# Every fixture is local and hermetic; the forge path is exercised by the helper's own use in the
# repository, never by this suite.

set -euo pipefail

PASS=0
FAIL=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${repo_root}/.claude/scripts/skill-owner.sh"

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to find [$3]" ;; esac
}
assert_not_contains() { # name haystack needle
  case "$2" in *"$3"*) bad "$1" "expected NOT to find [$3]" ;; *) ok "$1" ;; esac
}

skill_file() { # dir frontmatter-extra body
  mkdir -p "$(dirname "$1")"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$(basename "$(dirname "$1")")"
    printf 'description: fixture\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    printf -- '---\n\n'
    printf '%s\n' "${3:-body}"
  } > "$1"
}

# ---------------------------------------------------------------- plugin repo (the "submodule")
plug="$tmp/plug"
mkdir -p "$plug"
git -C "$plug" init -q -b main
git -C "$plug" config user.email t@example.com
git -C "$plug" config user.name t

P="$plug/plugins/agentic-engineering/skills"
skill_file "$P/synced/SKILL.md" 'metadata:
  github-repo: https://github.com/devantler-tech/agent-skills' 'synced body'
skill_file "$P/local/SKILL.md" '' 'see https://github.com/devantler-tech/agent-skills for context'
skill_file "$P/lookalike/SKILL.md" 'metadata:
  github-repo: https://github.com/devantler-tech/agent-skills-v2' 'lookalike body'
skill_file "$P/misplaced/SKILL.md" 'github-repo: https://github.com/devantler-tech/agent-skills' 'key outside metadata'
git -C "$plug" add -A >/dev/null
git -C "$plug" commit -qm fixture
PIN="$(git -C "$plug" rev-parse HEAD)"

# A second revision that ALSO carries an unreadable (empty) skill. Kept out of the clean revision so
# the well-formed listing can assert a plain exit 0 — one conjunct per fixture.
mkdir -p "$P/empty"
: > "$P/empty/SKILL.md"
git -C "$plug" add -A >/dev/null
git -C "$plug" commit -qm "fixture + empty skill"
PIN_EMPTY="$(git -C "$plug" rev-parse HEAD)"

# ---------------------------------------------------------------- consumer repo with the gitlink
mk_consumer() { # dest pin
  local c="$1" pin="$2"
  mkdir -p "$c"
  git -C "$c" init -q -b main
  git -C "$c" config user.email t@example.com
  git -C "$c" config user.name t
  printf '[submodule "libraries/agent-plugins"]\n\tpath = libraries/agent-plugins\n\turl = %s\n' "$plug" > "$c/.gitmodules"
  git -C "$c" add .gitmodules >/dev/null
  git -C "$c" update-index --add --cacheinfo 160000,"$pin",libraries/agent-plugins
  git -C "$c" commit -qm "pin $pin" >/dev/null
}

cons="$tmp/cons"
mk_consumer "$cons" "$PIN"
# The submodule is present but EMPTY in the working tree — exactly the per-run-worktree shape the
# helper exists for. `--source submodule` is pointed at the real object store instead.
mkdir -p "$cons/libraries/agent-plugins"

run() { # -> stdout on fd1, stderr captured, RC in $RC
  set +e
  OUT="$("$SUT" --repo-root "$cons" --source submodule --submodule-path libraries/agent-plugins "$@" 2>"$tmp/err")"
  RC=$?
  ERR="$(cat "$tmp/err")"
  set -e
}

printf 'skill-owner behavioural suite\n'

# The helper reads the submodule's object store, which in this fixture lives at $plug.
# Point the submodule path at it directly so `git -C <sub>` finds the pinned commit.
rm -rf "$cons/libraries/agent-plugins"
mkdir -p "$cons/libraries"
ln -s "$plug" "$cons/libraries/agent-plugins"

# ---- 1. GREEN: ownership resolves per file, from the pinned tree
run
assert_eq 'green: a fully readable pinned tree exits 0' 0 "$RC"
assert_contains 'synced skill reports its upstream' "$OUT" 'https://github.com/devantler-tech/agent-skills	synced'
assert_contains 'skill with no metadata reports LOCAL' "$OUT" 'LOCAL	local'

# ---- 2. A URL in the BODY does not set ownership (structural read, never a grep)
#     Ablation: `local/SKILL.md` contains the suite URL in its body. A grep-based reader would
#     report it as ours and skip the review that the sync trap requires.
assert_not_contains 'body-mention does not make a skill upstream-owned' "$OUT" 'https://github.com/devantler-tech/agent-skills	local'

# ---- 3. A prefix-extended lookalike is printed VERBATIM, so an exact compare separates it
assert_contains 'lookalike prints its own url' "$OUT" 'https://github.com/devantler-tech/agent-skills-v2	lookalike'

# ---- 4. The key must live under `metadata`, not merely somewhere in the frontmatter
assert_contains 'top-level github-repo is not metadata.github-repo' "$OUT" 'LOCAL	misplaced'

# ---- 5. An unreadable/empty skill is UNKNOWN, never LOCAL — separate revision, separate fixture
cons_empty="$tmp/cons_empty"
mk_consumer "$cons_empty" "$PIN_EMPTY"
rm -rf "$cons_empty/libraries/agent-plugins"; mkdir -p "$cons_empty/libraries"; ln -s "$plug" "$cons_empty/libraries/agent-plugins"
set +e
OUT_E="$("$SUT" --repo-root "$cons_empty" --source submodule --submodule-path libraries/agent-plugins 2>/dev/null)"
RC_E=$?
set -e
assert_eq 'a tree with an unreadable skill exits 2, never 0' 2 "$RC_E"
assert_contains 'empty skill body reports UNKNOWN' "$OUT_E" 'UNKNOWN	empty'
assert_not_contains 'empty skill is never reported LOCAL' "$OUT_E" 'LOCAL	empty'
assert_contains 'the readable siblings are still reported' "$OUT_E" 'LOCAL	local'

# ---- 6. THE CORE DEFECT: an empty enumeration is UNKNOWN, never an all-LOCAL listing
run --plugin no-such-plugin
assert_eq 'empty enumeration exits 2' 2 "$RC"
assert_eq 'empty enumeration prints NO rows' '' "$OUT"
assert_contains 'empty enumeration says UNKNOWN, not "nothing is synced"' "$ERR" 'UNKNOWN'

# ---- 7. --skill naming nothing is UNKNOWN, not an empty success
run --skill absent
assert_eq 'unknown --skill exits 2' 2 "$RC"
assert_eq 'unknown --skill prints no rows' '' "$OUT"

# ---- 8. A refs/replace entry must not be able to rewrite the pin
#     Without --no-replace-objects the consumer's HEAD resolves THROUGH the replacement, so the
#     helper would read a different gitlink while `rev-parse HEAD` still printed the expected one.
cons2="$tmp/cons2"
mk_consumer "$cons2" "$PIN"
rm -rf "$cons2/libraries/agent-plugins"; mkdir -p "$cons2/libraries"; ln -s "$plug" "$cons2/libraries/agent-plugins"
git -C "$plug" commit -q --allow-empty -m other
OTHER="$(git -C "$plug" rev-parse HEAD)"
decoy="$tmp/decoy"; mk_consumer "$decoy" "$OTHER"
DECOY_HEAD="$(git -C "$decoy" rev-parse HEAD)"
git -C "$cons2" fetch -q "$decoy" main 2>/dev/null || true
if git -C "$cons2" cat-file -e "$DECOY_HEAD^{commit}" 2>/dev/null; then
  git -C "$cons2" replace -f "$(git -C "$cons2" rev-parse HEAD)" "$DECOY_HEAD" >/dev/null 2>&1 || true
  set +e
  ERRR="$("$SUT" --repo-root "$cons2" --source submodule --submodule-path libraries/agent-plugins 2>&1 >/dev/null)"
  set -e
  assert_contains 'replacement object cannot rewrite the resolved pin' "$ERRR" "pin=$PIN"
else
  ok 'replacement-object arm skipped (decoy commit unavailable)'
fi

printf '\nskill-owner: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'skill-owner contract: PASS — ownership is per-file, structural, and fails closed on an empty enumeration\n'
