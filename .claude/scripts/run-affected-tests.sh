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
#   3. A job is selected when its `if:` names a hit filter as needs.changes.outputs.<name>,
#      or names no filter at all — CI runs such a job on every change.
#   4. Its scripts are every `*.test.sh` named in its steps' `run:` text, resolved against
#      the step's (or job's) working-directory.
#   Other parts of a job's `if:` (event checks) are ignored, so the local selection can be
#   a little wider than CI's, never narrower.
#
# USAGE
#   run-affected-tests.sh [--base <ref>] [--list | --list-json] [--all] [--convention]
#                         [--timeout <seconds>] [--ci-file <path>] [--root <dir>]
#
#   --list      print the selected scripts, run nothing
#   --list-json print the selection as a JSON array of {dir, run, path, how, timeout}, run nothing
#   --convention  select by what each test declares instead of by ci.yaml's filters: itself, its
#               <name>.sh and <name>-go/**, and its `# test-inputs:` header globs (monorepo#5052)
#   --all       select every script any gated job runs. Slow: run it in the background.
#   --timeout   override every per-script deadline in seconds. The default is 300 unless a
#               suite declares "# test-timeout-seconds: N" in its opening comment header
#               (1–3600 seconds). A script past its deadline receives TERM, then KILL five
#               seconds later, and is reported TIMEOUT.
#
# Some scripts need setup their CI job performs first, such as an initialised submodule.
# Such a script fails here the same way it would in a job missing that step; the log tail
# printed on failure says what was missing.
#
# EXIT: 0 every selected script passed (including when none was selected — the count of
#       changed files is printed so an empty selection is visible), 1 at least one FAILED
#       or TIMED OUT, 2 cannot tell (bad usage, unreadable workflow, git failure, or a
#       selected script that does not exist, which CI would fail running, or a broken watchdog).
set -uo pipefail

me="$(basename "$0")"
die() { printf '%s: %s\n' "${me}" "$*" >&2; exit 2; }

base="origin/main"
list_only=0
list_json=0
convention=0
select_all=0
timeout_s=300
timeout_explicit=0
kill_grace_s=5
ci_file=".github/workflows/ci.yaml"
root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) [ "$#" -ge 2 ] || die "--base needs a ref"; base="$2"; shift 2 ;;
    --list) list_only=1; shift ;;
    --list-json) list_only=1; list_json=1; shift ;;
    --convention) convention=1; shift ;;
    --all) select_all=1; shift ;;
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout needs seconds"
      case "$2" in ''|*[!0-9]*|0) die "--timeout must be a positive integer: '$2'" ;; esac
      timeout_s="$2"; timeout_explicit=1; shift 2 ;;
    --ci-file) [ "$#" -ge 2 ] || die "--ci-file needs a path"; ci_file="$2"; shift 2 ;;
    --root) [ "$#" -ge 2 ] || die "--root needs a directory"; root="$2"; shift 2 ;;
    -h|--help) sed -n "2,/^set -uo pipefail/p" "$0" | sed "\$d"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "${convention}" -eq 1 ] || command -v yq >/dev/null 2>&1 || die "yq is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"

if [ -z "${root}" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository (pass --root)"
fi
cd "${root}" || die "cannot enter ${root}"
[ -r "${ci_file}" ] || die "workflow not readable: ${ci_file}"

# --- selection by convention (monorepo#5052) -------------------------------------------------
# Instead of ci.yaml's filters, a test declares what it reads. `.claude/scripts/<name>.test.sh`
# always reads itself, `<name>.sh` and `<name>-go/**`; any further globs are listed in its opening
# comment header as `# test-inputs: <glob> <glob> …` lines. A Go module `<name>-go` with a go.mod is
# tested with `go -C <dir> test ./...` whenever its own files or its sibling test's inputs change.
# Glob semantics: inside [[ ]], `*` crosses `/`, so `**` behaves as dorny's `**`. Every
# `**/` — leading or embedded — may also match zero directories, so each one is tried both
# kept and dropped (`a/**/b` must match `a/b`, and `**/x` must match `x`).
glob_match() {
  local file="$1" done_part="$2" rest="$3" head tail
  case "${rest}" in
    *'**/'*)
      head="${rest%%'**/'*}"
      tail="${rest#*'**/'}"
      glob_match "${file}" "${done_part}${head}**/" "${tail}" && return 0
      glob_match "${file}" "${done_part}${head}" "${tail}" && return 0
      return 1 ;;
  esac
  # shellcheck disable=SC2053 # the right-hand side is a glob on purpose
  [[ "${file}" == ${done_part}${rest} ]]
}
matches() { glob_match "$1" "" "$2"; }

