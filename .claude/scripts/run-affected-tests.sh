#!/usr/bin/env bash
#
# Run the repository's shell self-tests that a change actually affects — the same
# selection CI makes — one at a time, with a per-script deadline and a result line per
# script as soon as it finishes.
#
# WHY: CI never runs the whole `.claude/scripts/*.test.sh` suite. Every script is its own
# job, gated by a `dorny/paths-filter` filter in `.github/workflows/ci.yaml`. A local run
# that loops over all of them does roughly twenty times the work CI asks for, and cannot
# fit in one foreground call: a single script can take minutes (monorepo#2829). This
# runner reads the filters and the jobs they gate from the workflow itself, so its
# selection cannot drift from CI's.
#
# HOW IT SELECTS:
#   1. Changed files = everything that differs from the merge base with --base (default
#      origin/main), committed or not, plus untracked files.
#   2. A filter is hit when any changed file matches any of its globs.
#   3. A job is selected when its `if:` names a hit filter as needs.changes.outputs.<name>.
#   4. Its scripts are every `*.test.sh` named in its steps' `run:` text, resolved against
#      the step's (or job's) working-directory.
#   Other parts of a job's `if:` (event checks) are ignored, so the local selection can be
#   a little wider than CI's, never narrower.
#
# USAGE
#   run-affected-tests.sh [--base <ref>] [--list] [--all] [--timeout <seconds>]
#                         [--ci-file <path>] [--root <dir>]
#
#   --list      print the selected scripts, run nothing
#   --all       select every script any gated job runs. Slow: run it in the background.
#   --timeout   per-script deadline in seconds (default 300). A script past it is killed
#               and reported TIMEOUT.
#
# Some scripts need setup their CI job performs first, such as an initialised submodule.
# Such a script fails here the same way it would in a job missing that step; the log tail
# printed on failure says what was missing.
#
# EXIT: 0 every selected script passed (including when none was selected — the count of
#       changed files is printed so an empty selection is visible), 1 at least one FAILED
#       or TIMED OUT, 2 cannot tell (bad usage, unreadable workflow, git failure).
set -uo pipefail

me="$(basename "$0")"
die() { printf '%s: %s\n' "${me}" "$*" >&2; exit 2; }

base="origin/main"
list_only=0
select_all=0
timeout_s=300
ci_file=".github/workflows/ci.yaml"
root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) [ "$#" -ge 2 ] || die "--base needs a ref"; base="$2"; shift 2 ;;
    --list) list_only=1; shift ;;
    --all) select_all=1; shift ;;
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout needs seconds"
      case "$2" in ''|*[!0-9]*|0) die "--timeout must be a positive integer: '$2'" ;; esac
      timeout_s="$2"; shift 2 ;;
    --ci-file) [ "$#" -ge 2 ] || die "--ci-file needs a path"; ci_file="$2"; shift 2 ;;
    --root) [ "$#" -ge 2 ] || die "--root needs a directory"; root="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v yq >/dev/null 2>&1 || die "yq is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"

