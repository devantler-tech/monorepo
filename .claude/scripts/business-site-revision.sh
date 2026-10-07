#!/usr/bin/env bash
# Emit the committed business-site gitlink, never an index or working-tree pin.
# Exit 1 rejects an invalid binding; exit 2 means the repository read is unknown.
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
if [[ $# == 2 && "$1" == --root ]]; then
  ROOT=$2
elif [[ $# != 0 ]]; then
  echo 'usage: business-site-revision.sh [--root DIR]' >&2
  exit 2
fi
unknown() { printf 'UNKNOWN: %s\n' "$*" >&2; exit 2; }
reject() { printf 'REJECTED: %s\n' "$*" >&2; exit 1; }
requested=$(CDPATH='' cd -P -- "$ROOT" 2>/dev/null && pwd) || unknown 'root does not resolve'
actual=$(git --no-replace-objects -C "$requested" rev-parse --show-toplevel 2>/dev/null) || unknown 'root is not a repository'
actual=$(CDPATH='' cd -P -- "$actual" 2>/dev/null && pwd) || unknown 'repository root does not resolve'
[[ "$actual" == "$requested" ]] || unknown 'root must name this repository exactly'
head=$(git --no-replace-objects -C "$requested" rev-parse --verify 'HEAD^{commit}') || unknown 'HEAD cannot be read'
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || unknown 'HEAD is not a full commit identifier'
entry=$(git --no-replace-objects -C "$requested" ls-tree "$head" -- applications/business-site) || unknown 'committed tree cannot be read'
[[ "$entry" =~ ^160000[[:space:]]commit[[:space:]]([0-9a-f]{40})[[:space:]]applications/business-site$ ]] || reject 'committed business-site gitlink is missing or malformed'
revision=${BASH_REMATCH[1]}
path=$(git --no-replace-objects -C "$requested" config --blob "$head:.gitmodules" --get-all submodule.applications/business-site.path) || reject 'committed website path is missing'
url=$(git --no-replace-objects -C "$requested" config --blob "$head:.gitmodules" --get-all submodule.applications/business-site.url) || reject 'committed website repository is missing'
[[ "$path" == applications/business-site ]] || reject 'committed website path does not match'
case "$url" in
  https://github.com/devantler-tech/business-site.git|git@github.com:devantler-tech/business-site.git) ;;
  *) reject 'committed website repository does not match' ;;
esac
printf '%s\n' "$revision"
