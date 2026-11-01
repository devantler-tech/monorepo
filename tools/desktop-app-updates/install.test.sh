#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/home"
HOME="$test_root/home" bash "$script_dir/install.sh" --no-schedule
deployment="$test_root/home/.local/libexec/desktop-app-updates"
[[ -L "$deployment/current" && -x "$deployment/current/app-lifecycle" ]]
[[ -x "$test_root/home/bin/update-agent-desktops" ]]
[[ ! -f "$test_root/home/Library/LaunchAgents/tech.devantler.desktop-app-updates.plist" ]]
jq -e '.sourceDigest|test("^[a-f0-9]{64}$")' "$deployment/current/manifest.json" >/dev/null
cmp "$script_dir/update.sh" "$deployment/current/update.sh"
# Installing again must retain the previous immutable release and unrelated files.
previous=$(readlink "$deployment/current")
touch "$deployment/unrelated"
HOME="$test_root/home" bash "$script_dir/install.sh" --no-schedule
[[ -d "$deployment/$previous" && -f "$deployment/unrelated" ]]
cmp "$script_dir/update.sh" "$deployment/current/update.sh"
printf 'PASS: reproducible install, immutable previous release, source identity and schedule opt-in\n'
