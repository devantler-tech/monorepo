#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -lt 5 ]]; then
  exit 2
fi

repo="$1"
author="$2"
branch="$3"
title="$4"
shift 4
files=("$@")

matches_exact_files() {
  local expected_count="$1"
  shift

  [[ "${#files[@]}" -eq "${expected_count}" ]] || return 1

  local expected actual found
  for expected in "$@"; do
    found=false
    for actual in "${files[@]}"; do
      if [[ "${actual}" == "${expected}" ]]; then
        found=true
        break
      fi
    done
    [[ "${found}" == true ]] || return 1
  done
}

is_semver() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]
}

if [[ "${repo}" == "ksail" &&
  "${author}" == "app/ksail-bot" &&
  "${title}" == "chore(copilot-plugin): release "* ]]; then
  version="${title#chore(copilot-plugin): release }"
  if is_semver "${version}" &&
    [[ "${branch}" == "chore/copilot-plugin-${version}" ]] &&
    matches_exact_files 4 \
      ".claude-plugin/marketplace.json" \
      ".github/plugin/marketplace.json" \
      "copilot-plugin/.claude-plugin/plugin.json" \
      "copilot-plugin/plugin.json"; then
    exit 0
  fi
fi

if [[ "${repo}" == "homebrew-tap" && "${author}" == "devantler" ]]; then
  case "${branch}" in
  goreleaser/ksail)
    component="ksail"
    expected_file="Casks/ksail.rb"
    ;;
  goreleaser/ksail-desktop)
    component="ksail-desktop"
    expected_file="Casks/ksail-desktop.rb"
    ;;
  *)
    exit 1
    ;;
  esac

  title_prefix="chore(cask): update ${component} to "
  if [[ "${title}" == "${title_prefix}"* ]]; then
    version="${title#"${title_prefix}"}"
    if is_semver "${version}" && matches_exact_files 1 "${expected_file}"; then
      exit 0
    fi
  fi
fi

exit 1
