#!/usr/bin/env bash
# local-review-payload.sh — build the fallback self-review payload in the ONE shape
# local-review-verdict.sh accepts, so nobody writes that shape by hand again (monorepo#4839).
#
# WHY THIS EXISTS
#   The review-lanes guide (*Local review round*) lets an agent's own posted review satisfy the
#   green-review gate when no review lane will deliver. local-review-verdict.sh accepts that
#   review only in one exact shape: a disclosure first line, a fixed heading, a `Reviewed commit:`
#   line with the full SHA, one list line per review lane and a standard verdict line. The shape
#   lived in prose and agents wrote it by hand. On 2026-11-04 five ksail fallback reviews used a
#   different heading; the verdict helper read all five as no review, and one of those PRs was
#   promoted before anyone noticed. The shape was only checked after the review was posted. This
#   helper produces the payload from structured inputs, so the shape cannot be wrong.
#
# USAGE
#   local-review-payload.sh --head <40-hex-sha> --cr <text> --codex <text> --bugbot <text>
#                           [--finding <P0|P1|nit> <path> <line> <text>]...
#                           [--actor engineer|improver] [--interactive]
#
#   --head         the FULL 40-character lowercase head sha the round reviewed (abbreviations are
#                  refused: the review binds to one commit).
#   --cr, --codex, --bugbot
#                  one line each saying WHAT failed for that lane and WHEN, for example
#                  `rate limited at 2026-11-04T06:12Z ("Review limit reached")`. All three are
#                  required: the fallback is invalid without evidence for every lane.
#   --finding      one inline finding; repeat the flag for more. The severity is the comment's
#                  first token. <path> is relative to the repository root and <line> is a line on
#                  the right-hand side of the diff. P0 and P1 block; a nit does not.
#   --actor        `engineer` (default) or `improver`: selects the canonical disclosure line.
#   --interactive  an interactive Claude Code session: marks the disclosure line as such and ends
#                  the body with the interactive-session marker.
#
#   Every text value is one line; a line break in any of them is refused, so no input can add a
#   second heading or verdict line to the body.
#
#   stdout: ONE JSON object for `POST /repos/<owner>/<repo>/pulls/<n>/reviews`, with
#   `event: "COMMENT"` (GitHub refuses APPROVE and REQUEST_CHANGES on your own pull request).
#   Post it with `gh api --method POST repos/<owner>/<repo>/pulls/<n>/reviews --input <file>`.
#   The helper posts nothing and decides nothing: whether a local round is allowed at all is the
#   review-lanes guide's rule, and the posted round is still judged by local-review-verdict.sh.
#
# EXIT CODES
#   0  payload printed
#   2  usage error or malformed input — nothing printed
set -euo pipefail

usage() {
  sed -n '15,41p' "$0" >&2
  exit 2
}

die() {
  echo "local-review-payload: $*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required"

# One non-blank line: no line break may reach the body, where a line start is structure.
one_line() { # one_line <what> <value>
  case "$2" in
    *$'\n'* | *$'\r'*) die "$1 must be a single line" ;;
  esac
  [[ "$2" =~ [^[:space:]] ]] || die "$1 must not be empty"
}

head=""
cr=""
codex=""
bugbot=""
cr_set=0
codex_set=0
bugbot_set=0
actor="engineer"
interactive=0
comments='[]'
p0=0
p1=0
total=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)
      [ "$#" -ge 2 ] || usage
      head="$2"
      shift 2
      ;;
    --cr)
      [ "$#" -ge 2 ] || usage
      cr="$2"
      cr_set=1
      shift 2
      ;;
    --codex)
      [ "$#" -ge 2 ] || usage
      codex="$2"
      codex_set=1
      shift 2
      ;;
    --bugbot)
      [ "$#" -ge 2 ] || usage
      bugbot="$2"
      bugbot_set=1
      shift 2
      ;;
    --actor)
      [ "$#" -ge 2 ] || usage
      actor="$2"
      shift 2
      ;;
    --interactive)
      interactive=1
      shift
      ;;
    --finding)
      [ "$#" -ge 5 ] || usage
      severity="$2"
      path="$3"
      line="$4"
      text="$5"
      shift 5
      case "${severity}" in
        P0) p0=$((p0 + 1)) ;;
        P1) p1=$((p1 + 1)) ;;
        nit) ;;
        *) die "unknown severity '${severity}': use P0, P1 or nit" ;;
      esac
      one_line "a finding's path" "${path}"
      case "${path}" in
        /* | .. | ../* | */../* | */..) die "a finding's path must be relative to the repository root" ;;
      esac
      [[ "${line}" =~ ^[1-9][0-9]*$ ]] || die "a finding's line must be a positive integer"
      one_line "a finding's text" "${text}"
      total=$((total + 1))
      comments="$(jq -cn --argjson acc "${comments}" --arg path "${path}" --arg line "${line}" \
        --arg body "${severity}: ${text}" \
        '$acc + [{path: $path, line: ($line | tonumber), side: "RIGHT", body: $body}]')" ||
        die "could not encode a finding"
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

[[ "${head}" =~ ^[0-9a-f]{40}$ ]] || die "--head must be a full 40-character lowercase sha"
[ "${cr_set}" = 1 ] || die "--cr is required: say what failed for CodeRabbit and when"
[ "${codex_set}" = 1 ] || die "--codex is required: say what failed for Codex and when"
[ "${bugbot_set}" = 1 ] || die "--bugbot is required: say what failed for Cursor Bugbot and when"
one_line "--cr" "${cr}"
one_line "--codex" "${codex}"
one_line "--bugbot" "${bugbot}"

case "${actor}" in
  engineer) disclosure='> 🤖 Generated by the Agentic Engineer' ;;
  improver) disclosure='> 🤖 Generated by the Agent Improver' ;;
  *) die "--actor must be engineer or improver" ;;
esac
footer=""
if [ "${interactive}" = 1 ]; then
  disclosure="${disclosure} (interactive Claude Code session)"
  footer=$'\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
fi

# A nit is counted but never blocks, so a round with nits alone still uses the counted form with a
# zero P0/P1 breakdown, which local-review-verdict.sh reads as clean.
if [ "${total}" -eq 0 ]; then
  verdict='Verdict: no P0/P1 findings'
else
  noun="findings"
  [ "${total}" -ne 1 ] || noun="finding"
  verdict="Verdict: ${total} ${noun} (P0: ${p0}, P1: ${p1})"
fi

body="${disclosure}

## Self-review (fallback — CodeRabbit, Codex and Cursor Bugbot unavailable)

Reviewed commit: ${head}

- CodeRabbit: ${cr}
- Codex: ${codex}
- Cursor Bugbot: ${bugbot}

${verdict}${footer}"

payload="$(jq -cn --arg commit "${head}" --arg body "${body}" --argjson comments "${comments}" \
  '{commit_id: $commit, event: "COMMENT", body: $body, comments: $comments}')" ||
  die "could not encode the payload"
printf '%s\n' "${payload}"
