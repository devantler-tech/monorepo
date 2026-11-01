#!/bin/bash
# Real macOS process lifecycle, using a disposable app, never either user's client.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=update.sh
source "$script_dir/update.sh"
test_root=$(mktemp -d)
test_root=$(cd "$test_root" && pwd -P)
canary="$test_root/Lifecycle Canary.app"
bundle=tech.devantler.desktop-app-updates.canary
LIFECYCLE="$test_root/app-lifecycle"
cleanup() {
  local result=$?
  if [[ -x "$LIFECYCLE" ]]; then
    rm -f "$canary/Contents/Resources/refuse"
    if ! "$LIFECYCLE" quit --bundle-id "$bundle" --app-path "$canary" --timeout 3 >/dev/null; then
      printf 'Canary cleanup deferred; retained %s\n' "$test_root" >&2
      exit 1
    fi
  fi
  rm -rf "$test_root"
  exit "$result"
}
trap cleanup EXIT
[[ $(uname -s) == Darwin ]] || { printf 'macOS GUI session required\n' >&2; exit 1; }
mkdir -p "$canary/Contents/MacOS" "$canary/Contents/Resources"
cat > "$canary/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tech.devantler.desktop-app-updates.canary</string>
<key>CFBundleExecutable</key><string>canary</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
clang -fobjc-arc -framework AppKit "$script_dir/fixtures/canary.m" -o "$canary/Contents/MacOS/canary"
(cd "$script_dir/helper" && go build -trimpath -buildvcs=false -o "$LIFECYCLE" .)
reopen_app "$canary" "$bundle"
first=$("$LIFECYCLE" status --bundle-id "$bundle" --app-path "$canary" | jq -er '.pids[0]')
if "$LIFECYCLE" quit --bundle-id "$bundle" --app-path "$test_root/Wrong.app" --timeout 1 > "$test_root/wrong-output" 2>&1; then
  printf 'FAIL: helper accepted another application path\n' >&2; exit 1
fi
touch "$canary/Contents/Resources/refuse"
if "$LIFECYCLE" quit --bundle-id "$bundle" --app-path "$canary" --timeout 1 > "$test_root/refused-output"; then
  printf 'FAIL: native quit refusal reported as success\n' >&2; exit 1
fi
[[ -f "$canary/Contents/Resources/quit-observed" ]]
[[ $("$LIFECYCLE" status --bundle-id "$bundle" --app-path "$canary" | jq -r '.pids[0]') == "$first" ]]
rm "$canary/Contents/Resources/refuse"
quit_app_gracefully "$canary" "$bundle"
if client_running "$canary" "$bundle"; then printf 'FAIL: app remained running\n' >&2; exit 1; fi
reopen_app "$canary" "$bundle"
second=$("$LIFECYCLE" status --bundle-id "$bundle" --app-path "$canary" | jq -er '.pids[0]')
[[ "$first" != "$second" ]]
printf 'PASS: real AppKit quit cancellation, exact path guard, process exit and normal reopen with a new PID\n'
