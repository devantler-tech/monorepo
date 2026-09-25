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
#   3. The Flux controllers themselves. A stored Ready=True outlives a stopped controller.
#   4. Pods whose containers are WAITING in a crash or image-pull state.
#   5. HTTPRoutes whose status has not caught up with their spec for 10 minutes — a gateway
#      controller that stopped applying routes, which every read above reports as healthy.
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
#   Without --context the context comes from prod-kube-context.sh, fed the kubeconfig of the same
#   kubectl the reads use. KUBECTL overrides that binary; the tests use it to supply recorded
#   payloads.
#
# EXIT CODES
#   0  healthy: every read succeeded and returned objects, and nothing is failing
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
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) usage_die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || usage_die "jq is required but not on PATH"
command -v "$KUBECTL" >/dev/null 2>&1 || usage_die "kubectl ('$KUBECTL') is not on PATH"

tmp="$(mktemp -d)" || usage_die "could not create a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# Resolve the context through the SAME kubectl the reads use, so a KUBECTL override (a wrapper,
# or a binary at a fixed path with its own kubeconfig) cannot resolve against one config and read
# through another.
if [ -z "$context" ]; then
  if ! "$KUBECTL" config view -o json >"$tmp/kubeconfig.json" 2>/dev/null ||
    ! context="$("$here/prod-kube-context.sh" --input "$tmp/kubeconfig.json")"; then
    echo "PLATFORM-HEALTH=UNKNOWN (no prod context resolved)"
    exit 2
  fi
fi

findings=0
unknown=0
: >"$tmp/rows"

# read_json <name> <kubectl get arguments...> — stores the payload, or records the read as UNKNOWN.
read_json() {
  local name="$1"
  shift
  if ! "$KUBECTL" --context "$context" --request-timeout=20s get "$@" -o json \
      >"$tmp/$name.json" 2>"$tmp/$name.err"; then
    printf 'UNREADABLE %s: kubectl get failed\n' "$name" >>"$tmp/rows"
    unknown=$((unknown + 1))
    return 1
  fi
  if ! jq -e '(.items | type) == "array"' "$tmp/$name.json" >/dev/null 2>&1; then
    printf 'UNREADABLE %s: the response is not a list\n' "$name" >>"$tmp/rows"
    unknown=$((unknown + 1))
    return 1
  fi
  # An empty list is a claim about the read, not about the cluster: a running platform always
  # has a Flux root, its sources, its controllers, and pods. Reading it as "nothing is failing"
  # would report a read that saw nothing as healthy.
  if jq -e '.items | length == 0' "$tmp/$name.json" >/dev/null 2>&1; then
    printf 'UNREADABLE %s: the read returned nothing\n' "$name" >>"$tmp/rows"
    unknown=$((unknown + 1))
    return 1
  fi
}

# extract <name> <jq program> — run the per-item program. Each item is evaluated on its own, so
# one malformed object cannot hide a failing one after it; the malformed one becomes MALFORMED,
# which counts as UNKNOWN. A jq failure outside that is UNKNOWN too, never a quiet pass.
extract() {
  local name="$1" program="$2"
  if ! jq -r --arg name "$name" "
    .items[] as \$o
    | try (\$o | $program)
      catch \"MALFORMED \\(\$name) \\(\$o.metadata.namespace // \"-\")/\\(\$o.metadata.name // \"?\")\"
  " "$tmp/$name.json" >>"$tmp/rows" 2>"$tmp/$name.jq.err"; then
    printf 'UNREADABLE %s: the response could not be processed\n' "$name" >>"$tmp/rows"
    unknown=$((unknown + 1))
  fi
}