# test_inputs <test> — every glob the test reads, one per line. A `# test-inputs:` line outside the
# opening comment header would be silently ignored, so it is refused (exit 2) instead.
test_inputs() {
  local t="$1" name="${1%.test.sh}"
  printf '%s\n%s\n%s\n' "${t}" "${name}.sh" "${name}-go/**"
  awk '
    /^[[:space:]]*#[[:space:]]*test-inputs/ && !/^# test-inputs: / {
      print "malformed test-inputs line " NR " (write it as: # test-inputs: <glob> …)" > "/dev/stderr"; bad = 1; exit
    }
    !body && /^# test-inputs: / { sub(/^# test-inputs: /, ""); n = split($0, g, /[[:space:]]+/); for (i = 1; i <= n; i++) if (g[i] != "") print g[i]; next }
    !body && /^[[:space:]]*(#|$)/ { next }
    { body = 1 }
    body && /^[[:space:]]*# test-inputs:/ { print "misplaced test-inputs line " NR > "/dev/stderr"; bad = 1; exit }
    END { exit bad ? 2 : 0 }
  ' "${t}"
}

# module_inputs <dir> — every glob a Go module reads: its own files, its sibling test inputs, and
# any `// test-inputs:` lines in its go.mod.
module_inputs() {
  local dir="$1" sibling="${1%-go}.test.sh"
  printf '%s\n' "${dir}/**"
  if [ -f "${sibling}" ]; then test_inputs "${sibling}" || return 2; fi
  awk '
    /\/\/[[:space:]]*test-inputs/ && !/^\/\/ test-inputs: / {
      print FILENAME ": malformed test-inputs line " NR " (write it as: // test-inputs: <glob> …)" > "/dev/stderr"; bad = 1; exit
    }
    /^\/\/ test-inputs: / { sub(/^\/\/ test-inputs: /, ""); n = split($0, g, /[[:space:]]+/); for (i = 1; i <= n; i++) if (g[i] != "") print g[i] }
    END { exit bad ? 2 : 0 }
  ' "${dir}/go.mod"
}

hit_any() { # hit_any <globs> — 0 when any changed file matches any glob
  local pat f
  while IFS= read -r pat; do
    [ -n "${pat}" ] || continue
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      if matches "${f}" "${pat}"; then return 0; fi
    done <<<"${changed}"
  done <<<"$1"
  return 1
}

if [ "${convention}" -eq 1 ]; then
  if [ "${select_all}" -eq 1 ]; then
    changed_count="all"
  else
  mb="$(git merge-base "${base}" HEAD 2>/dev/null)" || die "no merge base between ${base} and HEAD (fetch ${base} first)"
  changed="$( { git -c core.quotePath=false diff --name-only --no-renames "${mb}" || exit 2; git -c core.quotePath=false ls-files --others --exclude-standard || exit 2; } | sort -u )" \
    || die "cannot list changed files"
  changed_count="$(printf '%s\n' "${changed}" | grep -c . || true)"
  fi
  # Tracked tests and new ones not yet added, so a local run sees a test that is being written.
  tests="$( { git ls-files -- '.claude/scripts/*.test.sh' &&
    git ls-files --others --exclude-standard -- '.claude/scripts/*.test.sh'; } | sort -u)" ||
    die "cannot list the test scripts"
  selected=""
  hit_filters=""
  while IFS= read -r t; do
    [ -n "${t}" ] || continue
    inputs="$(test_inputs "${t}")" || die "cannot read the inputs of ${t}"
    if [ "${select_all}" -eq 1 ] || hit_any "${inputs}"; then selected+=".	${t}	bash"$'\n'; fi
  done <<<"${tests}"
  while IFS= read -r mod; do
    [ -n "${mod}" ] || continue
    dir="${mod%/go.mod}"
    inputs="$(module_inputs "${dir}")" || die "cannot read the inputs of ${dir}"
    if [ "${select_all}" -eq 1 ] || hit_any "${inputs}"; then selected+=".	go:${dir}	go"$'\n'; fi
  done <<<"$(git ls-files -- '.claude/scripts/*-go/go.mod')"
  selected="$(printf '%s' "${selected}" | awk '!seen[$0]++')"
