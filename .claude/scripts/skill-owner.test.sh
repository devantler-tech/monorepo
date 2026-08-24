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

# A revision carrying ONLY well-formed declarations. It exists so the suite can assert a plain
# exit 0: with the malformed fixtures below folded into the same commit, EVERY end-to-end arm
# required exit 2, and a regression that always answered UNKNOWN/2 would have passed the whole
# suite while the documented success path was unreachable.
git -C "$plug" add -A >/dev/null
git -C "$plug" commit -qm "well-formed fixture" >/dev/null
PIN_CLEAN="$(git -C "$plug" rev-parse HEAD)"

# PRESENT but not a usable value. `// "LOCAL"` would map both of these onto LOCAL, asserting local
# authorship from a malformed declaration — absent and invalid are different answers.
skill_file "$P/emptyval/SKILL.md" 'metadata:
  github-repo: ""' 'declared empty'
skill_file "$P/mapval/SKILL.md" 'metadata:
  github-repo:
    url: https://github.com/devantler-tech/agent-skills' 'declared as a mapping'
# A non-STRING scalar. yq renders any scalar as text, so a tag-blind reader prints `false` as
# though it were a repository and exits 0 — a malformed declaration answered with a well-formed
# looking row, which is the fail-open direction this helper exists to close.
skill_file "$P/boolval/SKILL.md" 'metadata:
  github-repo: false' 'declared as a bool'
git -C "$plug" add -A >/dev/null
git -C "$plug" commit -qm "fixture + malformed declarations"
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

# ---- 0. THE ORIGINATING SHAPE: the submodule directory exists but is EMPTY, exactly as in a fresh
#     per-run worktree. This is the case the old glob answered with silence and an exit 0, so assert
#     it first, against the real empty directory, before any symlink makes the objects reachable.
run
assert_eq 'empty submodule exits 2, never 0' 2 "$RC"
assert_eq 'empty submodule prints NO ownership rows' '' "$OUT"
assert_contains 'empty submodule is reported, not silent' "$ERR" 'pinned tree'

# The remaining arms need the pinned objects, which in this fixture live at $plug.
# Point the submodule path at it directly so `git -C <sub>` finds the pinned commit.
rm -rf "$cons/libraries/agent-plugins"
mkdir -p "$cons/libraries"
ln -s "$plug" "$cons/libraries/agent-plugins"

# ---- 1. GREEN: ownership resolves per file, from the pinned tree
run
assert_eq 'green: malformed declarations make the listing exit 2, never 0' 2 "$RC"
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

# ---- 4b. PRESENT-BUT-INVALID is UNKNOWN, never LOCAL — absent and malformed are different answers
assert_contains 'an empty github-repo value is UNKNOWN' "$OUT" 'UNKNOWN	emptyval'
assert_not_contains 'an empty github-repo value is never LOCAL' "$OUT" 'LOCAL	emptyval'
assert_contains 'a non-scalar github-repo value is UNKNOWN' "$OUT" 'UNKNOWN	mapval'
assert_not_contains 'a non-scalar github-repo value is never LOCAL' "$OUT" 'LOCAL	mapval'

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

# ---- 5b. --plugin is caller data, never a pattern. Exercised through the selector directly: on the
#      submodule path git's pathspec has ALREADY filtered literally, so an end-to-end run there
#      passes whether the selector is literal or a regex — it cannot discriminate. The forge path
#      filters a whole tree listing in process, which is where an interpolated ERE would silently
#      answer for the wrong plugin, so the property is proven against the selector itself.
CAND='plugins/agentic-engineering/skills/a/SKILL.md
plugins/other/skills/b/SKILL.md
plugins/agentic-engineering/skills/deep/nested/SKILL.md
plugins/agentic-engineering/skills//SKILL.md
plugins/agentic-engineering/skills/a/OTHER.md'

sel() { printf '%s\n' "$CAND" | "$SUT" --filter-only --plugin "$1"; }

assert_eq 'literal plugin name selects exactly its own well-formed skill' \
  'plugins/agentic-engineering/skills/a/SKILL.md' "$(sel agentic-engineering)"
