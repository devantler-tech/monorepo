#!/usr/bin/env bash
# shellcheck disable=SC2016 # The awk programs handed to mutate are literal awk source.
# rule-sensor-inventory.test.sh — self-test for rule-sensor-inventory.sh (monorepo#4284).
#
# Runs the checker against the real repository first (every committed inventory must be valid and
# report a prose-only share), then against a planted fixture: one valid inventory, and one mutation
# per refusal, so each check is shown to fire and the valid shape is shown to pass. The empty cases
# (no inventory, no rows, a guide with no rule) must exit 2, never 0.
#
# Exit codes: 0 every assertion held · 1 an assertion failed
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/../.." && pwd)
checker="${script_dir}/rule-sensor-inventory.sh"

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# expect <name> <exit code> <stderr substring or -> <args...>
expect() {
  local name="$1" want="$2" needle="$3" rc=0
  shift 3
  "${TEST_BASH:-bash}" "$checker" "$@" >"$work/out" 2>"$work/err" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    fail "$name: exit $rc, want $want ($(head -c 300 "$work/err"))"
  elif [ "$needle" != "-" ] && ! awk -v n="$needle" 'index($0, n) { found = 1 } END { exit !found }' "$work/err"; then
    fail "$name: stderr lacks \"$needle\" ($(head -c 300 "$work/err"))"
  else
    pass "$name"
  fi
}

# --- the committed inventories ---------------------------------------------------------------
expect "repository inventories are valid" 0 - --root "$repo_root" --check
expect "repository report runs" 0 - --root "$repo_root" --report
if awk -F'\t' '$1 == "merge-policy.md" && $2 ~ /^rules=[1-9]/ && $3 ~ /^prose-only=[0-9]+ \([0-9]+%\)$/ { found = 1 } END { exit !found }' "$work/out"; then
  pass "report gives merge-policy.md a rule count and prose-only share"
else
  fail "report lacks a merge-policy.md line: $(cat "$work/out")"
fi

# --- a planted fixture -------------------------------------------------------------------------
fx="$work/fx"
mkdir -p "$fx/.claude/guides" "$fx/.claude/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'echo "refuses main"' > "$fx/.claude/scripts/demo-guard.sh"
cat > "$fx/.claude/guides/demo.md" <<'EOF'
# Demo guide

## First section

Agents must run the helper
before merging. This sentence states nothing.

- Never push to main directly.
- A list item with no rule.

```sh
# never inside a fence is a rule
```

## Second section

The always-on core is described here. Reviewers never re-approve a stale head.

| a | table row that must be read |

> Quoted text that must
> stay.
EOF
valid=$(cat <<'EOF'
# a comment line
id	section	quote	kind	control	evidence
DG-001	first-section	Agents must run the helper before	computational	.claude/scripts/demo-guard.sh	refuses main
DG-002	first-section	Never push to main directly	none	-	-
DG-003	second-section	Reviewers never re-approve	narrative	-	-
DG-004	second-section	table row that must be read	runtime	.claude/scripts/demo-guard.sh	refuses main
DG-005	second-section	Quoted text that must stay	inferential	.claude/scripts/demo-guard.sh	refuses main
EOF
)
inv="$fx/.claude/guides/demo.sensors.tsv"
plant() { printf '%s\n' "$1" > "$inv"; }

plant "$valid"
expect "valid fixture passes" 0 - --root "$fx" --check
expect "valid fixture reports" 0 - --root "$fx" --report
want_report=$(printf 'demo.md\trules=4\tprose-only=1 (25%%)\tcomputational=1\truntime=1\tinferential=1\tnarrative=1')
if [ "$(cat "$work/out")" = "$want_report" ]; then pass "report counts each kind, narrative apart"; else fail "report: $(cat "$work/out")"; fi

expect "extract runs" 0 - --extract "$fx/.claude/guides/demo.md"
if [ "$(awk 'END { print NR }' "$work/out")" = 5 ]; then pass "extract finds exactly the five rule sentences"; else fail "extract: $(cat "$work/out")"; fi
if awk 'index($0, "inside a fence") || index($0, "always-on") || index($0, "states nothing") { bad = 1 } END { exit bad }' "$work/out"; then
  pass "code fences, hyphenated compounds and plain sentences are not rules"
else
  fail "extract kept a non-rule: $(cat "$work/out")"
fi
if awk -F'\t' '$1 == "first-section" && $2 == 5 && $3 == "Agents must run the helper before merging." { found = 1 } END { exit !found }' "$work/out"; then
  pass "wrapped lines join and the section is the heading anchor"
