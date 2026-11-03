#!/usr/bin/env bash
# shellcheck disable=SC2016
# Contract prose uses literal backticks, never shell substitutions.
#
# Guards the "upstream resources first, computer use last" rules (monorepo#4292).
#
# Why this needs a guard. On 2026-10-17 the maintainer gave two working directions: look for a
# vetted skill, MCP server, plugin or library before building something hard, and treat computer use
# as the exception behind an API, CLI, MCP server, plugin or infrastructure as code. They lived in
# one session's memory, which scheduled runs never read. The rules now live in
# .claude/guides/advance-work.md, with the tool-choice order repeated where a run shapes its tool
# calls (.claude/guides/tool-call-discipline.md). Losing the search order, a vetting item or the
# "computer use last" order in a later edit would go unnoticed.
#
# The checks read a whitespace-flattened copy of the rule's own section only, so a line rewrap cannot
# break them and the same phrase elsewhere in the guide cannot satisfy them. A missing or empty
# section fails closed, because an empty extraction would pass every substring check. Negative
# controls prove each failure mode fires for its own reason.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guide="${repo_root}/.claude/guides/advance-work.md"
discipline="${repo_root}/.claude/guides/tool-call-discipline.md"
index="${repo_root}/AGENTS.md"
heading='## Upstream resources first — vetted tools before building, computer use last'
anchor='advance-work.md#upstream-resources-first--vetted-tools-before-building-computer-use-last'
passed=0

fail() {
  echo "upstream-first contract: FAIL — $*" >&2
  exit 1
}

for f in "${guide}" "${discipline}" "${index}"; do
  [ -r "${f}" ] || fail "cannot read ${f}"
done

# Read a guide on stdin and print the rule's section, flattened. The heading must be present, or the
# extraction fails.
rule_section() {
  awk -v h="${heading}" '
    $0 == h { ins = 1; seen = 1; next }
    ins && /^## / { ins = 0 }
    ins { print }
    END { if (!seen) exit 3 }
  ' | tr '\n' ' ' | tr -s ' '
}

# Read the flattened section on stdin and print the first rule it lacks, if any.
missing_rule() {
  local text rule
  text="$(cat)"
  for rule in \
    'monorepo#4292' \
    'look for something that already does it before building it' \
    'is recommended and allowed' \
    '**Search order, before building something hard:**' \
    '1. the plugin catalog, MCP registries and skill catalogs;' \
    "2. the upstream project's own issues, pull requests and discussions;" \
    '3. maintained community tools.' \
    '**Vet a candidate before adopting it**, and record the verdict on the issue that needed it' \
    'its maintainer, recent activity, licence and adoption' \
    'an exact pinned version, never a floating tag or branch' \
    'what it can reach (network, files, secrets), configured with least privilege' \
    'a source review of anything that touches credentials or private data' \
    'its open security advisories' \
    'Private financial data never does' \
    '**Integrate only through reviewed surfaces:** `.claude/plugin-consumption/`' \
    'Never edit an installed cache or the runtime permission layer by hand.' \
    '**Tool-choice order: programmatic first, computer use last.**' \
    'Prefer an API or CLI, then an MCP server or plugin, then infrastructure as code.' \
    'Computer use (driving a browser or desktop UI) comes last, and only with the reason stated.' \
    'A blocked programmatic path is a `capability-gap` issue under monorepo#4288, never a reason to switch to clicking.'; do
    case "${text}" in
      *"${rule}"*) ;;
      *)
        printf '%s\n' "${rule}"
        return 0
        ;;
    esac
  done
}

guide_text="$(cat "${guide}")"

section="$(rule_section <<<"${guide_text}")" || fail "section '${heading}' not found in ${guide}"
[ -n "${section// /}" ] || fail "section '${heading}' is empty"
absent="$(printf '%s' "${section}" | missing_rule)"
[ -z "${absent}" ] || fail "the upstream-first section lacks: ${absent}"
passed=$((passed + 1))

