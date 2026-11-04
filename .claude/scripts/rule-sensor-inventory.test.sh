#!/usr/bin/env bash
# shellcheck disable=SC2016 # The awk programs handed to mutate are literal awk source.
# rule-sensor-inventory.test.sh — self-test for rule-sensor-inventory.sh (monorepo#4284).
#
# Runs the checker against the real repository first (every committed inventory must be valid and
# report a prose-only share), then against a planted fixture: one valid inventory, and one mutation
# per refusal, so each check is shown to fire and the valid shape is shown to pass. The empty cases
# (no inventory, no rows, a guide with no rule, an unclosed fence) must exit 2, never 0.
# TEST_BASH=/bin/bash runs the checker under macOS's bash 3.2.
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
# Bash 3.2 hands an EXIT trap $? = 0 after a `set -u` abort, so a successful rm could turn a crash
# into a pass. Reaching the end is the only way a zero status leaves this test.
rule_sensor_test_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  rm -rf "$work"
  if [ "$rule_sensor_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "rule-sensor-inventory.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

# expect <name> <exit code> <stderr substring or -> <args...>
expect() {
  local name="$1" want="$2" needle="$3" rc=0
  shift 3
  "${TEST_BASH:-bash}" "$checker" "$@" >"$work/out" 2>"$work/err" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    fail "$name: exit $rc, want $want ($(head -c 300 "$work/err"))"
  elif [ "$needle" != "-" ] && ! NEEDLE="$needle" awk 'index($0, ENVIRON["NEEDLE"]) { found = 1 } END { exit !found }' "$work/err"; then
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
printf '%s\n' '#!/usr/bin/env bash' 'echo "refuses main"' 'echo "refuses\main"' 'echo "tab\there"' \
  > "$fx/.claude/scripts/demo-guard.sh"
cat > "$fx/.claude/guides/demo.md" <<'EOF'
# Demo guide

## First section

Agents must run the helper
before merging. This sentence states nothing.

- Never push to main directly.
- A list item with no rule.

````md
```sh
# never inside a fence is a rule
```
~~~
also never a rule
````

## Second section

The always-on core is described here. Reviewers never re-approve a stale head. 🔴 **Always sign commits.**

| a | table row that must be read |

> Quoted text that must
> stay.

### Never merge on red
EOF
valid=$(cat <<'EOF'
# a comment line
id	section	quote	kind	control	evidence
DG-001	first-section	Agents must run the helper before	computational	.claude/scripts/demo-guard.sh	refuses main
DG-002	first-section	Never push to main directly	none	-	-
DG-003	second-section	Reviewers never re-approve	narrative	-	-
DG-004	second-section	table row that must be read	runtime	.claude/scripts/demo-guard.sh	refuses main
DG-005	second-section	Quoted text that must stay	inferential	.claude/scripts/demo-guard.sh	refuses main
DG-006	second-section	**Always sign commits.**	none	-	-
DG-007	never-merge-on-red	Never merge on red	none	-	-
EOF
)
inv="$fx/.claude/guides/demo.sensors.tsv"
plant() { printf '%s\n' "$1" > "$inv"; }
mutate() { printf '%s\n' "$valid" | awk -F'\t' -v OFS='\t' "$1" > "$inv"; }
want_report=$(printf 'demo.md\trules=6\tprose-only=3 (50%%)\tcomputational=1\truntime=1\tinferential=1\tnarrative=1')

plant "$valid"
expect "valid fixture passes" 0 - --root "$fx" --check
expect "valid fixture reports" 0 - --root "$fx" --report
if [ "$(cat "$work/out")" = "$want_report" ]; then pass "report counts each kind, narrative apart"; else fail "report: $(cat "$work/out")"; fi
mutate '$1 == "id" { print "" } { print }'
expect "a blank line before the header is skipped" 0 - --root "$fx" --report
if [ "$(cat "$work/out")" = "$want_report" ]; then pass "report never counts the header as a rule"; else fail "report after a blank line: $(cat "$work/out")"; fi

expect "extract runs" 0 - --extract "$fx/.claude/guides/demo.md"
if [ "$(awk 'END { print NR }' "$work/out")" = 7 ]; then pass "extract finds exactly the seven rule sentences"; else fail "extract: $(cat "$work/out")"; fi
if awk 'index($0, "fence") || index($0, "also never") || index($0, "always-on") || index($0, "states nothing") { bad = 1 } END { exit bad }' "$work/out"; then
  pass "nested fences, hyphenated compounds and plain sentences are not rules"
else
  fail "extract kept a non-rule: $(cat "$work/out")"
fi
if awk -F'\t' '$1 == "first-section" && $2 == 5 && $3 == "Agents must run the helper before merging." { found = 1 } END { exit !found }' "$work/out"; then
  pass "wrapped lines join and the section is the heading anchor"
else
  fail "extract shape: $(cat "$work/out")"
fi
if awk -F'\t' '$3 == "🔴 **Always sign commits.**" { a = 1 } $3 == "Reviewers never re-approve a stale head." { b = 1 } $1 == "never-merge-on-red" && $3 == "Never merge on red" { c = 1 } END { exit !(a && b && c) }' "$work/out"; then
  pass "a marker emoji starts a sentence and a heading is a unit"
else
  fail "extract split: $(cat "$work/out")"
fi

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
mutate '{ print } $1 == "DG-002" { print }'
expect "a repeated none row is refused" 1 "repeats a none row" --root "$fx" --check
mutate '{ print } $1 == "DG-001" { print "DG-001", $2, "Never push to main directly", $4, $5, $6 }'
expect "an id repeated with another quote is refused" 1 "repeats with a different" --root "$fx" --check
mutate '{ print } $1 == "DG-001" { print "DG-001", "second-section", $3, $4, $5, $6 }'
expect "an id repeated with another section is refused" 1 "repeats with a different" --root "$fx" --check
mutate '{ print } $1 == "DG-004" { print "DG-008", $2, $3, $4, $5, $6 }'
expect "a second id quoting the same text is refused" 1 "as DG-004; one rule, one id" --root "$fx" --check
mutate '{ print } $1 == "DG-001" { print "DG-008", $2, "the helper before merging.", "none", "-", "-" }'
expect "a second id quoting another part of one sentence is refused" 1 "as DG-001; one rule, one id" --root "$fx" --check
mutate '$1 == "DG-001" { $6 = "" } { print }'
expect "empty evidence is refused" 1 "at least 4 non-space characters" --root "$fx" --check
mutate '$1 == "DG-001" { $6 = "  " } { print }'
expect "whitespace evidence is refused" 1 "at least 4 non-space characters" --root "$fx" --check
mutate '$1 == "DG-001" { $6 = "ref" } { print }'
expect "evidence too short to identify a control is refused" 1 "at least 4 non-space characters" --root "$fx" --check
mutate '$1 == "DG-001" { $4 = "computational"; $5 = "-" } { print }'
expect "control kind without a path is refused" 1 "needs a control path" --root "$fx" --check
mutate '$1 == "DG-001" { $5 = "scripts/demo-guard.sh" } { print }'
expect "control outside .claude/ or .github/ is refused" 1 "control must be a path under" --root "$fx" --check
mutate '$1 == "DG-001" { $5 = ".claude/../.claude/scripts/demo-guard.sh" } { print }'
expect "control with a parent step is refused" 1 "control must be a path under" --root "$fx" --check
mutate '$1 == "DG-001" { $5 = ".claude/guides/demo.md"; $6 = "Agents must" } { print }'
expect "the guide itself is not a control" 1 "must be code, not prose" --root "$fx" --check
mutate '$1 == "DG-001" { $5 = ".claude/guides/demo.sensors.tsv"; $6 = "DG-002" } { print }'
expect "the inventory itself is not a control" 1 "must be code, not prose" --root "$fx" --check
printf 'refuses main\n' > "$fx/.claude/scripts/notes.md"
mutate '$1 == "DG-001" { $5 = ".claude/scripts/notes.md" } { print }'
expect "a markdown file is not a control" 1 "must be code, not prose" --root "$fx" --check
printf 'refuses main\n' > "$fx/.claude/scripts/NOTES.MD"
mutate '$1 == "DG-001" { $5 = ".claude/scripts/NOTES.MD" } { print }'
expect "the prose refusal ignores case" 1 "must be code, not prose" --root "$fx" --check
ln -s ../guides/demo.md "$fx/.claude/scripts/guide-link.sh"
printf 'refuses main\n' >> "$fx/.claude/guides/demo.md"
mutate '$1 == "DG-001" { $5 = ".claude/scripts/guide-link.sh" } { print }'
expect "a symlinked control is refused" 1 "passes through the symlink .claude/scripts/guide-link.sh" --root "$fx" --check
rm "$fx/.claude/scripts/guide-link.sh"
ln -s ../guides "$fx/.claude/scripts/gdir"
mutate '$1 == "DG-001" { $5 = ".claude/scripts/gdir/demo.md.txt" } { print }'
cp "$fx/.claude/guides/demo.md" "$fx/.claude/guides/demo.md.txt"
expect "a control under a symlinked directory is refused" 1 "passes through the symlink .claude/scripts/gdir" --root "$fx" --check
rm "$fx/.claude/scripts/gdir" "$fx/.claude/guides/demo.md.txt"
awk 'NR == 1 || !/^refuses main$/' "$fx/.claude/guides/demo.md" > "$work/demo.md.tmp" && mv "$work/demo.md.tmp" "$fx/.claude/guides/demo.md"
mutate '$1 == "DG-001" { $6 = "refuses\\main" } { print }'
expect "evidence with a backslash is matched literally" 0 - --root "$fx" --check
mutate '$1 == "DG-001" { $6 = "tab\\there" } { print }'
expect "evidence is not unescaped before matching" 0 - --root "$fx" --check
mutate '$1 == "DG-001" { $6 = "refuses\\tmain" } { print }'
expect "a backslash evidence that is absent is still refused" 1 "does not contain its evidence" --root "$fx" --check
mutate '$1 == "id" { $1 = "rule" } { print }'
expect "wrong header is refused" 1 "header must be" --root "$fx" --check
mutate '$1 == "DG-001" { print $1, $2, $3, $4, $5; next } { print }'
expect "wrong field count is refused" 1 "expected 6" --root "$fx" --check
mutate '$1 == "DG-001" { $1 = "dg-1" } { print }'
expect "malformed id is refused" 1 "is not of the form" --root "$fx" --check
expect "an invalid inventory reports nothing" 1 - --root "$fx" --report
if [ -s "$work/out" ]; then fail "report printed on failure: $(cat "$work/out")"; else pass "report stays silent while an inventory is wrong"; fi

# --- fails closed -----------------------------------------------------------------------------
mutate '/^#/ || $1 == "id" { print }'
expect "inventory with no rows exits 2" 2 "empty inventory" --root "$fx" --check
plant "$valid"
cp "$fx/.claude/guides/demo.md" "$work/demo.md.bak"
printf '%s\n' '# Demo guide' '' 'Nothing here is binding.' > "$fx/.claude/guides/demo.md"
expect "guide with no rule exits 2" 2 "empty extraction" --root "$fx" --check
expect "extract of a guide with no rule exits 2" 2 "empty extraction" --extract "$fx/.claude/guides/demo.md"
printf '%s\n' '# Demo guide' '' '```x``` is inline code, not a fence.' '' 'You must never merge on red.' '' \
  '```sh' 'never a rule' '```' '' 'Always sign commits.' > "$fx/.claude/guides/demo.md"
expect "inline triple-backtick code is not a fence" 0 - --extract "$fx/.claude/guides/demo.md"
if [ "$(awk -F'\t' '{ print $3 }' "$work/out")" = "$(printf '%s\n' 'You must never merge on red.' 'Always sign commits.')" ]; then
  pass "rules after inline triple-backtick code are still extracted"
else
  fail "inline backticks hid a rule: $(cat "$work/out")"
fi
printf '%s\n' '# Demo guide' '' 'You must run it.' '' '```sh' 'never closed' > "$fx/.claude/guides/demo.md"
expect "an unclosed fence exits 2" 2 "is never closed" --root "$fx" --check
expect "extract of an unclosed fence exits 2" 2 "is never closed" --extract "$fx/.claude/guides/demo.md"
rm "$fx/.claude/guides/demo.md"
expect "inventory without its guide exits 2" 2 "has no readable guide" --root "$fx" --check
cp "$work/demo.md.bak" "$fx/.claude/guides/demo.md"
plant "$valid"
printf 'id\tsection\tquote\tkind\tcontrol\tevidence\n' > "$fx/.claude/guides/aaa.sensors.tsv"
mutate '$1 == "DG-001" { $3 = "Agents must run the missing helper" } { print }'
expect "an unreadable inventory is not lowered to a plain failure by another" 2 "has no readable guide" --root "$fx" --check
rm "$fx/.claude/guides/aaa.sensors.tsv" "$inv"
expect "no inventory at all exits 2" 2 "no .claude/guides/*.sensors.tsv" --root "$fx" --check
expect "unreadable extract target exits 2" 2 "cannot read" --extract "$fx/absent.md"
expect "unknown argument exits 2" 2 "usage" --bogus

rule_sensor_test_finished=1
if [ "$failures" -eq 0 ]; then
  echo "rule-sensor-inventory.test.sh: all assertions held"
  exit 0
fi
echo "rule-sensor-inventory.test.sh: $failures assertion(s) failed" >&2
exit 1
