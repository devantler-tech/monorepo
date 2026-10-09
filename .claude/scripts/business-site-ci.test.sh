#!/usr/bin/env bash
# Exercise migrated catalogue/current-owner selection through the actual CI runner.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
business_site_ci_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$business_site_ci_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "business-site-ci.test: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$tmp/.github/workflows" "$tmp/applications/business-site/docs" "$tmp/.claude"
cp "$root/.github/workflows/ci.yaml" "$tmp/.github/workflows/ci.yaml"
ln -s "$root/.claude/scripts" "$tmp/.claude/scripts"
ln -s "$root/applications/business-site/docs/scripts" "$tmp/applications/business-site/docs/scripts"
git -C "$tmp" init -q
git -C "$tmp" add .github/workflows/ci.yaml .claude/scripts applications/business-site/docs/scripts
git -C "$tmp" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm baseline
for path in .gitmodules github/devantler-tech/.github-public github/devantler-tech/.github-public/actions/new/action.yaml github/devantler-tech/.github-public/.github/workflows/new.yml; do
  mkdir -p "$(dirname "$tmp/$path")"
  printf 'changed\n' > "$tmp/$path"
  selected="$(bash "$root/.claude/scripts/run-affected-tests.sh" --root "$tmp" --base HEAD --list)"
  case "$selected" in
    *applications/business-site/docs/scripts/check-active-projects-drift.test.sh*) ;;
    *) echo "FAIL: $path does not select the actual catalogue guard" >&2; exit 1 ;;
  esac
  rm "$tmp/$path"
done
# Execute the actual pinned-checkout resolver, then inspect its consumer binding.
# Use the runner's existing YAML tool: this guard runs before any npm install.
yq -o=json '.jobs | {"catalogue": ."drift-check-active-projects", "runner": ."test-run-affected-tests"}' \
  "$root/.github/workflows/ci.yaml" > "$tmp/jobs.json"
jq -e '.runner' "$tmp/jobs.json" > "$tmp/runner.json"
# Hosted macOS does not provide these tools; require setup before the real guard.
verify_runner_tools() {
  jq -e --arg macos "matrix.os == 'macos-latest'" '
    (.steps | to_entries | map(select(.value.run == "brew install shellcheck yq")) | .[0]) as $setup |
    (.steps | to_entries | map(select((.value.run // "") | contains("shellcheck .claude/scripts/business-site-ci.test.sh"))) | .[0]) as $verification |
    $setup != null and $verification != null and $setup.key < $verification.key and
    $setup.value.if == $macos and
    (($setup.value | has("continue-on-error") | not) or $setup.value["continue-on-error"] == false)
  ' "$1" > /dev/null
}
verify_runner_tools "$tmp/runner.json" || { echo 'FAIL: macOS tool setup must precede verification and fail closed' >&2; exit 1; }
setup_index="$(jq -er '.steps | to_entries | map(select(.value.run == "brew install shellcheck yq")) | .[0].key' "$tmp/runner.json")"
for mutation in missing late skipped tolerant; do
  jq --arg mutation "$mutation" --argjson index "$setup_index" '
    if $mutation == "missing" then del(.steps[$index])
    elif $mutation == "late" then .steps[$index] as $setup | del(.steps[$index]) | .steps += [$setup]
    elif $mutation == "skipped" then .steps[$index].if = "false"
    else .steps[$index]["continue-on-error"] = true end
  ' "$tmp/runner.json" > "$tmp/mutated-runner.json"
  if verify_runner_tools "$tmp/mutated-runner.json"; then
    echo "FAIL: $mutation macOS tool setup was accepted" >&2
    exit 1
  fi
done
jq --argjson index "$setup_index" '.steps[$index]["continue-on-error"] = false' \
  "$tmp/runner.json" > "$tmp/explicit-false.json"
verify_runner_tools "$tmp/explicit-false.json" || { echo 'FAIL: explicitly fail-closed tool setup was rejected' >&2; exit 1; }

jq -e '.catalogue.steps | map(select(.with.repository == "devantler-tech/.github")) | .[0]' \
  "$tmp/jobs.json" > "$tmp/checkout.json"
jq -e '.with.path == "github/devantler-tech/.github-public" and .with["persist-credentials"] == false and
  (.with.ref | test("^\\$\\{\\{ steps\\.[a-z-]+\\.outputs\\.revision \\}\\}$"))' \
  "$tmp/checkout.json" > /dev/null || { echo 'FAIL: CI must bind the current automation owner to its immutable resolver' >&2; exit 1; }
resolver_id="$(jq -er '.with.ref | capture("steps\\.(?<id>[a-z-]+)\\.outputs").id' "$tmp/checkout.json")"
resolver="$(jq -er --arg id "$resolver_id" '.catalogue.steps | map(select(.id == $id)) | .[0].run | select(type == "string" and length > 0)' "$tmp/jobs.json")"
expected="$(git -C "$root" --no-replace-objects rev-parse HEAD:github/devantler-tech/.github-public)"
[[ "$expected" =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL: expected source revision is not immutable' >&2; exit 1; }
# A blob also has a 40-character object ID, but is not a source gitlink.
invalid="$tmp/ordinary-file"
mkdir -p "$invalid/github/devantler-tech"
printf 'not a submodule\n' > "$invalid/github/devantler-tech/.github-public"
git init -q "$invalid"
git -C "$invalid" add github/devantler-tech/.github-public
git -C "$invalid" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm 'ordinary file'
# macOS system Bash 3.2 can ignore errexit for a failed compound [[ ... && ... ]].
# Execute the actual resolver with both shells even when PATH selects a newer Bash.
for shell in bash /bin/bash; do
  output="$tmp/output-${shell//\//-}"
  (cd "$root" && GITHUB_OUTPUT="$output" "$shell" -e -o pipefail -c "$resolver")
  [ "$(cat "$output")" = "revision=$expected" ] || { echo "FAIL: $shell did not emit the exact source revision" >&2; exit 1; }
  invalid_output="$tmp/invalid-output-${shell//\//-}"
  if (cd "$invalid" && GITHUB_OUTPUT="$invalid_output" "$shell" -e -o pipefail -c "$resolver") > "$tmp/resolver-rejection.log" 2>&1; then
    echo "FAIL: $shell admitted an ordinary committed blob as automation source" >&2
    exit 1
  fi
  [ ! -e "$invalid_output" ] || { echo "FAIL: $shell rejection emitted a revision" >&2; exit 1; }
done
printf 'PASS: real catalogue CI selection and current-owner gitlink checkout\n'
business_site_ci_finished=1
