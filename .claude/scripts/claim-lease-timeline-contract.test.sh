#!/usr/bin/env bash
#
# Guards the assignee lease-clock read in Claim protocol (monorepo#2798).
#
# The prescribed command used to be `gh api …/timeline --paginate --jq … | sort | tail -1`. When
# `gh api` fails, that pipeline prints nothing and exits 0 (the status is `tail`'s), so a server
# error reads exactly like "never assigned". Every assignment-timing surface returned HTTP 500 for
# `platform` alone on 2026-08-12.
#
# This test does not pin prose: it extracts the prescribed snippet from AGENTS.md and RUNS it
# against a fake `gh`, so a snippet that fails open is caught whatever its wording.
#   1. a failed read exits non-zero and prints no lease (UNKNOWN, never "unassigned");
#   2. a successful read across two pages yields the newest assignment (max, not per-page last);
#   3. a successful empty read exits 0 with an empty lease (genuinely unassigned).
#   4. ABLATION: the same snippet with `set -o pipefail` removed must fail property 1, so the test
#      proves it can see the defect it guards against.

# shellcheck disable=SC2016 # ${lease} is expanded by the generated snippet, not here
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${AGENTS_FILE:-${repo_root}/AGENTS.md}"

fail() {
  echo "claim-lease timeline contract: FAIL — $*" >&2
  exit 1
}

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# The fenced sh block that follows the "Lease clock for the assignee" bullet.
snippet="$(awk '
  /Lease clock for the assignee/        { seen = 1; next }
  seen && !inside && /^[[:space:]]*```sh/ { inside = 1; next }
  inside && /^[[:space:]]*```/          { exit }
  inside                                { print }
' "${constitution}")"
[ -n "${snippet}" ] || fail "no sh block after 'Lease clock for the assignee' in ${constitution}"
grep -Fq 'issues/<n>/timeline' <<<"${snippet}" || fail "the lease snippet no longer reads the timeline"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# A fake gh: FAKE_GH_MODE=fail exits 1; pages prints two pages' worth of filtered lines out of
# order; empty prints nothing. It emulates `gh api --paginate --jq` output, one match per line.
mkdir -p "${tmp}/bin"
cat >"${tmp}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "${FAKE_GH_MODE}" in
  fail) echo "HTTP 500: Server Error" >&2; exit 1 ;;
  pages) printf '%s\n' 2026-09-02T03:08:23Z 2026-08-01T10:00:00Z 2026-09-20T23:06:00Z 2026-08-15T00:00:00Z ;;
  empty) : ;;
esac
FAKE
chmod +x "${tmp}/bin/gh"

# Run a snippet with the placeholders filled, then print the lease it computed.
run() { # <snippet> <mode>
  printf '%s\nprintf "LEASE=%%s\\n" "${lease}"\n' "$1" |
    sed -e 's#<o>/<r>#devantler-tech/platform#' -e 's#<n>#2838#' >"${tmp}/snippet.sh"
  FAKE_GH_MODE="$2" PATH="${tmp}/bin:${PATH}" bash "${tmp}/snippet.sh" 2>"${tmp}/err"
}

# 1. Failed read → non-zero, no lease printed.
if out="$(run "${snippet}" fail)"; then
  fail "a failed timeline read exited 0 (printed: ${out:-nothing}) — it must read as UNKNOWN"
fi
grep -q '^LEASE=' <<<"${out}" && fail "a failed timeline read still produced a lease: ${out}"

# 2. Two pages → the newest assignment.
out="$(run "${snippet}" pages)" || fail "a successful read exited non-zero: $(cat "${tmp}/err")"
[ "${out}" = "LEASE=2026-09-20T23:06:00Z" ] || fail "expected the newest assignment, got: ${out}"

# 3. Successful empty read → unassigned, exit 0.
out="$(run "${snippet}" empty)" || fail "a successful empty read exited non-zero"
[ "${out}" = "LEASE=" ] || fail "a successful empty read must yield an empty lease, got: ${out}"

# 4. Ablation: without pipefail the failed read must pass through as exit 0 — proving property 1
#    detects the defect rather than passing vacuously.
ablated="$(grep -v 'set -o pipefail' <<<"${snippet}")"
[ "${ablated}" != "${snippet}" ] || fail "ablation removed nothing — the snippet has no 'set -o pipefail'"
if ! run "${ablated}" fail >/dev/null; then
  fail "ablation did not fire: the snippet without pipefail should exit 0 on a failed read"
fi

echo "claim-lease timeline contract: OK"
