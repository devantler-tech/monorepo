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
mkdir -p "$test_root/toolchain"
go_tool=$(command -v go)
{
  printf '#!/bin/bash\n'
  printf 'printf invoked > %q\n' "$test_root/home/go-invoked"
  printf 'exec %q "$@"\n' "$go_tool"
} > "$test_root/toolchain/go"
chmod +x "$test_root/toolchain/go"
HOME="$test_root/home" PATH="$test_root/toolchain:$PATH" bash "$script_dir/install.sh" --no-schedule
[[ -f "$test_root/home/go-invoked" ]] || { printf 'FAIL: installer discarded the selected Go toolchain\n' >&2; exit 1; }
[[ -d "$deployment/$previous" && -f "$deployment/unrelated" ]]
cmp "$script_dir/update.sh" "$deployment/current/update.sh"
# launchd can still be removing the old job when bootstrap runs: a transient
# refusal must not leave the hourly schedule unloaded, and a lasting one must fail.
mkdir -p "$test_root/launchd"
cat > "$test_root/launchd/launchctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$HOME/launchctl-calls"
if [[ "$1" == bootstrap ]]; then
  count=$(grep -c '^bootstrap$' "$HOME/launchctl-calls")
  ((count > ${BOOTSTRAP_REFUSALS:-0})) || exit 5
fi
STUB
printf '#!/bin/bash\n' > "$test_root/launchd/sleep"
chmod +x "$test_root/launchd/launchctl" "$test_root/launchd/sleep"
HOME="$test_root/home" PATH="$test_root/launchd:$PATH" BOOTSTRAP_REFUSALS=2 bash "$script_dir/install.sh" --schedule >/dev/null 2>&1 \
  || { printf 'FAIL: a transient bootstrap refusal failed the install\n' >&2; exit 1; }
[[ $(grep -c '^bootstrap$' "$test_root/home/launchctl-calls") == 3 ]] || { printf 'FAIL: bootstrap was not retried until it loaded\n' >&2; exit 1; }
rm "$test_root/home/launchctl-calls"
if HOME="$test_root/home" PATH="$test_root/launchd:$PATH" BOOTSTRAP_REFUSALS=99 bash "$script_dir/install.sh" --schedule >/dev/null 2>&1; then
  printf 'FAIL: a lasting bootstrap refusal reported success\n' >&2; exit 1
fi
[[ $(grep -c '^bootstrap$' "$test_root/home/launchctl-calls") == 5 ]] || { printf 'FAIL: bootstrap retries are not bounded at five\n' >&2; exit 1; }
printf 'PASS: reproducible install, immutable previous release, source identity, schedule opt-in and bootstrap retry\n'
