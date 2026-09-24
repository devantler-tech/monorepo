#!/usr/bin/env bash
# RED/GREEN coverage for platform-live-health.sh against a stub kubectl serving recorded payloads:
# each verdict, the crash-loop blind spot of a phase filter, and every read failure as UNKNOWN.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root/.claude/scripts/platform-live-health.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "platform-live-health test: $*" >&2; exit 1; }

# The stub answers `kubectl --context <ctx> --request-timeout=<t> get <resources> -A -o json` from
# $FAKE/<first resource>.json, or fails when $FAKE/<first resource>.fail exists.
cat >"$tmp/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = config ]; then
  [ -e "$FAKE/config.fail" ] && exit 1
  printf '{"contexts":[{"name":"admin-ctx","context":{"cluster":"prod","user":"admin"}},{"name":"prod-ctx","context":{"cluster":"prod","user":"oidc-user"}}]}'
  exit 0
fi
[ "$1" = --context ] && [ "$2" = prod-ctx ] || { echo "stub: unexpected context '$2'" >&2; exit 64; }
[ "$4" = get ] || { echo "stub: not a get" >&2; exit 64; }
resource="${5%%,*}"
resource="${resource%%.*}"
[ -e "$FAKE/$resource.fail" ] && { echo "stub: refused" >&2; exit 1; }
cat "$FAKE/$resource.json"
EOF
chmod +x "$tmp/kubectl"

ready() { # <kind> <ns> <name> <status> [reason]
  printf '{"kind":"%s","metadata":{"namespace":"%s","name":"%s"},"status":{"conditions":[{"type":"Ready","status":"%s","reason":"%s","message":"lookup ghcr.io on 10.96.0.10:53: server misbehaving"}]}}' \
    "$1" "$2" "$3" "$4" "${5:-Succeeded}"
}
list() { printf '{"items":[%s]}' "$(IFS=,; echo "$*")"; }
healthy_pod='{"metadata":{"namespace":"kube-system","name":"coredns-1"},"status":{"phase":"Running","containerStatuses":[{"name":"coredns","restartCount":0,"state":{"running":{}}}]}}'
crashloop_pod='{"metadata":{"namespace":"kube-system","name":"hubble-relay-1"},"status":{"phase":"Running","containerStatuses":[{"name":"hubble-relay","restartCount":49,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}'
pullback_init='{"metadata":{"namespace":"apps","name":"web-1"},"status":{"phase":"Pending","initContainerStatuses":[{"name":"migrate","restartCount":0,"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}'
# deployments <name:replicas:available>... — the flux-system controller Deployments
deployments() {
  local items=() d n r a
  for d in "$@"; do
    IFS=: read -r n r a <<<"$d"
    items+=("{\"metadata\":{\"namespace\":\"flux-system\",\"name\":\"$n\"},\"spec\":{\"replicas\":$r},\"status\":{\"availableReplicas\":$a}}")
  done
  list "${items[@]}"
}
oci_helmrepo='{"kind":"HelmRepository","metadata":{"namespace":"flux-system","name":"flux-operator"},"spec":{"type":"oci"}}'

scenario() { # <name> — fresh fixture dir populated with a healthy baseline
  FAKE="$tmp/$1"
  export FAKE
  mkdir -p "$FAKE"
  list "$(ready Kustomization flux-system infrastructure True)" "$(ready Kustomization flux-system apps True)" >"$FAKE/kustomizations.json"
  list "$(ready OCIRepository flux-system flux-system True)" "$oci_helmrepo" >"$FAKE/ocirepositories.json"
  deployments source-controller:1:1 kustomize-controller:2:2 helm-controller:2:2 notification-controller:2:2 >"$FAKE/deployments.json"
  list "$healthy_pod" >"$FAKE/pods.json"
}
run() { set +e; KUBECTL="$tmp/kubectl" "$checker" --context prod-ctx >"$tmp/out" 2>"$tmp/err"; rc=$?; set -e; }
expect() { # <label> <rc> <line fragment>
  [ "$rc" -eq "$2" ] || { cat "$tmp/out" "$tmp/err" >&2; fail "$1: rc=$rc, want $2"; }
  grep -qF -- "$3" "$tmp/out" || { cat "$tmp/out" "$tmp/err" >&2; fail "$1: missing '$3'"; }
}

scenario healthy; run
expect "healthy cluster" 0 "PLATFORM-HEALTH=OK"
grep -qF flux-operator "$tmp/out" && fail "an OCI HelmRepository never reconciles, so it must not be reported"

# The 2026-08-27 shape: the GitOps loop deadlocked on DNS.
scenario outage
list "$(ready Kustomization flux-system infrastructure False BuildFailed)" "$(ready Kustomization flux-system apps True)" >"$FAKE/kustomizations.json"
list "$(ready OCIRepository flux-system flux-system False OCIArtifactPullFailed)" >"$FAKE/ocirepositories.json"
run
expect "failing Kustomization" 1 "FAILING Kustomization flux-system/infrastructure reason=BuildFailed"
expect "failing source" 1 "FAILING OCIRepository flux-system/flux-system reason=OCIArtifactPullFailed"
expect "outage verdict" 1 "PLATFORM-HEALTH=UNHEALTHY failing=2"
grep -qF "server misbehaving" "$tmp/out" && fail "condition messages can carry internal hostnames and must never be printed"

scenario helmrelease
list "$(ready HelmRelease kube-system cilium False UpgradeFailed)" >"$FAKE/ocirepositories.json"
run
expect "failing HelmRelease" 1 "FAILING HelmRelease kube-system/cilium reason=UpgradeFailed"