assert_eq 'a dot in a plugin name is literal, not any-char' '' "$(sel 'agentic.engineering')"
assert_eq 'a regex-metacharacter plugin name matches nothing' '' "$(sel '.*')"
assert_eq 'another plugin is never selected' 'plugins/other/skills/b/SKILL.md' "$(sel other)"

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
git -C "$plug" commit -q --allow-empty -m other
OTHER="$(git -C "$plug" rev-parse HEAD)"
decoy="$tmp/decoy"; mk_consumer "$decoy" "$OTHER"
DECOY_HEAD="$(git -C "$decoy" rev-parse HEAD)"
# A fixture that fails to BUILD must fail the suite. An `else ok "skipped"` here would turn every
# future breakage of this arm into a silent pass — the exact vacuous-control shape these assertions
# exist to prevent.
# Fetch BEFORE the submodule path becomes a symlink: git refuses to walk a symlinked submodule path
# and would abort the fetch. (The original `|| true` here masked exactly that.)
git -C "$cons2" fetch -q "$decoy" main
rm -rf "$cons2/libraries/agent-plugins"; mkdir -p "$cons2/libraries"; ln -s "$plug" "$cons2/libraries/agent-plugins"
git -C "$cons2" cat-file -e "$DECOY_HEAD^{commit}" \
  || { bad 'replacement-object fixture' "decoy commit $DECOY_HEAD unreachable in cons2"; DECOY_HEAD=""; }
if [ -n "$DECOY_HEAD" ]; then
  git -C "$cons2" replace -f "$(git -C "$cons2" rev-parse HEAD)" "$DECOY_HEAD" >/dev/null
  # The replacement must actually take effect, or the arm proves nothing.
  if [ "$(git -C "$cons2" rev-parse 'HEAD^{tree}')" = "$(git -C "$cons2" --no-replace-objects rev-parse 'HEAD^{tree}')" ]; then
    bad 'replacement-object fixture' 'the replace ref did not change what HEAD resolves to'
  else
    ok 'replacement-object fixture actually redirects HEAD'
  fi
  set +e
  ERRR="$("$SUT" --repo-root "$cons2" --source submodule --submodule-path libraries/agent-plugins 2>&1 >/dev/null)"
  RC_R=$?
  set -e
  # This arm is about WHICH pin is resolved, so it must reach the summary line rather than die early.
  # The exit code itself is whatever the fixture's contents imply (2 here, because the same fixture
  # carries the deliberately malformed declarations), so assert reaching the report, not a code.
  case "$RC_R" in
    0|2) ok 'replacement-object arm reached its summary line' ;;
    *)   bad 'replacement-object arm reached its summary line' "died early with rc=$RC_R" ;;
  esac
  assert_contains 'replacement object cannot rewrite the resolved pin' "$ERRR" "pin=$PIN"
fi


# ---- 9. THE SUCCESS PATH IS REACHABLE. Every end-to-end arm above asserts exit 2, because the
#     fixture they share carries the deliberately malformed declarations. That alone would let a
#     regression which always answered UNKNOWN/2 pass the entire suite while the documented exit 0
#     was unreachable — a suite that cannot distinguish "fails closed correctly" from "never
#     succeeds". So assert the well-formed revision on its own.
cons_clean="$tmp/cons_clean"
mk_consumer "$cons_clean" "$PIN_CLEAN"
rm -rf "$cons_clean/libraries/agent-plugins"; mkdir -p "$cons_clean/libraries"
ln -s "$plug" "$cons_clean/libraries/agent-plugins"
set +e
OUT_C="$("$SUT" --repo-root "$cons_clean" --source submodule --submodule-path libraries/agent-plugins 2>"$tmp/err_c")"
RC_C=$?
set -e
assert_eq 'a wholly well-formed revision exits 0' 0 "$RC_C"
assert_contains 'clean revision resolves the synced skill' "$OUT_C" 'https://github.com/devantler-tech/agent-skills	synced'
assert_contains 'clean revision resolves the local skill'  "$OUT_C" 'LOCAL	local'
assert_not_contains 'clean revision reports no UNKNOWN'    "$OUT_C" 'UNKNOWN'

# ---- 10. A NON-STRING declaration is UNKNOWN, never an owner. yq renders every scalar as text, so
#     a tag-blind reader emits `false` in the owner column and exits 0 — malformed input answered
#     with a well-formed looking row, which is harder to notice than an outright error.
run  # $OUT is shared: later arms narrow it, so re-read the full listing for this assertion
assert_contains 'a non-string github-repo value is UNKNOWN' "$OUT" 'UNKNOWN	boolval'
assert_not_contains 'a non-string value never becomes an owner row' "$OUT" 'false	boolval'