else
  fail "extract shape: $(cat "$work/out")"
fi

mutate() { printf '%s\n' "$valid" | awk -F'\t' -v OFS='\t' "$1" > "$inv"; }

mutate '$1 == "DG-001" { $3 = "Agents must run the missing helper" } { print }'
expect "dangling quote is refused" 1 "dangling anchor" --root "$fx" --check
mutate '$1 == "DG-001" { $2 = "second-section" } { print }'
expect "wrong section is refused" 1 "not #second-section" --root "$fx" --check
mutate '$1 == "DG-001" { $5 = ".claude/scripts/absent.sh" } { print }'
expect "missing control is refused" 1 "does not exist" --root "$fx" --check
mutate '$1 == "DG-001" { $6 = "nothing like this" } { print }'
expect "control without its evidence is refused" 1 "does not contain its evidence" --root "$fx" --check
mutate '$1 != "DG-002" { print }'
expect "uncovered rule is refused" 1 "is not in the inventory" --root "$fx" --check
mutate '$1 == "DG-001" { $3 = "must" } { print }'
expect "ambiguous quote is refused" 1 "occurs in" --root "$fx" --check
mutate '$1 == "DG-001" { $3 = "This sentence states nothing" } { print }'
expect "a quote of a non-rule is refused" 1 "not a rule" --root "$fx" --check
mutate '$1 == "DG-001" { $4 = "manual" } { print }'
expect "unknown kind is refused" 1 "unknown kind" --root "$fx" --check
mutate '$1 == "DG-002" { $5 = ".claude/scripts/demo-guard.sh"; $6 = "refuses main" } { print }'
expect "kind none with a control is refused" 1 "takes control and evidence" --root "$fx" --check
mutate '{ print } $1 == "DG-002" { print "DG-002", $2, $3, "computational", ".claude/scripts/demo-guard.sh", "refuses main" }'
expect "kind none plus a control row is refused" 1 "and also given a control" --root "$fx" --check
mutate '{ print } $1 == "DG-001" { print "DG-001", $2, "Never push to main directly", $4, $5, $6 }'
expect "an id repeated with another quote is refused" 1 "repeats with a different" --root "$fx" --check
mutate '$1 == "DG-001" { $5 = "scripts/demo-guard.sh" } { print }'
expect "control outside .claude/ or .github/ is refused" 1 "control must be a path under" --root "$fx" --check
mutate '$1 == "DG-001" { $5 = ".claude/../.claude/scripts/demo-guard.sh" } { print }'
expect "control with a parent step is refused" 1 "control must be a path under" --root "$fx" --check
mutate '$1 == "DG-001" { $4 = "computational"; $5 = "-" } { print }'
expect "control kind without a path is refused" 1 "needs a control path" --root "$fx" --check
mutate '$1 == "id" { $1 = "rule" } { print }'
expect "wrong header is refused" 1 "header must be" --root "$fx" --check
mutate '$1 == "DG-001" { print $1, $2, $3, $4, $5; next } { print }'
expect "wrong field count is refused" 1 "expected 6" --root "$fx" --check
mutate '$1 == "DG-001" { $1 = "dg-1" } { print }'
expect "malformed id is refused" 1 "is not of the form" --root "$fx" --check

# --- fails closed -----------------------------------------------------------------------------
mutate '/^#/ || $1 == "id" { print }'
expect "inventory with no rows exits 2" 2 "empty inventory" --root "$fx" --check
plant "$valid"
cp "$fx/.claude/guides/demo.md" "$work/demo.md.bak"
printf '%s\n' '# Demo guide' '' 'Nothing here is binding.' > "$fx/.claude/guides/demo.md"
expect "guide with no rule exits 2" 2 "empty extraction" --root "$fx" --check
expect "extract of a guide with no rule exits 2" 2 "empty extraction" --extract "$fx/.claude/guides/demo.md"
rm "$fx/.claude/guides/demo.md"
expect "inventory without its guide exits 2" 2 "has no readable guide" --root "$fx" --check
cp "$work/demo.md.bak" "$fx/.claude/guides/demo.md"
rm "$inv"
expect "no inventory at all exits 2" 2 "no .claude/guides/*.sensors.tsv" --root "$fx" --check
expect "unreadable extract target exits 2" 2 "cannot read" --extract "$fx/absent.md"
expect "unknown argument exits 2" 2 "usage" --bogus

if [ "$failures" -eq 0 ]; then
  echo "rule-sensor-inventory.test.sh: all assertions held"
  exit 0
fi
echo "rule-sensor-inventory.test.sh: $failures assertion(s) failed" >&2
exit 1
