#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <submodule-path>"
  exit 1
}

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

path="${1%/}"

git submodule deinit -f -- "$path"
rm -rf ".git/modules/$path"
git rm -f -- "$path"