# Every Flux object: Ready=False is a finding, Ready=Unknown is progress, anything else is fine.
# A missing Ready condition is progress too — a freshly created object has none yet. An OCI-type
# HelmRepository is the exception: Flux never reconciles one, so it never gains a condition, and
# reporting it would print the same PROGRESSING lines on every healthy tick.
# shellcheck disable=SC2016  # $ready and $id are jq variables; the shell must not expand them.
flux_rows='
  select((.kind == "HelmRepository" and .spec.type == "oci") | not)
  | ((.status.conditions // []) | map(select(.type == "Ready")) | .[0]) as $ready
  | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name)" as $id
  | (if ($ready.status // "") == "False" then
       "FAILING \($id) reason=\($ready.reason // "none")"
     elif ($ready.status // "") != "True" then
       "PROGRESSING \($id)"
     else empty end),
    (if (.spec.suspend // false) then "SUSPENDED \($id)" else empty end)
'

if read_json kustomizations kustomizations.kustomize.toolkit.fluxcd.io -A; then
  extract kustomizations "$flux_rows"
fi

if read_json sources ocirepositories.source.toolkit.fluxcd.io,gitrepositories.source.toolkit.fluxcd.io,helmrepositories.source.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A; then
  extract sources "$flux_rows"
fi

# 🔴 A stored Ready=True OUTLIVES its controller. Stop or delete the Flux controllers and every
# object keeps the last condition it was given, so the reads above stay green while nothing is
# being applied. The controllers themselves must be running.
readonly flux_controllers='source-controller kustomize-controller helm-controller notification-controller'
if read_json controllers deployments -n flux-system; then
  for controller in $flux_controllers; do
    if ! state="$(jq -r --arg n "$controller" '
        [.items[] | select(.metadata.name == $n)]
        | if length == 0 then "missing"
          else .[0] | "\(.spec.replicas // 1) \(.status.availableReplicas // 0)"
          end' "$tmp/controllers.json" 2>/dev/null)"; then
      printf 'MALFORMED controllers flux-system/%s\n' "$controller" >>"$tmp/rows"
      continue
    fi
    case "$state" in
      missing) printf 'FAILING Deployment flux-system/%s reason=missing\n' "$controller" >>"$tmp/rows" ;;
      "0 "*) printf 'FAILING Deployment flux-system/%s reason=scaled-to-zero\n' "$controller" >>"$tmp/rows" ;;
      *" 0") printf 'FAILING Deployment flux-system/%s reason=unavailable\n' "$controller" >>"$tmp/rows" ;;
    esac
  done
fi

if read_json pods pods -A; then
  # shellcheck disable=SC2016  # $pod is a jq variable
  extract pods '
    . as $pod
    | (($pod.status.initContainerStatuses // []) + ($pod.status.containerStatuses // []))[]
    | select((.state.waiting.reason // "")
             | test("^(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|ErrImageNeverPull|CreateContainerConfigError|CreateContainerError|InvalidImageName)$"))
    | "FAILING Pod \($pod.metadata.namespace)/\($pod.metadata.name) container=\(.name) reason=\(.state.waiting.reason) restarts=\(.restartCount // 0)"
  '
fi

# 🔴 A gateway controller that has stopped APPLYING routes is invisible to every read above. The
# gateway keeps serving its last configuration, Flux applies each HTTPRoute and reports Ready, and
# the controller's pods run — but the route's status keeps the generation it last processed
# (platform#4198: Cilium's Gateway API controller never started after an operator restart, and
# route changes stopped reaching the gateway for 12 hours). So a route whose status lags its spec
# is the signal. A lag is normal for the seconds after an edit, so it fails only once the spec has
# been unchanged for ROUTE_GRACE_SECONDS; before that it is progress. The last spec change is the
# newest managedFields entry that owns spec fields, which is why this read asks for managed
# fields: a metadata-only edit (a label, an annotation) must not restart the grace period, or
# repeated ones would keep a stalled route PROGRESSING forever. Every parent's observedGeneration
# counts, and a missing one means that parent never observed the route.
readonly ROUTE_GRACE_SECONDS=600
now="${PLATFORM_HEALTH_NOW:-$(date -u +%s)}"
case "$now" in
  '' | *[!0-9]*) usage_die "PLATFORM_HEALTH_NOW must be a Unix timestamp, got '$now'" ;;
esac
# Per route: every DECLARED parent (spec.parentRefs) must have a status entry whose conditions all
# observed the current generation — a parent whose controller stopped may add no entry at all, so
# scanning only the entries that exist would read as current. Once current, an Accepted=False or
# ResolvedRefs=False on a parent is a route the gateway rejected: live breakage, not lag.
#
# ⚠️ The grace clock is the newest spec-owning managed-field time. The API records one time per
# field manager, so a metadata-only apply by the manager that also owns the spec moves it too. That
# can only postpone a FAILING by one grace period per such apply, and a frozen gateway lags every
# route it is sent, so concealing it would need that edit on every lagging route every ten minutes.
# shellcheck disable=SC2016  # the $-names below are jq variables
route_rows='
  .metadata.namespace as $ns
  | .metadata.generation as $gen
  | "HTTPRoute \($ns)/\(.metadata.name)" as $id
  | [ .spec.parentRefs[]?
      | {name, namespace: (.namespace // $ns), sectionName: (.sectionName // null)} ] as $declared
  | [ .status.parents[]?
      | { ref: { name: .parentRef.name, namespace: (.parentRef.namespace // $ns),
                 sectionName: (.parentRef.sectionName // null) },
          seen: ([.conditions[]?.observedGeneration] | min),
          rejected: [ .conditions[]?
                      | select((.type == "Accepted" or .type == "ResolvedRefs") and .status == "False")
                      | "\(.type)/\(.reason // "none")" ] } ] as $status
  | ( if ($declared | length) > 0
      then [ $declared[] as $d | ([ $status[] | select(.ref == $d) | .seen ] | max) ]
      else [ $status[].seen ] end
      | min ) as $seen
  | ([ .metadata.managedFields[]?
       | select((.subresource // "") != "status" and ((.fieldsV1 // {}) | has("f:spec")))
       | .time ]
     + [ .metadata.creationTimestamp ] | map(select(. != null)) | max) as $changed
  | ([ $status[] | select(.seen != null and .seen >= $gen) | .rejected[] ] | unique) as $rejections
  | if ($seen != null and $seen >= $gen) then
      if ($rejections | length) > 0
      then "FAILING \($id) reason=route-rejected conditions=\($rejections | join(","))"
      else empty end
    elif (__NOW__ - ($changed | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) > __GRACE__ then
      "FAILING \($id) reason=gateway-not-applying generation=\($gen) applied=\($seen // "none")"
    else "PROGRESSING \($id)" end
'
route_rows="${route_rows//__NOW__/$now}"
route_rows="${route_rows//__GRACE__/$ROUTE_GRACE_SECONDS}"
if read_json httproutes httproutes.gateway.networking.k8s.io -A --show-managed-fields; then
  extract httproutes "$route_rows"
fi

cat "$tmp/rows"
findings="$(grep -c '^FAILING ' "$tmp/rows")"
unknown=$((unknown + $(grep -c '^MALFORMED ' "$tmp/rows")))

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
