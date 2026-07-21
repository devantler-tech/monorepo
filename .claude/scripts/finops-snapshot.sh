#!/usr/bin/env bash
# finops-snapshot.sh — READ-ONLY cost snapshot for the FinOps engineer.
#
# Prints ONE fixed-shape digest of where platform money goes, so a run starts
# from a measurement instead of an impression. Raw JSON never reaches the
# agent's context; only the digest does.
#
# Usage: finops-snapshot.sh [--window 3d] [--context admin@prod] [--top N] [--no-port-forward]
#
# READ-ONLY by construction: it GETs the OpenCost API and `kubectl get`s. It
# never applies, patches, scales or deletes. The only side effect is a
# port-forward it opens and closes itself.
#
# Shaping is jq, never python — AGENTS.md makes bash-or-Go constitutional, and
# jq is already this repo's JSON tool (see agent-telemetry.sh).
#
# ⚠️ WINDOW: default 3d, deliberately short. OpenCost has been OOM-killed by 14d
#    allocation queries on this cluster. Widen only on purpose.
#
# ⚠️ WHAT THIS IS NOT: OpenCost models in-cluster CPU/RAM/storage/egress from a
#    hand-derived price table. The load balancer, floating IP, cloud volumes,
#    object storage and domains are NOT in it, and neither is any other cloud.
#    This digest attributes cost; it is NOT an invoice. Every figure it prints
#    is MODELLED. The footer says so on every run, because a number that travels
#    without its provenance eventually gets quoted as one that has it.
set -uo pipefail

WINDOW="3d"; CONTEXT="admin@prod"; TOP="12"; PF=1; PORT="19003"
NS="opencost"; SVC="svc/opencost"; API_PORT="9003"

die() { printf 'finops-snapshot: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --window)  [ $# -ge 2 ] || die "--window needs a value"; WINDOW="$2"; shift 2 ;;
    --context) [ $# -ge 2 ] || die "--context needs a value"; CONTEXT="$2"; shift 2 ;;
    --top)     [ $# -ge 2 ] || die "--top needs a value"; TOP="$2"; shift 2 ;;
    --port)    [ $# -ge 2 ] || die "--port needs a value"; PORT="$2"; shift 2 ;;
    --no-port-forward) PF=0; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$WINDOW" in ''|*[!0-9dhwm]*) die "--window must look like 3d / 24h / 1w (got: $WINDOW)" ;; esac
case "$TOP" in ''|*[!0-9]*) die "--top must be a positive integer (got: $TOP)" ;; esac

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v jq      >/dev/null 2>&1 || die "jq not found"
command -v curl    >/dev/null 2>&1 || die "curl not found"

# Days in the window, for the /month projection. Pure shell arithmetic on the
# suffix; awk only for the fractional hour case.
WNUM="${WINDOW%[dhwm]}"; WSUF="${WINDOW##*[0-9]}"
case "$WSUF" in
  d) DAYS="$WNUM" ;;
  w) DAYS=$(awk -v n="$WNUM" 'BEGIN{printf "%.6f", n*7}') ;;
  m) DAYS=$(awk -v n="$WNUM" 'BEGIN{printf "%.6f", n*30}') ;;
  h) DAYS=$(awk -v n="$WNUM" 'BEGIN{printf "%.6f", n/24}') ;;
  *) DAYS="$WNUM" ;;
esac
SCALE=$(awk -v d="$DAYS" 'BEGIN{ if (d>0) printf "%.6f", 30/d; else print 0 }')

PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; return 0; }
# Registered BEFORE the port-forward starts, so a signal mid-setup still reaps it.
trap cleanup EXIT HUP INT TERM

BASE="http://localhost:${PORT}"
if [ "$PF" -eq 1 ]; then
  kubectl --context "$CONTEXT" -n "$NS" port-forward "$SVC" "${PORT}:${API_PORT}" >/dev/null 2>&1 &
  PF_PID=$!
  # Poll for readiness rather than sleeping a fixed guess. A loopback probe
  # against a process we started ourselves is the contract-permitted local
  # timer, not a remote busy-wait.
  ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf -o /dev/null --max-time 2 "${BASE}/allocation/compute?window=1h" 2>/dev/null; then
      ready=1; break
    fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "OpenCost API unreachable on ${BASE} (cluster reachable? opencost running?)"
fi

ALLOC=$(curl -sf --max-time 60 \
  "${BASE}/allocation/compute?window=${WINDOW}&aggregate=namespace&accumulate=true" 2>/dev/null)
