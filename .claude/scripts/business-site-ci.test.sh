#!/usr/bin/env bash
# Exercise migrated catalogue/current-owner selection through the actual CI runner.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
CI_JOB_JSON="$(yq -o=json '.jobs."drift-check-active-projects"' "$root/.github/workflows/ci.yaml")"
ROOT="$root" CI_JOB_JSON="$CI_JOB_JSON" node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
const root = process.env.ROOT;
const job = JSON.parse(process.env.CI_JOB_JSON);
const checkout = job.steps.find(s => s.with?.repository === 'devantler-tech/.github');
assert.ok(checkout, 'CI must check out the current automation owner');
assert.equal(checkout.with.path, 'github/devantler-tech/.github-public');
assert.equal(checkout.with['persist-credentials'], false);
assert.match(checkout.with.ref, /^\$\{\{ steps\.[a-z-]+\.outputs\.revision \}\}$/);
const id = checkout.with.ref.match(/steps\.([a-z-]+)\.outputs/)[1];
const resolver = job.steps.find(s => s.id === id);
assert.ok(resolver?.run, 'The checkout ref must come from an executed immutable resolver');
const dir = mkdtempSync(resolve(tmpdir(), 'active-projects-pin-'));
try {
  const output = resolve(dir, 'output');
  execFileSync('bash', ['-e', '-o', 'pipefail', '-c', resolver.run], { cwd: root, env: { ...process.env, GITHUB_OUTPUT: output } });
  const expected = execFileSync('git', ['--no-replace-objects', 'rev-parse', 'HEAD:github/devantler-tech/.github-public'], { cwd: root, encoding: 'utf8' }).trim();
  assert.equal(readFileSync(output, 'utf8').trim(), `revision=${expected}`);
  assert.match(expected, /^[0-9a-f]{40}$/);
  // A blob also has a 40-character object ID, but is not a source gitlink.
  const invalid = resolve(dir, 'ordinary-file');
  mkdirSync(resolve(invalid, 'github/devantler-tech'), { recursive: true });
  writeFileSync(resolve(invalid, 'github/devantler-tech/.github-public'), 'not a submodule\n');
  execFileSync('git', ['init', '-q', invalid]);
  execFileSync('git', ['-C', invalid, 'add', 'github/devantler-tech/.github-public']);
  execFileSync('git', ['-C', invalid, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'ordinary file']);
  assert.throws(() => execFileSync('bash', ['-e', '-o', 'pipefail', '-c', resolver.run], {
    cwd: invalid, env: { ...process.env, GITHUB_OUTPUT: resolve(dir, 'invalid-output') }, stdio: 'pipe',
  }), 'An ordinary committed blob must not be admitted as automation source');
} finally { rmSync(dir, { recursive: true, force: true }); }
NODE
printf 'PASS: real catalogue CI selection and current-owner gitlink checkout\n'
