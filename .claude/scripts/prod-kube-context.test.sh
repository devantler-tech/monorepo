#!/usr/bin/env bash
# prod-kube-context.test.sh — RED/GREEN coverage for the prod kube-context resolver.
#
# The defect this guards against is an agent-host definition naming a context that either does not
# exist or is the wrong PRIVILEGE TIER (monorepo#3122). Both failure directions matter, and they are
# not symmetric:
#
#   * Resolving to NOTHING is loud and cheap -- the caller sees a clear error and stops.
#   * Resolving to the BREAK-GLASS ADMIN context when a least-privilege one exists is silent and
#     expensive: every routine read the agent makes would run with admin credentials, against the
#     host least-privilege rule. That is the assertion this file weights most heavily.
#
# So the resolver must PREFER the least-privilege context and FAIL CLOSED on anything it cannot
# resolve unambiguously. Guessing is never acceptable: a wrong context that happens to work is how
# an agent silently acquires more privilege than its mandate needs.
#
# Fixtures are hand-built `kubectl config view -o json` payloads passed through the --input seam.
# No kubectl, no kubeconfig, no network, no host state.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/prod-kube-context.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
asserts=0
note_fail() { echo "FAIL: $1" >&2; fails=$(( fails + 1 )); }

# payload <file> <json>
payload() { printf '%s\n' "$2" >"$TMP/$1"; printf '%s' "$TMP/$1"; }

# run_case <name> <input-file> <want-rc> <want-stdout>
# want-stdout of "" asserts stdout is EMPTY -- a fail-closed path must never emit a context name a
# caller could go on to use.
run_case() {
  local name=$1 input=$2 want_rc=$3 want_out=$4
  asserts=$(( asserts + 1 ))
  local out rc
  set +e
  out=$("$SCRIPT" --input "$input" 2>"$TMP/err.$asserts"); rc=$?
  set -e
  if [ "$rc" != "$want_rc" ]; then
    note_fail "$name: exit $rc, want $want_rc (stderr: $(tr '\n' ' ' <"$TMP/err.$asserts"))"
    return
  fi
  if [ "$out" != "$want_out" ]; then
    note_fail "$name: stdout '$out', want '$want_out'"
    return
  fi
  # Every fail-closed exit must say what to DO, not merely that it failed. A guard that blocks
  # without naming the fix trains the reader to route around it.
  if [ "$want_rc" != "0" ] && ! grep -q 'kubectl config' "$TMP/err.$asserts"; then
    note_fail "$name: fail-closed message does not name an actionable next step"
  fi
}

# ---------------------------------------------------------------------------
# 1. The measured host shape (monorepo#3122): exactly one prod context, OIDC.
# ---------------------------------------------------------------------------
run_case "single oidc context resolves" "$(payload single '{
  "contexts":[{"name":"oidc@prod","context":{"cluster":"prod","user":"oidc-prod"}}]
}')" 0 "oidc@prod"

# ---------------------------------------------------------------------------
# 2. THE LOAD-BEARING ONE. Both tiers present -> the least-privilege one wins.
#    If this ever regresses to admin@prod, the agent silently gains admin on every read.
# ---------------------------------------------------------------------------
run_case "prefers least-privilege over break-glass admin" "$(payload both '{
  "contexts":[
    {"name":"admin@prod","context":{"cluster":"prod","user":"admin-prod"}},
    {"name":"oidc@prod","context":{"cluster":"prod","user":"oidc-prod"}}
  ]
}')" 0 "oidc@prod"

# Order must not decide it -- same fixture, admin listed second.
run_case "preference is not an artifact of list order" "$(payload both_rev '{
  "contexts":[
    {"name":"oidc@prod","context":{"cluster":"prod","user":"oidc-prod"}},
    {"name":"admin@prod","context":{"cluster":"prod","user":"admin-prod"}}
  ]
}')" 0 "oidc@prod"

# ---------------------------------------------------------------------------
# 3. Fail closed: nothing for this cluster.
# ---------------------------------------------------------------------------
run_case "no prod context fails closed" "$(payload none '{
  "contexts":[{"name":"oidc@staging","context":{"cluster":"staging","user":"oidc-staging"}}]
}')" 2 ""

run_case "empty context list fails closed" "$(payload empty '{"contexts":[]}')" 2 ""

run_case "absent contexts key fails closed" "$(payload nokey '{}')" 2 ""

# ---------------------------------------------------------------------------
# 4. Fail closed: ambiguous. Two equally-privileged prod contexts and no basis
#    to choose -> refuse, rather than pick the first and look successful.
# ---------------------------------------------------------------------------
run_case "ambiguous non-oidc candidates fail closed" "$(payload ambig '{
  "contexts":[
    {"name":"admin@prod","context":{"cluster":"prod","user":"admin-prod"}},
    {"name":"backup@prod","context":{"cluster":"prod","user":"backup-prod"}}
  ]
}')" 2 ""

# ...and ambiguity WITHIN the preferred tier is still ambiguity.
run_case "two oidc candidates fail closed" "$(payload ambig_oidc '{
  "contexts":[
    {"name":"oidc@prod","context":{"cluster":"prod","user":"oidc-prod"}},
    {"name":"oidc2@prod","context":{"cluster":"prod","user":"oidc-prod-2"}}
  ]
}')" 2 ""

# ---------------------------------------------------------------------------
# 5. Fail closed: malformed / unreadable input. An unparseable kubeconfig must
#    never read as "no contexts" and must never read as success.
# ---------------------------------------------------------------------------
run_case "malformed json fails closed" "$(payload bad 'not json at all')" 2 ""

asserts=$(( asserts + 1 ))
set +e
out=$("$SCRIPT" --input "$TMP/definitely-absent" 2>/dev/null); rc=$?
set -e
[ "$rc" = "2" ] && [ -z "$out" ] || note_fail "missing input file: exit $rc out '$out', want exit 2 and empty stdout"

# ---------------------------------------------------------------------------
# 6. Negative control. The ambiguity guard must be firing for the RIGHT reason:
#    disambiguate the fixture from case 4 and it must now SUCCEED. Without this,
#    a resolver that failed closed unconditionally would pass every case above.
# ---------------------------------------------------------------------------
run_case "NEGATIVE CONTROL: disambiguated fixture succeeds" "$(payload disambig '{
  "contexts":[
    {"name":"admin@prod","context":{"cluster":"prod","user":"admin-prod"}},
    {"name":"backup@staging","context":{"cluster":"staging","user":"backup-staging"}}
  ]
}')" 0 "admin@prod"

# ---------------------------------------------------------------------------
# 7. --cluster is honoured, so the resolver is not hard-wired to one cluster name.
# ---------------------------------------------------------------------------
asserts=$(( asserts + 1 ))
set +e
out=$("$SCRIPT" --input "$(payload multi '{
  "contexts":[
    {"name":"oidc@prod","context":{"cluster":"prod","user":"oidc-prod"}},
    {"name":"oidc@staging","context":{"cluster":"staging","user":"oidc-staging"}}
  ]
}')" --cluster staging 2>/dev/null); rc=$?
set -e
[ "$rc" = "0" ] && [ "$out" = "oidc@staging" ] || note_fail "--cluster staging: exit $rc out '$out', want 0 and oidc@staging"

echo "prod-kube-context.test.sh: $asserts assertion(s), $fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
