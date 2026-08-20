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
# Membership states that a fragment is NOT RUNNABLE -- not that the guard happens
# to refuse it. Three entries (`gh pr view`, `gh search prs`, `gh search issues`)
# are currently allowed by the guard and so would be skipped anyway; they are kept
# because the property being recorded is a property of the PROSE, and a later
# guard revision that tightened a bare verb should not silently turn a sentence
# fragment into a finding.
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

# Every file that PRESCRIBES a survey command, with a per-source candidate floor.
#
# The plugin's own surveyor definition is here because the run loop sources that
# entry point and only THEN reads the local file as a compatibility overlay, so a
# gitlink bump can introduce a command that no local file mentions. It lives in
# the same submodule as the guard, so it adds no failure mode this script did not
# already have: no submodule, no verdict, exit 2.
#
# The floor is PER SOURCE, not a combined total. A combined count hides the
# failure it is meant to catch — the overlay alone clears any total worth
# setting, so extraction could stop matching an entire other surface unnoticed.
# Counts today are 38 / 23 / 4; each floor sits below its own count so ordinary
# editing does not trip it, and a surface dropping out does.
SOURCE_FLOORS="$repo_root/.claude/agents/portfolio-surveyor.md	25
$repo_root/.claude/skills/portfolio-maintenance/SKILL.md	15
$repo_root/libraries/agent-plugins/plugins/agentic-engineering/agents/portfolio-surveyor.agent.md	3"
SOURCES="$(printf '%s\n' "$SOURCE_FLOORS" | cut -f1)"
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
gh pr view --json
gh run list --json
gh search
gh search prs
gh search issues
gh search prs --help
gh search prs/issues --owner devantler-tech --state open …
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
# a forge verb -- or would open with one once a leading assignment or command
# substitution is stripped. Generous on purpose: the guard does the discriminating.
#
# WHAT REACHES THE GUARD IS THE COMPLETE PRESCRIBED LINE, never a stripped form.
# The stripping decides only WHETHER a line is a candidate; it never rewrites the
# text being classified. That distinction is the whole correctness of this file:
# the runtime hands the guard the shell command it is about to run, so a check
# that classifies `gh api ...` while the deployment would run
# `RUN_NAME="$run_name" gh api ...` is asserting the boundary holds for a command
# nobody runs. Measured against the pinned guard: the bare read is ALLOWed, while
# both prescribed wrappers are refused -- `a read must begin with a forge command`
# and `dollar-paren command substitution is not a read`. Classifying the stripped
# form reported those two prescriptions covered.
#
# The two streams are extracted SEPARATELY and tagged, because PROSE_FRAGMENTS must
# apply to only one of them. That list holds exact runnable forms -- `git fetch`,
# `git worktree add`, `gh api` -- so a source PRESCRIBING one of those inside a
# fenced block would exact-match the exclusion and be skipped before the guard ever
# saw it. That is fail-open on precisely the commands this check exists to catch:
# measured against the pinned guard, 20 of the 23 fragments are DENIED, and 16 of
# those carry a deny reason no corpus row acknowledges. Provenance is what lets the
# exclusion keep serving prose without also excusing a prescription.
extract_inline() {
  local f=$1
  # A Markdown code span may cross newlines, so a per-LINE scan cannot see one:
  # `grep -ohE` matched within a line and silently dropped every multi-line span.
  # The run loop's own paginated CodeRabbit read is one (SKILL.md, five physical
  # lines), so the check was blind to a command it is specifically meant to cover.
  #
  # Joining more than that is what must NOT be done. Backticks pair sequentially,
  # so one stray backtick re-pairs every span after it, and these sources are not
  # paragraph-shaped -- the surveyor overlay runs 478 consecutive lines with no
  # blank line, so a paragraph bound is no bound at all. Measured: joining on that
  # bound silently LOST the `--commenter` and `--merged-at` reads, both of which
  # carry a corpus row.
  #
  # So join ONLY while a span is genuinely open (an odd backtick count), and cap
  # it. Every line whose spans already close is left exactly where line-based
  # pairing had it, which is what makes this add the multi-line case while moving
  # nothing else: measured, zero candidates lost across all three sources.
  # A fence marker is a hard reset -- ``` is itself an odd run and would otherwise
  # start swallowing the block.
  #
  # The residual, stated rather than hidden: an odd count cannot tell an OPENING
  # backtick from a CLOSING one, because the state a line starts in is exactly what
  # per-line scanning discards. So a stray or unmatched backtick joins the lines
  # after it and can mis-pair a span there. It is bounded by the cap and re-syncs
  # on the next flush -- unlike a whole-file join, where one stray backtick
  # re-pairs the entire remainder -- and the per-source floors below would catch a
  # material loss. Measured on all three sources today it costs nothing: the
  # extracted set is unchanged except for the multi-line span it recovers.
  awk '
    function bt(s,   n) { n = gsub(/`/, "`", s); return n }
    /^[[:space:]]*(```|~~~)/ { if (buf != "") print buf; buf = ""; held = 0; next }
    {
      buf = (buf == "" ? $0 : buf " " $0)
      if (bt(buf) % 2 == 1 && held < 10) { held++; next }
      print buf; buf = ""; held = 0
    }
    END { if (buf != "") print buf }
  ' "$f" 2>/dev/null \
    | awk '
        # Code spans with VARIABLE-LENGTH delimiters, per CommonMark: a span opens
        # on a run of N backticks and closes on the next run of EXACTLY N. The
        # single-backtick regex this replaces (`[^`]+`) cannot express that, and the
        # gap is a fail-open rather than a dropped line: a prescription written as
        #
        #   ``result=`gh api rate_limit` ``
        #
        # is split at the INNER shell backticks, both fragments fail the verb filter,
        # and NOTHING reaches the guard -- while the deployment runs a command the
        # guard refuses (`backtick command substitution is not a read`). A run with
        # no matching closer is literal text, so scanning resumes after it instead of
        # pairing across it.
        {
          s = $0; n = length(s); i = 1
          while (i <= n) {
            if (substr(s, i, 1) != "`") { i++; continue }
            j = i; while (j <= n && substr(s, j, 1) == "`") j++
            olen = j - i
            k = j; found = 0
            while (k <= n) {
              if (substr(s, k, 1) == "`") {
                m = k; while (m <= n && substr(s, m, 1) == "`") m++
                if (m - k == olen) { found = 1; break }
                k = m
              } else k++
            }
            if (!found) { i = j; continue }
            content = substr(s, j, k - j)
            # CommonMark strips one leading AND trailing space when both are present,
            # which is how a span may end with a backtick at all.
            if (content ~ /^ / && content ~ / $/ && content ~ /[^ ]/) \
              content = substr(content, 2, length(content) - 2)
            if (content != "") print content
            i = m
          }
        }' \
    | sed -E 's/^[[:space:]]*\$[[:space:]]+//' \
    | awk '
        function opens(s) { return (s ~ /^[[:space:]]*(env[[:space:]]|(gh|git)[[:space:]])/) }
        function strip_assigns(s) {
          while (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|[^[:space:]("'"'"']*)[[:space:]]+/)) s = substr(s, RSTART + RLENGTH)
          return s
        }
        # Both substitution spellings, exactly as the fenced recogniser carries them.
        # Recovering the multi-backtick SPAN above is only half the path: the span it
        # yields is `result=`gh api rate_limit``, whose verb sits behind a legacy
        # backtick substitution, so a `$(`-only test drops it here instead and the
        # command still never reaches the guard.
        function strip_subst(s) {
          if (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$\(/)) return substr(s, RSTART + RLENGTH)
          if (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?`/)) return substr(s, RSTART + RLENGTH)
          return ""
        }
        opens($0) || opens(strip_assigns($0)) || opens(strip_subst($0))
      '
}

extract_fenced() {
  local f=$1
  {
    # Fenced blocks carry MULTI-LINE commands: a trailing backslash, or a quoted
    # operand (a GraphQL query) that runs across lines. Splitting on newlines
    # hands the guard half a command, which it rightly refuses as unbalanced
    # quoting -- an extraction artifact that would read as a real finding. Join
    # continuation lines until quotes balance and no backslash is pending.
    #
    # `env ...` is in the grammar because the maintenance procedure prescribes
    # `env -u GH_TOKEN -u GITHUB_TOKEN gh auth status ...` for credential recovery.
    # A bare `^(gh|git)` filter DISCARDS that span, so the guard never sees it --
    # fail-open, and the per-source floor still passes on the other candidates.
    #
    # A documented command may also be written with a shell PROMPT (`$ gh ...`).
    # That one is stripped BEFORE the verb filter, and it is the dangerous
    # direction: an unstripped prompt does not match `^(gh|git)`, so the command
    # is skipped ENTIRELY and a refusal nobody classified passes unnoticed --
    # fail-open, where the split-command case merely produces a noisy finding.
    #
    # The SAME fail-open reaches two more prescribed shapes, and the verb is not
    # at the start of the line in either: a one-shot environment assignment in
    # front of the verb (`RUN_NAME="$run_name" gh api ...`), and a verb nested in
    # a command substitution (`fid_status=$(gh api ...)`). Both are prescribed by
    # the surveyor overlay today, so an unmatched line dropped before
    # classification hides a guard refusal from CI. The strip is therefore a
    # RECOGNISER only -- it decides that the line is worth classifying, and the
    # COMPLETE line is what the guard is then asked about, because that is what
    # the deployment would actually run.
    #
    # Quote state is tracked as a MACHINE, not a count: `'"'"'` inside a double-quoted
    # operand (and `"` inside a single-quoted one) is a literal, so counting either
    # delimiter alone would leave an apostrophe in `--jq "won'"'"'t"` permanently
    # unbalanced and swallow the rest of the block into one candidate.
    awk '
      function unbalanced(s,   i, c, sq, dq) {
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "\\" && !sq) { i++; continue }
          else if (c == "'"'"'" && !dq) sq = !sq
          else if (c == "\"" && !sq) dq = !dq
        }
        return (sq || dq)
      }
      # Recognisers. Neither rewrites what gets classified: each answers only
      # "would this line open with a forge verb once its wrapper is set aside".
      function strip_assigns(s) {
        while (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|[^[:space:]("'"'"']*)[[:space:]]+/)) {
          s = substr(s, RSTART + RLENGTH)
        }
        return s
      }
      # Both substitution spellings. The guard refuses each -- `dollar-paren
      # command substitution is not a read` and `backtick command substitution
      # is not a read` -- so recognising only `$(` leaves the legacy form
      # fail-OPEN in a way that is worse than being dropped: extract_inline
      # reads the wrapper backticks as a Markdown code span and submits the
      # INNER read, which the guard allows, so the job goes green on a line
      # the deployment would be refused for.
      function strip_subst(s) {
        if (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$\(/)) return substr(s, RSTART + RLENGTH)
        if (match(s, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?`/)) return substr(s, RSTART + RLENGTH)
        return ""
      }
      # A substitution may also OPEN on a line carrying no verb at all -- the shape
      # the MANDATORY merge preflight is written in:
      #
      #   unresolved=$(
      #     set -o pipefail
      #     gh api graphql ... | jq -s ...
      #   ) || { echo "thread read FAILED" >&2; exit 1; }
      #
      # Anchored on the verb, the buffer starts at the bare `gh api` line, so the
      # guard is asked about the INNER read -- which it ALLOWS -- while the
      # deployment runs the whole substitution, which it refuses (`dollar-paren
      # command substitution is not a read`). Same fail-open the backtick spelling
      # above closes, on the one read this repo makes mandatory before every merge.
      #
      # Only the `$(` spelling is tracked, because the closing test below is
      # paren-depth: a multi-line BACKTICK substitution has no depth to model, so
      # claiming it here would assert coverage this cannot deliver.
      function opens_subst(s) {
        return (s ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$\([[:space:]]*$/)
      }
      # Depth of substitution still OPEN -- quote-aware for exactly the reason
      # `unbalanced` is: a `(` inside a jq filter is a literal, so a bare paren
      # count would never close. A buffer opening no paren scores 0, which is what
      # leaves every other candidate precisely where it was.
      function subst_open(s,   i, c, sq, dq, d) {
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "\\" && !sq) { i++; continue }
          else if (c == "'"'"'" && !dq) sq = !sq
          else if (c == "\"" && !sq) dq = !dq
          else if (!sq && !dq) {
            if (c == "(") d++
            else if (c == ")" && d > 0) d--
          }
        }
        return (d > 0)
      }
      # A verb-less opener cannot be judged until the substitution CLOSES, so such a
      # buffer is provisional: kept only if the joined text turns out to wrap a forge
      # verb. Without this every `x=$(date)` would reach the guard and stand as a
      # permanent false finding.
      function has_forge(s) { return (s ~ /(^|[[:space:]]|[;&|(])(gh|git)[[:space:]]/) }
      function opens(s) { return (s ~ /^[[:space:]]*(env[[:space:]]|(gh|git)[[:space:]])/) }
      function candidate(s) { return (opens(s) || opens(strip_assigns(s)) || opens(strip_subst(s))) }
      function flush(   keep) {
        keep = (!pend || has_forge(buf))
        if (buf != "" && keep) print buf
        buf = ""; pend = 0
      }
      # Fences are DELIMITER-AWARE. `~~~` is a valid Markdown fence, and a machine
      # knowing only backticks never ENTERS such a block: the command inside is
      # dropped before classification and its refusal never surfaces -- fail-open,
      # with the per-source floor still passing on the other candidates. Closing
      # only on the delimiter that opened the block is what keeps a `~~~` written
      # inside a ```-block from ending it early.
      /^[[:space:]]*(```|~~~)/ {
        fd = ($0 ~ /^[[:space:]]*~~~/) ? "~" : "`"
        if (!inb) { inb = 1; fence = fd }
        else if (fd == fence) { inb = 0; fence = ""; flush() }
        next
      }
      !inb { next }
      {
        line = $0
        sub(/^[[:space:]]*\$[[:space:]]+/, "", line)
        if (buf == "") {
          if (candidate(line)) { buf = line; pend = 0 }
          else if (opens_subst(line)) { buf = line; pend = 1 }
          else next
        }
        else { sub(/\\[[:space:]]*$/, "", buf); buf = buf " " line }
        # A trailing pipe or boolean is a shell CONTINUATION exactly as a backslash is,
        # and the operand it joins is often where the real verdict lives. Flushing there
        # hands the guard a command ending in `|`, which it rightly refuses as an empty
        # pipeline segment -- a split artifact reading as a real finding, the same
        # failure the multi-line quoted operand above already avoids. An unclosed
        # substitution is a continuation too, and the only one whose opening line
        # carries no trailing marker at all.
        if (!unbalanced(buf) && !subst_open(buf) && buf !~ /\\[[:space:]]*$/ && buf !~ /(\||&&)[[:space:]]*$/) flush()
      }
      END { flush() }
    ' "$f" 2>/dev/null
  }
}


# Emits `<origin> <command>`, origin being `inline` or `fenced`. Each stream is
# normalised BEFORE the tag is prefixed: normalize collapses whitespace runs, so
# tagging first would let it eat the separator and make the two fields
# unsplittable. One command appearing in both streams yields both rows, which is
# intended -- the fenced one still gets classified.
extract_commands() {
  local f=$1
  {
    extract_inline "$f" | normalize | sed 's/^/inline /'
    extract_fenced "$f" | normalize | sed 's/^/fenced /'
  } | sort -u
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
  local findings=0 checked=0 skipped=0 classified=0 tagged origin cand reason
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -r "$f" ] || { echo "  unreadable source: $f" >&2; return 2; }
    while IFS= read -r tagged; do
      [ -n "$tagged" ] || continue
      origin=${tagged%% *}
      cand=${tagged#* }
      [ -n "$cand" ] || continue
      # Prose exclusion applies to INLINE candidates only. A fenced block is a
      # prescription, so it always reaches the guard however it is spelled.
      if [ "$origin" = inline ] \
         && printf '%s\n' "$PROSE_FRAGMENTS" | grep -qxF -- "$cand"; then
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
# The SAME text as a fenced PRESCRIPTION must still be classified. `git worktree add`
# is an exact PROSE_FRAGMENTS entry, so an exclusion applied without provenance skips
# it and no decision is ever prompted -- fail-open on a mutating command. Chosen for
# the same two reasons bad.md's is: the refusal is NOVEL (no corpus row acknowledges
# `git worktree is not a read verb`) and INVARIANT, because creating a working tree
# can never become a read operation, so this fixture cannot age out.
printf '%s\n' 'The surveyor must now also run:' '' '```sh' \
  'git worktree add' '```' > "$fixdir/prose-fenced.md"
# The refusal must be NOVEL (an already-acknowledged one like `gh pr merge` is
# correctly reported as covered) and INVARIANT. An evolving read FLAG is the
# wrong choice: `--involves` is an ordinary search filter that will plausibly join
# `--commenter` on the allowlist, and on the day it does this fixture flips to
# allowed and the self-test reports the detector broken — blocking CI over a
# guard improvement. A create VERB can never become a read, so its denial cannot
# age out, and `gh release create` carries a reason no corpus row acknowledges.
printf '%s\n' 'The surveyor must now also run:' '' '```sh' \
  'gh release create v1 --repo devantler-tech/monorepo' '```' > "$fixdir/bad.md"
printf '%s\n' 'A newly mandated read:' '' '```sh' \
  'gh pr list --repo devantler-tech/monorepo --state open --limit 50' '```' > "$fixdir/good.md"

# A command written with a shell PROMPT must still be extracted. This is the
# fail-OPEN direction: unstripped, `$ gh ...` never matches the verb filter, so
# the command is skipped entirely and its unclassified refusal passes unnoticed.
printf '%s\n' 'Run it like this:' '' '```sh' \
  '$ gh release create v1 --repo devantler-tech/monorepo' '```' > "$fixdir/prompt.md"
# A fenced command whose DOUBLE-quoted operand spans lines must be joined into one
# candidate. Split, the guard rightly refuses half a command as unbalanced quoting
# and it reads as a real finding -- the fail-CLOSED direction, noisy but safe.
printf '%s\n' 'The surveyor runs:' '' '```sh' \
  'gh api graphql -f query="query {' \
  '  repository(owner: \\"devantler-tech\\", name: \\"monorepo\\") { name }' \
  '}"' '```' > "$fixdir/dquote.md"

# An ENV-PREFIXED command must reach the guard. Unmatched, it is dropped before
# classification and the per-source floor still passes on the other candidates --
# fail-open, and the credential-recovery path is exactly where it would bite.
printf '%s\n' 'On a rejected credential run:' '' '```sh' \
  'env -u GH_TOKEN gh release create v1 --repo devantler-tech/monorepo' '```' > "$fixdir/env.md"

# Assert EXTRACTION, not detection: every `env ...` command shares one deny reason,
# so once that reason is classified the command is correctly "covered". What the
# grammar buys is that the command reaches the guard AT ALL -- without it the span
# is dropped before classification and no decision is ever prompted.
env_extracted=$(extract_commands "$fixdir/env.md" | grep -c '^fenced env ')
[ "${env_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: an env-prefixed command was never extracted, so it cannot reach the guard (fail-open)"

# An ASSIGNMENT-PREFIXED command must reach the guard. The overlay prescribes
# `RUN_NAME="$run_name" gh api ...` for the default-branch streak walk; with the verb
# no longer at the start of the line, an opener test anchored on the verb drops it.
printf '%s\n' 'The streak walk runs:' '' '```sh' \
  'RUN_NAME="$run_name" gh api --paginate "repos/devantler-tech/monorepo/actions/runs" --jq ".workflow_runs[].id"' '```' > "$fixdir/assign.md"

# A command SUBSTITUTION must reach the guard too, and must arrive without the shell
# that surrounds it: the overlay prescribes `fid_status=$(gh api ... ) || { ...; }`,
# and handing the guard the trailing `|| { ... }` classifies something that is not
# the command. Spans lines and carries parens inside a jq filter, which is what makes
# a bare paren count wrong.
printf '%s\n' 'The board census runs:' '' '```sh' \
  'fid_status=$(gh api "orgs/devantler-tech/projectsV2/5/fields?per_page=100" \' \
  '  --jq '"'"'.[]|select(.name=="Status")|.id'"'"') \' \
  '  || { echo "board_coverage=unknown:field-lookup-failed"; exit 0; }' '```' > "$fixdir/subst.md"

# The assignment-prefixed command must reach the guard AS PRESCRIBED. Asserting
# `^fenced gh api ` would pass on the stripped form, which is the fail-open this
# pair closes: the deployment runs the prefix, and the guard refuses it
# (`a read must begin with a forge command`), so classifying the bare read
# reports a boundary that holds for a command nobody runs.
assign_extracted=$(extract_commands "$fixdir/assign.md" | grep -c '^fenced RUN_NAME="\$run_name" gh api ')
[ "${assign_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: an assignment-prefixed command did not reach the guard as prescribed (fail-open)"

# Same for the substitution, and here the wrapper is what the guard refuses
# (`dollar-paren command substitution is not a read`), so the complete form is
# the only one whose verdict describes the deployment.
subst_extracted=$(extract_commands "$fixdir/subst.md" | grep -c '^fenced fid_status=\$(gh api ')
[ "${subst_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: a command-substitution command did not reach the guard as prescribed (fail-open)"

# The LEGACY backtick substitution must reach the guard too. This form fails open
# more sharply than being dropped would: extract_inline reads the wrapper
# backticks as a Markdown code span and submits the INNER read, which the guard
# ALLOWS -- so the job goes green on a line the deployment is refused for
# (`backtick command substitution is not a read`). The fixture asserts both that
# the complete line is extracted AND that its unclassified refusal is DETECTED,
# so it cannot pass by extracting something harmless.
printf '%s\n' 'The census runs:' '' '```sh' \
  'result=`gh api "orgs/devantler-tech/projectsV2/5/fields?per_page=100"`' '```' > "$fixdir/backtick.md"
bt_extracted=$(extract_commands "$fixdir/backtick.md" | grep -c '^fenced result=`gh api ')
[ "${bt_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: a backtick command substitution did not reach the guard as prescribed (fail-open)"
if check_sources "$fixdir/backtick.md" >/dev/null 2>&1; then
  die_unknown "self-test: a backtick substitution's unclassified refusal was NOT detected (fail-open)"
fi

# A substitution that OPENS before the verb, which is how the MANDATORY merge
# preflight is written. Anchored on the verb, extraction starts at the bare
# `gh api` line and submits the INNER read -- ALLOWed -- while the deployment runs
# the whole substitution, which is refused. Measured on the real sources, this is
# not hypothetical: the preflight in `.claude/skills/portfolio-maintenance/SKILL.md`
# is the one and only extraction this recogniser changes.
printf '%s\n' 'The merge preflight runs:' '' '```sh' \
  'unresolved=$(' \
  '  set -o pipefail' \
  '  gh api graphql --paginate -f owner=devantler-tech -f name=monorepo' \
  ') || { echo "thread read FAILED" >&2; exit 1; }' '```' > "$fixdir/opensubst.md"
os_extracted=$(extract_commands "$fixdir/opensubst.md" | grep -c '^fenced unresolved=\$( set -o pipefail gh api ')
[ "${os_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: a substitution opening before the verb did not reach the guard as prescribed (fail-open)"

# ...and the provisional buffer it needs must not turn every assignment into a
# candidate. A verb-less opener wrapping no forge command is discarded, or it
# would reach the guard and stand as a permanent false finding.
printf '%s\n' 'Timestamp it:' '' '```sh' \
  'stamp=$(' '  date -u +%Y' ')' '```' > "$fixdir/opensubst-nonforge.md"
nf_extracted=$(extract_commands "$fixdir/opensubst-nonforge.md" | grep -c .)
[ "${nf_extracted:-0}" -eq 0 ] \
  || die_unknown "self-test: a substitution wrapping no forge verb yielded $nf_extracted candidate(s), expected 0 (false finding)"

# A TILDE-fenced block must be entered. `~~~` is valid Markdown, and a fence
# machine knowing only backticks never enters one, so the command inside is
# dropped before classification and its refusal never surfaces -- fail-open, with
# the per-source floor still passing on the other candidates. Asserts extraction
# AND detection, so it cannot pass by extracting something harmless.
printf '%s\n' 'The surveyor runs:' '' '~~~sh' \
  'gh release create v1 --repo devantler-tech/monorepo' '~~~' > "$fixdir/tilde.md"
tl_extracted=$(extract_commands "$fixdir/tilde.md" | grep -c '^fenced gh release create ')
[ "${tl_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: a tilde-fenced command was never extracted, so it cannot reach the guard (fail-open)"
if check_sources "$fixdir/tilde.md" >/dev/null 2>&1; then
  die_unknown "self-test: a tilde-fenced command's unclassified refusal was NOT detected (fail-open)"
fi

# A MULTI-BACKTICK inline span must be parsed by its own delimiter length. A span
# opens on a run of N backticks and closes on the next run of exactly N, which is
# how a prescription may contain a shell backtick substitution at all. Matched with
# a single-backtick regex the text splits at the INNER backticks, both fragments
# fail the verb filter, and NOTHING reaches the guard -- while the deployment runs a
# command the guard refuses (`backtick command substitution is not a read`). Asserts
# extraction AND detection, so it cannot pass by extracting a harmless fragment.
printf '%s\n' 'The census runs ``result=`gh api rate_limit` `` before selecting.' > "$fixdir/multibacktick.md"
mb_extracted=$(extract_commands "$fixdir/multibacktick.md" | grep -c '^inline result=`gh api ')
[ "${mb_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: a multi-backtick inline span did not reach the guard as prescribed (fail-open)"
if check_sources "$fixdir/multibacktick.md" >/dev/null 2>&1; then
  die_unknown "self-test: a multi-backtick span's unclassified refusal was NOT detected (fail-open)"
fi

# A MULTI-LINE inline span must be seen. A per-line scan cannot match one, so the
# span is dropped whole and its refusal never surfaces -- fail-open, and the run
# loop prescribes one of these today.
printf '%s\n' 'Per PR also check' \
  '`gh release create v1 --repo devantler-tech/monorepo' \
  '  --title "x"`.' > "$fixdir/multiline.md"
ml_extracted=$(extract_commands "$fixdir/multiline.md" | grep -c '^inline gh release create ')
[ "${ml_extracted:-0}" -ge 1 ] \
  || die_unknown "self-test: a multi-line inline code span was never extracted, so it cannot reach the guard (fail-open)"
if check_sources "$fixdir/multiline.md" >/dev/null 2>&1; then
  die_unknown "self-test: a multi-line inline span's unclassified refusal was NOT detected"
fi

# A command split across a trailing PIPE must be joined before classification.
# This is the fail-CLOSED direction and it is noisy rather than dangerous, but it
# is not hypothetical: the merge preflight's own `gh api graphql … | jq -s …` read
# is written this way, and split at the pipe the guard rightly refuses the first
# half as an `empty pipeline segment`. Joined, the complete read is ALLOWed -- so
# the split turned a mandated, permitted read into a standing false finding.
# The fixture is chosen so the two halves DISAGREE: the whole is allowed, the
# first half alone is denied, so the assertion cannot pass by accident.
printf '%s\n' 'The preflight runs:' '' '```sh' \
  'gh pr list --repo devantler-tech/monorepo --state open --json number |' \
  '  jq -r '"'"'.[].number'"'"'' '```' > "$fixdir/pipe.md"
pipe_candidates=$(extract_commands "$fixdir/pipe.md" | grep -c .)
[ "${pipe_candidates:-0}" -eq 1 ] \
  || die_unknown "self-test: a pipe-continued command yielded $pipe_candidates candidate(s), expected 1 joined"
if ! check_sources "$fixdir/pipe.md" >/dev/null 2>&1; then
  die_unknown "self-test: a command split at a trailing pipe was reported as a finding"
fi

if check_sources "$fixdir/prompt.md" >/dev/null 2>&1; then
  die_unknown "self-test: a prompt-prefixed command was skipped instead of checked (fail-open)"
fi
if ! check_sources "$fixdir/dquote.md" >/dev/null 2>&1; then
  die_unknown "self-test: a multi-line double-quoted command was split and reported as a finding"
fi
if ! check_sources "$fixdir/prose.md" >/dev/null 2>&1; then
  die_unknown "self-test: prose fragments were flagged as unclassified commands"
fi
if check_sources "$fixdir/prose-fenced.md" >/dev/null 2>&1; then
  die_unknown "self-test: a prose-fragment command PRESCRIBED in a fenced block was skipped
  as prose instead of classified (fail-open). If a corpus row now acknowledges
  'git worktree is not a read verb', this fixture is stale rather than the check broken --
  pick another denied PROSE_FRAGMENTS entry whose refusal no corpus row covers."
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

while IFS=$'\t' read -r f floor; do
  [ -n "${f:-}" ] || continue
  [ -r "$f" ] || die_unknown "source is unreadable: ${f#"$repo_root"/}
  (populate the submodule: .claude/scripts/submodule-init.sh libraries/agent-plugins)"
  n=$(extract_commands "$f" | grep -c .)
  [ "$n" -ge "$floor" ] \
    || die_unknown "extracted only $n candidate(s) from ${f#"$repo_root"/} (floor $floor); the extractor is not matching this source"
done <<< "$SOURCE_FLOORS"

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
