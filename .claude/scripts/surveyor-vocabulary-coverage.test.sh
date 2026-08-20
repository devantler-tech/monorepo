#!/usr/bin/env bash
# Pins SOURCES -> CORPUS, the half `surveyor-forge-vocabulary.test.sh` states
# plainly that it does not cover.
#
# That file pins CORPUS -> GUARD: every command in its hand-maintained list is
# re-asserted against the read-only forge guard. What nothing checked is whether
# the list still COVERS the commands the surveyor's own definition prescribes.
# #2931 added those definition files to the job's path filter, so a PR touching
# them RUNS the job -- but the job re-checks the same unchanged corpus and stays
# green, even when the guard would refuse the newly mandated read. The failure
# that hides is a mandated survey read failing closed mid-run, which is exactly
# what the guard's rollout note tells deployments to rule out beforehand.
#
# THE DESIGN, and why it is not a Markdown command extractor.
#
# Extracting commands from prose is the fragile part, and the honest move is to
# stop trying to decide what counts as a command. The GUARD is the classifier,
# so this file asks it about every candidate and only ever fails on the answer
# that matters:
#
#   guard ALLOWS it   -> covered. A mandated read that works needs no corpus row,
#                        and a prose fragment that happens to parse as a read
#                        (`gh api`, `gh pr view`) is silently harmless. This is
#                        what keeps the false-positive rate at zero for the bulk
#                        of extracted noise.
#   guard DENIES it   -> somebody must have DECIDED that. It is covered only if
#                        the corpus carries it verbatim (as `deny` or `gap`), or
#                        it is a listed prose fragment. Otherwise: FAIL.
#
# So the only way to fail is to add a command the guard refuses and classify it
# nowhere -- precisely the drift being closed, and nothing else.
#
# PROSE_FRAGMENTS is an explicit exclusion list rather than a heuristic, on the
# repo's own lesson that when a check keeps finding another spelling, you invert
# to a whitelist. Every entry is a fragment that reads as a command but is not
# runnable: a bare verb, a `/`-alternation naming a family, or an ellipsis. It is
# deliberately exact-match and deliberately small: a NEW prose fragment fails the
# run and forces a decision, which is the intended direction.
#
# The corpus is READ FROM the sibling file rather than duplicated, so the two can
# never drift into disagreeing about what is classified.
#
# Exit: 0 every prescribed command is covered * 1 an unclassified command *
#       2 UNKNOWN (guard, sources or corpus unavailable, or a self-test failed).
# UNKNOWN is never success: an unverifiable boundary is unproven.
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd) || exit 2
guard="$repo_root/libraries/agent-plugins/plugins/agentic-engineering/scripts/forge-readonly-guard.sh"
corpus_file="$repo_root/.claude/scripts/surveyor-forge-vocabulary.test.sh"

SOURCES="$repo_root/.claude/agents/portfolio-surveyor.md
$repo_root/.claude/skills/portfolio-maintenance/SKILL.md"

# A real source change must not be able to drop the candidate count to near zero
# and pass vacuously. Set well under the ~59 the two files yield today, so
# ordinary editing does not trip it but a broken extractor does.
MIN_CANDIDATES=30
MIN_CORPUS_ROWS=25

die_unknown() { echo "surveyor-vocabulary-coverage: UNKNOWN — $1" >&2; exit 2; }

[ -f "$guard" ] || die_unknown "guard not found at $guard
  (populate the submodule: .claude/scripts/submodule-init.sh libraries/agent-plugins)"
[ -x "$guard" ] || die_unknown "guard is not executable: $guard"
[ -r "$corpus_file" ] || die_unknown "corpus file unreadable: $corpus_file"

# Prove the guard discriminates before trusting a single verdict. Without this a
# guard that errored on everything would mark every candidate denied and this
# file would report a pile of false findings.
"$guard" --command 'gh pr list --repo devantler-tech/monorepo --state open' >/dev/null 2>&1 \
  || die_unknown "guard denied its own smoke-test read"
if "$guard" --command 'gh pr merge 1 --repo devantler-tech/monorepo --squash' >/dev/null 2>&1; then
  die_unknown "guard allowed a merge; it is not discriminating"
fi

