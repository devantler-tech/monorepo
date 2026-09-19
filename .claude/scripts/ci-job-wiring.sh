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
trap 'rm -rf "$tmp"' EXIT

# Every read is checked: a failed parse must never leave an empty set that compares as clean.
read_set() { # <name> <yq expression>
  yq -r "$2" "$workflow" >"$tmp/$1" 2>"$tmp/err" ||
    { echo "ci-job-wiring: cannot evaluate $1 in $workflow: $(cat "$tmp/err")" >&2; exit 2; }
  sort -u -o "$tmp/$1" "$tmp/$1"
}

read_set jobs '.jobs | keys | .[]'
[[ -s "$tmp/jobs" ]] || { echo "ci-job-wiring: $workflow declares no jobs" >&2; exit 2; }
grep -qx status "$tmp/jobs" || { echo "ci-job-wiring: $workflow has no status job" >&2; exit 2; }

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
  fi
  read_set outputs '.jobs.changes.outputs // {} | keys | .[]'

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
  [[ -n "$refs" ]] || continue
  # Only the job-level `if` filters the job: a reference in a step `if`, `env` or `run` is not wiring,
  # and neither is text inside a quoted string literal of that `if`.
  JOB="$job" yq -r '.jobs[strenv(JOB)].if // ""' "$workflow" | sed "s/'[^']*'//g" |
    { grep -oE 'needs\.changes\.outputs\.[A-Za-z0-9_-]+' || true; } | sed 's/^needs\.changes\.outputs\.//' >>"$tmp/referenced"
  needs_changes="$(JOB="$job" yq -r '[.jobs[strenv(JOB)].needs] | flatten | map(select(. == "changes")) | length' "$workflow")"
  [[ "$needs_changes" != 0 ]] || defect "$job: reads needs.changes.outputs but does not list 'changes' in needs"
  while IFS= read -r ref; do
    grep -qx -- "$ref" "$tmp/outputs" ||
      defect "$job: reads needs.changes.outputs.$ref, which the changes job does not declare (the job would skip forever)"
  done <<<"$refs"
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
yq -r "$aggregate | .[0].with.\"job-results\" // \"\"" "$workflow" |
  # Only the untransformed expression passes a result through; anything else can mask a failure.
  { grep -oE '\$\{\{ *needs\.[A-Za-z0-9_-]+\.result *\}\}' || true; } | { grep -oE 'needs\.[A-Za-z0-9_-]+\.result' || true; } | sed -E 's/^needs\.(.*)\.result$/\1/' | sort -u >"$tmp/status_results"
read_set nonblocking '.jobs | to_entries | .[] | select((.value.name // "") | test("\\(non-blocking\\)$")) | .key'

while IFS= read -r job; do
  [[ -n "$job" && "$job" != status ]] || continue
  grep -qx -- "$job" "$tmp/nonblocking" && continue
  grep -qx -- "$job" "$tmp/status_needs" || defect "$job: missing from status.needs, so it never gates the merge"
  grep -qx -- "$job" "$tmp/status_results" || defect "$job: missing from status job-results, so its failure is never counted"
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
echo "ci-job-wiring: OK ($(wc -l <"$tmp/jobs" | tr -d ' ') jobs, $(wc -l <"$tmp/outputs" | tr -d ' ') filtered outputs)"
