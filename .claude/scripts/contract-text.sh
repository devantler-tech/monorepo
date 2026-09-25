#!/usr/bin/env bash
# contract-text.sh — print the agent contract: the root AGENTS.md followed by every guide it indexes.
#
# The contract is split so every session loads only the always-on core (AGENTS.md) and reads a guide
# under .claude/guides/ when its work needs one. A contract test that asserts a rule spanning several
# guides reads the whole contract through this helper instead of assuming it is one file.
#
# The guide list comes from the links in AGENTS.md's "## Agent guides" table, and it must match the
# files in .claude/guides/ exactly. A guide that exists but is not indexed is invisible to every agent,
# and an indexed guide that is missing is a dead instruction, so either one fails closed rather than
# assembling a contract that silently lacks a part.
#
# Usage: contract-text.sh [--files] [--root <repo-root>]
#   default   print the contract text, root first, then each guide in index order
#   --files   print the repository-relative paths instead, one per line
# Exit codes: 0 printed · 2 the contract cannot be assembled (each reason printed on stderr).
set -euo pipefail

mode=text
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --files) mode=files; shift ;;
    --root) [ $# -ge 2 ] || { echo "contract-text: --root needs a value" >&2; exit 2; }; root="$2"; shift 2 ;;
    *) echo "usage: contract-text.sh [--files] [--root <repo-root>]" >&2; exit 2 ;;
  esac
done

agents="$root/AGENTS.md"
guides_dir="$root/.claude/guides"
[ -r "$agents" ] || { echo "contract-text: cannot read $agents" >&2; exit 2; }
[ -d "$guides_dir" ] || { echo "contract-text: no guides directory at $guides_dir" >&2; exit 2; }

# Guides named by the index, in order: every `.claude/guides/<name>.md` link inside the
# "## Agent guides" section, first occurrence only.
indexed="$(awk '
  /^## Agent guides[[:space:]]*$/ { inside = 1; next }
  inside && /^## / { exit }
  inside {
    line = $0
    while (match(line, /\]\(\.claude\/guides\/[A-Za-z0-9._-]+\.md\)/)) {
      path = substr(line, RSTART + 2, RLENGTH - 3)
      if (!(path in seen)) { seen[path] = 1; print path }
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "$agents")"
[ -n "$indexed" ] || { echo "contract-text: AGENTS.md has no '## Agent guides' index linking .claude/guides/" >&2; exit 2; }

problems=0
while IFS= read -r path; do
  [ -r "$root/$path" ] || { echo "contract-text: indexed guide is missing: $path" >&2; problems=1; }
done <<<"$indexed"
for file in "$guides_dir"/*.md; do
  [ -e "$file" ] || continue
  path=".claude/guides/$(basename "$file")"
  grep -Fxq "$path" <<<"$indexed" ||
    { echo "contract-text: guide is not in the AGENTS.md index, so no agent will find it: $path" >&2; problems=1; }
done
[ "$problems" -eq 0 ] || exit 2

if [ "$mode" = files ]; then
  printf '%s\n' AGENTS.md
  printf '%s\n' "$indexed"
  exit 0
fi

cat "$agents"
while IFS= read -r path; do
  printf '\n'
  cat "$root/$path"
done <<<"$indexed"
