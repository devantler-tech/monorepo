#!/usr/bin/env bash
# prod-kube-context.sh — resolve the kube context an agent-host definition should read prod through.
#
# WHY THIS EXISTS (monorepo#3122)
#   Agent-host definitions used to hard-code `--context admin@prod`. That context does not exist on
#   this host, so every live-cluster read failed at its first command -- including the live-security
#   surveyor, whose whole point is that a broken-but-silent scanner is never mistaken for a clean
#   cluster.
#
#   Renaming the literal would fix today and re-break on the next kubeconfig change, so this
#   resolves the context instead of naming it. Two properties matter more than convenience:
#
#   1. PREFER LEAST PRIVILEGE. `admin@prod` is the break-glass admin context; `oidc@prod` is the
#      scoped one. Routine agent reads must land on the scoped credential even when both are
#      present, per the host least-privilege rule in AGENTS.md. Pinning definitions to the admin
#      context would quietly hand every survey admin rights it does not need.
#   2. FAIL CLOSED, NEVER GUESS. Picking "the first prod-ish context" would look like it worked
#      while reading the cluster through whichever credential happened to be listed first. An
#      unresolvable kubeconfig is an UNKNOWN the caller must see, not a default to fall back on.
#
#   The CI copies under platform/scripts/** are deliberately NOT in scope: they run where the
#   KUBE_CONFIG secret supplies exactly `admin@prod`, and that is correct there.
#
# USAGE
#   prod-kube-context.sh [--cluster prod] [--input <kubectl-config-view-json>]
#
#   Prints the resolved context name on stdout and exits 0. On any failure it prints nothing on
#   stdout -- so `ctx=$(prod-kube-context.sh) || exit` can never continue with a bogus context --
#   and explains the fix on stderr.
#
#   --input takes a `kubectl config view -o json` payload from a file instead of running kubectl.
#   It exists for the tests; nothing in normal operation needs it.
#
# READ-ONLY by construction: it only ever reads kubeconfig metadata. It never contacts a cluster and
# never prints credentials -- only context names, which are already public in monorepo#3122.
#
# EXIT CODES
#   0  a single context resolved; its name is on stdout
#   2  UNKNOWN -- unreadable input, no candidate, or an ambiguous one. Never treat as a default.

set -uo pipefail

CLUSTER="prod"
INPUT=""

die() { printf 'prod-kube-context: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) [ $# -ge 2 ] || die "--cluster needs a value"; CLUSTER="$2"; shift 2 ;;
    --input)   [ $# -ge 2 ] || die "--input needs a value";   INPUT="$2";   shift 2 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"

if [ -n "$INPUT" ]; then
  [ -f "$INPUT" ] || die "input file not found: $INPUT (expected a 'kubectl config view -o json' payload)"
  raw=$(cat -- "$INPUT") || die "could not read input file: $INPUT"
else
  raw=$(kubectl config view -o json 2>/dev/null) || die "could not read the kubeconfig; check 'kubectl config view' works for this user"
fi

# A malformed payload must be UNKNOWN, never an empty candidate list -- those are different facts
# and only one of them is safe to report as "no prod context".
printf '%s' "$raw" | jq -e . >/dev/null 2>&1 \
  || die "kubeconfig did not parse as JSON; check 'kubectl config view -o json' output"

candidates=$(printf '%s' "$raw" | jq -r --arg c "$CLUSTER" '
  (.contexts // [])
  | map(select((.context.cluster // "") == $c))
  | .[]
  | "\(.name)\t\(.context.user // "")"
') || die "could not enumerate contexts; check 'kubectl config view -o json' output"

if [ -z "$candidates" ]; then
  die "no context targets cluster '$CLUSTER'. List what exists with 'kubectl config get-contexts', then add or rename one."
fi

total=$(printf '%s\n' "$candidates" | grep -c . )

# The scoped tier is identified by its CREDENTIAL (authinfo), not by the context's display name:
# the name is cosmetic and can be set to anything, while the user is what actually decides the
# privilege the read runs with.
scoped=$(printf '%s\n' "$candidates" | awk -F'\t' 'tolower($2) ~ /^oidc/ { print $1 }')
scoped_n=$(printf '%s\n' "$scoped" | grep -c . )

if [ "$scoped_n" -eq 1 ]; then
  printf '%s\n' "$scoped"
  exit 0
fi

if [ "$scoped_n" -gt 1 ]; then
  die "cluster '$CLUSTER' has $scoped_n scoped (oidc) contexts and no basis to choose between them: $(printf '%s' "$scoped" | tr '\n' ' '). Resolve with 'kubectl config get-contexts' and pass --cluster, or remove the duplicate."
fi

if [ "$total" -eq 1 ]; then
  printf '%s\n' "$(printf '%s\n' "$candidates" | awk -F'\t' '{ print $1 }')"
  exit 0
fi

die "cluster '$CLUSTER' has $total contexts and none uses a scoped (oidc) credential, so there is no least-privilege choice to make: $(printf '%s' "$candidates" | awk -F'\t' '{ print $1 }' | tr '\n' ' '). Inspect them with 'kubectl config get-contexts' and remove or rename the ones this host should not use."
