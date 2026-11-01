#!/bin/bash
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/update.sh"
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [[ -z "${CASE_DIR:-}" || ! -f "$CASE_DIR/output" ]] || cat "$CASE_DIR/output" >&2
  exit 1
}
[[ -f "$SCRIPT" ]] || fail 'Homebrew desktop updater is not implemented'
# shellcheck source=update.sh
source "$SCRIPT"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

setup_case() {
  CASE_DIR="$test_root/$1"
  mkdir -p "$CASE_DIR"
  STATE_DIR="$CASE_DIR/state"
  printf '4.1.0\n' > "$CASE_DIR/claude.version"
  printf '26.1.1\n' > "$CASE_DIR/chatgpt.version"
  : > "$CASE_DIR/calls"
  MODE=apply
  running=1
  wrong_bundle=0
  fetch_failure=0
  reopen_during_fetch=0
  update_noop=0
  receipt_current=0
  metadata_bad=0
  quit_refused=0
  update_failure=0
  reopen_failure=0
  quit_changes_version=0
  metadata_drift=0
  RECOVERED_TOKENS=""
}
brew_cmd() {
  printf '%s\n' "$*" >> "$CASE_DIR/calls"
  local token="${!#}"
  case "$1" in
    info)
      if [[ "$metadata_bad" == 1 ]]; then printf '{}\n'; return; fi
      local available=4.2.0 receipt=4.0.0 app=Claude.app
      if [[ "$token" == chatgpt ]]; then available=26.2.1; receipt=26.0.1; app=ChatGPT.app; fi
      if [[ "$metadata_drift" == 1 && -f "$CASE_DIR/fetched" ]]; then available=4.0.0; fi
      [[ "$receipt_current" == 0 ]] || receipt="$available"
      jq -n --arg token "$token" --arg version "$available" --arg receipt "$receipt" --arg app "$app" \
        '{casks:[{token:$token,tap:"homebrew/cask",version:$version,installed:$receipt,pinned:false,disabled:false,deprecated:false,sha256:("a"*64),artifacts:[{app:[$app],target:("/Applications/"+$app)}]}]}'
      ;;
    fetch)
      [[ "$fetch_failure" == 0 ]] || return 1
      [[ "$reopen_during_fetch" == 0 ]] || touch "$CASE_DIR/open"
      touch "$CASE_DIR/fetched"
      ;;
    upgrade|reinstall)
      [[ "$update_failure" == 0 ]] || return 1
      [[ "$update_noop" == 0 ]] || return 0
      if [[ "$token" == claude ]]; then printf '4.2.0\n' > "$CASE_DIR/claude.version";
      else printf '26.2.1\n' > "$CASE_DIR/chatgpt.version"; fi
      ;;
    *) return 0 ;;
  esac
}
plist_value() {
  local token=claude
  [[ "$1" != /Applications/ChatGPT.app ]] || token=chatgpt
  case "$2" in
    CFBundleIdentifier)
      if [[ "$wrong_bundle" == 1 ]]; then printf 'wrong.app\n';
      elif [[ "$token" == claude ]]; then printf 'com.anthropic.claudefordesktop\n';
      else printf 'com.openai.codex\n'; fi ;;
    CFBundleShortVersionString) cat "$CASE_DIR/$token.version" ;;
    CFBundleVersion) printf '1234\n' ;;
  esac
}
app_running() {
  [[ ! -f "$CASE_DIR/open" ]] || return 0
  return "$running"
}
app_exists() { return 0; }
client_running() { app_running "$1"; }
quit_app_gracefully() {
  printf 'quit %s\n' "$1" >> "$CASE_DIR/calls"
  [[ "$quit_refused" == 0 ]] || return 1
  running=1
  [[ "$quit_changes_version" == 0 ]] || printf '4.100.0\n' > "$CASE_DIR/claude.version"
  rm -f "$CASE_DIR/open"
}
reopen_app() {
  printf 'reopen %s\n' "$1" >> "$CASE_DIR/calls"
  [[ "$reopen_failure" == 0 ]] || return 1
  running=0
}
run_claude() { update_one claude /Applications/Claude.app com.anthropic.claudefordesktop > "$CASE_DIR/output" 2>&1; }
no_mutation() { ! /usr/bin/grep -Eq '^(fetch|upgrade|reinstall|install) ' "$CASE_DIR/calls" || fail "$1"; }