[ -n "$ALLOC" ] || die "empty response from the OpenCost allocation API — treat as UNMEASURED, never as zero"

# Validate the SHAPE before trusting any number. A malformed payload must fail
# loudly: a clean-looking 0.00 from a broken measurement is the most dangerous
# output this script could produce.
printf '%s' "$ALLOC" | jq -e '.data[0] | type == "object"' >/dev/null 2>&1 \
  || die "malformed OpenCost payload (no .data[0] object) — UNMEASURED, not zero"

echo "════════════════════════════════════════════════════════════════"
echo " FINOPS SNAPSHOT — window ${WINDOW} — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo " context: ${CONTEXT}   source: OpenCost (MODELLED, not an invoice)"
echo "════════════════════════════════════════════════════════════════"
echo
echo "── COST BY NAMESPACE ────────────────────────────────────────────"

# jq emits TSV; awk formats. Splitting shaping from formatting keeps the jq
# readable and the columns actually aligned (hand-rolled padding inside jq
# string interpolation was both unreadable and wrong).
ROWS=$(printf '%s' "$ALLOC" | jq -r '
  # Normalise once: every downstream section reads these fields, and a missing
  # key must become 0 here rather than `null` propagating into arithmetic.
  .data[0] | to_entries[] | select(.value | type == "object")
  | [ .key,
      (.value.totalCost             // 0), (.value.cpuCost   // 0),
      (.value.ramCost               // 0), (.value.pvCost    // 0),
      (.value.networkCost           // 0), (.value.loadBalancerCost // 0),
      (.value.cpuEfficiency         // 0), (.value.ramEfficiency    // 0),
      (.value.cpuCoreRequestAverage // 0), (.value.cpuCoreUsageAverage // 0),
      (.value.pvBytes               // 0) ]
  | @tsv') || die "failed to shape the OpenCost payload — treat this run as UNMEASURED"

[ -n "$ROWS" ] || die "OpenCost returned no namespaces — UNMEASURED, not zero cost"

printf '%s\n' "$ROWS" | sort -t"$(printf '\t')" -k2 -gr | awk -F'\t' -v top="$TOP" -v scale="$SCALE" '
{
  n++; name[n]=$1; tot[n]=$2; cpu[n]=$3; ram[n]=$4; pv[n]=$5; net[n]=$6; lb[n]=$7;
  ceff[n]=$8; reff[n]=$9; creq[n]=$10; cuse[n]=$11; pvb[n]=$12;
  grand+=$2; scpu+=$3; sram+=$4; spv+=$5; snet+=$6; slb+=$7; suse+=$11; spvb+=$12;
}
END {
  printf "  %-26s %9s %10s %7s %8s %8s\n", "namespace", "total", "/mo proj", "share", "cpu-eff", "ram-eff";
  shown=0;
  for (i=1; i<=n && i<=top; i++) {
    share = (grand>0) ? tot[i]/grand*100 : 0; shown += tot[i];
    printf "  %-26.26s %9.3f %10.2f %6.1f%% %7.1f%% %7.1f%%\n",
           name[i], tot[i], tot[i]*scale, share, ceff[i]*100, reff[i]*100;
  }
  printf "  %s\n", "──────────────────────────────────────────────────────────────";
  printf "  %-26s %9.3f %10.2f   ← projected monthly, MODELLED\n", "TOTAL (" n " namespaces)", grand, grand*scale;
  if (n > top) printf "  (%d smaller namespaces omitted, %.3f combined — NOT dropped from the total)\n", n-top, grand-shown;

  printf "\n── COST COMPOSITION ─────────────────────────────────────────────\n";
  split("cpu ram storage network loadbalancer", lab, " ");
  v[1]=scpu; v[2]=sram; v[3]=spv; v[4]=snet; v[5]=slb;
  for (i=1; i<=5; i++)
    printf "  %-14s %9.3f  %5.1f%%%s\n", lab[i], v[i], (grand>0? v[i]/grand*100 : 0),
           (v[i]==0 && (i==3 || i==5) ? "   ⚠️ zero — see gaps below" : "");

  printf "\n── RIGHTSIZING CANDIDATES (requested >> used) ───────────────────\n";
  # 🔴 VACUITY GUARD. If NOTHING reports usage, cpuEfficiency is 0 everywhere and
  # the filter matches every namespace — a list that flags everything flags
  # nothing, and would have the agent confidently "rightsize" the whole cluster
  # from a broken signal. Detect the dead sensor and refuse to emit candidates.
  if (suse == 0) {
    printf "  🔴 UNMEASURABLE THIS RUN — usage metrics are absent for EVERY namespace\n";
    printf "     (cpuCoreUsageAverage sums to 0 across all %d). That is a BROKEN\n", n;
    printf "     SENSOR, not an idle cluster: OpenCost is not receiving usage data\n";
    printf "     from Prometheus. Rightsizing cannot be assessed until it is fixed,\n";
    printf "     and any candidate list built from this would be an artefact.\n";
    printf "     → Treat fixing the metrics path as the prerequisite work.\n";
  } else {
    c=0;
    for (i=1; i<=n; i++)
      if (creq[i] > 0.05 && ceff[i] < 0.25 && tot[i] > 0.01 && c < top) {
        c++;
        printf "  %-26.26s req %7.3f cores  used %7.3f  eff %5.1f%%  %7.2f/mo\n",
               name[i], creq[i], cuse[i], ceff[i]*100, tot[i]*scale;
      }
    if (c == 0) printf "  (none at this threshold)\n";
    printf "  NOTE: a CANDIDATE, not a verdict. Headroom is not waste — bursty and\n";
    printf "        failover capacity look idle BY DESIGN, and the lifestyle floor\n";
    printf "        protects several of them outright. Confirm against Prometheus.\n";
  }

  printf "\n── STORAGE ──────────────────────────────────────────────────────\n";
  if (spvb == 0) { printf "  (no persistent volumes attributed)\n"; }
  else {
    # Same vacuity shape as above: bytes present but every price zero means
    # storage is UNPRICED, not free. Say which, or a reader concludes "free".
    if (spv == 0)
      printf "  ⚠️ %.0f GB attributed but pvCost is 0 for ALL of it — storage is\n     UNPRICED in this model, NOT free. Volumes are billed by the provider.\n", spvb/1e9;
    printf "  (ordered by namespace COST, not by size)\n";
    s=0;
    for (i=1; i<=n && s<top; i++)
      if (pvb[i] > 0) { s++; printf "  %-26.26s %8.2f GB   pvCost %8.3f\n", name[i], pvb[i]/1e9, pv[i]; }
  }
}'

echo
echo "── PROVIDER SURFACE OPENCOST CANNOT SEE ─────────────────────────"
LBJSON=$(kubectl --context "$CONTEXT" get svc -A -o json 2>/dev/null)
if [ -n "$LBJSON" ]; then
  printf '%s' "$LBJSON" | jq -r '
    [ .items[] | select(.spec.type == "LoadBalancer") ] as $lb
    | "  LoadBalancer services ..... \($lb|length)  (each may back a billable cloud LB)",
      ( $lb[:8][] | "    - \(.metadata.namespace)/\(.metadata.name)" )
  ' 2>/dev/null || echo "  (LB shaping failed — UNMEASURED)"
else
  echo "  (svc query failed — UNMEASURED, not zero)"
fi

# Released/unbound PVs are the classic orphan: nothing claims them, they keep
# billing. Reported as CANDIDATES only — deleting one is a data decision.
PVJSON=$(kubectl --context "$CONTEXT" get pv -o json 2>/dev/null)
if [ -n "$PVJSON" ]; then
  printf '%s' "$PVJSON" | jq -r '
    [ .items[] | select(.status.phase == "Released" or .status.phase == "Available" or .status.phase == "Failed") ] as $o
    | "  Unbound/released PVs ...... \($o|length)  (orphan candidates — verify before ANY deletion)",
      ( $o[:8][] | "    - \(.metadata.name)  \(.spec.capacity.storage // "?")  \(.status.phase)" )
  ' 2>/dev/null || echo "  (PV shaping failed — UNMEASURED)"
else
  echo "  (pv query failed — UNMEASURED, not zero)"
fi

cat <<'FOOTER'

── PROVENANCE (read before quoting any number above) ────────────────
  MODELLED, NOT BILLED. Every figure comes from OpenCost's hand-derived
  price table, not from the provider. Treat it as ATTRIBUTION — which
  workload, which driver, which trend — never as an invoice.
  Known measurement gaps, all real:
    - unit prices are static, hand-derived and duplicated in 3 places
      that must stay in lockstep; the FX rate is frozen at a fixed date
    - load balancer, floating IP, cloud volumes, object storage and
      domains are OUTSIDE the model entirely
    - CI clusters in other clouds are wholly unobserved
    - cpuEfficiency 0 can mean "no usage metrics", not "idle"
  A saving is REALISED only when the provider's bill agrees. Until the
  billing API is wired, projected-vs-realised cannot be closed here.
FOOTER
