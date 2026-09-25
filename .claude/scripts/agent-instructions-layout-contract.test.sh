#!/usr/bin/env bash
#
# Guards the layout of this repository's agent instructions: a small always-on AGENTS.md, topic guides
# under .claude/guides/ read on demand, and nested AGENTS.md files next to the code they govern.
#
# Why it needs enforcing: AGENTS.md grew to 495 KB (5,592 lines) because every lesson was appended to
# the one file every session loads. Two concrete costs followed. Codex reads at most 32 KiB of project
# instructions by default (`project_doc_max_bytes`) and silently truncates the rest, so its lanes booted
# with the first 6.6% of the contract — cut off before the trust gate, untrusted-input, egress and git
# safety rules. Claude Code loaded all of it, so every session and every surveyor dispatch paid for
# ~125k tokens of instructions, most of them irrelevant to the task at hand.
#
# Guarded properties:
#   1. the root AGENTS.md stays within its byte budget, and the root plus any nested AGENTS.md stays
#      within Codex's 32 KiB default, so no tool ever reads a truncated contract;
#   2. while the root keeps its CLAUDE.md shim, every nested AGENTS.md has one beside it too — with a
#      root CLAUDE.md present, Claude Code reads CLAUDE.md files only, so a nested AGENTS.md without a
#      shim is invisible to it. (Once #3448 removes the root shim, Claude reads AGENTS.md directly and
#      the nested shims stop being required.);
#   3. the guide index and .claude/guides/ agree exactly (via contract-text.sh), so no guide is
#      orphaned and no indexed guide is missing;
#   4. the sections other tools resolve by name stay in the root: the plugin contract sections, the
#      Stack map the vibe-coding guardrail fails closed without, and the Review guidelines reviewers read;
#   5. every relative link and anchor in the instruction files resolves.
# Each property has a negative control that must fail for its own reason.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract_text="${repo_root}/.claude/scripts/contract-text.sh"

ROOT_BUDGET_BYTES=29696   # 29 KiB: leaves room under Codex's 32 KiB for a nested AGENTS.md
CODEX_DOC_MAX_BYTES=32768 # Codex `project_doc_max_bytes` default

fail() {
  echo "agent-instructions layout contract: FAIL — $*" >&2
  exit 1
}

# slug <heading text> — GitHub's heading anchor: lowercase, drop everything but letters, digits,
# spaces, hyphens and underscores, then turn each space into a hyphen. The headings here use only
# ASCII plus punctuation such as em dashes, so the C locale is exact.
slug() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'
}

# anchors <file> — every heading anchor in a Markdown file, ignoring fenced code blocks.
anchors() {
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    !fence && /^#{1,6} / { sub(/^#+ /, ""); print }
  ' "$1" | while IFS= read -r heading; do slug "${heading}"; printf '\n'; done
}

# resolve_rel <dir> <relative-path> — the repository-relative path a link from <dir> points at, with
# `.` and `..` segments applied; fails when the link climbs above the repository root.
resolve_rel() {
  local -a parts=()
  local segment joined
  IFS=/ read -r -a parts <<<"$1"
  [ "$1" = . ] && parts=()
  local -a rel=()
  IFS=/ read -r -a rel <<<"$2"
  for segment in "${rel[@]}"; do
    case "${segment}" in
      '' | .) ;;
      ..) [ "${#parts[@]}" -gt 0 ] || return 1; unset 'parts[${#parts[@]}-1]'; parts=("${parts[@]+"${parts[@]}"}") ;;
      *) parts+=("${segment}") ;;
    esac
  done
  joined="$(IFS=/; printf '%s' "${parts[*]+"${parts[*]}"}")"
  printf '%s' "${joined:-.}"
}

# nested_agents <root> — this repository's own nested AGENTS.md files, tracked or new. `git ls-files`
# never descends into a submodule, whose AGENTS.md belongs to that product's repository. A failed
# listing aborts the check rather than reading as "no nested files".
nested_agents() {
  local listing
  listing="$(git -C "$1" ls-files --cached --others --exclude-standard -- ':(glob)**/AGENTS.md')" ||
    { echo "cannot list nested AGENTS.md files under $1" >&2; return 2; }
  printf '%s\n' "${listing}" | grep -v '^AGENTS\.md$' | LC_ALL=C sort -u || true
}