# The tool-call discipline guide repeats the order where a run shapes its calls, and links the section.
discipline_text="$(tr '\n' ' ' <"${discipline}" | tr -s ' ')"
for rule in \
  '**Programmatic first, computer use last.**' \
  'an API or CLI, then an MCP server or plugin, then infrastructure as code, and computer use (driving a browser or desktop UI) only last, with the reason stated' \
  'A blocked programmatic path is a `capability-gap` issue, never a reason to switch to clicking.' \
  "(${anchor})"; do
  case "${discipline_text}" in
    *"${rule}"*) ;;
    *) fail "tool-call-discipline.md lacks: ${rule}" ;;
  esac
done
passed=$((passed + 1))

# The link target must be the section's real heading: GitHub drops the em dash and comma and turns
# each space into a hyphen, so the anchor is derived from the heading rather than trusted.
derived="$(printf '%s' "${heading#\#\# }" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9 -]//g' -e 's/ /-/g')"
[ "advance-work.md#${derived}" = "${anchor}" ] ||
  fail "the tool-call-discipline link anchor '${anchor}' does not match the heading's anchor '${derived}'"
passed=$((passed + 1))

# The always-loaded index must point readers at the section from the advance-work row.
index_row="$(grep -F '| [advance-work](.claude/guides/advance-work.md) |' "${index}" || true)"
[ -n "${index_row}" ] || fail "AGENTS.md has no advance-work row in its guide index"
case "${index_row}" in
  *' Upstream first '*) ;;
  *) fail "the AGENTS.md advance-work row does not list Upstream first" ;;
esac
passed=$((passed + 1))

# Negative control: a guide without the heading must fail the extraction, not pass it empty.
no_heading="$(grep -vxF "${heading}" <<<"${guide_text}")"
if rule_section <<<"${no_heading}" >/dev/null; then
  fail "negative control: a guide without the heading still extracted a section"
fi
passed=$((passed + 1))

# Negative control: a heading with no body must be caught as empty.
empty="$(printf '%s\n\n## Next section\nits open security advisories\n' "${heading}" | rule_section)" ||
  fail "negative control: the empty fixture did not extract"
[ -z "${empty// /}" ] || fail "negative control: an empty section extracted text from the next section"
passed=$((passed + 1))

# Negative control: drop one rule from the section; the check must name exactly that rule.
rule='Computer use (driving a browser or desktop UI) comes last, and only with the reason stated.'
mutant="${section/"${rule}"/}"
[ "${mutant}" != "${section}" ] || fail "negative control could not remove the computer-use rule"
absent="$(printf '%s' "${mutant}" | missing_rule)"
[ "${absent}" = "${rule}" ] || fail "negative control did not fire for the computer-use rule (got: '${absent}')"
passed=$((passed + 1))

# Negative control: the same rule moved OUT of the section must not satisfy it. The rule spans a line
# break in the guide, so move a single-line rule instead.
rule='its open security advisories'
moved_doc="$(awk -v h="${heading}" -v r="${rule}" '
  $0 == h { ins = 1 }
  ins && /^## / && $0 != h { ins = 0; after = 1 }
  { line = $0; if (ins) { i = index(line, r); if (i) line = substr(line, 1, i - 1) substr(line, i + length(r)) } print line }
  after { print "Elsewhere: " r; after = 0 }
' <<<"${guide_text}")"
case "${moved_doc}" in
  *"Elsewhere: ${rule}"*) ;;
  *) fail "negative control could not move the rule out of the section" ;;
esac
moved="$(rule_section <<<"${moved_doc}")" || fail "negative control: the moved fixture did not extract"
absent="$(printf '%s' "${moved}" | missing_rule)"
[ "${absent}" = "${rule}" ] || fail "negative control: a rule outside the section still satisfied it (got: '${absent}')"
passed=$((passed + 1))

echo "upstream-first contract: ${passed} checks passed"
