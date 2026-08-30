#!/usr/bin/env bash
#
# disclosure-drift-sweep.sh
#
# Runs comment-disclosure-drift.sh in --since mode across several repositories and
# reports only the findings that are REAL, so a non-zero exit is actionable rather
# than routine. Without this, nothing sweeps live comments: CI runs the drift
# guard's unit test and never the guard itself (monorepo#2757).
#
# Usage:
#   disclosure-drift-sweep.sh --since <ISO-8601-UTC> --repo <owner>/<repo> [--repo ...]
#
#   --author <login>   forwarded to the drift guard (default: its own default)
#
# Exit codes:
#   0  every repository swept clean, or every finding cleared on re-verification
#   1  at least one REAL violation
#   2  UNKNOWN — a sweep or a re-verification could not produce a verdict
#
# WHY A WRAPPER AND NOT A BARE --since CALL
#
# A --since sweep exits 1 ROUTINELY on any repository that uses Bugbot, and those
# findings are not violations. The guard's own header states the reason: `since`
# selects by UPDATED time, so a discussion's returned history is not contiguous and
# adjacency cannot establish the disclosure/trigger pairing Bugbot's bare-trigger
# carve-out requires. It therefore never grants that carve-out, by design.
#
# So a caller that keys on the exit code alone fails constantly on compliant
# comments, and a caller that ignores the exit code sees nothing. Both make the
# detector useless in exactly the way #2757 describes. AGENTS.md resolves it by
# consuming the FINDINGS, not the code: re-verify ONLY a body that is exactly
# `@cursor review`, with --issue, where the full comment list is present.
#
# THE RE-VERIFICATION IS SCOPED TO ONE TRIGGER ON PURPOSE
#
# Re-verifying by SHAPE ("any bare trigger") instead of by LANE would send
# `@coderabbitai review` and `@codex review` through it too. Those lanes have NO
# carve-out, so their bare triggers are violations on sight and the round-trip
# cannot change the verdict — but it CAN file them inside the Bugbot pile, where
# they read as known noise. monorepo#2965 records a misread of exactly that shape.
#
# FAILURE DIRECTION
#
# Re-verification can only CLEAR a finding, never create one, and it clears only on
# a verdict the authoritative --issue mode actually produced. A re-verification that
# cannot run is UNKNOWN, never cleared: an unprovable carve-out is not a carve-out.
# Likewise an empty finding list is only clean when the sweep it came from SUCCEEDED
# — a failed read produces no findings, which is the same output as a clean one.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Overridable so the test can drive this against a stub instead of the network.
drift_cmd="${DISCLOSURE_DRIFT_CMD:-$script_dir/comment-disclosure-drift.sh}"

since=""
author=""
repos=()

die() {
  echo "disclosure-drift-sweep: $1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      [ $# -ge 2 ] || die "--since needs a value"
      since="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || die "--repo needs a value"
      repos+=("$2")
      shift 2
      ;;
    --author)
      [ $# -ge 2 ] || die "--author needs a value"
      author="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '3,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$since" ] || die "--since is required"
[ "${#repos[@]}" -gt 0 ] || die "at least one --repo is required"
[ -x "$drift_cmd" ] || die "drift guard not executable: $drift_cmd"

# `set -u` makes "${arr[@]}" an unbound-variable error for an EMPTY array under
# bash 3.2, so every expansion of these arrays uses the `+` guard form. Without it
# the script dies mid-sweep and exits non-zero — which a caller reads as "found
# violations", the one wrong answer that still looks like a working check.
author_args=()
[ -n "$author" ] && author_args=(--author "$author")

# `run_drift` deliberately captures rather than pipes. Piping the guard into a
# parser makes the PARSER's status the pipeline status, so a guard that died would
# read as a clean sweep — the exact fail-open this wrapper exists to remove.
DRIFT_OUT=""
DRIFT_RC=0
run_drift() {
  if DRIFT_OUT="$("$drift_cmd" "$@" 2>&1)"; then
    DRIFT_RC=0
  else
    DRIFT_RC=$?
  fi
}

