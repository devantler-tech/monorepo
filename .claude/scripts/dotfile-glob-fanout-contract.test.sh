#!/usr/bin/env bash
#
# Guards the *Latency discipline* bullet that stops a per-repository fan-out from silently
# dropping `devantler-tech/.github` (monorepo#2778).
#
# Why this needs a guard. A survey that caches one file per repository and then iterates the
# cache with a bare glob (`for f in dir/*.json`) never visits `.github.json`: a glob does not
# match a leading dot in bash or zsh by default. The skip is silent and reads as "nothing found in
# that repo" — and `.github` is where maintainer comments on org-wide conventions live, so the
# missed read is a missed instruction on the control channel.
#
# Two halves. The fixture proves the hazard the bullet describes is real in this shell and that
# the prescribed form (iterate the authoritative repo list, fail on a missing cache) covers the
# dot-prefixed repo. The prose assertions pin the bullet, scoped to it rather than the whole file.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"

fail() {
  echo "dotfile glob fan-out contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# --- Fixture: the hazard and the prescribed form -------------------------------------------------
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
repos=(monorepo platform .github ksail)
for r in "${repos[@]}"; do printf '{}\n' >"${fixture}/${r}.json"; done

# F1. The bare glob drops the dotfile. If this ever stops holding, the bullet is describing a
#     hazard this shell no longer has and should be revisited rather than silently kept.
globbed=0
for f in "${fixture}"/*.json; do
  [ "$(basename "${f}")" = ".github.json" ] && fail "bare glob matched .github.json — the hazard premise no longer holds"
  globbed=$((globbed + 1))
done
[ "${globbed}" -eq 3 ] || fail "bare glob visited ${globbed} files, expected 3 of 4 (the dotfile dropped)"

# F2. Iterating the repo list visits every repository, including `.github`, and a missing cache is
#     an error rather than an omission.
visited=()
for r in "${repos[@]}"; do
  [ -r "${fixture}/${r}.json" ] || fail "fixture cache missing for ${r}"
  visited+=("${r}")
done
[ "${#visited[@]}" -eq "${#repos[@]}" ] || fail "repo-list fan-out visited ${#visited[@]} of ${#repos[@]}"
case " ${visited[*]} " in *" .github "*) ;; *) fail "repo-list fan-out did not visit .github" ;; esac

rm "${fixture}/ksail.json"
missing=0
for r in "${repos[@]}"; do [ -r "${fixture}/${r}.json" ] || missing=$((missing + 1)); done
[ "${missing}" -eq 1 ] || fail "a missing cache file was not detected by the repo-list fan-out"

# --- Prose: the bullet exists and says the load-bearing things -----------------------------------
bullet="$(
  awk '
    /^- \*\*A per-repository fan-out /  { inb = 1; print; next }
    inb && /^- \*\*/                    { inb = 0 }
    inb && /^This changes only/         { inb = 0 }
    inb                                 { print }
  ' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' '
)"

[ -n "${bullet}" ] ||
  fail "could not locate the per-repository fan-out bullet in AGENTS.md *Latency discipline*"

bullet_words="$(printf '%s' "${bullet}" | wc -w | tr -d ' ')"
[ "${bullet_words}" -lt 400 ] ||
  fail "bullet extracted as ${bullet_words} words — runaway extraction, the end anchor probably moved"

assert_bullet() {
  case "${bullet}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}

assert_bullet 'never by globbing the cache directory' \
  "the bullet does not forbid globbing the cache directory as the fan-out source"
assert_bullet 'does not match a leading dot' \
  "the bullet does not name the cause (a glob skips dot-prefixed names)"
# shellcheck disable=SC2016 # literal backticks are the Markdown being matched
assert_bullet '`.github`' \
  "the bullet does not name the repository the hazard drops"
assert_bullet 'iterate the repo list' \
  "the bullet does not name the prescribed alternative (iterate the authoritative repo list)"
assert_bullet 'missing cache file is an error' \
  "the bullet does not make a missing cache fail loudly instead of reading as an empty result"

echo "dotfile glob fan-out contract: OK — 3 fixture checks and 5 assertions passed"
