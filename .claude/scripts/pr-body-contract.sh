#!/usr/bin/env bash
# Seed and validate agent-authored pull-request bodies at the write boundary.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "pr-body contract: FAIL — $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  pr-body-contract.sh seed --repo OWNER/REPO --output FILE [--role agentic-engineer|agent-improver]
  pr-body-contract.sh check --repo OWNER/REPO --body-file FILE|- [--role agentic-engineer|agent-improver] [--allow-no-issue]

seed fetches the repository's own default pull-request template, falling back to
OWNER/.github, and prepends the canonical role disclosure. Fill that file without
replacing its visible structure, run check, and pass it to gh with --body-file.
--allow-no-issue is reserved for the consumer contract's explicit trivial-fix
carve-out; replace the seeded issue placeholder with the exact visible line
"No issue: trivial fix." before using it.
EOF
  exit 2
}

command_name="${1:-}"
[ -n "${command_name}" ] || usage
shift

repo=''
output=''
role='agentic-engineer'
body_file=''
allow_no_issue=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || usage
      repo="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || usage
      output="$2"
      shift 2
      ;;
    --role)
      [ "$#" -ge 2 ] || usage
      role="$2"
      shift 2
      ;;
    --body-file)
      [ "$#" -ge 2 ] || usage
      body_file="$2"
      shift 2
      ;;
    --allow-no-issue)
      allow_no_issue=1
      shift
      ;;
    *) usage ;;
  esac
done