# One record per finding: <shape> <url> <first-line...>
# The guard prints the first line on its own indented continuation line, so the
# two are joined here rather than matched independently — a finding whose
# continuation is missing must not silently inherit the previous finding's body.
parse_findings() { # reads $DRIFT_OUT on stdin
  # Emits MALFORMED for any record missing a shape, a URL, or its continuation.
  # The previous form kept `if (url != "")` as the emit condition, which drops
  # such a record SILENTLY: a lone one is caught downstream by the empty-findings
  # guard, but one sitting beside a well-formed record simply vanishes and the
  # sweep under-reports while still exiting 1. The guard always emits all three
  # fields today, so this changes nothing on real output — it closes the
  # shape-changed-under-us hole the empty-findings guard only half covers.
  awk '
    function emit() {
      if (shape == "" || url == "" || !body_seen) { print "MALFORMED\t\t"; return }
      print shape "\t" url "\t" body
    }
    /^VIOLATION / {
      if (seen) emit()
      shape = $2; url = $3; body = ""; body_seen = 0; seen = 1; next
    }
    /^[[:space:]]+first line:/ {
      sub(/^[[:space:]]+first line:[[:space:]]*/, "")
      body = $0; body_seen = 1; next
    }
    END { if (seen) emit() }
  '
}

real_count=0
cleared_count=0
unknown_count=0
real_lines=()
unknown_lines=()

for repo in "${repos[@]}"; do
  run_drift --repo "$repo" --since "$since" ${author_args[@]+"${author_args[@]}"}
  if [ "$DRIFT_RC" -eq 2 ]; then
    unknown_count=$((unknown_count + 1))
    unknown_lines+=("$repo: sweep could not verify — $(printf '%s' "$DRIFT_OUT" | tail -1)")
    continue
  fi
  if [ "$DRIFT_RC" -eq 0 ]; then
    printf 'clean    %s\n' "$repo"
    continue
  fi

  findings="$(printf '%s\n' "$DRIFT_OUT" | parse_findings)"
  if [ -z "$findings" ]; then
    # Exit 1 with nothing parseable means the output shape changed under us.
    unknown_count=$((unknown_count + 1))
    unknown_lines+=("$repo: guard reported drift but no finding could be parsed")
    continue
  fi

  while IFS=$'\t' read -r shape url body; do
    # An incomplete record means the guard's output shape changed under us, so
    # this repository's result is unverifiable rather than clean. Checked BEFORE
    # the url test below, which would otherwise `continue` past it silently —
    # the very drop this record type exists to surface.
    if [ "$shape" = "MALFORMED" ]; then
      unknown_count=$((unknown_count + 1))
      unknown_lines+=("$repo: a finding record was incomplete — the guard's output shape changed under us")
      continue
    fi
    [ -n "$url" ] || continue
    # Only Bugbot's exact bare trigger is carve-out eligible. Everything else —
    # including a bare @coderabbitai/@codex trigger — is a violation on sight.
    if [ "$shape" = "undisclosed-trigger" ] && [ "$body" = "@cursor review" ]; then
      number="${url##*/}"
      number="${number%%#*}"
      cid="${url##*#issuecomment-}"
      run_drift --repo "$repo" --issue "$number" ${author_args[@]+"${author_args[@]}"}
      if [ "$DRIFT_RC" -eq 2 ]; then
        unknown_count=$((unknown_count + 1))
        unknown_lines+=("$url: re-verification could not run")
        continue
      fi
      # Cleared only when the authoritative full-history read no longer names it.
      if printf '%s\n' "$DRIFT_OUT" | grep -qF -- "issuecomment-$cid"; then
        real_count=$((real_count + 1))
        real_lines+=("$url ($shape) $body")
      else
        cleared_count=$((cleared_count + 1))
      fi
      continue
    fi
    real_count=$((real_count + 1))
    real_lines+=("$url ($shape) $body")
  done <<<"$findings"
done

printf '\n'
for line in ${unknown_lines[@]+"${unknown_lines[@]}"}; do
  printf 'UNKNOWN  %s\n' "$line"
done
for line in ${real_lines[@]+"${real_lines[@]}"}; do
  printf 'REAL     %s\n' "$line"
done

printf '\ndisclosure-drift-sweep: %d real, %d cleared on re-verification, %d unknown\n' \
  "$real_count" "$cleared_count" "$unknown_count"

# UNKNOWN outranks a clean result: an unswept repository is not a swept one.
[ "$unknown_count" -eq 0 ] || exit 2
[ "$real_count" -eq 0 ] || exit 1