PROSE_FRAGMENTS='gh ... list/view/search
gh api
gh api --jq
gh api --paginate
gh api --slurp
gh pr merge/create/comment/edit/review
gh pr/issue list
gh pr create
gh pr merge
gh pr view
gh run list --json
gh search
gh search prs
gh search issues
gh search prs --help
gh search prs/issues --owner devantler-tech --state open …
gh auth login
gh auth status
gh auth status --active --hostname github.com
gh api --include --hostname github.com user
gh api graphql --hostname github.com -f query='"'"'{viewer{login}}'"'"'
git log/status
git push
git fetch
git ls-remote
git check-ref-format
git worktree add
git submodule update --init'

# Collapse the placeholder vocabulary the prose uses (<o>, <repo>, <from>) to a
# literal so the guard sees a parseable argv. Substitution is applied to BOTH
# sides, so corpus matching stays exact under it.
normalize() {
  sed -E 's/<[A-Za-z][A-Za-z0-9_ .>=-]*>/PLACEHOLDER/g' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

# Candidates: inline code spans plus fenced-block lines, kept when they open with
# a forge verb. Generous on purpose -- the guard does the discriminating.
extract_commands() {
  local f=$1
  {
    grep -ohE '`[^`]+`' "$f" 2>/dev/null | sed 's/^`//; s/`$//' \
      | grep -E '^[[:space:]]*(gh|git)[[:space:]]'
    # Fenced blocks carry MULTI-LINE commands: a trailing backslash, or a quoted
    # operand (a GraphQL query) that runs across lines. Splitting on newlines
    # hands the guard half a command, which it rightly refuses as unbalanced
    # quoting -- an extraction artifact that would read as a real finding. Join
    # continuation lines until quotes balance and no backslash is pending.
    awk '
      /^[[:space:]]*```/ { inb = !inb; if (!inb && buf != "") { print buf; buf = "" } next }
      !inb { next }
      {
        if (buf == "") { if ($0 !~ /^[[:space:]]*(gh|git)[[:space:]]/) next; buf = $0 }
        else { sub(/\\[[:space:]]*$/, "", buf); buf = buf " " $0 }
        tmp = buf; cnt = gsub(/'"'"'/, "x", tmp)
        if (cnt % 2 == 0 && buf !~ /\\[[:space:]]*$/) { print buf; buf = "" }
      }
      END { if (buf != "") print buf }
    ' "$f" 2>/dev/null
  } | normalize | sort -u
}

raw_corpus() {
  awk '/^corpus=\$\(cat <<.?CORPUS.?$/{inb=1;next} /^CORPUS$/{inb=0} inb{print}' "$corpus_file"
}

read_corpus() { raw_corpus | cut -f2- | normalize | sort -u; }

# The set of refusals the corpus has already ACKNOWLEDGED. Keying coverage on the
# guard's own reason -- rather than on command text -- is what makes this robust:
# every refusal the guard issues names a verb, a flag, or a shell construct, so
# the reason IS the classification. Two prose spellings of the same denied flag
# are one decision, while a genuinely new flag produces a reason nobody has
# acknowledged and fails. It also sidesteps matching a source's `<placeholder>`
# prose against a corpus row's concrete values, which no text normalisation can
# unify without discarding the flags the verdict actually turns on.
corpus_deny_reasons() {
  local want cmd r
  while IFS=$'\t' read -r want cmd; do
    [ -n "${want:-}" ] || continue
    [ -n "${cmd:-}" ] || continue
    r=$("$guard" --command "$cmd" 2>&1 | head -1)
    case "$r" in deny:*) printf '%s\n' "$r" ;; esac
  done <<< "$(raw_corpus)"
}

# Computed ONCE: ~44 guard calls, and check_sources runs five times per
# invocation (four self-tests plus the real pass).
CORPUS_REASONS=""

check_sources() {
  local findings=0 checked=0 skipped=0 classified=0 cand reason
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -r "$f" ] || { echo "  unreadable source: $f" >&2; return 2; }
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      if printf '%s\n' "$PROSE_FRAGMENTS" | grep -qxF -- "$cand"; then
        skipped=$((skipped+1)); continue
      fi
      checked=$((checked+1))
      if "$guard" --command "$cand" >/dev/null 2>&1; then continue; fi
      reason=$("$guard" --command "$cand" 2>&1 | head -1)
      if printf '%s\n' "$CORPUS_REASONS" | grep -qxF -- "$reason"; then
        classified=$((classified+1)); continue
      fi
      findings=$((findings+1))
      echo "UNCLASSIFIED  the guard refuses a command this source prescribes,"
      echo "              and no corpus row acknowledges that refusal:"
      echo "                source: ${f#"$repo_root"/}"
      echo "                command: $cand"
      echo "                reason: $reason"
      echo "              Fix: teach the guard upstream and add a 'gap' row, or add a"
      echo "              'deny' row if the refusal is correct, in ${corpus_file#"$repo_root"/}"
    done <<< "$(extract_commands "$f")"
  done <<< "$1"
  CHECKED=$checked; SKIPPED=$skipped; CLASSIFIED=$classified
  [ "$findings" -eq 0 ]
}

CORPUS_REASONS=$(corpus_deny_reasons)
[ -n "$CORPUS_REASONS" ] || die_unknown "no corpus row produced a deny reason; the corpus or the guard is not being read"

# ── Self-tests: planted fixtures, before any real verdict is trusted ──────────
fixdir=$(mktemp -d) || die_unknown "cannot create fixture dir"
trap 'rm -rf "$fixdir"' EXIT

printf '%s\n' 'Prose: run `gh api` then `gh pr view`, never `gh pr merge/create/comment/edit/review`.' \
  '' 'Also `git log/status` and `gh search prs --help` are families, not commands.' > "$fixdir/prose.md"
# A NOVEL refusal on purpose. An already-acknowledged one (`gh pr merge`) would
# be correctly reported as covered, which is the design working, not a miss.
printf '%s\n' 'The surveyor must now also run:' '' '```sh' \
  'gh search issues --owner devantler-tech --state open --involves devantler' '```' > "$fixdir/bad.md"
printf '%s\n' 'A newly mandated read:' '' '```sh' \
  'gh pr list --repo devantler-tech/monorepo --state open --limit 50' '```' > "$fixdir/good.md"

if ! check_sources "$fixdir/prose.md" >/dev/null 2>&1; then
  die_unknown "self-test: prose fragments were flagged as unclassified commands"
fi
if check_sources "$fixdir/bad.md" >/dev/null 2>&1; then
  die_unknown "self-test: an unclassified guard-denied command was NOT detected"
fi
if ! check_sources "$fixdir/good.md" >/dev/null 2>&1; then
  die_unknown "self-test: a guard-allowed mandated read was wrongly flagged"
fi
if check_sources "$fixdir/missing-file.md" >/dev/null 2>&1; then
  die_unknown "self-test: an unreadable source did not fail closed"
fi

# ── Anti-vacuity: the extractor and the corpus must still see something ───────
corpus_rows=$(read_corpus | grep -c .)
[ "$corpus_rows" -ge "$MIN_CORPUS_ROWS" ] \
  || die_unknown "parsed only $corpus_rows corpus row(s) from ${corpus_file#"$repo_root"/}; the heredoc markers likely moved"

total_candidates=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$(extract_commands "$f" | grep -c .)
  total_candidates=$((total_candidates + n))
done <<< "$SOURCES"
[ "$total_candidates" -ge "$MIN_CANDIDATES" ] \
  || die_unknown "extracted only $total_candidates candidate(s) from the sources (expected >= $MIN_CANDIDATES); the extractor is not matching"

# ── The real check ───────────────────────────────────────────────────────────
CHECKED=0; SKIPPED=0; CLASSIFIED=0
# Capture the status DIRECTLY. After `fi`, `$?` is the status of the `if`
# compound (0 when the condition merely failed), so reading it there cannot
# distinguish a finding from an UNKNOWN and would silently report an unreadable
# source as a finding.
check_sources "$SOURCES"
status=$?
if [ "$status" -eq 0 ]; then
  echo "surveyor-vocabulary-coverage: $CHECKED prescribed command(s) covered" \
       "($CLASSIFIED classified in corpus, $SKIPPED prose fragment(s) skipped," \
       "$corpus_rows corpus row(s))"
  exit 0
fi
[ "$status" -eq 2 ] && die_unknown "a source was unreadable"
echo "surveyor-vocabulary-coverage: unclassified command(s) found — see above" >&2
exit 1