[[ $(compare_versions 26.1027.51404 26.1023.51421) == 1 ]] || fail 'CalVer comparison'
[[ $(compare_versions 4.9 4.10) == -1 ]] || fail 'numeric comparison'
[[ $(compare_versions 4.1 4.1.0) == 0 ]] || fail 'zero suffix comparison'
if compare_versions latest 4.1 >/dev/null; then fail 'unparseable version accepted'; fi

setup_case running
running=0
run_claude
grep -q '^quit /Applications/Claude.app$' "$CASE_DIR/calls" || fail 'running app was not gracefully closed'
grep -q '^reopen /Applications/Claude.app$' "$CASE_DIR/calls" || fail 'updated app was not reopened'
[[ $(cat "$CASE_DIR/claude.version") == 4.2.0 ]] || fail 'running app was not updated'
jq -e '.wasRunning==true and .reopened==true and .sessionRestoration=="native_unverified"' "$STATE_DIR"/snapshots/*.json >/dev/null || fail 'restart receipt missing or overclaims session recovery'
[[ ! -f "$STATE_DIR/pending-claude.json" ]] || fail 'successful restart left pending recovery'

setup_case quit_cancelled
running=0
quit_refused=1
run_claude
! grep -Eq '^(upgrade|reinstall) ' "$CASE_DIR/calls" || fail 'app updated despite quit refusal'
grep -q DEFER "$CASE_DIR/output" || fail 'quit refusal not reported'
jq -e '.reopened==false and .result=="quit_deferred"' "$STATE_DIR"/snapshots/*.json >/dev/null || fail 'refused quit was reported as a restart'
[[ -f "$STATE_DIR/pending-claude.json" ]] || fail 'late normal quit would lose automatic reopen'
recover_pending > "$CASE_DIR/recovery-output"
[[ -f "$STATE_DIR/pending-claude.json" ]] || fail 'running app lost pending late quit'
! grep -q '^reopen ' "$CASE_DIR/calls" || fail 'still-running app reported as reopened'
# Simulate the user completing the native quit after the updater timed out.
running=1
recover_pending > "$CASE_DIR/recovery-output"
[[ "$running" == 0 ]] || fail 'late quit left the original client closed'
[[ ! -f "$STATE_DIR/pending-claude.json" ]] || fail 'late reopen did not finish recovery'

setup_case failed_update_reopens
running=0
update_failure=1
if run_claude; then fail 'failed Homebrew update reported as successful'; fi
grep -q '^reopen /Applications/Claude.app$' "$CASE_DIR/calls" || fail 'old app not reopened after failed update'

setup_case downgrade
printf '4.100.0\n' > "$CASE_DIR/claude.version"
run_claude
no_mutation 'newer app would be downgraded'

setup_case current
printf '4.2.0\n' > "$CASE_DIR/claude.version"
run_claude
no_mutation 'current version was reinstalled'

setup_case update
run_claude
grep -q '^upgrade --cask --greedy --no-quit .* claude$' "$CASE_DIR/calls" || fail 'targeted safe upgrade missing'
[[ $(cat "$CASE_DIR/claude.version") == 4.2.0 ]] || fail 'update missing'
grep -q UPDATED "$CASE_DIR/output" || fail 'verified update not reported'
jq -e '.before.version=="4.1.0" and .after.version=="4.2.0" and .result=="updated"' "$STATE_DIR"/snapshots/*.json >/dev/null || fail 'snapshot missing'
! grep -q '^reopen ' "$CASE_DIR/calls" || fail 'an app previously closed by the user was opened'

setup_case adopted_old_bundle
receipt_current=1
run_claude
grep -q '^reinstall --cask .* claude$' "$CASE_DIR/calls" || fail 'adopted old bundle not repaired'

setup_case process_unknown
running=2
if run_claude; then fail 'process inspection error treated as closed'; fi
no_mutation 'unknown process state changed app'

setup_case wrong_identity
wrong_bundle=1
if run_claude; then fail 'wrong bundle accepted'; fi
no_mutation 'wrong app changed'

setup_case download_failed
running=0
fetch_failure=1
if run_claude; then fail 'download failure hidden'; fi
! grep -Eq '^(upgrade|reinstall) ' "$CASE_DIR/calls" || fail 'update after failed download'
! grep -q '^quit ' "$CASE_DIR/calls" || fail 'app closed before download succeeded'

setup_case launched_during_download
reopen_during_fetch=1
run_claude
grep -q '^quit ' "$CASE_DIR/calls" || fail 'app opening during download not closed gracefully'
grep -q '^reopen ' "$CASE_DIR/calls" || fail 'app opening during download not restored'

setup_case reopen_failed
running=0
reopen_failure=1
if run_claude; then fail 'failed reopen reported as successful'; fi
[[ -f "$STATE_DIR/pending-claude.json" ]] || fail 'failed reopen lost recovery journal'
pending_before=$(cksum "$STATE_DIR/pending-claude.json")
running=1
update_one chatgpt /Applications/ChatGPT.app com.openai.codex > "$CASE_DIR/second-output" 2>&1 || fail 'one blocked app prevented the other closed app updating'
[[ $(cksum "$STATE_DIR/pending-claude.json") == "$pending_before" ]] || fail 'unfinished restart journal changed'
reopen_failure=0
recover_pending > "$CASE_DIR/recovery-output"
[[ ! -f "$STATE_DIR/pending-claude.json" ]] || fail 'pending reopen was not recovered'

setup_case no_update_effect
update_noop=1
if run_claude; then fail 'unchanged installed version reported as success'; fi
! grep -q UPDATED "$CASE_DIR/output" || fail 'false update receipt'

setup_case native_update_during_quit
running=0
quit_changes_version=1
run_claude
! grep -Eq '^(upgrade|reinstall) ' "$CASE_DIR/calls" || fail 'native update during quit would be overwritten'
[[ "$running" == 0 ]] || fail 'bundle change during quit left app closed'

setup_case cask_changed_during_fetch
metadata_drift=1
run_claude
! grep -Eq '^(upgrade|reinstall|quit) ' "$CASE_DIR/calls" || fail 'stale cask identity was used to close or replace app'

setup_case malformed_metadata
metadata_bad=1
if run_claude; then fail 'malformed metadata accepted'; fi
no_mutation 'mutation with malformed metadata'

setup_case dry_run
MODE=check
run_claude
no_mutation 'check mode mutated app'
[[ ! -d "$STATE_DIR" ]] || fail 'check mode wrote state'

# Exercise the real updater decision path for each adapter. Only external
# Homebrew, process and launch boundaries are substituted by fixtures above.
for client in claude chatgpt; do
  setup_case "adapter-$client"
  running=0
  if [[ "$client" == claude ]]; then
    client_app=/Applications/Claude.app; client_id=com.anthropic.claudefordesktop; expected=4.2.0
  else
    client_app=/Applications/ChatGPT.app; client_id=com.openai.codex; expected=26.2.1
  fi
  update_one "$client" "$client_app" "$client_id" > "$CASE_DIR/output" 2>&1
  [[ $(cat "$CASE_DIR/$client.version") == "$expected" ]] || fail "$client bundle was not updated"
  [[ "$running" == 0 ]] || fail "$client was left closed"
  jq -e --arg id "$client_id" '.bundleId==$id and .result=="updated" and .reopened==true' "$STATE_DIR"/snapshots/*.json >/dev/null || fail "$client result did not verify update/reopen"
done

setup_case live_lock
mkdir -p "$STATE_DIR/lock"
printf '%s\n' "$$" > "$STATE_DIR/lock/pid"
if acquire_lock > "$CASE_DIR/output"; then fail 'overlapping updater acquired live lock'; fi
[[ $(cat "$STATE_DIR/lock/pid") == "$$" ]] || fail 'live lock changed'

setup_case corrupt_lock
mkdir -p "$STATE_DIR/lock"
printf 'invalid\n' > "$STATE_DIR/lock/pid"
lock_result=0
acquire_lock > "$CASE_DIR/output" || lock_result=$?
[[ "$lock_result" == 2 ]] || fail 'invalid lock did not report an error'

setup_case extra_argument
if main --check unexpected > "$CASE_DIR/output" 2>&1; then fail 'extra argument was silently accepted'; fi
[[ ! -s "$CASE_DIR/calls" ]] || fail 'invalid invocation accessed Homebrew'

# Inspect real JSON validation rather than the lifecycle fixture substitution.
setup_case malformed_lifecycle
cat > "$CASE_DIR/helper" <<'HELPER'
#!/bin/bash
printf '{"bundleId":"wrong.app","running":false,"pids":[]}\n'
HELPER
chmod +x "$CASE_DIR/helper"
state_result=0
bash -c 'source "$1"; LIFECYCLE="$2"; client_running /Applications/Claude.app com.anthropic.claudefordesktop' \
  _ "$SCRIPT" "$CASE_DIR/helper" || state_result=$?
[[ "$state_result" == 2 ]] || fail 'invalid lifecycle identity was treated as a closed client'

printf 'PASS: graceful quit/update/reopen, quit refusal, failure recovery, restart journal, native-restoration labels, downgrade refusal, identity, download ordering, launch race, version readback, check mode and locking\n'