else
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
  changed="$( { git -c core.quotePath=false diff --name-only --no-renames "${mb}" || exit 2; git -c core.quotePath=false ls-files --others --exclude-standard || exit 2; } | sort -u )" \
    || die "cannot list changed files"
  changed_count="$(printf '%s\n' "${changed}" | grep -c . || true)"


  filter_keys="$(jq -e -r 'keys[]' <<<"${filters_json}")" || die "cannot list filter names in ${ci_file}"
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    hit=0
    pats="$(jq -e -r --arg n "${name}" '
      .[$n]
      | if type == "string" then [.]
        elif type == "array" then flatten
        else error("filter " + $n + " has unsupported shape") end
      | .[]
      | if type != "string" then error("filter " + $n + " contains non-string rule") else . end
    ' <<<"${filters_json}")" || die "failed to decode filter patterns for ${name}"
    while IFS= read -r pat; do
      [ -n "${pat}" ] || continue
      while IFS= read -r f; do
        [ -n "${f}" ] || continue
        if matches "${f}" "${pat}"; then hit=1; break; fi
      done <<<"${changed}"
      [ "${hit}" -eq 1 ] && break
    done <<<"${pats}"
    [ "${hit}" -eq 1 ] && hit_filters+="${name}"$'\n'
  done <<<"${filter_keys}"
fi

# --- the scripts the hit filters' jobs run -------------------------------------------------
jobs_json="$(yq -o=json '.jobs' "${ci_file}")" || die "cannot parse jobs in ${ci_file}"
hits_json="$(printf '%s' "${hit_filters}" | jq -R -s 'split("\n") | map(select(length > 0))')"

