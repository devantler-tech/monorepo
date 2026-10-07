#!/usr/bin/env bash
# The publisher must select only the website pin from the committed aggregator.
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/business-site-revision.sh"
TMP=$(mktemp -d)
finished=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$finished" != 1 && "$rc" == 0 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT

fixture() {
  local root
  root=$(mktemp -d "$TMP/repo.XXXXXX")
  git init -q "$root"
  git -C "$root" config user.name Fixture
  git -C "$root" config user.email fixture@example.invalid
  git -C "$root" config commit.gpgsign false
  printf 'fixture\n' > "$root/README.md"
  git -C "$root" add README.md
  git -C "$root" commit -qm baseline
  printf '%s\n' "$root"
}
modules() {
  git -C "$1" config -f .gitmodules submodule.applications/business-site.path applications/business-site
  git -C "$1" config -f .gitmodules submodule.applications/business-site.url "$2"
  git -C "$1" add .gitmodules
}
pin() { git -C "$1" update-index --add --cacheinfo "160000,$2,applications/business-site"; }
commit() { git -C "$1" commit -qm "$2"; }
asserts=0
expect() {
  local name=$1 want=$2 expected=$3 root=$4 rc=0 out
  asserts=$((asserts + 1))
  out=$(bash "$SCRIPT" --root "$root" 2> "$TMP/error") || rc=$?
  if [[ "$rc" != "$want" || "$out" != "$expected" ]]; then
    printf 'FAIL: %s: exit=%s output=%s; wanted exit=%s output=%s\n' "$name" "$rc" "$out" "$want" "$expected" >&2
    exit 1
  fi
}

root=$(fixture)
expect 'missing committed gitlink' 1 '' "$root"
sha=$(git -C "$root" rev-parse HEAD)
modules "$root" https://github.com/devantler-tech/business-site.git
pin "$root" "$sha"
expect 'staged pin is not published' 1 '' "$root"
commit "$root" pin
expect 'committed website pin' 0 "$sha" "$root"
next=$(git -C "$root" rev-parse HEAD)
pin "$root" "$next"
expect 'staged replacement does not alter published pin' 0 "$sha" "$root"
git -C "$root" config -f .gitmodules submodule.applications/business-site.url https://example.invalid/foreign.git
expect 'dirty modules do not alter committed identity' 0 "$sha" "$root"
commit "$root" next-pin
expect 'new committed pin is selected' 0 "$next" "$root"
git -C "$root" add .gitmodules
commit "$root" foreign-url
expect 'foreign repository is refused' 1 '' "$root"
modules "$root" git@github.com:devantler-tech/business-site.git
commit "$root" ssh-url
expect 'canonical SSH repository is accepted' 0 "$next" "$root"
git -C "$root" config -f .gitmodules submodule.applications/business-site.path applications/elsewhere
git -C "$root" add .gitmodules
commit "$root" wrong-path
expect 'wrong configured path is refused' 1 '' "$root"

root=$(fixture)
modules "$root" https://github.com/devantler-tech/business-site.git
blob=$(git -C "$root" rev-parse HEAD:README.md)
git -C "$root" update-index --add --cacheinfo "100644,$blob,applications/business-site"
commit "$root" ordinary-file
expect 'ordinary file is not a gitlink' 1 '' "$root"
mkdir -p "$root/uninitialized-child"
expect 'child may not resolve to parent repository' 2 '' "$root/uninitialized-child"
mkdir -p "$TMP/not-git"
expect 'non-repository is unknown' 2 '' "$TMP/not-git"
root=$(fixture)
sha=$(git -C "$root" rev-parse HEAD)
pin "$root" "$sha"
commit "$root" no-modules
expect 'gitlink without repository binding is refused' 1 '' "$root"
finished=1
printf 'business-site-revision.test: all %s assertions passed\n' "$asserts"