if [ -z "${root}" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository (pass --root)"
fi
cd "${root}" || die "cannot enter ${root}"
[ -r "${ci_file}" ] || die "workflow not readable: ${ci_file}"

# --- the filters CI evaluates ------------------------------------------------------------
# The paths-filter `filters:` input is a YAML document inside a string, so parse it twice.
filters_json="$(yq '.jobs.changes.steps[] | select(.uses != null and (.uses | test("paths-filter"))) | .with.filters' "${ci_file}" \
  | yq -o=json '.')" || die "cannot parse the paths-filter filters in ${ci_file}"
[ "$(jq 'if type == "object" then length else 0 end' <<<"${filters_json}")" -gt 0 ] \
  || die "no paths-filter filters found in ${ci_file}"

# --- which filters the change hits ---------------------------------------------------------
hit_filters=""
if [ "${select_all}" -eq 1 ]; then
  hit_filters="$(jq -r 'keys[]' <<<"${filters_json}")"
  changed_count="all"
else
  mb="$(git merge-base "${base}" HEAD 2>/dev/null)" || die "no merge base between ${base} and HEAD (fetch ${base} first)"
  changed="$( { git diff --name-only --no-renames "${mb}" || exit 2; git ls-files --others --exclude-standard || exit 2; } | sort -u )" \
    || die "cannot list changed files"
  changed_count="$(printf '%s\n' "${changed}" | grep -c . || true)"

  # Glob semantics: inside [[ ]], `*` crosses `/`, so `**` behaves as dorny's `**`. A
  # leading `**/` must also match zero directories, so try the pattern without it too.
  matches() {
    local file="$1" pat="$2"
    # shellcheck disable=SC2053 # the right-hand side is a glob on purpose
    [[ "${file}" == ${pat} ]] && return 0
    # shellcheck disable=SC2053 # the right-hand side is a glob on purpose
    case "${pat}" in
      '**/'*) [[ "${file}" == ${pat#'**/'} ]] && return 0 ;;
    esac
    return 1
  }

  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    hit=0
    while IFS= read -r pat; do
      [ -n "${pat}" ] || continue
      while IFS= read -r f; do
        [ -n "${f}" ] || continue
        if matches "${f}" "${pat}"; then hit=1; break; fi
      done <<<"${changed}"
      [ "${hit}" -eq 1 ] && break
    done < <(jq -r --arg n "${name}" '.[$n] | flatten[] | select(type == "string")' <<<"${filters_json}")
    [ "${hit}" -eq 1 ] && hit_filters+="${name}"$'\n'
  done < <(jq -r 'keys[]' <<<"${filters_json}")
fi

# --- the scripts the hit filters' jobs run -------------------------------------------------
jobs_json="$(yq -o=json '.jobs' "${ci_file}")" || die "cannot parse jobs in ${ci_file}"
hits_json="$(printf '%s' "${hit_filters}" | jq -R -s 'split("\n") | map(select(length > 0))')"

selected="$(jq -r --argjson hits "${hits_json}" '
  to_entries[]
  | .value as $job
  | select(($job["if"] // "") | type == "string")
  | select([(($job["if"] // "") | scan("needs\\.changes\\.outputs\\.([A-Za-z0-9_-]+)") | .[0])]
           | any(. as $f | $hits | index($f)))
  | ($job.defaults.run["working-directory"] // ".") as $jobwd
  | $job.steps[]?
  | (.["working-directory"] // $jobwd) as $wd
  | (.run // "") | scan("[A-Za-z0-9_./-]+\\.test\\.sh")
  | [$wd, .] | @tsv' <<<"${jobs_json}")" || die "cannot read the gated jobs in ${ci_file}"

scripts=""
while IFS=$'\t' read -r wd s; do
  [ -n "${s}" ] || continue
  s="${s#./}"
  if [ -f "${wd}/${s}" ]; then p="${wd}/${s}"; elif [ -f "${s}" ]; then p="${s}"; else continue; fi
  p="${p#./}"
  case $'\n'"${scripts}" in *$'\n'"${p}"$'\n'*) continue ;; esac
  scripts+="${p}"$'\n'
done <<<"${selected}"

n_scripts="$(printf '%s' "${scripts}" | grep -c . || true)"
printf '%s: changed=%s filters_hit=%s scripts=%s\n' "${me}" "${changed_count}" \
  "$(printf '%s' "${hit_filters}" | grep -c . || true)" "${n_scripts}"

if [ "${list_only}" -eq 1 ]; then
  printf '%s' "${scripts}"
  exit 0
fi
[ "${n_scripts}" -gt 0 ] || { printf '%s: no affected test scripts\n' "${me}"; exit 0; }

# --- run them, one at a time, each under its own deadline ---------------------------------
logdir="$(mktemp -d)" || die "cannot create a log directory"
trap 'rm -rf "${logdir}"' EXIT
set -m   # each background script gets its own process group, so a timeout kills its children too
failed=0
i=0
while IFS= read -r s; do
  [ -n "${s}" ] || continue
  i=$((i + 1))
  log="${logdir}/${i}.log"
  start="$(date +%s)"
  bash "${s}" >"${log}" 2>&1 &
  pid=$!
  ( sleep "${timeout_s}"; kill -TERM -- "-${pid}" 2>/dev/null ) &
  watchdog=$!
  wait "${pid}"
  rc=$?
  kill -TERM -- "-${watchdog}" 2>/dev/null
  wait "${watchdog}" 2>/dev/null
  secs=$(( $(date +%s) - start ))
  if [ "${rc}" -eq 0 ]; then
    printf 'PASS     %4ss  %s\n' "${secs}" "${s}"
  else
    failed=1
    if [ "${secs}" -ge "${timeout_s}" ]; then state=TIMEOUT; else state=FAIL; fi
    printf '%-8s %4ss  %s (exit %s) — last lines:\n' "${state}" "${secs}" "${s}" "${rc}"
    tail -n 20 "${log}" | sed 's/^/    /'
  fi
done <<<"${scripts}"

exit "${failed}"
