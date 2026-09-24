#!/usr/bin/env bash
# platform-live-health.sh — the rung-0 read of whether the prod platform cluster is actually up.
#
# WHY THIS EXISTS (monorepo#3090)
#   The survey reads GitHub, and a prod outage is not on GitHub. On 2026-08-27 a merged platform
#   change took cluster DNS down, every Flux source went `False`, and the survey still returned
#   `nothing_on_fire: true` because every repository was green. Rung 0 is live breakage, so a run
#   must be able to see this without a full security pass. This is that read: bounded, read-only,
#   and cheap enough for every tick.
#
# WHAT IT READS (through the scoped context prod-kube-context.sh resolves, never admin)
#   1. Flux Kustomizations — the GitOps layers themselves. In the incident they went `False`
#      within seconds and stayed there.
#   2. Flux sources and HelmReleases — an unreachable registry shows here first.
#   3. Pods whose containers are WAITING in a crash or image-pull state.
#
#   🔴 A pod-phase filter CANNOT see a crash loop. A crash-looping pod's phase stays `Running`;
#   only the container's `state.waiting.reason` says `CrashLoopBackOff`. The obvious health query,
#   `--field-selector=status.phase!=Running`, returned nothing but completed Jobs during the
#   incident. So this reads container state, and the test pins the phase-only filter as blind.
#
# ONLY `False` IS UNHEALTHY. `Unknown` is what a resource reports while it reconciles, which every
# deploy does, so it is reported as PROGRESSING and never fails the check. Condition MESSAGES are
# never printed: they can carry internal hostnames, and the reason is enough to act on.
#
# USAGE
#   platform-live-health.sh [--context <kube-context>]
#
#   Without --context the context comes from prod-kube-context.sh. KUBECTL overrides the kubectl
#   binary; the tests use it to supply recorded payloads.
#
# EXIT CODES
#   0  healthy: every read succeeded, at least one Flux Kustomization exists, nothing is failing
#   1  UNHEALTHY: something is failing. A known failure wins over an unreadable read elsewhere,
#      because an unreadable surface must never mask one that is visibly broken.
#   2  UNKNOWN: a read failed or returned nothing checkable. Never report this as healthy, and
#      `nothing_on_fire` cannot be true while it holds.

set -uo pipefail

KUBECTL="${KUBECTL:-kubectl}"
context=""
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage_die() { printf 'platform-live-health: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --context) [ $# -ge 2 ] || usage_die "--context needs a value"; context="$2"; shift 2 ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) usage_die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || usage_die "jq is required but not on PATH"
command -v "$KUBECTL" >/dev/null 2>&1 || usage_die "kubectl ('$KUBECTL') is not on PATH"

if [ -z "$context" ]; then
  context="$("$here/prod-kube-context.sh")" || {
    echo "PLATFORM-HEALTH=UNKNOWN (no prod context resolved)"
    exit 2
  }
fi

tmp="$(mktemp -d)" || usage_die "could not create a temporary directory"
trap 'rm -rf "$tmp"' EXIT

findings=0
unknown=0

# read_json <name> <kubectl get arguments...> — stores the payload, or records the read as UNKNOWN.
read_json() {
  local name="$1"
  shift
  if ! "$KUBECTL" --context "$context" --request-timeout=20s get "$@" -A -o json \
      >"$tmp/$name.json" 2>"$tmp/$name.err"; then
    printf 'UNREADABLE %s: kubectl get failed\n' "$name"
    unknown=$((unknown + 1))
    return 1
  fi
  if ! jq -e '(.items | type) == "array"' "$tmp/$name.json" >/dev/null 2>&1; then
    printf 'UNREADABLE %s: the response is not a list\n' "$name"
    unknown=$((unknown + 1))
    return 1
  fi
}

# Every Flux object: Ready=False is a finding, Ready=Unknown is progress, anything else is fine.
# A missing Ready condition is progress too — a freshly created object has none yet. An OCI-type
# HelmRepository is the exception: Flux never reconciles one, so it never gains a condition, and
# reporting it would print the same PROGRESSING lines on every healthy tick.
# shellcheck disable=SC2016  # $ready and $id are jq variables; the shell must not expand them.
flux_rows='
  .items[]
  | select((.kind == "HelmRepository" and .spec.type == "oci") | not)
  | ((.status.conditions // []) | map(select(.type == "Ready")) | .[0]) as $ready
  | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name)" as $id
  | if ($ready.status // "") == "False" then
      "FAILING \($id) reason=\($ready.reason // "none")"
    elif ($ready.status // "") != "True" then
      "PROGRESSING \($id)"
    else empty end,
    (if (.spec.suspend // false) then "SUSPENDED \($id)" else empty end)
'

if read_json kustomizations kustomizations.kustomize.toolkit.fluxcd.io; then
  count="$(jq '.items | length' "$tmp/kustomizations.json")"
  if [ "$count" -eq 0 ]; then
    # An empty list is a claim about the read, not about the cluster: Flux always has a root.
    echo "UNREADABLE kustomizations: no Flux Kustomization returned"
    unknown=$((unknown + 1))
  fi
  jq -r "$flux_rows" "$tmp/kustomizations.json" >>"$tmp/rows"
fi

if read_json sources ocirepositories.source.toolkit.fluxcd.io,gitrepositories.source.toolkit.fluxcd.io,helmrepositories.source.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io; then
  jq -r "$flux_rows" "$tmp/sources.json" >>"$tmp/rows"
fi

if read_json pods pods; then
  jq -r '
    .items[] as $pod
    | (($pod.status.initContainerStatuses // []) + ($pod.status.containerStatuses // []))[]
    | select((.state.waiting.reason // "")
             | test("^(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|InvalidImageName)$"))
    | "FAILING Pod \($pod.metadata.namespace)/\($pod.metadata.name) container=\(.name) reason=\(.state.waiting.reason) restarts=\(.restartCount // 0)"
  ' "$tmp/pods.json" >>"$tmp/rows"
fi

if [ -s "$tmp/rows" ]; then
  cat "$tmp/rows"
  findings="$(grep -c '^FAILING ' "$tmp/rows")"
fi

if [ "$findings" -gt 0 ]; then
  echo "PLATFORM-HEALTH=UNHEALTHY failing=$findings"
  exit 1
fi
if [ "$unknown" -gt 0 ]; then
  echo "PLATFORM-HEALTH=UNKNOWN unreadable=$unknown"
  exit 2
fi
echo "PLATFORM-HEALTH=OK"
exit 0
