#!/usr/bin/env bash
# Verify that every path-filtered job in a CI workflow is wired end to end.
#
# A path-filtered job needs five coordinated edits: a paths-filter entry, a `changes` job output,
# the job itself, the aggregate `status` job's `needs:` and its `job-results` list. Missing the
# output makes the job's `if:` evaluate against an empty string, so it reports `skipped` forever
# while every file looks wired. Missing either status entry lets it run without gating the merge.
# Neither failure is visible in a passing run, so this checks the wiring directly.
#
# Usage: ci-job-wiring.sh [workflow]   (default: .github/workflows/ci.yaml)
# A job whose `name` ends in "(non-blocking)" is exempt from the status-gate checks only.
# Exit codes: 0 wired, 1 wiring defects (each printed), 2 usage or unreadable workflow.
set -euo pipefail

workflow="${1:-.github/workflows/ci.yaml}"
[[ $# -le 1 ]] || { echo "usage: ci-job-wiring.sh [workflow]" >&2; exit 2; }
[[ -r "$workflow" ]] || { echo "ci-job-wiring: cannot read $workflow" >&2; exit 2; }
command -v yq >/dev/null || { echo "ci-job-wiring: yq is required" >&2; exit 2; }

tmp="$(mktemp -d)"
# A guard that exits 0 without having run is worse than one that errors, and two things can produce
# exactly that. Bash 3.2 reports $? as 0 to an EXIT trap for a parameter-expansion abort (`set -u`),
# and a successful `rm` in the trap can become the script's own status. So completion is recorded
# explicitly: reaching the end is the only way a zero status leaves this script.
ci_job_wiring_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [[ "$ci_job_wiring_finished" != 1 && $rc -eq 0 ]]; then
    echo "ci-job-wiring: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

# Every read is checked: a failed parse must never leave an empty set that compares as clean.
read_set() { # <name> <yq expression>
  yq -r "$2" "$workflow" >"$tmp/$1" 2>"$tmp/err" ||
    { echo "ci-job-wiring: cannot evaluate $1 in $workflow: $(cat "$tmp/err")" >&2; exit 2; }
  sort -u -o "$tmp/$1" "$tmp/$1"
}

read_set jobs '.jobs | keys | .[]'
[[ -s "$tmp/jobs" ]] || { echo "ci-job-wiring: $workflow declares no jobs" >&2; exit 2; }
grep -qx status "$tmp/jobs" || { echo "ci-job-wiring: $workflow has no status job" >&2; exit 2; }

# The only clause a filter may carry: run on every non-PR event and on same-repository PRs. Any other
# clause could be constant-false and skip the job on every matching change.
same_repo_clause=" && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)"

# filter_output <condition> — print the output a job-level if filters on, or fail when the condition is
# not needs.changes.outputs.<name> == 'true', optionally followed by exactly $same_repo_clause.
filter_output() {
  local c="$1" head="^needs\\.changes\\.outputs\\.([A-Za-z0-9_-]+) == 'true'(.*)$"
  [[ "$c" =~ $head ]] || return 1
  [[ -z "${BASH_REMATCH[2]}" || "${BASH_REMATCH[2]}" == "$same_repo_clause" ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# The only conditions a BLOCKING job that reads no changes output may carry. Such a job is not
# path-filtered, so its `if` is the single thing deciding whether it runs — and the aggregate counts
# a skipped job as a pass. `if: false`, a repository variable, or anything else switchable therefore
# takes a required check out of the gate while every file still looks wired. Gating on the event that
# triggered the run is allowed because nothing outside the workflow can turn it off. This is an
# allow-list on purpose: an unrecognised spelling is refused rather than assumed safe.
unfiltered_conditions=("github.event_name == 'pull_request'")
allowed_unfiltered_condition() {
  local c="$1" allowed
  for allowed in ${unfiltered_conditions[@]+"${unfiltered_conditions[@]}"}; do
    [[ "$c" == "$allowed" ]] && return 0
  done
  return 1
}

# job_condition <job> — print the job-level `if`, normalised. Presence is tested with has(), never
# `//`, which reads a YAML `false` as absent — the exact spelling that disables a job outright.
job_condition() {
  [[ "$(JOB="$1" yq -r '.jobs[strenv(JOB)] | has("if")' "$workflow")" == true ]] || return 1
  JOB="$1" yq -r '.jobs[strenv(JOB)].if | tostring' "$workflow" |
    tr -s '[:space:]' ' ' | sed -E 's/^ *(\$\{\{ *)?//; s/ *(\}\} *)?$//'
}

failures=0
defect() { echo "✗ $*"; failures=$((failures + 1)); }

if grep -qx changes "$tmp/jobs"; then
  filter_text="$(yq -r '.jobs.changes.steps[] | select(.id == "filter") | .with.filters // ""' "$workflow")"
  if [[ -z "$filter_text" ]]; then
    defect "changes: no step with id 'filter' declares 'with.filters'"
    : >"$tmp/filters"
  else
    printf '%s\n' "$filter_text" | yq -r 'keys | .[]' >"$tmp/filters" 2>"$tmp/err" ||
      { echo "ci-job-wiring: cannot parse the paths-filter filters: $(cat "$tmp/err")" >&2; exit 2; }
    sort -u -o "$tmp/filters" "$tmp/filters"
    # A filter with no rules never matches, so its job skips on every change.
    while IFS= read -r name; do
      [[ -n "$name" ]] && defect "filter '$name' has no path rules, so it never matches"
    done < <(printf '%s\n' "$filter_text" |
      yq -r 'to_entries | .[] | select((.value | tag) != "!!seq" or (.value | length) == 0) | .key')
  fi
  read_set outputs '.jobs.changes.outputs // {} | keys | .[]'
  # The producer must always run: a skipped or failure-suppressed filter empties every output, and each
  # filtered job then reports skipped, which the aggregate accepts. Presence is tested, never `//`, which
  # treats a YAML false as absent. The producer must be paths-filter itself.
  [[ "$(yq -r '.jobs.changes | has("if")' "$workflow")" == false ]] ||
    defect "changes: has a job-level if, so its outputs can be empty and every filtered job skipped"
  [[ "$(yq -r '.jobs.changes | has("continue-on-error")' "$workflow")" == false ]] ||
    defect "changes: sets continue-on-error, so a failed filter empties every output"
  [[ "$(yq -r '[.jobs.changes.steps[] | select(.id == "filter") | has("if")] | any' "$workflow")" == false ]] ||
    defect "changes: the filter step has an if, so it can be skipped"
  [[ "$(yq -r '[.jobs.changes.steps[] | select(.id == "filter") | has("continue-on-error")] | any' "$workflow")" == false ]] ||
    defect "changes: the filter step sets continue-on-error, so a failed filter empties every output"
  [[ "$(yq -r '[.jobs.changes.steps[] | select(.id == "filter") | (.uses // "") | test("^dorny/paths-filter@")] | all' "$workflow")" == true ]] ||
    defect "changes: the filter step does not run dorny/paths-filter, so it sets no outputs"
  [[ "$(yq -r '[.jobs.changes.steps[] | select(.id == "filter") | ((.with."predicate-quantifier" // "some") == "some")] | all' "$workflow")" == true ]] ||
    defect "changes: the filter step sets predicate-quantifier != some, which can cause multi-path filters to never match"

  while IFS= read -r name; do
    defect "filter '$name' has no changes output, so no job can read it"
  done < <(comm -23 "$tmp/filters" "$tmp/outputs")
  while IFS= read -r name; do
    defect "changes output '$name' has no paths-filter entry"
  done < <(comm -13 "$tmp/filters" "$tmp/outputs")

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    want="\${{ steps.filter.outputs.$name }}"
    got="$(NAME="$name" yq -r '.jobs.changes.outputs[strenv(NAME)]' "$workflow")"
    [[ "$got" == "$want" ]] || defect "changes output '$name' is '$got', expected '$want'"
  done <"$tmp/outputs"
else
  : >"$tmp/outputs"
fi

: >"$tmp/referenced"
: >"$tmp/unfiltered"
while IFS= read -r job; do
  [[ -n "$job" && "$job" != changes ]] || continue
  JOB="$job" yq -o=json '.jobs[strenv(JOB)]' "$workflow" >"$tmp/job.json"
  # Index syntax (needs['changes']...) is equivalent in GitHub expressions but invisible to the
  # dot-syntax extraction below, so it is refused rather than silently skipped — including an
  # index after any dotted chain (needs.changes.outputs['x']).
  if grep -qE 'needs(\.[A-Za-z0-9_-]+)*[[:space:]]*\[' "$tmp/job.json"; then
    defect "$job: reads needs with index syntax; write needs.changes.outputs.<name> so the wiring can be checked"
  fi
  refs="$(grep -oE 'needs\.changes\.outputs\.[A-Za-z0-9_-]+' "$tmp/job.json" | sed 's/^needs\.changes\.outputs\.//' | sort -u || true)"
  # Whether a job is path-filtered is decided by its job-level `if` ALONE. A reference anywhere else
  # in the job — a step `env`, a `run` string, a `with:` input — changes nothing about when the job
  # runs, so reading one must never exempt the job from the blocking-condition allow-list below.
  # Only these two shapes filter a job (an allow-list: every other spelling, including a negated or
  # quoted reference, reads as no filter):
  #   needs.changes.outputs.<name> == 'true'
  #   needs.changes.outputs.<name> == 'true' && (<a predicate that reads no changes output>)
  # Presence is read through job_condition's has(), never `//`, which reads a YAML `false` as absent.
  condition="$(job_condition "$job" || true)"
  if filter="$(filter_output "$condition")"; then
    printf '%s\n' "$filter" >>"$tmp/referenced"
  elif [[ "$condition" == *needs.changes.outputs.* ]]; then
    defect "$job: job-level if is not needs.changes.outputs.<name> == 'true' (optionally with the same-repository clause), so it does not filter the job"
  else
    # No changes output governs this job, so its own `if` is the only thing deciding whether it runs.
    printf '%s\n' "$job" >>"$tmp/unfiltered"
  fi
  # Reference hygiene applies to every reference in the job, wherever it appears: a step reading an
  # output the changes job does not declare is still broken wiring, even though it filters nothing.
  if [[ -n "$refs" ]]; then
    needs_changes="$(JOB="$job" yq -r '[.jobs[strenv(JOB)].needs] | flatten | map(select(. == "changes")) | length' "$workflow")"
    [[ "$needs_changes" != 0 ]] || defect "$job: reads needs.changes.outputs but does not list 'changes' in needs"
    while IFS= read -r ref; do
      grep -qx -- "$ref" "$tmp/outputs" ||
        defect "$job: reads needs.changes.outputs.$ref, which the changes job does not declare (the job would skip forever)"
    done <<<"$refs"
  fi
done <"$tmp/jobs"
sort -u -o "$tmp/referenced" "$tmp/referenced"
while IFS= read -r name; do
  defect "changes output '$name' filters no job (no job-level if reads it)"
done < <(comm -23 "$tmp/outputs" "$tmp/referenced")

read_set status_needs '[.jobs.status.needs] | flatten | .[] | select(. != null)'
# Read job-results from exactly the aggregate step: another step's input proves nothing.
aggregate='[.jobs.status.steps[] | select((.uses // "") | test("^devantler-tech/actions/aggregate-job-checks@"))]'
aggregate_steps="$(yq -r "$aggregate | length" "$workflow")"
[[ "$aggregate_steps" == 1 ]] ||
  defect "status: expected exactly one aggregate-job-checks step, found $aggregate_steps"
# The aggregate step must always run and never swallow its own failure.
[[ "$(yq -r "$aggregate | map(has(\"if\") or has(\"continue-on-error\")) | any" "$workflow")" == false ]] ||
  defect "status: the aggregate-job-checks step has an if or continue-on-error, so it can pass without enforcing"
yq -r "$aggregate | .[0].with.\"job-results\" // \"\"" "$workflow" |
  # Strip spacing within ${{ ... }} so each interpolation expression becomes a single contiguous token.
  sed -E 's/\$\{\{[[:space:]]*/\${{/g; s/[[:space:]]*\}\}/}}/g' |
  tr -s '[:space:]' '\n' |
  # Only the untransformed expression occupying a whole token passes a result through; anything else can mask a failure.
  { grep -xE '\$\{\{needs\.[A-Za-z0-9_-]+\.result\}\}' || true; } |
  sed -E 's/^\$\{\{needs\.([A-Za-z0-9_-]+)\.result\}\}$/\1/' |
  sort -u >"$tmp/status_results"
read_set nonblocking '.jobs | to_entries | .[] | select((.value.name // "") | test("\\(non-blocking\\)$")) | .key'

while IFS= read -r job; do
  [[ -n "$job" && "$job" != status ]] || continue
  grep -qx -- "$job" "$tmp/nonblocking" && continue
  # A blocking job must not depend on a non-blocking one. If the prerequisite fails, this job is
  # skipped, and the aggregate counts a skip as a pass — so a required check silently stops running.
  # Only direct needs are read: every intermediate job in a chain is itself blocking and checked here,
  # which is also what stops the `changes` producer being renamed non-blocking out of the gate.
  while IFS= read -r need; do
    [[ -n "$need" ]] || continue
    if grep -qx -- "$need" "$tmp/nonblocking"; then
      defect "$job: needs '$need', which is non-blocking; if that job fails this one skips and the gate counts the skip as a pass"
    fi
    if grep -qx -- "$job" "$tmp/unfiltered" && [[ "$need" != changes ]] && ! grep -qx -- "$need" "$tmp/unfiltered"; then
      defect "$job: is unfiltered but needs '$need', which is path-filtered; if '$need' skips this job skips and the gate counts the skip as a pass"
    fi
  done < <(JOB="$job" yq -r '[.jobs[strenv(JOB)].needs] | flatten | .[] | select(. != null)' "$workflow")
  grep -qx -- "$job" "$tmp/status_needs" || defect "$job: missing from status.needs, so it never gates the merge"
  grep -qx -- "$job" "$tmp/status_results" || defect "$job: missing from status job-results, so its failure is never counted"
  # A job whose result the gate counts, and which no changes output filters, must not be able to
  # skip itself: the aggregate reads `skipped` as a pass, so its condition is checked here.
  if grep -qx -- "$job" "$tmp/unfiltered" && grep -qx -- "$job" "$tmp/status_results" &&
    condition="$(job_condition "$job")" && ! allowed_unfiltered_condition "$condition"; then
    defect "$job: job-level if is not an allowed condition for a blocking job that reads no changes output (found '$condition'), so it can skip while the gate still passes"
  fi
  [[ "$(JOB="$job" yq -r '.jobs[strenv(JOB)]."continue-on-error" // false' "$workflow")" == false ]] ||
    defect "$job: sets continue-on-error, so it can fail without failing the merge"
done <"$tmp/jobs"
[[ "$(yq -r '.jobs.status."continue-on-error" // false' "$workflow")" == false ]] ||
  defect "status: sets continue-on-error, so a failed gate does not fail the merge"
while IFS= read -r job; do
  grep -qx -- "$job" "$tmp/jobs" || defect "status.needs names '$job', which is not a job"
done <"$tmp/status_needs"
while IFS= read -r job; do
  grep -qx -- "$job" "$tmp/status_needs" || defect "status job-results reads '$job', which status does not need"
done <"$tmp/status_results"

if ((failures > 0)); then
  echo "ci-job-wiring: $failures wiring defect(s) in $workflow" >&2
  exit 1
fi
ci_job_wiring_finished=1
echo "ci-job-wiring: OK ($(wc -l <"$tmp/jobs" | tr -d ' ') jobs, $(wc -l <"$tmp/outputs" | tr -d ' ') filtered outputs)"