# 🔴 The crash loop, and the negative control: the phase filter a health check reaches for is blind.
scenario crashloop
list "$healthy_pod" "$crashloop_pod" >"$FAKE/pods.json"
phase_filtered="$(jq '[.items[] | select(.status.phase != "Running")] | length' "$FAKE/pods.json")"
[ "$phase_filtered" -eq 0 ] || fail "negative control: a phase-only filter was expected to see nothing, saw $phase_filtered"
run
expect "crash loop found by container state" 1 "FAILING Pod kube-system/hubble-relay-1 container=hubble-relay reason=CrashLoopBackOff restarts=49"

scenario pullback
list "$pullback_init" >"$FAKE/pods.json"
run
expect "image pull failure in an init container" 1 "FAILING Pod apps/web-1 container=migrate reason=ImagePullBackOff"

# Unknown is what every object reports mid-reconcile; it must never fail a tick during a deploy.
scenario progressing
list "$(ready Kustomization flux-system infrastructure Unknown Progressing)" >"$FAKE/kustomizations.json"
run
expect "reconciling is not failing" 0 "PROGRESSING Kustomization flux-system/infrastructure"

scenario suspended
printf '{"items":[{"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"apps"},"spec":{"suspend":true},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' >"$FAKE/kustomizations.json"
run
expect "a suspension is reported" 0 "SUSPENDED Kustomization flux-system/apps"

# Every way a read can fail is UNKNOWN, never healthy.
scenario refused
touch "$FAKE/kustomizations.fail"
run
expect "refused read" 2 "PLATFORM-HEALTH=UNKNOWN unreadable=1"

scenario empty
list >"$FAKE/kustomizations.json"
run
expect "no Kustomization at all" 2 "UNREADABLE kustomizations: the read returned nothing"

scenario nosources
list >"$FAKE/ocirepositories.json"
run
expect "no Flux source at all" 2 "UNREADABLE sources: the read returned nothing"

scenario nopods
list >"$FAKE/pods.json"
run
expect "no pod at all" 2 "UNREADABLE pods: the read returned nothing"

scenario garbage
printf 'error: You must be logged in to the server\n' >"$FAKE/pods.json"
run
expect "a non-JSON response" 2 "UNREADABLE pods: the response is not a list"

scenario notlist
printf '{"kind":"Status","status":"Failure"}' >"$FAKE/ocirepositories.json"
run
expect "a JSON response that is not a list" 2 "UNREADABLE sources: the response is not a list"

# A visibly broken surface is never masked by an unreadable one.
scenario mixed
touch "$FAKE/kustomizations.fail"
list "$crashloop_pod" >"$FAKE/pods.json"
run
expect "known failure beats an unknown" 1 "PLATFORM-HEALTH=UNHEALTHY failing=1"
grep -qF "UNREADABLE kustomizations" "$tmp/out" || fail "the unreadable surface must still be reported beside the failure"

# 🔴 A stored Ready=True outlives its controller: every object above stays green while nothing applies.
scenario controller-down
deployments source-controller:1:1 kustomize-controller:0:0 helm-controller:2:2 notification-controller:2:2 >"$FAKE/deployments.json"
run
expect "a controller scaled to zero" 1 "FAILING Deployment flux-system/kustomize-controller reason=scaled-to-zero"

scenario controller-missing
deployments source-controller:1:1 kustomize-controller:2:2 notification-controller:2:2 >"$FAKE/deployments.json"
run
expect "a deleted controller" 1 "FAILING Deployment flux-system/helm-controller reason=missing"

scenario controller-unavailable
deployments source-controller:1:0 kustomize-controller:2:2 helm-controller:2:2 notification-controller:2:2 >"$FAKE/deployments.json"
run
expect "a controller with no available replica" 1 "FAILING Deployment flux-system/source-controller reason=unavailable"

scenario neverpull
list '{"metadata":{"namespace":"apps","name":"web-2"},"status":{"phase":"Pending","containerStatuses":[{"name":"web","restartCount":0,"state":{"waiting":{"reason":"ErrImageNeverPull"}}}]}}' >"$FAKE/pods.json"
run
expect "an image that may never be pulled" 1 "FAILING Pod apps/web-2 container=web reason=ErrImageNeverPull"

# One malformed object must neither pass as healthy nor hide a failing object after it.
malformed_ks='{"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"odd"},"status":{"conditions":"not-a-list"}}'
scenario malformed
list "$malformed_ks" "$(ready Kustomization flux-system apps True)" >"$FAKE/kustomizations.json"
run
expect "a malformed object is unknown" 2 "MALFORMED kustomizations flux-system/odd"

scenario malformed-then-failing
list "$malformed_ks" "$(ready Kustomization flux-system infrastructure False BuildFailed)" >"$FAKE/kustomizations.json"
run
expect "a failing object after a malformed one is still found" 1 "FAILING Kustomization flux-system/infrastructure reason=BuildFailed"

# Without --context the context is resolved through the SAME kubectl override, choosing the scoped one.
runresolve() { set +e; KUBECTL="$tmp/kubectl" "$checker" >"$tmp/out" 2>"$tmp/err"; rc=$?; set -e; }
scenario resolve
runresolve
expect "the context resolves through the kubectl override" 0 "PLATFORM-HEALTH=OK"

scenario resolve-fails
touch "$FAKE/config.fail"
runresolve
expect "an unreadable kubeconfig is unknown" 2 "PLATFORM-HEALTH=UNKNOWN (no prod context resolved)"

echo "platform-live-health test: OK"
