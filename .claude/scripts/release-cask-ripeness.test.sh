#!/usr/bin/env bash
# Tests for release-cask-ripeness.sh (monorepo#2992): a programmed cask PR's draft fence may be
# cleared only when its release is published with every asset the cask installs, at the pinned digest.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/release-cask-ripeness.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

A=$(printf 'a%.0s' $(seq 64)); B=$(printf 'b%.0s' $(seq 64)); C=$(printf 'c%.0s' $(seq 64))
DL=https://github.com/devantler-tech/ksail/releases/download/v1.2.3

# The shape GoReleaser writes for ksail: an intel stanza with :no_check, then pinned arm stanzas.
CASK=$(cat <<EOF
cask "ksail" do
  version "1.2.3"
  on_macos do
    on_intel do
      sha256 :no_check
      url "https://github.com/devantler-tech/ksail/releases/download/v#{version}/ksail_#{version}_darwin_arm64.tar.gz"
    end
  end
  on_macos do
    on_arm do
      sha256 "$A"
      url "https://github.com/devantler-tech/ksail/releases/download/v#{version}/ksail_#{version}_darwin_arm64.tar.gz"
    end
  end
  on_linux do
    on_arm do
      sha256 "$B"
      url "https://github.com/devantler-tech/ksail/releases/download/v#{version}/ksail_#{version}_linux_arm64.tar.gz"
    end
  end
end
EOF
)

release() { # [draft] [darwin-digest] [linux-digest|none|missing] [tag] [html repo]
  local draft=${1:-false} dd=${2:-$A} ld=${3:-$B} tag=${4:-v1.2.3} repo=${5:-devantler-tech/ksail}
  jq -n --argjson draft "$draft" --arg dd "sha256:$dd" --arg ld "$ld" --arg tag "$tag" --arg repo "$repo" --arg dl "$DL" '
    {tag_name: $tag, draft: $draft, html_url: "https://github.com/\($repo)/releases/tag/\($tag)",
     assets: ([{name: "ksail_1.2.3_darwin_arm64.tar.gz", browser_download_url: "\($dl)/ksail_1.2.3_darwin_arm64.tar.gz", digest: $dd}]
       + (if $ld == "missing" then []
          elif $ld == "none" then [{name: "ksail_1.2.3_linux_arm64.tar.gz", browser_download_url: "\($dl)/ksail_1.2.3_linux_arm64.tar.gz", digest: null}]
          else [{name: "ksail_1.2.3_linux_arm64.tar.gz", browser_download_url: "\($dl)/ksail_1.2.3_linux_arm64.tar.gz", digest: "sha256:\($ld)"}] end))}'
}

