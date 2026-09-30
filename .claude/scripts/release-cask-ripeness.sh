#!/usr/bin/env bash
# release-cask-ripeness.sh — decide whether ONE Homebrew-tap cask PR's release is published, so
# that promoting the PR cannot ship a cask for a release that does not exist yet (monorepo#2992).
#
# WHY THIS EXISTS
#   A product's CD opens its cask PR as a DRAFT on purpose: the draft is the fence that keeps the
#   tap from merging a cask while the GitHub release is still a draft, or after the CD's own
#   hand-off failed. programmed-bot-review-exemption.sh proves who produced the PR, never whether
#   it is ripe, so "draft + exempt + CLEAN" read as "promote me" and an agent removed the fence
#   (homebrew-tap#1496 on 2026-08-22; #1534 was surveyed as promotable on 2026-08-29 while its
#   release did not exist). This helper answers the missing question from the cask itself: every
#   download URL the cask installs must be an asset of a PUBLISHED release, and every pinned sha256
#   must equal the digest GitHub records for that asset.
#
#   The CD run's conclusion is deliberately NOT the test. A published release can sit behind a CD
#   run reported `cancelled` (homebrew-tap#1743, 2026-09-30), and a green run proves nothing about
#   the asset URLs the cask points at. The release's `*checksums.txt` is not the test either: it
#   lists only some archives (KSail's omits the desktop zip), while every asset carries a digest.
#
# USAGE
#   Resolve the release with the status-checked, 404-only lookup in
#   .claude/guides/merge-policy.md, then build the JSON payload as shown there.
#   release-cask-ripeness.sh --input - < payload.json
#
#   --input -  REQUIRED: stdin is ONE JSON object with exactly the keys
#                cask     string — the cask file at the PR's head commit
#                release  object or null — the REST release for the cask's version. Pass null only
#                         when that read returned 404: a draft release is not readable by tag, so it
#                         arrives here as null, which is correct because it is not published. Any
#                         other failed read is UNKNOWN for the caller, never null.
#              This is the only shape the surveyor's read-only guard admits for a declared helper.
#
# OUTPUT (one line on stdout)
#   RIPE <owner/repo> v<version>  the release is published, carries every asset the cask installs,
#                                 and every pinned sha256 equals that asset's digest
#   NOT-RIPE <reason>             the release is absent or a draft, lacks an asset the cask installs,
#                                 or an asset's digest differs from the cask's sha256
#   UNKNOWN <reason>              the input cannot be judged: a cask this helper cannot parse, a
#                                 release for another repository or tag, or an asset with no digest
#
# EXIT CODES
#   0  RIPE — the draft fence may be cleared
#   1  NOT-RIPE — keep the PR a draft and report it parked on the release
#   2  UNKNOWN, a usage error, or unreadable input — never read as ripe
set -euo pipefail

usage() {
  sed -n '20,44p' "$0" >&2
  exit 2
}

if [ "$#" -ne 2 ] || [ "$1" != "--input" ] || [ "$2" != "-" ]; then
  usage
fi
command -v jq >/dev/null 2>&1 || {
  echo "release-cask-ripeness: jq is required" >&2
  exit 2
}

payload="$(cat)" || exit 2
jq -se 'length == 1 and (.[0] | type == "object"
    and (keys == ["cask", "release"])
    and (.cask | type == "string")
    and (.release | type == "object" or type == "null"))' \
  <<<"${payload}" >/dev/null 2>&1 || {
  echo "release-cask-ripeness: stdin must be one JSON object with exactly cask (string) and release (object|null)" >&2
  exit 2
}

