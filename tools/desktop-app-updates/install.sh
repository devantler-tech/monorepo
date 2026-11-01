#!/bin/bash
# Install a reviewed source snapshot. Scheduling is an explicit opt-in.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
schedule=false
case "${1:---no-schedule}" in
  --no-schedule) ;;
  --schedule) schedule=true ;;
  *) printf 'Usage: install.sh [--no-schedule|--schedule]\n' >&2; exit 2 ;;
esac
[[ $# -le 1 && $(uname -s) == Darwin ]] || exit 2
command -v go >/dev/null
command -v jq >/dev/null
[[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]] || { printf 'Homebrew is required\n' >&2; exit 1; }
# Share the updater lock, so an installation never replaces an active run.
# shellcheck source=update.sh
source "$script_dir/update.sh"
umask 077
acquire_lock
stage=""
cleanup() {
  local result=$?
  [[ -z "$stage" ]] || rm -rf "$stage"
  release_lock
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
deployment="$HOME/.local/libexec/desktop-app-updates"
mkdir -p "$deployment/releases" "$HOME/bin"
stage=$(mktemp -d "$deployment/releases/.install.XXXXXX")
files=(update.sh install.sh README.md test.sh install.test.sh lifecycle.test.sh validate.sh
  helper/go.mod helper/main.go helper/main_test.go helper/lifecycle.h helper/lifecycle_darwin.m fixtures/canary.m)
mkdir -p "$stage/helper" "$stage/fixtures"
for file in "${files[@]}"; do cp "$script_dir/$file" "$stage/$file"; done
digest=$(cd "$stage" && shasum -a 256 "${files[@]}" | shasum -a 256 | awk '{print $1}')
revision=$(git -C "$script_dir" rev-parse HEAD 2>/dev/null || printf 'unversioned')
(cd "$stage/helper" && go build -trimpath -buildvcs=false -o "$stage/app-lifecycle" .)
chmod 700 "$stage/app-lifecycle" "$stage"/*.sh
jq -n --arg sha "$revision" --arg digest "$digest" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{revision:$sha,sourceDigest:$digest,installedAt:$at}' > "$stage/manifest.json"
release="releases/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mv "$stage" "$deployment/$release"
stage=""
ln -s "$release" "$deployment/current.new-$$"
# -h replaces the link itself on macOS, rather than moving into its target.
mv -fh "$deployment/current.new-$$" "$deployment/current"
cat > "$HOME/bin/update-agent-desktops.tmp-$$" <<'LAUNCHER'
#!/bin/bash
exec /bin/bash "$HOME/.local/libexec/desktop-app-updates/current/update.sh" "$@"
LAUNCHER
chmod 700 "$HOME/bin/update-agent-desktops.tmp-$$"
mv "$HOME/bin/update-agent-desktops.tmp-$$" "$HOME/bin/update-agent-desktops"

if [[ "$schedule" == true ]]; then
  label=tech.devantler.desktop-app-updates
  domain="gui/$(id -u)"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  jq -n --arg program "$HOME/bin/update-agent-desktops" --arg log "$HOME/Library/Logs/DesktopAppUpdates.log" \
    '{Label:"tech.devantler.desktop-app-updates",ProgramArguments:[$program,"--apply"],
      RunAtLoad:false,StartInterval:3600,ProcessType:"Background",LowPriorityIO:true,
      StandardOutPath:$log,StandardErrorPath:$log}' > "$plist.tmp-$$"
  plutil -convert xml1 "$plist.tmp-$$"
  plutil -lint "$plist.tmp-$$"
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$label"
  fi
  mv "$plist.tmp-$$" "$plist"
  launchctl bootstrap "$domain" "$plist"
  printf 'Hourly schedule loaded; no app restart is triggered by installation.\n'
fi
printf 'Installed source %s from revision %s\n' "$digest" "$revision"