# expect <name> <want-rc> <want-stdout-prefix> <cask> <release-json>
expect() {
  local name=$1 want_rc=$2 want=$3 cask=$4 rel=$5 out rc
  out=$(jq -n --arg cask "$cask" --argjson release "$rel" '{cask:$cask, release:$release}' \
        | bash "$SUT" --input - 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && [ "${out#"$want"}" != "$out" ]; then ok "$name"
  else bad "$name" "rc=$rc (want $want_rc) out=$out"; fi
}

expect "a published release with every asset at the pinned digest is RIPE" \
  0 "RIPE devantler-tech/ksail v1.2.3" "$CASK" "$(release)"
expect "a release not readable by tag (absent or draft) is NOT-RIPE" \
  1 "NOT-RIPE release devantler-tech/ksail v1.2.3 is not published" "$CASK" null
expect "a draft release is NOT-RIPE" \
  1 "NOT-RIPE release devantler-tech/ksail v1.2.3 is a draft" "$CASK" "$(release true)"
expect "a release missing an asset the cask installs is NOT-RIPE" \
  1 "NOT-RIPE release devantler-tech/ksail v1.2.3 lacks the asset(s) the cask installs: $DL/ksail_1.2.3_linux_arm64.tar.gz" \
  "$CASK" "$(release false "$A" missing)"
expect "an asset whose digest differs from the cask sha256 is NOT-RIPE" \
  1 "NOT-RIPE release devantler-tech/ksail v1.2.3 asset digest differs from the cask sha256: $DL/ksail_1.2.3_linux_arm64.tar.gz" \
  "$CASK" "$(release false "$A" "$C")"
expect "an asset with no recorded digest is UNKNOWN, never RIPE" \
  2 "UNKNOWN release devantler-tech/ksail v1.2.3 asset has no digest" "$CASK" "$(release false "$A" none)"
expect "a release for another tag is UNKNOWN" \
  2 "UNKNOWN supplied release is v1.2.4, not v1.2.3" "$CASK" "$(release false "$A" "$B" v1.2.4)"
expect "a release belonging to another repository is UNKNOWN" \
  2 "UNKNOWN supplied release does not belong to devantler-tech/ksail" \
  "$CASK" "$(release false "$A" "$B" v1.2.3 devantler-tech/other)"

# A :no_check stanza pins nothing, so its asset must exist but its digest is never compared.
NOCHECK_CASK=${CASK/ksail_#\{version\}_darwin_arm64.tar.gz\"/ksail_#\{version\}_darwin_amd64.tar.gz\"}
expect ":no_check requires its asset but never compares its digest" \
  0 "RIPE" "$NOCHECK_CASK" \
  "$(release | jq --arg dl "$DL" --arg c "sha256:$C" '.assets += [{name: "ksail_1.2.3_darwin_amd64.tar.gz", browser_download_url: "\($dl)/ksail_1.2.3_darwin_amd64.tar.gz", digest: $c}]')"
expect ":no_check still requires its asset to be published" \
  1 "NOT-RIPE release devantler-tech/ksail v1.2.3 lacks the asset(s) the cask installs: $DL/ksail_1.2.3_darwin_amd64.tar.gz" \
  "$NOCHECK_CASK" "$(release)"

expect "a cask with two version lines is UNKNOWN" \
  2 "UNKNOWN cask must declare exactly one quoted version line" \
  "$(printf '%s\n  version "9.9.9"\n' "$CASK")" "$(release)"
expect "a url outside devantler-tech releases is UNKNOWN" \
  2 "UNKNOWN cask url is not a devantler-tech release download: https://example.com/x.tgz" \
  "$(sed 's#https://github.com/devantler-tech/ksail/releases/download/v\#{version}/ksail_\#{version}_linux_arm64.tar.gz#https://example.com/x.tgz#' <<<"$CASK")" \
  "$(release)"
expect "urls under another tag than the cask version are UNKNOWN" \
  2 "UNKNOWN cask urls do not all point at one repository and tag v1.2.3" \
  "$(sed 's#download/v\#{version}/ksail_\#{version}_linux#download/v0.0.1/ksail_\#{version}_linux#' <<<"$CASK")" \
  "$(release)"
expect "a sha256 line with no url to pair is UNKNOWN" \
  2 "UNKNOWN cask has 4 sha256 line(s) for 3 url line(s)" \
  "$(printf '%s\n  sha256 "%s"\n' "$CASK" "$C")" "$(release)"
expect "a malformed sha256 line is UNKNOWN" \
  2 "UNKNOWN cask has a sha256 line that is neither a quoted 64-hex digest nor :no_check" \
  "${CASK//sha256 \"$B\"/sha256 \"XYZ\"}" "$(release)"

# Input-shape gate: anything but exactly {cask, release} is a usage error, never a verdict.
name="an input object with an extra key is refused"
out=$(jq -n --arg cask "$CASK" '{cask:$cask, release:null, checksums:null}' | bash "$SUT" --input - 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'stdin must be one JSON object' <<<"$out"; then ok "$name"; else bad "$name" "rc=$rc $out"; fi
name="a positional argument is refused"
out=$(bash "$SUT" "$CASK" </dev/null 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "$name"; else bad "$name" "rc=$rc $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