# The whole verdict is one jq program, so no shell step can drop a field between reads. It yields
# exactly one line whose first word is the verdict.
#
# The n-th `sha256` line is paired with the n-th `url` line, in file order: each cask stanza holds
# exactly one of each (GoReleaser and the World at Ruin CD both write them that way). A cask whose
# sha256 and url counts differ cannot be paired and is UNKNOWN rather than half-checked.
verdict="$(jq -r '
  def lines: split("\n") | map(sub("\r$"; ""));
  def matching($re): [.[] | select(test($re))];
  .release as $release
  | (.cask | lines) as $cask
  | ($cask | matching("^\\s*version\\s")) as $version_lines
  | ($cask | matching("^\\s*url\\s")) as $url_lines
  | ($cask | matching("^\\s*sha256\\s")) as $sha_lines
  | [$version_lines[] | capture("^\\s*version\\s+\"(?<v>[^\"]+)\"\\s*$").v] as $versions
  | [$url_lines[] | capture("^\\s*url\\s+\"(?<u>[^\"]+)\"").u] as $raw_urls
  | [$sha_lines[] | capture("^\\s*sha256\\s+(?:\"(?<s>[0-9a-f]{64})\"|(?<n>:no_check))\\s*$") | .s] as $shas
  | if ($version_lines | length) != 1 or ($versions | length) != 1 then
      "UNKNOWN cask must declare exactly one quoted version line"
    elif ($url_lines | length) == 0 or ($raw_urls | length) != ($url_lines | length) then
      "UNKNOWN cask has no url, or a url line that is not one quoted string"
    elif ($shas | length) != ($sha_lines | length) then
      "UNKNOWN cask has a sha256 line that is neither a quoted 64-hex digest nor :no_check"
    elif ($shas | length) != ($raw_urls | length) then
      "UNKNOWN cask has \($shas | length) sha256 line(s) for \($raw_urls | length) url line(s), so they cannot be paired"
    else
      $versions[0] as $v
      | [range(0; $raw_urls | length) | {url: ($raw_urls[.] | gsub("#\\{version\\}"; $v)), sha: $shas[.]}] as $pairs
      | "^https://github\\.com/(?<r>devantler-tech/[A-Za-z0-9._-]+)/releases/download/(?<t>[^/]+)/[^/]+$" as $shape
      | ([$pairs[].url | select(test($shape) | not)]) as $foreign
      | if ($foreign | length) > 0 then
          "UNKNOWN cask url is not a devantler-tech release download: \($foreign[0])"
        else
          [$pairs[].url | capture($shape)] as $parts
          | if ([$parts[].r] | unique | length) != 1 or ([$parts[].t] | unique) != ["v\($v)"] then
              "UNKNOWN cask urls do not all point at one repository and tag v\($v)"
            else
              $parts[0].r as $repo
              | if $release == null then
                  "NOT-RIPE release \($repo) v\($v) is not published (not readable by tag: absent or still a draft)"
                elif ($release.tag_name // "") != "v\($v)" then
                  "UNKNOWN supplied release is \($release.tag_name // "untagged"), not v\($v)"
                elif (($release.html_url // "") | startswith("https://github.com/\($repo)/releases/") | not) then
                  "UNKNOWN supplied release does not belong to \($repo)"
                elif $release.draft != false then
                  "NOT-RIPE release \($repo) v\($v) is a draft"
                else
                  ($release.assets // []) as $assets
                  | [$pairs[] | .url as $u | select([$assets[] | select(.browser_download_url == $u)] | length == 0) | .url] as $missing
                  | [$pairs[] | select(.sha != null) | .url as $u | .sha as $s
                      | ([$assets[] | select(.browser_download_url == $u)][0].digest) as $d
                      | {url: $u, want: "sha256:\($s)", have: $d}] as $pinned
                  | if ($missing | length) > 0 then
                      "NOT-RIPE release \($repo) v\($v) lacks the asset(s) the cask installs: \($missing | unique | join(" "))"
                    elif ([$pinned[] | select((.have | type) != "string")] | length) > 0 then
                      "UNKNOWN release \($repo) v\($v) asset has no digest: \([$pinned[] | select((.have | type) != "string")][0].url)"
                    elif ([$pinned[] | select(.have != .want)] | length) > 0 then
                      "NOT-RIPE release \($repo) v\($v) asset digest differs from the cask sha256: \([$pinned[] | select(.have != .want)][0].url)"
                    else
                      "RIPE \($repo) v\($v)"
                    end
                end
            end
        end
    end
' <<<"${payload}")" || {
  echo "release-cask-ripeness: could not evaluate the input" >&2
  exit 2
}

printf '%s\n' "${verdict}"
case "${verdict}" in
  RIPE\ *) exit 0 ;;
  NOT-RIPE\ *) exit 1 ;;
  *) exit 2 ;;
esac
