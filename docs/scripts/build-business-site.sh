#!/usr/bin/env bash
# Exercise both release states; leave the selected production build in dist/.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
selected=${FEATURE_BUSINESS_SITE:-false}
case "$selected" in
  true) other=false ;;
  false) other=true ;;
  *) echo 'FEATURE_BUSINESS_SITE must be true or false' >&2; exit 1 ;;
esac
preview_dir=$(mktemp -d "${TMPDIR:-/tmp}/devantler-business-build.XXXXXX")
trap 'rm -r -- "$preview_dir"' EXIT
FEATURE_BUSINESS_SITE="$other" astro build --outDir "$preview_dir"
node scripts/check-business-site.mjs "$preview_dir" "$other"
FEATURE_BUSINESS_SITE="$selected" astro build
node scripts/check-business-site.mjs dist "$selected"