# check_layout <root> — runs every property against a checkout rooted at <root>; prints the first
# violation and returns 1, or returns 0.
check_layout() {
  local root="$1" agents="$1/AGENTS.md" size nested nested_list files file dir target path anchor anchor_list chain_size chain_dir
  [ -r "${agents}" ] || { echo "cannot read ${agents}"; return 1; }
  nested_list="$(nested_agents "${root}")" || { echo "cannot list the nested AGENTS.md files"; return 1; }

  # 1. budgets
  size="$(wc -c <"${agents}" | tr -d ' ')"
  [ "${size}" -le "${ROOT_BUDGET_BYTES}" ] ||
    { echo "root AGENTS.md is ${size} B, over its ${ROOT_BUDGET_BYTES} B budget — move procedures, evidence and edge cases into a guide"; return 1; }
  while IFS= read -r nested; do
    [ -n "${nested}" ] || continue
    # Codex concatenates every AGENTS.md from the root down to the working directory, so the budget
    # is the whole chain, not the root plus one file.
    chain_size="${size}"
    chain_dir="$(dirname "${nested}")"
    while [ "${chain_dir}" != . ]; do
      if [ -f "${root}/${chain_dir}/AGENTS.md" ]; then
        chain_size=$((chain_size + $(wc -c <"${root}/${chain_dir}/AGENTS.md" | tr -d ' ')))
      fi
      chain_dir="$(dirname "${chain_dir}")"
    done
    [ "${chain_size}" -le "${CODEX_DOC_MAX_BYTES}" ] ||
      { echo "the AGENTS.md chain down to ${nested} is ${chain_size} B, over Codex's ${CODEX_DOC_MAX_BYTES} B default — Codex would truncate it"; return 1; }
    # 2. Claude shim beside every nested AGENTS.md
    if [ -e "${root}/CLAUDE.md" ]; then
      [ "$(cat "${root}/$(dirname "${nested}")/CLAUDE.md" 2>/dev/null)" = '@AGENTS.md' ] ||
        { echo "${nested} has no CLAUDE.md shim containing exactly '@AGENTS.md' — while the root has one, Claude Code would never read it"; return 1; }
    fi
  done <<<"${nested_list}"
  if [ -e "${root}/CLAUDE.md" ]; then
    [ "$(cat "${root}/CLAUDE.md")" = '@AGENTS.md' ] ||
      { echo "root CLAUDE.md must contain exactly '@AGENTS.md', so there is one source of instructions"; return 1; }
  fi

  # 3. index ↔ guides
  files="$("${contract_text}" --files --root "${root}" 2>&1)" || { echo "${files}"; return 1; }
  # The assembled text is what the multi-guide contract tests read, so it must be exactly the root
  # followed by each indexed guide — a helper that silently dropped a guide would pass every presence
  # check that happens to be satisfied elsewhere.
  local expected actual listed
  expected="$(cat "${agents}"; while IFS= read -r listed; do
    [ "${listed}" = AGENTS.md ] && continue
    printf '\n'; cat "${root}/${listed}"
  done <<<"${files}")"
  actual="$("${contract_text}" --root "${root}")" || { echo "contract-text.sh failed to print the contract"; return 1; }
  [ "${actual}" = "${expected}" ] ||
    { echo "contract-text.sh does not print exactly AGENTS.md followed by every indexed guide"; return 1; }

  # 4. sections resolved by name must stay in the root
  local heading
  for heading in '## Portfolio map' '## Stack map' '### Agentic engineering plugin contract' \
    '### Trust gate' '### Cadence & focus' '### Durable memory' '### Maintainer channels' \
    '### Spend contract' '### Agent definition locations' '### Authority model' '## Agent guides' \
    '## Review guidelines'; do
    grep -q "^${heading}" "${agents}" ||
      { echo "root AGENTS.md lost its '${heading}' section, which another tool resolves by name"; return 1; }
  done
  # 5. links and anchors in every instruction file
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    dir="$(dirname "${file}")"
    while IFS= read -r target; do
      case "${target}" in
        http://* | https://* | mailto:* | …) continue ;;
      esac
      path="${target%%#*}"
      anchor=""
      [ "${target}" != "${path}" ] && anchor="${target#*#}"
      if [ -z "${path}" ]; then
        path="${file}"
      else
        path="$(resolve_rel "${dir}" "${path}")" ||
          { echo "${file} links to ${target}, which leaves the repository"; return 1; }
      fi
      # A link into an unpopulated submodule cannot be checked here; the submodule owns that file.
      if [ ! -e "${root}/${path}" ]; then
        case "${path}" in
          libraries/* | applications/* | platform/* | templates/* | github/* | homebrew-tap/*) continue ;;
        esac
        echo "${file} links to ${target}, which does not exist"
        return 1
      fi
      path="${root}/${path}"
      if [ -n "${anchor}" ]; then
        # Captured first: piping into `grep -q` under pipefail fails whenever grep exits early.
        anchor_list="$(anchors "${path}")"
        grep -Fxq -- "${anchor}" <<<"${anchor_list}" ||
          { echo "${file} links to ${target}, but that file has no such heading"; return 1; }
      fi
    done < <(awk '
      /^[[:space:]]*```/ { fence = !fence; next }
      !fence {
        line = $0
        while (match(line, /\]\([^) ]+\)/)) { print substr(line, RSTART + 2, RLENGTH - 3); line = substr(line, RSTART + RLENGTH) }
      }' "${root}/${file}")
  done <<<"$(printf '%s\n%s\n' "${files}" "${nested_list}")"

  return 0
}

[ -x "${contract_text}" ] || fail "cannot execute ${contract_text}"
result="$(check_layout "${repo_root}")" || fail "${result}"
echo "ok   the live instruction layout satisfies every property"

# ── Negative controls: each mutation must fail for its own reason ─────────────────────────────────
scratch="$(mktemp -d)"
layout_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "${scratch}"
  if [ "${layout_test_finished}" != 1 ] && [ "${rc}" -eq 0 ]; then
    echo "agent-instructions layout contract: aborted before finishing" >&2
    rc=1
  fi
  exit "${rc}"
}
trap cleanup EXIT

fixture() {
  rm -rf "${scratch}/repo"
  mkdir -p "${scratch}/repo/.claude"
  cp "${repo_root}/AGENTS.md" "${repo_root}/CLAUDE.md" "${scratch}/repo/"
  cp -R "${repo_root}/.claude/guides" "${scratch}/repo/.claude/guides"
  mkdir -p "${scratch}/repo/.claude/scripts" "${scratch}/repo/docs"
  cp "${repo_root}/.claude/scripts/AGENTS.md" "${repo_root}/.claude/scripts/CLAUDE.md" "${scratch}/repo/.claude/scripts/"
  cp "${repo_root}/docs/AGENTS.md" "${repo_root}/docs/CLAUDE.md" "${scratch}/repo/docs/"
  git -C "${scratch}/repo" init -q
  # Link targets the instruction files point at, so only the mutation under test can fail.
  (cd "${repo_root}" && git ls-files -- .claude docs/README.md) | while IFS= read -r f; do
    [ -e "${scratch}/repo/${f}" ] && continue
    mkdir -p "$(dirname "${scratch}/repo/${f}")"
    cp "${repo_root}/${f}" "${scratch}/repo/${f}" 2>/dev/null || true
  done
}

expect_failure() { # <label> <expected substring>
  local out
  if out="$(check_layout "${scratch}/repo")"; then
    fail "negative control '$1' passed — the property it mutates is unguarded"
  fi
  case "${out}" in
    *"$2"*) echo "ok   negative control: $1" ;;
    *) fail "negative control '$1' failed for the wrong reason: ${out}" ;;
  esac
}

fixture
check_layout "${scratch}/repo" >/dev/null || fail "the unmutated fixture does not pass — the controls below would prove nothing"

fixture
head -c "$((ROOT_BUDGET_BYTES + 1))" /dev/zero | tr '\0' 'x' >>"${scratch}/repo/AGENTS.md"
expect_failure "root over budget" "over its ${ROOT_BUDGET_BYTES} B budget"

fixture
head -c 8000 /dev/zero | tr '\0' 'x' >>"${scratch}/repo/docs/AGENTS.md"
expect_failure "AGENTS.md chain over Codex's limit" "Codex would truncate it"

fixture
rm "${scratch}/repo/docs/CLAUDE.md"
expect_failure "nested AGENTS.md without a Claude shim" "no CLAUDE.md shim"

# Positive control for the shim rule: once the root shim is gone (#3448), Claude reads AGENTS.md
# directly, so nested files no longer need one and the layout must still pass.
fixture
rm "${scratch}/repo/CLAUDE.md" "${scratch}/repo/docs/CLAUDE.md" "${scratch}/repo/.claude/scripts/CLAUDE.md"
check_layout "${scratch}/repo" >/dev/null ||
  fail "a layout with no CLAUDE.md shims at all was rejected — the shim rule must follow the root"
echo "ok   positive control: no root shim, no nested shims required"

fixture
printf '# Orphan\n' >"${scratch}/repo/.claude/guides/orphan.md"
expect_failure "guide missing from the index" "not in the AGENTS.md index"

fixture
rm "${scratch}/repo/.claude/guides/cadence.md"
expect_failure "indexed guide missing" "indexed guide is missing"

fixture
# A helper that lists every guide but prints only the root as text: the multi-guide contract tests
# would then read an incomplete contract, so the equality check must refuse it.
cat >"${scratch}/contract-text-stub.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = --files ]; then exec "${REAL_CONTRACT_TEXT}" "$@"; fi
while [ $# -gt 0 ]; do
  if [ "$1" = --root ]; then cat "$2/AGENTS.md"; exit 0; fi
  shift
done
STUB
chmod +x "${scratch}/contract-text-stub.sh"
real_contract_text="${contract_text}"
export REAL_CONTRACT_TEXT="${real_contract_text}"
contract_text="${scratch}/contract-text-stub.sh"
expect_failure "contract-text.sh drops guides from its text" "does not print exactly"
contract_text="${real_contract_text}"

fixture
printf '\nSee [nowhere](no-such-file.md).\n' >>"${scratch}/repo/.claude/guides/cadence.md"
expect_failure "dead relative link" "which does not exist"

fixture
printf '\nSee [the ladder](../../AGENTS.md#no-such-heading).\n' >>"${scratch}/repo/.claude/guides/cadence.md"
expect_failure "dead anchor" "has no such heading"

fixture
sed -i.bak 's/^## Stack map$/## Stack catalogue/' "${scratch}/repo/AGENTS.md"
expect_failure "named section moved out of the root" "'## Stack map'"

layout_test_finished=1
echo "agent-instructions layout contract: PASS"