case "${repo}" in
  */*) ;;
  *) fail "--repo must be OWNER/REPO" ;;
esac

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

strip_comments() {
  awk '
    function unescaped_comment_start(text, offset, relative, position, slashes, index_before) {
      offset = 1
      while (offset <= length(text)) {
        relative = index(substr(text, offset), "<!--")
        if (relative == 0) { return 0 }
        position = offset + relative - 1
        slashes = 0
        index_before = position - 1
        while (index_before > 0 && substr(text, index_before, 1) == "\\") {
          slashes++
          index_before--
        }
        if (slashes % 2 == 0) { return position }
        offset = position + 4
      }
      return 0
    }

    {
      sub(/\r$/, "")
      line = $0
      output = ""
      while (1) {
        if (in_comment) {
          comment_end = index(line, "-->")
          if (comment_end == 0) {
            line = ""
            break
          }
          line = substr(line, comment_end + 3)
          in_comment = 0
          continue
        }

        comment_start = unescaped_comment_start(line)
        if (comment_start == 0) {
          output = output line
          line = ""
          break
        }
        output = output substr(line, 1, comment_start - 1)
        line = substr(line, comment_start + 4)
        in_comment = 1
      }

      if (output ~ /^[[:space:]]*[-*+][[:space:]]+\[[ xX]\]/) {
        sub(/\[[xX]\]/, "[ ]", output)
      }
      sub(/[[:space:]]+$/, "", output)
      if (!in_comment || length(output) > 0) {
        print output
      }
    }
  ' "$1"
}

strip_blockquotes() {
  awk '
    {
      line = $0
      while (line ~ /^ {0,3}>[[:space:]]?/) {
        sub(/^ {0,3}>[[:space:]]?/, "", line)
      }
      print line
    }
  ' "$1"
}

extract_atx_headings() {
  awk '
    {
      line = $0
      if (line ~ /^ {0,3}#{1,6}[[:space:]]+/) {
        sub(/^ {1,3}/, "", line)
        sub(/[[:space:]]+#+[[:space:]]*$/, "", line)
        print line
      }
    }
  ' "$1"
}

fetch_raw() {
  local source_repo="$1"
  local source_path="$2"
  local destination="$3"
  local error_file="${work_dir}/gh-api-error"

  if gh api \
    -H 'Accept: application/vnd.github.raw+json' \
    "repos/${source_repo}/contents/${source_path}" \
    >"${destination}" 2>"${error_file}"; then
    [ -s "${destination}" ] ||
      fail "template lookup returned empty content for ${source_repo}/${source_path}"
    return 0
  fi

  if grep -Eq '(HTTP 404|Not Found)' "${error_file}"; then
    return 1
  fi
  fail "template lookup failed for ${source_repo}/${source_path}"
}

discovered_path=''
find_template_path() {
  local source_repo="$1"
  local source_directory="$2"
  local endpoint="repos/${source_repo}/contents"
  local listing="${work_dir}/template-directory-listing"
  local matches="${work_dir}/template-directory-matches"
  local error_file="${work_dir}/gh-api-error"
  local match_count

  if [ "${source_directory}" != '.' ]; then
    endpoint="${endpoint}/${source_directory}"
  fi
  if ! gh api "${endpoint}" --jq '.[] | select(.type == "file") | .name' \
    >"${listing}" 2>"${error_file}"; then
    if grep -Eq '(HTTP 404|Not Found)' "${error_file}"; then
      return 1
    fi
    fail "template directory lookup failed for ${source_repo}/${source_directory}"
  fi

  awk 'tolower($0) ~ /^pull_request_template[.](md|txt)$/ { print }' \
    "${listing}" >"${matches}"
  match_count="$(wc -l <"${matches}" | tr -d '[:space:]')"
  [ "${match_count}" -le 1 ] ||
    fail "template lookup is ambiguous for ${source_repo}/${source_directory}"
  [ "${match_count}" -eq 1 ] || return 1
  IFS= read -r discovered_path <"${matches}"
  if [ "${source_directory}" != '.' ]; then
    discovered_path="${source_directory}/${discovered_path}"
  fi
}

resolve_template() {
  local target_repo="$1"
  local destination="$2"
  local owner="${target_repo%%/*}"
  local directory

  for directory in '.github' '.' 'docs'; do
    if find_template_path "${target_repo}" "${directory}"; then
      fetch_raw "${target_repo}" "${discovered_path}" "${destination}" ||
        fail "discovered template disappeared for ${target_repo}/${discovered_path}"
      return 0
    fi
  done

  for directory in '.github' '.' 'docs'; do
    if find_template_path "${owner}/.github" "${directory}"; then
      fetch_raw "${owner}/.github" "${discovered_path}" "${destination}" ||
        fail "discovered template disappeared for ${owner}/.github/${discovered_path}"
      return 0
    fi
  done

  fail "no effective GitHub pull request template found for ${target_repo} or ${owner}/.github"
}

validate_template() {
  local template="$1"
  local visible="${work_dir}/template-visible.md"
  local why_line
  local what_line
  strip_comments "${template}" >"${visible}"

  grep -Fqx '## Why' "${visible}" ||
    fail "effective template does not provide the required PM-facing heading: ## Why"
  grep -Fqx '## What' "${visible}" ||
    fail "effective template does not provide the required PM-facing heading: ## What"
  why_line="$(grep -nFx '## Why' "${visible}" | head -n 1 | cut -d: -f1)"
  what_line="$(grep -nFx '## What' "${visible}" | head -n 1 | cut -d: -f1)"
  [ "${why_line}" -lt "${what_line}" ] ||
    fail "effective template must place ## Why before ## What"
}

validate_body() {
  local template="$1"
  local body="$2"
  local visible_template="${work_dir}/template-visible.md"
  local visible_body="${work_dir}/body-visible.md"
  local markdown_template="${work_dir}/template-markdown.md"
  local markdown_body="${work_dir}/body-markdown.md"
  local template_headings="${work_dir}/template-headings"
  local template_headings_unique="${work_dir}/template-headings-unique"
  local body_headings="${work_dir}/body-headings"
  local template_setext_headings="${work_dir}/template-setext-headings"
  local body_setext_headings="${work_dir}/body-setext-headings"
  local template_structure="${work_dir}/template-structure"
  local template_fixed="${work_dir}/template-fixed"
  local template_fixed_unique="${work_dir}/template-fixed-unique"
  local body_content="${work_dir}/body-content.md"
  local body_validation="${work_dir}/body-validation.md"
  local body_prose="${work_dir}/body-prose.md"
  local body_symbols="${work_dir}/body-symbols.md"
  local first_line
  local expected_disclosure
  local heading
  local structure_line
  local fixed_line
  local allowed_count
  local body_count
  local line_number
  local previous_line=0
  local first_template_line
  local first_template_body_line
  local issue_count
  local relationship_marker_count
  local routine_disclosure_count
  local fixes_count
  local part_of_count
  local fixes_issue
  local part_of_issue
  local no_issue_marker_count
  local no_issue_line
  local issue_line
  local final_delivery_line
  local what_line
  local why_chars
  local what_chars
  local why_sentences
  local what_sentences
  local visible_chars

  strip_comments "${template}" >"${visible_template}"
  strip_comments "${body}" >"${visible_body}"
  strip_blockquotes "${visible_template}" >"${markdown_template}"
  strip_blockquotes "${visible_body}" >"${markdown_body}"
  validate_template "${template}"

  IFS= read -r first_line <"${body}" || fail "body is empty"
  first_line="${first_line%$'\r'}"
  case "${role}" in
    agentic-engineer) expected_disclosure='> 🤖 Generated by the Agentic Engineer' ;;
    agent-improver) expected_disclosure='> 🤖 Generated by the Agent Improver' ;;
    *) fail "unsupported --role: ${role}" ;;
  esac
  [ "${first_line}" = "${expected_disclosure}" ] ||
    fail "first-line disclosure does not match --role ${role}"
  routine_disclosure_count="$(awk -f "${script_dir}/markdown-structural-lines.awk" "${visible_body}" | \
    grep -Ec '^(🤖[[:space:]]*)?Generated by the (Agentic Engineer|Agent Improver|Daily AI Engineer|Daily AI Assistant)[[:space:]]*$' || true)"
  [ "${routine_disclosure_count}" -eq 1 ] ||
    fail "body must contain exactly one routine-role disclosure"

  extract_atx_headings "${markdown_template}" >"${template_headings}"
  [ -s "${template_headings}" ] || fail "effective template has no visible Markdown headings"
  extract_atx_headings "${markdown_body}" >"${body_headings}"
  awk '!seen[$0]++' "${template_headings}" >"${template_headings_unique}"

  while IFS= read -r heading; do
    allowed_count="$(grep -Fxc -- "${heading}" "${template_headings}" || true)"
    body_count="$(grep -Fxc -- "${heading}" "${body_headings}" || true)"
    [ "${body_count}" -eq "${allowed_count}" ] ||
      fail "required template heading is missing: ${heading}"
  done <"${template_headings_unique}"

  while IFS= read -r heading; do
    grep -Fqx "${heading}" "${template_headings}" ||
      fail "body adds a non-template section: ${heading}"
  done <"${body_headings}"

  awk 'previous != "" && /^[[:space:]]*(=+|-+)[[:space:]]*$/ { print previous } { previous = $0 }' \
    "${markdown_template}" >"${template_setext_headings}"
  awk 'previous != "" && /^[[:space:]]*(=+|-+)[[:space:]]*$/ { print previous } { previous = $0 }' \
    "${markdown_body}" >"${body_setext_headings}"
  while IFS= read -r heading; do
    grep -Fqx "${heading}" "${template_setext_headings}" ||
      fail "body adds a non-template Setext section: ${heading}"
  done <"${body_setext_headings}"

  awk '
    NF {
      if ($0 ~ /^(Fixes|Part of) #$/) { print "@RELATIONSHIP@" }
      else { print }
    }
  ' "${visible_template}" >"${template_structure}"
  # Preserve level-two section headings in the authored-content view so Why
  # and What can stop at the next repository-template section.
  awk 'NF && $0 !~ /^##[[:space:]]+/ && $0 !~ /^(Fixes|Part of) #$/ { print }' \
    "${visible_template}" >"${template_fixed}"
  awk '!seen[$0]++' "${template_fixed}" >"${template_fixed_unique}"
  while IFS= read -r fixed_line; do
    allowed_count="$(grep -Fxc -- "${fixed_line}" "${template_fixed}" || true)"
    body_count="$(grep -Fxc -- "${fixed_line}" "${visible_body}" || true)"
    [ "${body_count}" -le "${allowed_count}" ] ||
      fail "body repeats visible template content: ${fixed_line}"
  done <"${template_fixed_unique}"
  awk '
    FILENAME == ARGV[1] { inherited[$0]++; next }
    inherited[$0] > 0 { inherited[$0]--; next }
    { print }
  ' "${template_fixed}" "${visible_body}" >"${body_content}"
  # A blockquote changes presentation, not the kind of content it contains.
  # Peel every nested quote prefix before checking for structures that the
  # product-facing body forbids, while preserving the original body for prose,
  # template-order, and relationship validation.
  strip_blockquotes "${body_content}" >"${body_validation}"
  awk '
    function thematic_break(line, compact) {
      compact = line
      gsub(/[[:space:]]/, "", compact)
      return compact ~ /^(\*{3,}|-{3,}|_{3,})$/
    }
    function reference_title(line) {
      return line ~ /^ {1,3}"[^"]*"[[:space:]]*$/ ||
        line ~ /^ {1,3}\047[^\047]*\047[[:space:]]*$/ ||
        line ~ /^ {1,3}\([^)]*\)[[:space:]]*$/
    }
    awaiting_title && reference_title($0) { awaiting_title = 0; next }
    { awaiting_title = 0 }
    /^ {0,3}\[[^]]+\]:[[:space:]]*/ { awaiting_title = 1; next }
    !thematic_break($0) {
      rendered = $0
      gsub(/<\/?[A-Za-z][A-Za-z0-9-]*([[:space:]][^>]*)?\/?>/, "", rendered)
      gsub(/&(#([xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);/, "", rendered)
      if (rendered ~ /[^[:space:]]/) { print rendered }
    }
  ' "${body_validation}" >"${body_prose}"
  sed -E \
    -e '/^ {0,3}#{1,6}[[:space:]]+/d' \
    -e 's/(^|[^[:alnum:]_])(GitHub|CodeRabbit|OpenAI|OpenBao|OpenCost|CloudWatch|FleetDM|GitOps|DevEx|FinOps|KSail|ASCoaching|PostgreSQL|JavaScript|TypeScript|Node[.]js|Next[.]js|Vue[.]js|iPhone|iPad|iPod|iOS|iPadOS|macOS|watchOS)([^[:alnum:]_]|$)/\1product\3/g' \
    -e 's#https?://[^[:space:])}>]+#url#g' \
    "${body_validation}" >"${body_symbols}"
  previous_line=0
  while IFS= read -r structure_line; do
    if [ "${structure_line}" = '@RELATIONSHIP@' ]; then
      line_number="$(awk -v after="${previous_line}" '
        NR > after && (/^(Fixes|Part of) #[1-9][0-9]*$/ || /^No issue: trivial fix[.]$/) {
          print NR
          exit
        }
      ' "${visible_body}")"
      if [ -z "${line_number}" ]; then
        if grep -Eq '^(Fixes|Part of) #[1-9][0-9]*$|^No issue: trivial fix[.]$' "${visible_body}"; then
          fail "body changes effective template structure order"
        fi
        continue
      fi
    else
      line_number="$(awk -v target="${structure_line}" -v after="${previous_line}" '
        NR > after && $0 == target { print NR; exit }
      ' "${visible_body}")"
      [ -n "${line_number}" ] ||
        fail "required template structure is missing or out of order: ${structure_line}"
    fi
    previous_line="${line_number}"
  done <"${template_structure}"

  IFS= read -r first_template_line <"${template_structure}" ||
    fail "effective template has no visible structure"
  first_template_body_line="$(grep -nFx -- "${first_template_line}" "${visible_body}" | head -n 1 | cut -d: -f1)"
  if awk -v boundary="${first_template_body_line}" '
    NR > 1 && NR < boundary && NF { found = 1 }
    END { exit found ? 0 : 1 }
  ' "${visible_body}"; then
    fail "body adds visible content before the effective template"
  fi

  if grep -Eq '^(Fixes|Part of) #[[:space:]]*$' "${visible_body}"; then
    fail "body contains an unresolved issue placeholder"
  fi

  issue_count="$(grep -Ec '^(Fixes|Part of) #[1-9][0-9]*$' "${visible_body}" || true)"
  relationship_marker_count="$(grep -Eic '(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]*(#|[[:alnum:]_.-]+/[[:alnum:]_.-]+#|https?://github[.]com/[[:alnum:]_.-]+/[[:alnum:]_.-]+/issues/)|(^|[^[:alnum:]_])part[[:space:]]+of[[:space:]]*#' \
    "${visible_body}" || true)"
  fixes_count="$(grep -Ec '^Fixes #[1-9][0-9]*$' "${visible_body}" || true)"
  part_of_count="$(grep -Ec '^Part of #[1-9][0-9]*$' "${visible_body}" || true)"
  no_issue_marker_count="$(grep -Fxc 'No issue: trivial fix.' "${visible_body}" || true)"
  case "${issue_count}:${fixes_count}:${part_of_count}" in
    1:1:0|1:0:1|2:1:1)
      [ "${relationship_marker_count}" -eq "${issue_count}" ] ||
        fail "every issue relationship marker must use the permitted shape"
      [ "${no_issue_marker_count}" -eq 0 ] ||
        fail "the trivial-fix marker cannot accompany an issue relationship"
      ;;
    0:0:0)
      [ "${allow_no_issue}" -eq 1 ] ||
        fail "body must contain exactly one issue relationship: Fixes #N or Part of #N; one Fixes and one Part of experiment relationship may appear together"
      [ "${relationship_marker_count}" -eq 0 ] ||
        fail "no-issue mode forbids relationship markers"
      [ "${no_issue_marker_count}" -eq 1 ] ||
        fail "no-issue mode requires the explicit trivial-fix marker: No issue: trivial fix."
      ;;
    *)
      fail "body must contain exactly one issue relationship: Fixes #N or Part of #N; one Fixes and one Part of experiment relationship may appear together"
      ;;
  esac
  if [ "${issue_count}" -gt 0 ]; then
    if [ "${issue_count}" -eq 2 ]; then
      fixes_issue="$(sed -n 's/^Fixes #//p' "${visible_body}")"
      part_of_issue="$(sed -n 's/^Part of #//p' "${visible_body}")"
      [ "${fixes_issue}" != "${part_of_issue}" ] ||
        fail "delivery and experiment issue numbers must be distinct"
      if awk '
        /^(Fixes|Part of) #[1-9][0-9]*$/ { seen++; next }
        seen == 1 && NF { invalid = 1 }
        END { exit invalid ? 0 : 1 }
      ' "${body_content}"; then
        fail "issue relationship lines must be contiguous"
      fi
    fi
    issue_line="$(grep -nE '^(Fixes|Part of) #[1-9][0-9]*$' "${visible_body}" | head -n 1 | cut -d: -f1)"
    what_line="$(grep -nFx '## What' "${visible_body}" | cut -d: -f1)"
    [ "${issue_line}" -gt "${what_line}" ] || fail "issue relationship must follow the What section"
  else
    no_issue_line="$(grep -nFx 'No issue: trivial fix.' "${visible_body}" | cut -d: -f1)"
    what_line="$(grep -nFx '## What' "${visible_body}" | cut -d: -f1)"
    [ "${no_issue_line}" -gt "${what_line}" ] ||
      fail "the trivial-fix marker must follow the What section"
  fi

  why_chars="$(awk '
    /^## Why$/ { active = 1; next }
    active && /^##[[:space:]]+/ { active = 0 }
    active {
      line = $0
      if (line ~ /[[:alpha:]]/) { has_prose = 1 }
      gsub(/[[:space:]]/, "", line)
      total += length(line)
    }
    END { print has_prose ? total + 0 : 0 }
  ' "${body_prose}")"
  what_chars="$(awk '
    /^## What$/ { active = 1; next }
    active && /^##[[:space:]]+/ { active = 0 }
    /^(Fixes|Part of) #[1-9][0-9]*$/ || /^No issue: trivial fix[.]$/ { active = 0 }
    active {
      line = $0
      if (line ~ /[[:alpha:]]/) { has_prose = 1 }
      gsub(/[[:space:]]/, "", line)
      total += length(line)
    }
    END { print has_prose ? total + 0 : 0 }
  ' "${body_prose}")"
  [ "${why_chars}" -gt 0 ] || fail "Why section has no visible explanation"
  [ "${what_chars}" -gt 0 ] || fail "What section has no visible explanation"
  [ "${why_chars}" -le 800 ] || fail "Why section is too long for the PM review surface"
  [ "${what_chars}" -le 800 ] || fail "What section is too long for the PM review surface"

  # Curly quotes are literal Markdown delimiters in the AWK regex.
  # shellcheck disable=SC1112
  why_sentences="$(awk '
    function sentence_count(text, rest, count) {
      rest = text
      gsub(/[eE][.][gG][.]/, "eg", rest)
      gsub(/[iI][.][eE][.]/, "ie", rest)
      gsub(/[eE]tc[.]/, "etc", rest)
      gsub(/[vV]s[.]/, "vs", rest)
      gsub(/[mM]r[.]/, "Mr", rest)
      gsub(/[mM]rs[.]/, "Mrs", rest)
      gsub(/[dD]r[.]/, "Dr", rest)
      gsub(/[uU][.][sS][.]/, "US", rest)
      while (match(rest, /[.!?]["”’)}\]*_]*([[:space:]]|$)/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (text ~ /[^[:space:]]/ && count == 0) { count = 1 }
      return count
    }
    /^## Why$/ { active = 1; next }
    active && /^##[[:space:]]+/ { active = 0 }
    active { text = text " " $0 }
    END { print sentence_count(text) }
  ' "${body_prose}")"
  # Curly quotes are literal Markdown delimiters in the AWK regex.
  # shellcheck disable=SC1112
  what_sentences="$(awk '
    function sentence_count(text, rest, count) {
      rest = text
      gsub(/[eE][.][gG][.]/, "eg", rest)
      gsub(/[iI][.][eE][.]/, "ie", rest)
      gsub(/[eE]tc[.]/, "etc", rest)
      gsub(/[vV]s[.]/, "vs", rest)
      gsub(/[mM]r[.]/, "Mr", rest)
      gsub(/[mM]rs[.]/, "Mrs", rest)
      gsub(/[dD]r[.]/, "Dr", rest)
      gsub(/[uU][.][sS][.]/, "US", rest)
      while (match(rest, /[.!?]["”’)}\]*_]*([[:space:]]|$)/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (text ~ /[^[:space:]]/ && count == 0) { count = 1 }
      return count
    }
    /^## What$/ { active = 1; next }
    active && /^##[[:space:]]+/ { active = 0 }
    /^(Fixes|Part of) #[1-9][0-9]*$/ || /^No issue: trivial fix[.]$/ { active = 0 }
    active { text = text " " $0 }
    END { print sentence_count(text) }
  ' "${body_prose}")"
  if [ "${why_sentences}" -lt 1 ] || [ "${why_sentences}" -gt 3 ] || \
    [ "${what_sentences}" -lt 1 ] || [ "${what_sentences}" -gt 3 ]; then
    fail "Why and What must each contain 1 to 3 sentences"
  fi

  if awk '
    /^## Why$/ { active = 1; next }
    /^## What$/ { active = 1; next }
    active && /^##[[:space:]]+/ { active = 0 }
    active && /^[[:space:]]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "${body_validation}"; then
    fail "Why and What must be short prose, not bullet inventories"
  fi
  if awk '
    /^## Why$/ || /^## What$/ { active = 1; next }
    active && /^##[[:space:]]+/ { active = 0 }
    /^(Fixes|Part of) #[1-9][0-9]*$/ || /^No issue: trivial fix[.]$/ { active = 0 }
    active && (/^[[:space:]]*\|.*\|[[:space:]]*$/ ||
      /^[[:space:]]*:?-{3,}:?[[:space:]]*(\|[[:space:]]*:?-{3,}:?[[:space:]]*)+$/) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "${body_validation}"; then
    fail "Why and What must be short prose, not Markdown tables"
  fi

  if [ "${issue_count}" -gt 0 ] || [ "${allow_no_issue}" -eq 1 ]; then
    final_delivery_line="$(grep -nE '^(Fixes|Part of) #[1-9][0-9]*$|^No issue: trivial fix[.]$' \
      "${body_content}" | tail -n 1 | cut -d: -f1)"
    if awk -v boundary="${final_delivery_line}" '
      NR > boundary && NF {
        if ($0 ~ /^##[[:space:]]+/) {
          in_template_section = 1
        } else if (in_template_section) {
          next
        } else if ($0 ~ /^⚠️ Merge order:[[:space:]]+[^[:space:]]/ ||
            $0 ~ /^💥 Breaking change:[[:space:]]+[^[:space:]]/ ||
            $0 ~ /^📦 New dependency:[[:space:]]+[^[:space:]]/ ||
            $0 ~ /^👉 After merge\/promotion:[[:space:]]+[^[:space:]]/) {
          kind = $0
          sub(/:.*/, ":", kind)
          seen[kind]++
          if (seen[kind] > 1) { invalid = 1 }
        } else {
          invalid = 1
        }
      }
      END { exit invalid ? 0 : 1 }
    ' "${body_content}"; then
      fail "body adds non-template text after the final delivery relationship"
    fi
  fi

  if grep -Eiq '</?(pre|code|samp|kbd)([[:space:]>]|$)' "${body_validation}"; then
    fail "PR body must not contain raw HTML code containers"
  fi
  if grep -Eiq '^[[:space:]]*</?h[1-6]([[:space:]>]|$)' "${body_validation}"; then
    fail "body adds a non-template HTML section"
  fi
  if grep -Eq '^[[:space:]]*(```|~~~)' "${body_validation}"; then
    fail "PR body must not contain code or command fences"
  fi
  if awk '/^    / || /^\t/ { found = 1 } END { exit found ? 0 : 1 }' "${body_validation}"; then
    fail "PR body must not contain indented code blocks"
  fi
  if grep -Fq '`' "${body_validation}"; then
    fail "PR body must not contain code or command snippets"
  fi
  if grep -Eq '(^|[^[:alnum:]_])([Aa]dd|[Aa]dded|[Aa]dding|[Cc]all|[Cc]alled|[Cc]alling|[Cc]hange|[Cc]hanged|[Cc]hanging|[Ff]ix|[Ff]ixed|[Ff]ixing|[Ii]mplement|[Ii]mplemented|[Ii]mplementing|[Ii]ntroduce|[Ii]ntroduced|[Ii]ntroducing|[Ii]nvoke|[Ii]nvoked|[Ii]nvoking|[Mm]odify|[Mm]odified|[Mm]odifying|[Rr]efactor|[Rr]efactored|[Rr]efactoring|[Rr]emove|[Rr]emoved|[Rr]emoving|[Rr]ename|[Rr]enamed|[Rr]enaming|[Rr]eplace|[Rr]eplaced|[Rr]eplacing|[Uu]pdate|[Uu]pdated|[Uu]pdating|[Uu]se|[Uu]sed|[Uu]sing)[[:space:]]+(the[[:space:]]+)?[A-Za-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*([^[:alnum:]_]|$)|(^|[^[:alnum:]_])[A-Za-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*[[:space:]]+(now[[:space:]]+)?(accepts?|calls?|creates?|deletes?|fails?|handles?|invokes?|loads?|parses?|reads?|returns?|runs?|updates?|validates?|writes?)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])([Ff]unction|[Mm]ethod|[Ss]ymbol|[Tt]ype|[Cc]lass|[Ss]truct|[Ii]nterface)[[:space:]]+[A-Za-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*([^[:alnum:]_]|$)' \
    "${body_symbols}"; then
    fail "PR body must not contain implementation or validation detail"
  fi
  if grep -Eiq '(^|[^[:alnum:]_])(([.]{1,2}/|/)[[:alnum:]_./-]+|(src|test|tests|internal|cmd|pkg|docs|[.]github)/[[:alnum:]_./-]+)|(^|[^[:alnum:]_])(Dockerfile|Makefile|Taskfile|Justfile|Procfile|Gemfile|Rakefile|Jenkinsfile|Vagrantfile|Tiltfile|Brewfile)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])[[:alnum:]_.-]+\.(go|sh|py|ts|tsx|js|jsx|yaml|yml|json|md|cs|rs|java|kt|tf|hcl|mod|sum|toml|lock|ini|conf|cfg|env|properties|gradle|xml|sql|proto)([^[:alnum:]_]|$)|[[:alnum:]]+_[[:alnum:]_]+|(^|[^[:alnum:]])SC[0-9]{4}([^[:alnum:]]|$)|(^|[^[:alnum:]_])[[:alnum:]_]+\(\)|(^|[[:space:]])--[[:alnum:]][[:alnum:]-]*([^[:alnum:]-]|$)|(^|[^[:alnum:]_])(kubectl[[:space:]]+(apply|create|delete|describe|exec|get|logs|patch|rollout|scale|set|wait)|helm[[:space:]]+(dependency|install|lint|list|package|repo|rollback|status|template|test|uninstall|upgrade)|docker[[:space:]]+(build|compose|exec|images|inspect|logs|ps|pull|push|run|stop)|git[[:space:]]+(add|branch|checkout|cherry-pick|clone|commit|diff|fetch|log|merge|pull|push|rebase|reset|restore|show|status|switch|tag|worktree)|gh[[:space:]]+(api|auth|issue|pr|repo|run|workflow)|(terraform|tofu)[[:space:]]+(apply|destroy|fmt|import|init|output|plan|providers|refresh|show|state|taint|test|validate|workspace)|(curl|wget)[[:space:]]+url|ansible(-playbook|-galaxy)?[[:space:]]+(all|localhost|install|playbook|run))([^[:alnum:]_]|$)|(^|[^[:alnum:]_])(go[[:space:]]+(test|build|run|mod|generate|install|get)|npm[[:space:]]+(run|test|install)|pnpm[[:space:]]+(run|test|install)|cargo[[:space:]]+(test|build|run)|dotnet[[:space:]]+(test|build|run))([^[:alnum:]_]|$)|(^|[^[:alnum:]])(shellcheck|pytest|ruff|mypy|golangci-lint|go test|cargo test|npm (run )?test|pnpm (run )?test)([^[:alnum:]]|$)|(^|[^[:alnum:]_])(all[[:space:]]+)?(tests?|lint([[:space:]]+checks?)?|checks?)([[:space:]]+and[[:space:]]+(tests?|lint([[:space:]]+checks?)?|checks?))*[[:space:]]+(passed|failed|succeeded)([^[:alnum:]_]|$)|[0-9]+[[:space:]]+(tests?|checks?)([[:space:]]+|$)' \
    "${body_symbols}"; then
    fail "PR body must not contain implementation or validation detail"
  fi

  visible_chars="$(wc -c <"${visible_body}" | tr -d '[:space:]')"
  [ "${visible_chars}" -le 2000 ] || fail "PR body is too long for the PM review surface"
}

template_file="${work_dir}/template.md"
resolve_template "${repo}" "${template_file}"
validate_template "${template_file}"

case "${command_name}" in
  seed)
    [ -n "${output}" ] || usage
    [ -z "${body_file}" ] || usage
    [ ! -e "${output}" ] || fail "refusing to overwrite existing output: ${output}"
    case "${role}" in
      agentic-engineer) disclosure='> 🤖 Generated by the Agentic Engineer' ;;
      agent-improver) disclosure='> 🤖 Generated by the Agent Improver' ;;
      *) fail "unsupported --role: ${role}" ;;
    esac
    {
      printf '%s\n\n' "${disclosure}"
      cat "${template_file}"
    } >"${output}"
    ;;
  check)
    [ -z "${output}" ] || usage
    [ -n "${body_file}" ] || usage
    if [ "${body_file}" = '-' ]; then
      body_file="${work_dir}/stdin-body.md"
      cat >"${body_file}"
    fi
    [ -f "${body_file}" ] || fail "body file does not exist: ${body_file}"
    validate_body "${template_file}" "${body_file}"
    ;;
  *) usage ;;
esac
