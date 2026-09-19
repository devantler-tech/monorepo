#!/usr/bin/env bash
# Seed and validate agent-authored pull-request bodies at the write boundary.

set -euo pipefail

fail() {
  echo "pr-body contract: FAIL — $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  pr-body-contract.sh seed --repo OWNER/REPO --output FILE [--role agentic-engineer|agent-improver]
  pr-body-contract.sh check --repo OWNER/REPO --body-file FILE|- [--role agentic-engineer|agent-improver]

seed fetches the repository's own default pull-request template, falling back to
OWNER/.github, and prepends the canonical role disclosure. Fill that file without
replacing its visible structure, run check, and pass it to gh with --body-file.
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

        comment_start = index(line, "<!--")
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

resolve_template() {
  local target_repo="$1"
  local destination="$2"
  local owner="${target_repo%%/*}"
  local candidate

  for candidate in \
    '.github/PULL_REQUEST_TEMPLATE.md' \
    '.github/pull_request_template.md' \
    'PULL_REQUEST_TEMPLATE.md' \
    'pull_request_template.md' \
    'docs/PULL_REQUEST_TEMPLATE.md' \
    'docs/pull_request_template.md'; do
    if fetch_raw "${target_repo}" "${candidate}" "${destination}"; then
      return 0
    fi
  done

  for candidate in \
    '.github/PULL_REQUEST_TEMPLATE.md' \
    '.github/pull_request_template.md' \
    'PULL_REQUEST_TEMPLATE.md' \
    'pull_request_template.md' \
    'docs/PULL_REQUEST_TEMPLATE.md' \
    'docs/pull_request_template.md'; do
    if fetch_raw "${owner}/.github" "${candidate}" "${destination}"; then
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
  local template_headings="${work_dir}/template-headings"
  local body_headings="${work_dir}/body-headings"
  local template_setext_headings="${work_dir}/template-setext-headings"
  local body_setext_headings="${work_dir}/body-setext-headings"
  local template_structure="${work_dir}/template-structure"
  local template_fixed="${work_dir}/template-fixed"
  local template_fixed_unique="${work_dir}/template-fixed-unique"
  local body_content="${work_dir}/body-content.md"
  local first_line
  local expected_disclosure
  local heading
  local structure_line
  local fixed_line
  local count
  local allowed_count
  local body_count
  local line_number
  local previous_line=0
  local first_template_line
  local first_template_body_line
  local issue_count
  local fixes_count
  local part_of_count
  local fixes_issue
  local part_of_issue
  local issue_line
  local final_issue_line
  local what_line
  local why_chars
  local what_chars
  local why_sentences
  local what_sentences
  local visible_chars

  strip_comments "${template}" >"${visible_template}"
  strip_comments "${body}" >"${visible_body}"
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

  extract_atx_headings "${visible_template}" >"${template_headings}"
  [ -s "${template_headings}" ] || fail "effective template has no visible Markdown headings"
  extract_atx_headings "${visible_body}" >"${body_headings}"

  while IFS= read -r heading; do
    count="$(grep -Fxc "${heading}" "${visible_body}" || true)"
    [ "${count}" -eq 1 ] || fail "required template heading is missing: ${heading}"
    line_number="$(grep -nFx "${heading}" "${visible_body}" | head -n 1 | cut -d: -f1)"
    [ "${line_number}" -gt "${previous_line}" ] ||
      fail "template headings are out of order at: ${heading}"
    previous_line="${line_number}"
  done <"${template_headings}"

  while IFS= read -r heading; do
    grep -Fqx "${heading}" "${template_headings}" ||
      fail "body adds a non-template section: ${heading}"
  done <"${body_headings}"

  awk 'previous != "" && /^[[:space:]]*(=+|-+)[[:space:]]*$/ { print previous } { previous = $0 }' \
    "${visible_template}" >"${template_setext_headings}"
  awk 'previous != "" && /^[[:space:]]*(=+|-+)[[:space:]]*$/ { print previous } { previous = $0 }' \
    "${visible_body}" >"${body_setext_headings}"
  while IFS= read -r heading; do
    grep -Fqx "${heading}" "${template_setext_headings}" ||
      fail "body adds a non-template Setext section: ${heading}"
  done <"${body_setext_headings}"

  awk 'NF && $0 !~ /^(Fixes|Part of) #$/ { print }' "${visible_template}" >"${template_structure}"
  awk 'NF && $0 !~ /^#{1,6} / && $0 !~ /^(Fixes|Part of) #$/ { print }' \
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
  previous_line=0
  while IFS= read -r structure_line; do
    line_number="$(awk -v target="${structure_line}" -v after="${previous_line}" '
      NR > after && $0 == target { print NR; exit }
    ' "${visible_body}")"
    [ -n "${line_number}" ] ||
      fail "required template structure is missing or out of order: ${structure_line}"
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

  issue_count="$(grep -Ec '^(Fixes|Part of) #[1-9][0-9]*$' "${visible_body}" || true)"
  fixes_count="$(grep -Ec '^Fixes #[1-9][0-9]*$' "${visible_body}" || true)"
  part_of_count="$(grep -Ec '^Part of #[1-9][0-9]*$' "${visible_body}" || true)"
  case "${issue_count}:${fixes_count}:${part_of_count}" in
    1:1:0|1:0:1|2:1:1) ;;
    *)
      fail "body must contain exactly one issue relationship: Fixes #N or Part of #N; one Fixes and one Part of experiment relationship may appear together"
      ;;
  esac
  if [ "${issue_count}" -eq 2 ]; then
    fixes_issue="$(sed -n 's/^Fixes #//p' "${visible_body}")"
    part_of_issue="$(sed -n 's/^Part of #//p' "${visible_body}")"
    [ "${fixes_issue}" != "${part_of_issue}" ] ||
      fail "delivery and experiment issue numbers must be distinct"
  fi
  issue_line="$(grep -nE '^(Fixes|Part of) #[1-9][0-9]*$' "${visible_body}" | head -n 1 | cut -d: -f1)"
  what_line="$(grep -nFx '## What' "${visible_body}" | cut -d: -f1)"
  [ "${issue_line}" -gt "${what_line}" ] || fail "issue relationship must follow the What section"

  why_chars="$(awk '
    /^## Why$/ { active = 1; next }
    /^## What$/ { active = 0 }
    active { line = $0; gsub(/[[:space:]]/, "", line); total += length(line) }
    END { print total + 0 }
  ' "${body_content}")"
  what_chars="$(awk '
    /^## What$/ { active = 1; next }
    /^(Fixes|Part of) #[1-9][0-9]*$/ { active = 0 }
    active { line = $0; gsub(/[[:space:]]/, "", line); total += length(line) }
    END { print total + 0 }
  ' "${body_content}")"
  [ "${why_chars}" -gt 0 ] || fail "Why section has no visible explanation"
  [ "${what_chars}" -gt 0 ] || fail "What section has no visible explanation"
  [ "${why_chars}" -le 800 ] || fail "Why section is too long for the PM review surface"
  [ "${what_chars}" -le 800 ] || fail "What section is too long for the PM review surface"

  why_sentences="$(awk '
    function sentence_count(text, rest, count) {
      rest = text
      while (match(rest, /[.!?]([[:space:]]|$)/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (text ~ /[^[:space:]]/ && count == 0) { count = 1 }
      return count
    }
    /^## Why$/ { active = 1; next }
    /^## What$/ { active = 0 }
    active { text = text " " $0 }
    END { print sentence_count(text) }
  ' "${body_content}")"
  what_sentences="$(awk '
    function sentence_count(text, rest, count) {
      rest = text
      while (match(rest, /[.!?]([[:space:]]|$)/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (text ~ /[^[:space:]]/ && count == 0) { count = 1 }
      return count
    }
    /^## What$/ { active = 1; next }
    /^(Fixes|Part of) #[1-9][0-9]*$/ { active = 0 }
    active { text = text " " $0 }
    END { print sentence_count(text) }
  ' "${body_content}")"
  if [ "${why_sentences}" -lt 1 ] || [ "${why_sentences}" -gt 3 ] || \
    [ "${what_sentences}" -lt 1 ] || [ "${what_sentences}" -gt 3 ]; then
    fail "Why and What must each contain 1 to 3 sentences"
  fi

  if awk '
    /^## Why$/ { active = 1; next }
    /^## What$/ { active = 1; next }
    active && /^[[:space:]]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "${body_content}"; then
    fail "Why and What must be short prose, not bullet inventories"
  fi

  final_issue_line="$(grep -nE '^(Fixes|Part of) #[1-9][0-9]*$' "${body_content}" | tail -n 1 | cut -d: -f1)"
  if awk -v boundary="${final_issue_line}" '
    NR > boundary && NF {
      if ($0 ~ /^⚠️ (Merge order|Breaking change|New dependency):[[:space:]]+[^[:space:]]/ ||
          $0 ~ /^👉 (Maintainer action|After merge):[[:space:]]+[^[:space:]]/) {
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
    fail "body adds non-template text after the final issue relationship"
  fi

  if grep -Eq '^[[:space:]]*(```|~~~)' "${visible_body}"; then
    fail "PR body must not contain code or command fences"
  fi
  if grep -Fq '`' "${body_content}"; then
    fail "PR body must not contain code or command snippets"
  fi
  if grep -Eiq '(^|[^[:alnum:]_])([.]{0,2}/)?[[:alnum:]_.-]+/[[:alnum:]_./-]+|(^|[^[:alnum:]_])[[:alnum:]_.-]+\.(go|sh|py|ts|tsx|js|jsx|yaml|yml|json|md|cs|rs|java|kt|tf|hcl)([^[:alnum:]_]|$)|[[:alnum:]]+_[[:alnum:]_]+|(^|[^[:alnum:]])SC[0-9]{4}([^[:alnum:]]|$)|(^|[^[:alnum:]_])[[:alnum:]_]+\(\)|(^|[^[:alnum:]])(shellcheck|pytest|ruff|mypy|golangci-lint|go test|cargo test|npm (run )?test|pnpm (run )?test)([^[:alnum:]]|$)|[0-9]+[[:space:]]+(tests?|checks?)([[:space:]]+|$)' \
    "${body_content}"; then
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