selected="$(jq -r --argjson hits "${hits_json}" '
  [ to_entries[]
  | .key as $job_name
  | .value as $job
  | (($job["if"] // "") | tostring) as $cond
  | if ($cond | test("needs\\.changes\\.outputs\\.[A-Za-z0-9_-]+[ \t]*(!=|==[ \t]*[\u0027\"]false[\u0027\"])") or ($cond | test("![ \t]*needs\\.changes\\.outputs"))) then
      error("job " + $job_name + " contains unsupported negative filter condition in if: " + $cond)
    else . end
  | [$cond | scan("needs\\.changes\\.outputs\\.([A-Za-z0-9_-]+)") | .[0]] as $gates
  # A job with no filter gate runs on every change in CI, so it is always selected.
  | select(($gates | length) == 0 or ($gates | any(. as $f | $hits | index($f))))
  | ($job.defaults.run["working-directory"] // ".") as $jobwd
  | $job.steps[]?
  | (.["working-directory"] // $jobwd) as $wd
  | (.run // "") as $run
  | ($run | scan("[A-Za-z0-9_./-]+\\.test\\.sh")) as $script
  | ($script | gsub("\\."; "\\.")) as $escaped
  # A step runs the script through a shell ("bash"), runs it as a command of its own
  # ("direct"), or only names it, as a lint step does ("mention"). Only the first two say how
  # CI runs it (#3629).
  | (if ($run | test("(^|[ \t\n;&|])(bash|sh)[ \t]+" + $escaped)) then "bash"
     elif ($run | test("(^|[\n;&|(])[ \t]*" + $escaped + "([ \t\n;&|)]|$)")) then "direct"
     else "mention" end) as $how
  | [$wd, $script, $how] ]
  # Steps that run a script come before steps that only name it (sort_by is stable), so the
  # first row kept for each script below is the one that says how CI runs it.
  | sort_by(if .[2] == "mention" then 1 else 0 end)[]
  | @tsv' <<<"${jobs_json}")" || die "cannot read the gated jobs in ${ci_file}"
# Go modules the selected jobs test with `go -C <dir> test`, so both selections list them.
go_selected="$(jq -r --argjson hits "${hits_json}" '
  to_entries[] | .value as $job
  | ([(($job["if"] // "") | tostring) | scan("needs\\.changes\\.outputs\\.([A-Za-z0-9_-]+)") | .[0]]) as $gates
  | select(($gates | length) == 0 or ($gates | any(. as $f | $hits | index($f))))
  | $job.steps[]? | (.run // "")
  | scan("go[ \t]+-C[ \t]+([A-Za-z0-9_./-]+)[ \t]+test") | .[0]
  | [".", ("go:" + sub("/$"; "")), "go"] | @tsv' <<<"${jobs_json}")" || die "cannot read the Go test steps in ${ci_file}"
selected="$(printf '%s\n%s\n' "${selected}" "${go_selected}" | awk 'NF && !seen[$0]++')"
fi

# A measured slow suite may declare "# test-timeout-seconds: N" in its opening
# comment header (#4160). Validate every declaration before any selected test runs;
# no header retains 300 seconds, and an explicit --timeout remains the operator override.
script_timeout() {
  local file="$1" declaration value
  declaration="$(awk '
    /^# test-timeout-seconds/ { print; next }
    /^[[:space:]]*(#|$)/ { next }
    { exit }
  ' "$file")" || return 2
  if [ -z "$declaration" ]; then
    printf '%s\n' "$timeout_s"
    return 0
  fi
  case "$declaration" in
    '# test-timeout-seconds: '*) value=${declaration#'# test-timeout-seconds: '} ;;
    *) echo "$file: invalid test-timeout-seconds header" >&2; return 2 ;;
  esac
  if ! [[ "$value" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$value" -gt 3600 ]; then
    echo "$file: invalid test-timeout-seconds header (one integer from 1 to 3600 required)" >&2
    return 2
  fi
  if [ "$timeout_explicit" -eq 1 ]; then value="$timeout_s"; fi
  printf '%s\n' "$value"
}

scripts=""
runs=""
missing=""
unrunnable=""
while IFS=$'\t' read -r wd s how; do
  [ -n "${s}" ] || continue
  if [ "${how}" = go ]; then
    # A Go module: `go -C <dir> test ./...` from the repository root. A whole module suite runs
    # longer than one script, so it gets 900 seconds unless --timeout says otherwise.
    [ -f "${s#go:}/go.mod" ] || { missing+="${s} (no go.mod)"$'\n'; continue; }
    case $'\n'"${scripts}" in *$'\n'"${s}"$'\n'*) continue ;; esac
    scripts+="${s}"$'\n'
    go_deadline=900
    [ "${timeout_explicit}" -eq 0 ] || go_deadline="${timeout_s}"
    runs+="."$'\t'"${s}"$'\t'"${s}"$'\t'"go"$'\t'"${go_deadline}"$'\n'
    continue
  fi
  s="${s#./}"
  # CI launches the script from the step's working-directory, so the runner does too.
  target="${wd}/${s}"
  target="${target#./}"
  if [ -f "${target}" ]; then
    run_wd="${wd}"
    p="${target}"
  else
    # CI would fail trying to run it, so a selected script that does not exist is never
    # silently dropped from the selection.
    missing+="${s} (working-directory ${wd})"$'\n'
    continue
  fi
  p="${p#./}"
  case $'\n'"${scripts}" in *$'\n'"${p}"$'\n'*) continue ;; esac
  if [ "${how}" = "mention" ]; then
    # Only named, never run, by the selected jobs: running it either way would be a guess.
    unrunnable+="${p}"$'\n'
    continue
  fi
  deadline="$(script_timeout "${p}")" || die "invalid test-timeout-seconds in ${p}"
  scripts+="${p}"$'\n'
  runs+="${run_wd}"$'\t'"${s}"$'\t'"${p}"$'\t'"${how}"$'\t'"${deadline}"$'\n'
done <<<"${selected}"

if [ -n "${missing}" ]; then
  printf '%s: a selected script does not exist, so CI would fail running it:\n%s' \
    "${me}" "${missing}" >&2
  exit 2
fi

if [ -n "${unrunnable}" ]; then
  printf '%s: cannot tell how CI runs these scripts; a selected step names them but none runs them:\n%s' \
    "${me}" "${unrunnable}" >&2
  exit 2
fi

n_scripts="$(printf '%s' "${scripts}" | grep -c . || true)"
summary="$(printf '%s: changed=%s filters_hit=%s scripts=%s' "${me}" "${changed_count}" \
  "$(printf '%s' "${hit_filters}" | grep -c . || true)" "${n_scripts}")"
# The JSON listing owns stdout, so its summary goes to stderr.
if [ "${list_json}" -eq 1 ]; then printf '%s\n' "${summary}" >&2; else printf '%s\n' "${summary}"; fi

if [ "${list_json}" -eq 1 ]; then
  # One object per selected entry, in run order, for a dynamic CI matrix or a selection diff.
  printf '%s' "${runs}" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {dir: .[0], run: .[1], path: .[2], how: .[3], timeout: (.[4] | tonumber)})' ||
    die "cannot print the selection as JSON"
  exit 0
fi
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
unknown=0
i=0
while IFS=$'\t' read -r run_wd rel s how test_timeout; do
  [ -n "${s}" ] || continue
  i=$((i + 1))
  log="${logdir}/${i}.log"
  start="$(date +%s)"
  if [ "${how}" = "direct" ]; then
    cmd=( "./${rel#./}" )
  elif [ "${how}" = go ]; then
    cmd=( go -C "${rel#go:}" test ./... )
  else
    cmd=( bash "${rel}" )
  fi
  ( cd "${run_wd}" && exec "${cmd[@]}" ) >"${log}" 2>&1 &
  pid=$!
  # TERM first, then KILL after a short grace, so a script that ignores TERM cannot outlive
  # its deadline.
  # The marker records that the deadline fired, so a script that exits 0 on TERM is still a TIMEOUT.
  (
    timer_failed=0
    if sleep "${test_timeout}"; then
      : >"${log}.timeout"
    else
      # Cancellation can reach sleep before the subshell on macOS. Its nonzero return is
      # not a deadline. Only the parent, after reaping the test, may authorize cancellation.
      [ ! -e "${log}.cancelled" ] || exit 0
      : >"${log}.timer-error"
      timer_failed=1
    fi
    kill -TERM -- "-${pid}" 2>/dev/null
    sleep "${kill_grace_s}"
    kill -KILL -- "-${pid}" 2>/dev/null
    [ "$timer_failed" -eq 0 ] || exit 2
  ) &
  watchdog=$!
  wait "${pid}"
  rc=$?
  if ! : >"${log}.cancelled"; then
    kill -TERM -- "-${watchdog}" 2>/dev/null
    wait "${watchdog}" 2>/dev/null
    die "cannot record watchdog cancellation"
  fi
  kill -TERM -- "-${watchdog}" 2>/dev/null
  wait "${watchdog}" 2>/dev/null
  watchdog_rc=$?
  secs=$(( $(date +%s) - start ))
  if [ -e "${log}.timer-error" ] || [ "$watchdog_rc" -eq 2 ]; then
    unknown=1
    printf 'UNKNOWN  %4ss  %s — watchdog failed before its deadline\n' "${secs}" "${s}"
    tail -n 20 "${log}" | sed 's/^/    /'
  elif [ "${rc}" -eq 0 ] && [ ! -e "${log}.timeout" ]; then
    printf 'PASS     %4ss  %s\n' "${secs}" "${s}"
  else
    failed=1
    if [ -e "${log}.timeout" ]; then state=TIMEOUT; else state=FAIL; fi
    printf '%-8s %4ss  %s (exit %s) — last lines:\n' "${state}" "${secs}" "${s}" "${rc}"
    tail -n 20 "${log}" | sed 's/^/    /'
  fi
done <<<"${runs}"

[ "$unknown" -eq 0 ] || exit 2
exit "${failed}"
