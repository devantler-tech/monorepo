#!/bin/bash
# Homebrew maintenance for this Mac's two desktop apps. No agent or chat access.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_UPGRADE=1
export HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 HOMEBREW_NO_ANALYTICS=1
# launchd cannot access the normal cache on the protected external volume.
# This job downloads public packages into its own internal cache.
export HOMEBREW_CACHE="$HOME/Library/Caches/DesktopAppUpdates/Homebrew"
STATE_DIR="${DESKTOP_UPDATES_STATE_DIR:-$HOME/Library/Application Support/DesktopAppUpdates}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIFECYCLE="$SCRIPT_DIR/app-lifecycle"
MODE=check
RECOVERED_TOKENS=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
brew_cmd() {
  local brew=/opt/homebrew/bin/brew
  [[ -x "$brew" ]] || brew=/usr/local/bin/brew
  "$brew" "$@"
}
app_exists() { [[ -f "$1/Contents/Info.plist" ]]; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
app_running() {
  local processes
  processes=$(/bin/ps -axo comm=) || return 2
  printf '%s\n' "$processes" | /usr/bin/awk -v prefix="$1/Contents/" \
    'index($0,prefix)==1 {found=1} END {exit !found}'
}

# Compare the numeric product versions used by these two casks, not receipts.
# Unknown version schemes fail closed instead of guessing about a downgrade.
compare_versions() {
  local first="$1" second="$2" i a b
  local -a left right
  [[ "$first" =~ ^[0-9]+([.][0-9]+){0,3}$ && "$second" =~ ^[0-9]+([.][0-9]+){0,3}$ ]] || return 2
  IFS=. read -r -a left <<< "$first"
  IFS=. read -r -a right <<< "$second"
  for ((i=0; i<4; i++)); do
    a="${left[i]:-0}"; b="${right[i]:-0}"
    [[ ${#a} -le 9 && ${#b} -le 9 ]] || return 2
    a=$((10#$a)); b=$((10#$b))
    if ((a<b)); then printf '%s\n' -1; return; fi
    if ((a>b)); then printf '%s\n' 1; return; fi
  done
  printf '0\n'
}

quit_app_gracefully() {
  local i rc
  [[ -x "$LIFECYCLE" ]] || { log 'ERROR: application lifecycle helper is missing'; return 1; }
  "$LIFECYCLE" quit --bundle-id "$2" --app-path "$1" --timeout 45 || return 1
  # The normal quit must also let the app's helpers exit. Never signal them.
  for ((i=0; i<10; i++)); do
    if app_running "$1"; then /bin/sleep 1;
    else rc=$?; [[ "$rc" == 1 ]] && return 0; return 1; fi
  done
  return 1
}

reopen_app() {
  local i rc
  # Use the existing installed app and its normal saved state, in the background.
  /usr/bin/open -g -a "$1" || return 1
  for ((i=0; i<30; i++)); do
    if client_running "$1" "$2"; then return 0;
    else rc=$?; [[ "$rc" == 1 ]] || return 1; fi
    /bin/sleep 1
  done
  return 1
}

client_running() {
  local state
  state=$("$LIFECYCLE" status --bundle-id "$2" --app-path "$1") || return 2
  jq -e --arg id "$2" '.bundleId==$id and (.running|type)=="boolean"
    and (.pids|type)=="array" and all(.pids[]; type=="number" and .>0 and floor==.)
    and (.running==((.pids|length)>0))' <<< "$state" >/dev/null || return 2
  jq -e '.running==true' <<< "$state" >/dev/null
}

recover_one() {
  local token="$1" app bundle_id phase rc did_reopen=false pending="$STATE_DIR/pending-$1.json"
  [[ -f "$pending" ]] || return 0
  case "$token" in
    claude) app=/Applications/Claude.app; bundle_id=com.anthropic.claudefordesktop ;;
    chatgpt) app=/Applications/ChatGPT.app; bundle_id=com.openai.codex ;;
    *) log 'ERROR: invalid pending restart cask'; return 1 ;;
  esac
  jq -e --arg token "$token" --arg app "$app" --arg id "$bundle_id" \
    '.cask==$token and .path==$app and .bundleId==$id and .wasRunning==true
      and (.phase=="quit_requested" or .phase=="update_started")' "$pending" >/dev/null || return 1
  phase=$(jq -r '.phase' "$pending") || return 1
  app_exists "$app" && [[ $(plist_value "$app" CFBundleIdentifier) == "$bundle_id" ]] || {
    log "ERROR $token: pending reopen needs the original app identity at $app"; return 1;
  }
  if client_running "$app" "$bundle_id"; then
    if [[ "$phase" == quit_requested ]]; then
      log "WAIT $token: native quit is pending or cancelled; finish the native quit when ready (no update performed)"
      return 0
    fi
  else
    rc=$?
    [[ "$rc" == 1 ]] || { log "ERROR $token: cannot read client state for restoration"; return 1; }
    reopen_app "$app" "$bundle_id" || { log "ERROR $token: automatic reopen failed; retained restart journal"; return 1; }
    did_reopen=true
  fi
  jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson didReopen "$did_reopen" \
    '. + {reopened:$didReopen,clientRunning:true,checkedAt:$at,sessionRestoration:"native_unverified"}' \
    "$pending" > "$STATE_DIR/recovery-last-$token.json.tmp" || return 1
  mv "$STATE_DIR/recovery-last-$token.json.tmp" "$STATE_DIR/recovery-last-$token.json" || return 1
  rm "$pending" || return 1
  RECOVERED_TOKENS="$RECOVERED_TOKENS $token "
  if [[ "$did_reopen" == true ]]; then
    log "REOPENED $token: normal app launch verified; native session restoration is unverified by this script"
  else
    log "RUNNING $token: client is already running; no launch needed"
  fi
}

recover_pending() {
  local token failed=0 legacy="$STATE_DIR/reopen-pending.json"
  # Preserve recovery from the first local-only installer, if any.
  if [[ -f "$legacy" ]]; then
    token=$(jq -er '.cask|select(.=="claude" or .=="chatgpt")' "$legacy") || return 1
    [[ ! -e "$STATE_DIR/pending-$token.json" ]] || return 1
    jq '. + {phase:"update_started"}' "$legacy" > "$STATE_DIR/pending-$token.json.tmp" &&
      mv "$STATE_DIR/pending-$token.json.tmp" "$STATE_DIR/pending-$token.json" && rm "$legacy" || return 1
  fi
  for token in claude chatgpt; do recover_one "$token" || failed=1; done
  return "$failed"
}

snapshot_result() {
  local snapshot="$1" result="$2" after="$3" reopened="$4"
  jq --arg result "$result" --arg version "$after" --argjson reopened "$reopened" \
    '. + {result:$result,after:{version:$version},reopened:$reopened}' \
    "$snapshot" > "$snapshot.tmp" && mv "$snapshot.tmp" "$snapshot"
}

update_one() {
  local token="$1" app="$2" bundle_id="$3"
  local metadata refreshed definition next_definition available receipt before build identity comparison rc snapshot after pending="$STATE_DIR/pending-$token.json" was_running=false reopened=false
  if [[ -f "$pending" ]]; then
    log "WAIT $token: pending app restoration is retained; no new quit or update"
    return 0
  fi
  if [[ "$RECOVERED_TOKENS" == *" $token "* ]]; then
    log "DEFER $token: client was just restored; leave it running until the next check"
    return 0
  fi
  if ! app_exists "$app"; then log "SKIP $token: app absent (will not reinstall an intentionally removed app)"; return 0; fi
  metadata=$(brew_cmd info --cask --json=v2 "$token") || { log "ERROR $token: Homebrew metadata unavailable"; return 1; }
  if ! jq -e --arg token "$token" --arg app "$app" '
      (.casks|length)==1 and .casks[0].token==$token and .casks[0].tap=="homebrew/cask"
      and .casks[0].disabled==false and .casks[0].deprecated==false
      and (.casks[0].sha256|test("^[a-f0-9]{64}$"))
      and any(.casks[0].artifacts[]; .target==$app and (.app|type)=="array")
      and (.casks[0].installed|type)=="string"
    ' <<< "$metadata" >/dev/null; then
    log "ERROR $token: expected an installed, active official Homebrew cask with the correct app target"
    return 1
  fi
  if [[ $(jq -r '.casks[0].pinned' <<< "$metadata") == true ]]; then log "SKIP $token: Homebrew pin retained"; return 0; fi
  available=$(jq -er '.casks[0].version|split(",")[0]' <<< "$metadata") || return 1
  receipt=$(jq -er '.casks[0].installed' <<< "$metadata") || return 1
  identity=$(plist_value "$app" CFBundleIdentifier) || { log "ERROR $token: cannot read installed identity"; return 1; }
  [[ "$identity" == "$bundle_id" ]] || { log "ERROR $token: installed bundle identity does not match"; return 1; }
  before=$(plist_value "$app" CFBundleShortVersionString) || return 1
  build=$(plist_value "$app" CFBundleVersion) || return 1
  comparison=$(compare_versions "$before" "$available") || { log "ERROR $token: unsupported version format"; return 1; }
  if [[ "$comparison" == 1 ]]; then log "SKIP $token: installed $before is newer than Homebrew $available"; return 0; fi
  if [[ "$comparison" == 0 ]]; then log "CURRENT $token: $before (Homebrew managed)"; return 0; fi
  if app_running "$app"; then was_running=true;
  else rc=$?; [[ "$rc" == 1 ]] || { log "ERROR $token: process state unknown"; return 1; }; fi
  if [[ "$MODE" == check ]]; then
    log "PLAN $token: $before -> $available; gracefully quit/reopen if running (currently running=$was_running)"
    return 0
  fi

  # Download/verify first, then re-check the process state before touching an app.
  brew_cmd fetch --cask "$token" || { log "ERROR $token: download failed; app untouched"; return 1; }
  refreshed=$(brew_cmd info --cask --json=v2 "$token") || return 1
  definition=$(jq -ceS '.casks[0]|{token,tap,version,sha256,artifacts,pinned,disabled,deprecated}' <<< "$metadata") || return 1
  next_definition=$(jq -ceS '.casks[0]|{token,tap,version,sha256,artifacts,pinned,disabled,deprecated}' <<< "$refreshed") || return 1
  if [[ "$definition" != "$next_definition" ]]; then
    log "DEFER $token: Homebrew definition changed during download; app untouched"
    return 0
  fi
  was_running=false
  if app_running "$app"; then was_running=true;
  else rc=$?; [[ "$rc" == 1 ]] || { log "ERROR $token: process state unknown after download"; return 1; }; fi
  [[ $(plist_value "$app" CFBundleShortVersionString) == "$before" &&
     $(plist_value "$app" CFBundleVersion) == "$build" &&
     $(plist_value "$app" CFBundleIdentifier) == "$identity" ]] || { log "DEFER $token: bundle changed during download"; return 0; }
  mkdir -p "$STATE_DIR/snapshots" || return 1
  snapshot="$STATE_DIR/snapshots/$token-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  jq -n --arg token "$token" --arg path "$app" --arg id "$identity" \
    --arg version "$before" --arg build "$build" --arg available "$available" --argjson wasRunning "$was_running" \
    '{cask:$token,path:$path,bundleId:$id,before:{version:$version,build:$build},available:$available,result:"pending",phase:"quit_requested",wasRunning:$wasRunning,reopened:false,sessionRestoration:"native_unverified"}' \
    > "$snapshot" || return 1
  if [[ "$was_running" == true ]]; then
    cp "$snapshot" "$pending.tmp" && mv "$pending.tmp" "$pending" || return 1
    if ! quit_app_gracefully "$app" "$bundle_id"; then
      log "DEFER $token: normal quit was refused or timed out; no update performed"
      recover_one "$token" || return 1
      if [[ ! -f "$pending" ]]; then reopened=$(jq -r '.reopened' "$STATE_DIR/recovery-last-$token.json") || return 1; fi
      snapshot_result "$snapshot" quit_deferred "$before" "$reopened" || return 1
      return 0
    fi
  fi
  # Native self-updaters may replace the bundle while processing normal quit.
  # Re-check immediately before Homebrew to avoid overwriting a newer build.
  if [[ $(plist_value "$app" CFBundleShortVersionString) != "$before" ||
        $(plist_value "$app" CFBundleVersion) != "$build" ||
        $(plist_value "$app" CFBundleIdentifier) != "$identity" ]]; then
    log "DEFER $token: bundle changed during normal quit; no Homebrew update"
    recover_one "$token" || return 1
    snapshot_result "$snapshot" bundle_changed "$(plist_value "$app" CFBundleShortVersionString)" false || return 1
    return 0
  fi
  # Refuse the Homebrew mutation if any app process remains or appeared again.
  if app_running "$app"; then
    log "DEFER $token: a process remains after the graceful quit"
    recover_one "$token" || return 1
    snapshot_result "$snapshot" quit_deferred "$before" false || return 1
    return 0
  else rc=$?; [[ "$rc" == 1 ]] || { log "ERROR $token: process state unknown before update"; recover_one "$token"; return 1; }; fi
  if [[ "$was_running" == true ]]; then
    jq '.phase="update_started"' "$pending" > "$pending.tmp" && mv "$pending.tmp" "$pending" || return 1
  fi

  # --adopt registers self-updating apps without replacing their existing bundle.
  # If its receipt already names the newest cask but the actual bundle is older,
  # upgrade is a no-op. A closed-app reinstall resolves that one-time mismatch.
  if [[ "${receipt%%,*}" == "$available" ]]; then
    brew_cmd reinstall --cask --no-ask --require-sha --no-binaries --skip-cask-deps "$token"
    rc=$?
  else
    brew_cmd upgrade --cask --greedy --no-quit --no-ask --require-sha --no-binaries --skip-cask-deps "$token"
    rc=$?
  fi
  if [[ "$rc" != 0 ]]; then
    log "ERROR $token: Homebrew failed; attempting normal app restoration"
    if recover_one "$token" && [[ "$was_running" == true ]]; then
      reopened=$(jq -r '.reopened' "$STATE_DIR/recovery-last-$token.json") || return 1
    fi
    snapshot_result "$snapshot" update_failed "$before" "$reopened" || return 1
    return 1
  fi
  identity=$(plist_value "$app" CFBundleIdentifier) || return 1
  after=$(plist_value "$app" CFBundleShortVersionString) || return 1
  [[ "$identity" == "$bundle_id" ]] || { log "ERROR $token: installed identity changed"; return 1; }
  comparison=$(compare_versions "$after" "$available") || return 1
  if [[ "$comparison" == -1 ]]; then
    log "ERROR $token: expected at least $available but found $after; snapshot $snapshot"
    recover_one "$token" || return 1
    if [[ "$was_running" == true ]]; then reopened=$(jq -r '.reopened' "$STATE_DIR/recovery-last-$token.json"); fi
    snapshot_result "$snapshot" verification_failed "$after" "$reopened" || return 1
    return 1
  fi
  if [[ "$was_running" == true ]]; then
    recover_one "$token" || return 1
    reopened=$(jq -r '.reopened' "$STATE_DIR/recovery-last-$token.json") || return 1
  fi
  snapshot_result "$snapshot" updated "$after" "$reopened" || return 1
  log "UPDATED $token: $before -> $after; snapshot $snapshot"
}

release_lock() {
  if [[ -f "$STATE_DIR/lock/pid" && $(cat "$STATE_DIR/lock/pid") == "$$" ]]; then
    rm "$STATE_DIR/lock/pid"
    rmdir "$STATE_DIR/lock"
  fi
}
acquire_lock() {
  local owner
  mkdir -p "$STATE_DIR" || { log 'ERROR: cannot create updater state directory'; return 2; }
  if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
    owner=$(cat "$STATE_DIR/lock/pid" 2>/dev/null) || { log 'DEFER: another updater is starting'; return 1; }
    [[ "$owner" =~ ^[0-9]+$ ]] || { log 'ERROR: invalid updater lock'; return 2; }
    if kill -0 "$owner" 2>/dev/null; then log 'DEFER: updater already running'; return 1; fi
    [[ $(cat "$STATE_DIR/lock/pid") == "$owner" ]] || return 1
    rm "$STATE_DIR/lock/pid" && rmdir "$STATE_DIR/lock" && mkdir "$STATE_DIR/lock" || return 2
  fi
  printf '%s\n' "$$" > "$STATE_DIR/lock/pid" || return 2
}

main() {
  local failed=0 rc
  [[ $# -le 1 ]] || { printf 'Usage: update-agent-desktops [--check|--apply]\n' >&2; return 2; }
  case "${1:---check}" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    *) printf 'Usage: update-agent-desktops [--check|--apply]\n'; return 2 ;;
  esac
  command -v jq >/dev/null || { log 'ERROR: jq is required'; return 1; }
  umask 077
  if [[ "$MODE" == apply ]]; then
    if acquire_lock; then :;
    else rc=$?; [[ "$rc" == 1 ]] && return 0; return "$rc"; fi
    trap release_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    recover_pending || failed=1
    [[ ! -f "$STATE_DIR/reopen-pending.json" ]] || { log 'ERROR: unresolved legacy recovery journal'; return 1; }
    brew_cmd update --quiet || { log 'ERROR: Homebrew refresh failed'; return 1; }
  fi
  update_one claude /Applications/Claude.app com.anthropic.claudefordesktop || failed=1
  update_one chatgpt /Applications/ChatGPT.app com.openai.codex || failed=1
  return "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
