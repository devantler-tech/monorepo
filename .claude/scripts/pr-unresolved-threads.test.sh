#!/usr/bin/env bash
# pr-unresolved-threads.test.sh — hermetic proof for pr-unresolved-threads.sh (monorepo#2670).
# A stub `gh` on PATH serves canned GraphQL pages, so no token or network is needed. Each
# property is paired with an ablated copy of the helper that must FAIL the same case.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
tool="${here}/pr-unresolved-threads.sh"

tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then exit 1; fi
}
trap on_exit EXIT
failures=0
checks=0

# page <total> <has-next> <cursor> <resolved-flags...>  — one GraphQL page as gh prints it.
page() {
  local total="$1" next="$2" cursor="$3" nodes="" flag
  shift 3
  for flag in "$@"; do nodes="${nodes:+${nodes},}{\"isResolved\":${flag}}"; done
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":%s,"nodes":[%s],"pageInfo":{"hasNextPage":%s,"endCursor":"%s"}}}}}}\n' \
    "${total}" "${nodes}" "${next}" "${cursor}"
}

mkdir -p "${tmp}/bin" "${tmp}/pages"
# The stub prints page 1 only, unless --paginate was passed, in which case it prints every page
# — the same observable difference as the real CLI.
cat >"${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
dir="${STUB_PAGES:?}"
[ -e "${dir}/fail" ] && exit 1
paginate=0
for a in "$@"; do [ "$a" = "--paginate" ] && paginate=1; done
if [ "${paginate}" = 1 ]; then cat "${dir}"/page-*; else cat "${dir}/page-1"; fi
STUB
chmod +x "${tmp}/bin/gh"

scenario() { # scenario <name> then page lines on stdin, one file per line
  local d="${tmp}/pages/$1" i=0 line
  mkdir -p "${d}"
  while IFS= read -r line; do
    i=$((i + 1))
    printf '%s\n' "${line}" >"${d}/page-${i}"
  done
}

expect() { # expect <label> <tool> <scenario> <want-rc> <want-line>
  local label="$1" t="$2" s="$3" want_rc="$4" want="$5" got rc
  checks=$((checks + 1))
  set +e
  got="$(STUB_PAGES="${tmp}/pages/${s}" PATH="${tmp}/bin:${PATH}" bash "${t}" devantler-tech/monorepo 2436 2>/dev/null)"
  rc=$?
  set -e
  if [ "${rc}" = "${want_rc}" ] && [ "${got}" = "${want}" ]; then
    echo "ok   ${label}"
  else
    echo "FAIL ${label}: want rc=${want_rc} '${want}', got rc=${rc} '${got}'" >&2
    failures=$((failures + 1))
  fi
}

page 0 false "" | scenario zero
page 1 false c1 false | scenario unresolved
page 2 false c1 true true | scenario resolved-only
# 103 threads: 100 resolved on page 1, three on page 2 of which one is unresolved.
{
  flags=()
  for _ in $(seq 1 100); do flags+=(true); done
  page 103 true c1 "${flags[@]}"
  page 103 false c2 true false true
} | scenario paginated
page 1 false c1 false | scenario failed
: >"${tmp}/pages/failed/fail"
printf '%s\n' '{"errors":[{"message":"Could not resolve to a PullRequest"}],"data":{"repository":{"pullRequest":null}}}' | scenario malformed

expect "zero-thread PR" "${tool}" zero 0 "unresolved=0 total=0"
expect "unresolved-thread PR" "${tool}" unresolved 1 "unresolved=1 total=1"
expect "resolved-only PR" "${tool}" resolved-only 0 "unresolved=0 total=2"
expect "103 threads across two pages" "${tool}" paginated 1 "unresolved=1 total=103"
expect "failed read is UNKNOWN, not zero" "${tool}" failed 2 "UNKNOWN read-failed"
expect "missing pull request is UNKNOWN" "${tool}" malformed 2 "UNKNOWN malformed"

# Ablation 1: without --paginate the helper sees 100 of 103 — the truncation check must catch it
# rather than report the first page's zero.
sed 's/ --paginate//' "${tool}" >"${tmp}/no-paginate.sh"
expect "ablation: no --paginate is caught as truncation" "${tmp}/no-paginate.sh" paginated 2 "UNKNOWN truncated fetched=100 total=103"
# ...and with the truncation check also removed, the same read prints the dangerous zero. This
# proves the check above is what decides it.
# shellcheck disable=SC2016 # a literal pattern for sed, not a shell expansion
sed 's/ --paginate//; s/"\${fetched}" != "\${total}"/"x" = "y"/' "${tool}" >"${tmp}/no-guard.sh"
expect "ablation: no paginate and no guard reads as zero (the #2436 failure)" "${tmp}/no-guard.sh" paginated 0 "unresolved=0 total=103"

# Ablation 2: an author/outdated-style filter on the nodes drops threads and must change the count.
sed 's/select(.isResolved == false)/select(.isResolved == false and .isOutdated == false)/' "${tool}" >"${tmp}/filtered.sh"
checks=$((checks + 1))
set +e
got="$(STUB_PAGES="${tmp}/pages/unresolved" PATH="${tmp}/bin:${PATH}" bash "${tmp}/filtered.sh" devantler-tech/monorepo 2436 2>/dev/null)"
set -e
if [ "${got}" != "unresolved=1 total=1" ]; then
  echo "ok   ablation: a node filter changes the count ('${got}'), so the unfiltered count is load-bearing"
else
  echo "FAIL ablation: a node filter did not change the count" >&2
  failures=$((failures + 1))
fi

# Usage errors are UNKNOWN too.
for args in "devantler-tech/monorepo" "monorepo 12" "devantler-tech/monorepo 0" "devantler-tech/monorepo 1x"; do
  checks=$((checks + 1))
  set +e
  # shellcheck disable=SC2086 # word-splitting the canned argument list is the point
  PATH="${tmp}/bin:${PATH}" bash "${tool}" ${args} >/dev/null 2>&1
  rc=$?
  set -e
  if [ "${rc}" = 2 ]; then echo "ok   usage refused: ${args}"; else
    echo "FAIL usage '${args}': want rc=2, got ${rc}" >&2
    failures=$((failures + 1))
  fi
done

# The merge preflight names the helper, so the run's final thread read is the tested one.
checks=$((checks + 1))
merge_policy="$(awk '/^### Merge policy/{i=1} i' "${root}/AGENTS.md")"
# A here-string, not a pipe: under pipefail an early-exiting grep -q reads a match as a miss.
if grep -Fq 'pr-unresolved-threads.sh devantler-tech/' <<<"${merge_policy}"; then
  echo "ok   contract: the Merge policy preflight names pr-unresolved-threads.sh"
else
  echo "FAIL contract: AGENTS.md Merge policy must name pr-unresolved-threads.sh" >&2
  failures=$((failures + 1))
fi

completed=1
echo "pr-unresolved-threads: ${checks} checks, ${failures} failures"
[ "${failures}" -eq 0 ]