# ---- 11. THE FORGE FALLBACK, exercised hermetically. This is the path the whole change exists for:
#     in a fresh per-run worktree the submodule is empty, so `try_forge` is what actually answers.
#     Every arm above forces `--source submodule`, so a regression in slug derivation, tree
#     enumeration, the truncation guard or the blob read would ship undetected while CI stayed
#     green. A fake `gh` on PATH covers all four without a network call or a token.
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
# The fake serves the two calls try_forge makes, and records the slug it was asked for so the arm
# can prove the slug was DERIVED from .gitmodules rather than hard-coded.
cat > "$fake_bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "${2:-}" in
  */git/trees/*)
    slug="${2#repos/}"; slug="${slug%%/git/trees/*}"
    printf '%s\n' "$slug" > "$GH_SLUG_SEEN"
    if [ "${FAKE_GH_TRUNCATED:-0}" = 1 ]; then
      # A PARTIAL listing, never an empty one. An empty tree is caught by the empty-enumeration
      # guard instead, so the truncation arm would pass even with the truncation guard removed —
      # i.e. pass for the wrong reason. One real skill here means dropping the guard yields a
      # plausible-looking short listing and exit 0, which is the silent drop being guarded against.
      "$FAKE_GH_TREE_CMD" | jq '{truncated:true, tree:[.tree[]|select(.path|endswith("/synced/SKILL.md"))]}'
      exit 0
    fi
    "$FAKE_GH_TREE_CMD"
    ;;
  */contents/*)
    path="${2#*/contents/}"; path="${path%%\?*}"
    cat "$FAKE_GH_BLOBS/$(printf '%s' "$path" | tr '/' '_')"
    ;;
  *) exit 1 ;;
esac
FAKEGH
chmod +x "$fake_bin/gh"

# Serve the tree and the blobs straight out of the fixture repo at PIN, so the fake reports what
# the pinned revision actually contains rather than a hand-written listing that could drift.
tree_cmd="$tmp/tree_cmd"
cat > "$tree_cmd" <<TREECMD
#!/usr/bin/env bash
set -euo pipefail
git -C "$plug" ls-tree -r --name-only "$PIN" \
  | jq -R -s '{truncated:false, tree:[splits("\n")|select(length>0)|{type:"blob", path:.}]}'
TREECMD
chmod +x "$tree_cmd"

blobs="$tmp/blobs"; mkdir -p "$blobs"
git -C "$plug" ls-tree -r --name-only "$PIN" | while IFS= read -r bp; do
  [ -n "$bp" ] || continue
  git -C "$plug" show "$PIN:$bp" > "$blobs/$(printf '%s' "$bp" | tr '/' '_')" 2>/dev/null || true
done

# The consumer's submodule directory is EMPTY here — the fresh-worktree shape — so the forge path
# is the only one that can answer.
cons_forge="$tmp/cons_forge"
mk_consumer "$cons_forge" "$PIN"
mkdir -p "$cons_forge/libraries/agent-plugins"

run_forge() { # -> OUT_F / RC_F / ERR_F
  set +e
  OUT_F="$(PATH="$fake_bin:$PATH" GH_CALL_LOG="$tmp/ghcalls" GH_SLUG_SEEN="$tmp/ghslug" \
           FAKE_GH_TREE_CMD="$tree_cmd" FAKE_GH_BLOBS="$blobs" FAKE_GH_TRUNCATED="${1:-0}" \
           "$SUT" --repo-root "$cons_forge" --source forge --submodule-path libraries/agent-plugins \
           2>"$tmp/err_f")"
  RC_F=$?
  ERR_F="$(cat "$tmp/err_f")"
  set -e
}

: > "$tmp/ghcalls"; : > "$tmp/ghslug"
run_forge 0
assert_contains 'forge path reports source=forge'        "$ERR_F" 'source=forge'
assert_contains 'forge path resolves the synced skill'   "$OUT_F" 'https://github.com/devantler-tech/agent-skills	synced'
assert_contains 'forge path resolves the local skill'    "$OUT_F" 'LOCAL	local'
assert_contains 'forge path still fails closed on a malformed value' "$OUT_F" 'UNKNOWN	boolval'
# The slug must come from .gitmodules, not a constant: mk_consumer points the url at $plug.
assert_eq 'forge slug is derived from .gitmodules' "$(basename "$plug")" "$(sed 's@.*/@@' "$tmp/ghslug")"
# Ablation: a truncated tree is a PARTIAL listing. Accepting it would drop skills silently, which is
# the same "absence read as an answer" defect the helper exists to close.
run_forge 1
assert_eq 'a truncated forge tree is UNKNOWN, never a partial listing' 2 "$RC_F"
assert_not_contains 'a truncated forge tree prints no ownership rows' "$OUT_F" 'synced'
printf '\nskill-owner: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'skill-owner contract: PASS — ownership is per-file, structural, and fails closed on an empty enumeration\n'
