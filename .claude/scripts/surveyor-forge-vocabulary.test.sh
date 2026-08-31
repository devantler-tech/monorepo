#!/usr/bin/env bash
# Pins the corpus of survey commands below against the plugin's read-only forge
# guard, so a guard revision cannot silently start refusing one of them.
#
# SCOPE, precisely: this pins CORPUS -> GUARD. It does NOT pin SOURCES -> CORPUS.
# The corpus is hand-maintained, so a mandated read added to the surveyor
# definition or its run loop is not classified here merely because those files
# are watched: the job runs, re-checks this unchanged list, and stays green. The
# path filter decides WHEN this runs; it cannot decide WHAT it knows about.
# Closing that second half needs a source-to-corpus coverage check or a
# machine-readable command inventory -- monorepo#2936. Until it lands, adding a
# survey command means adding its row here by hand.
#
# Why this exists. `plugins/agentic-engineering/README.md` makes the wiring the
# consumer's step and says plainly: "run your own deployment's survey vocabulary
# through it before turning it on: a read it does not yet recognise fails closed,
# which is the intended direction but is better discovered deliberately than
# mid-run." This file IS that check, kept executable so it also catches the
# reverse drift — a guard revision that starts allowing a mutation.
#
# Dispositions:
#   allow  the guard must permit it; a deny would break a mandated survey read
#   deny   the guard must refuse it; an allow is a security regression
#   gap    denied TODAY by a guard defect, tracked upstream. Asserted as deny so
#          the suite is green on main, and it FAILS THE MOMENT IT STARTS BEING
#          ALLOWED — which is the signal that the upstream fix has landed and
#          this entry should be promoted to `allow`.
#
# The three credential-diagnosis rows are ORCHESTRATOR pre-flight, not surveyor
# reads: `gh auth ...`, `gh api --hostname ...` and the `env -u GH_TOKEN ...`
# wrapper are prescribed by the maintenance procedure for recovering a rejected
# credential, and the surveyor never runs them. They are pinned `deny` rather
# than skipped so the refusal is a recorded decision — a prose-exclusion list
# hid them before, which let a real refusal pass unclassified.
#
# The two `gh search` query FILTERS — `--commenter` selects issues a user commented
# on, `--merged-at` bounds a merge window — are `allow`. Both are reads, both are
# prescribed by the surveyor definition, and the guard refused both until
# agent-plugins#148 fixed it; while it did, the maintainer-comment sweep and the
# merged-PR retrospective would each have failed closed mid-run. They were found by
# the sources-to-corpus coverage check in `surveyor-vocabulary-coverage.test.sh`,
# tracked as `gap` rows, and promoted here when this repo's pin picked the fix up —
# which is exactly the lifecycle a `gap` row exists to drive.
#
#
# On `$ENV` in a `--jq` filter: the guard refuses it, and that refusal is RIGHT, so
# it is pinned `deny` rather than tracked as a gap. `$ENV` hands the filter the whole
# environment, `GITHUB_TOKEN` included, and the guard classifies statically — it
# cannot tell `$ENV.RUN_NAME` from `$ENV.GITHUB_TOKEN`, so allowing the construct at
# all would open a credential path straight into the surveyor's own digest. Teaching
# it to whitelist safe names means parsing jq programs inside a security boundary,
# which is more attack surface than the one benign use is worth.
#
# The surveyor overlay prescribes exactly that benign use today (the default-branch
# streak walk, to avoid pasting a run name into a jq program as a literal), so with
# the guard enforcing, that walk fails closed mid-run. The fix belongs in the overlay
# — filter in the shell instead of in jq — and is tracked as monorepo#2939. This row
# records the refusal as a decision so it stops being invisible; it is deliberately
# NOT a gap, because promoting it to `allow` is the one outcome that would be unsafe.
# On the two WRAPPED prescriptions: both are pinned `deny` because the refusal is
# right in each case, and in each the fix belongs to the CALLER, not the guard.
#
# `RUN_NAME="$run_name" gh api ...` — a one-shot environment assignment in front
# of the verb. Allowing an assignment prefix in general is unsafe for the same
# reason `$ENV` is: the guard classifies statically from argv, and a prefix is an
# execution vector (`LD_PRELOAD=`, `GIT_SSH_COMMAND=`, `GH_HOST=`), so it would
# have to whitelist names and reason about their semantics inside a security
# boundary. This is the same overlay line the `$ENV` row above covers, so the one
# overlay fix tracked as monorepo#2939 — filter in the shell, not in jq — removes
# both refusals together.
#
# `fid_status=$(gh api ...)` — a read wrapped in a command substitution. The guard
# refuses BOTH substitution forms (backtick and dollar-paren) as a category, which
# is a deliberate rule rather than an oversight: proving a whole compound shell
# line is a read means parsing shell. So this is NOT a `gap` — promoting it to
# `allow` is not the outcome being waited on. The caller-side fix is to hand the
# guard the inner read rather than the shell that captures it; tracked as
# monorepo#2943.
#
# `for T in Epic Feature ...; do gh api ...; done` — the mandated issue-type sweep,
# and the same category one step further out: a compound whose every segment is a
# read, refused as `chaining with ; can carry a write`. Pinned `deny` for exactly
# the reason above — proving that a whole shell construct is read-only means
# parsing shell, inside a security boundary, so promoting it is not the outcome
# being waited on. The refusal is real rather than theoretical: the runtime submits
# the WHOLE construct, so a deployment that wires the guard onto the surveyor has
# this sweep fail closed mid-run. The caller-side fix is to express the sweep
# without a shell loop; tracked as monorepo#2955.

# `set -o pipefail; fid_status=$(gh api ...)` — the board-coverage census, which the
# surveyor definition opens with a load-bearing options line. Two statements, so the
# guard refuses the pair as `chaining with ; can carry a write` — a DIFFERENT verdict
# from the `fid_status=$(...)` row above, which is what the sub-statement alone draws.
# That difference is the point: extraction used to drop the options line and pin only
# the narrower verdict, so the script the deployment actually runs was never
# classified (monorepo#2963). Pinned `deny` for the same reason as the sweep above —
# proving a whole shell construct is read-only means parsing shell inside a security
# boundary — so this is NOT a `gap`. The caller-side fix is to hand the guard the
# inner read and set the shell option outside the classified command.
#
# On `git status`: the surveyor definition names `git log/status` among its read
# verbs, but only the hardened invocation is actually a read, and the guard is
# right to insist on it. Bare `git status` is pinned as `deny` for two reasons
# the guard states: without `-c core.fsmonitor=` repository configuration can
# name a hook program git executes (arbitrary execution while merely looking at
# a repo), and without `--no-optional-locks` the "read" rewrites the index. The
# allow/deny pair therefore pins BOTH halves: the form a surveyor may run, and
# the form it may not. A definition that tells a surveyor to run the bare form
# would fail closed mid-run — see the note in the corpus's companion issue.
#
# Exit: 0 all entries match · 1 a mismatch · 2 UNKNOWN (guard unavailable).
# UNKNOWN is never reported as success: an unverifiable boundary is unproven.
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd) || exit 2
guard="$repo_root/libraries/agent-plugins/plugins/agentic-engineering/scripts/forge-readonly-guard.sh"

if [ ! -f "$guard" ]; then
  echo "surveyor-forge-vocabulary: UNKNOWN — guard not found at $guard" >&2
  echo "  (populate the submodule: .claude/scripts/submodule-init.sh libraries/agent-plugins)" >&2
  exit 2
fi
if [ ! -x "$guard" ]; then
  echo "surveyor-forge-vocabulary: UNKNOWN — guard is not executable: $guard" >&2
  exit 2
fi

# Prove the guard answers at all before trusting any verdict it gives. Without
# this, a guard that errored on every input would mark the whole corpus "deny"
# and the suite would pass vacuously on its deny entries.
#
# The guard has THREE outcomes, so "not allowed" is not the same as "denied":
# 0 allowed, 1 denied with a `deny:` first line, 2 usage/error. A bare non-zero
# check accepts a status 2 as a refusal, so a guard that merely ERRORED on the
# merge probe would satisfy this gate -- and every `deny` row below would then
# rest on a discrimination proof that was never obtained. Note also that the
# probe and the corpus differ in their PR number, so a guard broken only for the
# corpus' spelling would still pass a probe that accepts any failure.
smoke_out=$(GH_TELEMETRY=0 "$guard" --command 'gh pr list --repo devantler-tech/monorepo --state open' 2>&1); smoke_status=$?
if [ "$smoke_status" -ne 0 ]; then
  echo "surveyor-forge-vocabulary: UNKNOWN — guard returned status $smoke_status for its own smoke-test read, so no verdict it gives is trustworthy: $(printf '%s\n' "$smoke_out" | head -1)" >&2
  exit 2
fi
smoke_out=$(GH_TELEMETRY=0 "$guard" --command 'gh pr merge 1 --repo devantler-tech/monorepo --squash' 2>&1); smoke_status=$?
smoke_reason=$(printf '%s\n' "$smoke_out" | head -1)
case "$smoke_status:$smoke_reason" in
  1:deny:*) : ;;
  0:*) echo "surveyor-forge-vocabulary: UNKNOWN — guard allowed a merge; it is not discriminating" >&2; exit 2 ;;
  *) echo "surveyor-forge-vocabulary: UNKNOWN — guard returned status $smoke_status for the merge probe, so its refusal is unverifiable rather than a denial: $smoke_reason" >&2; exit 2 ;;
esac

# ── Corpus ───────────────────────────────────────────────────────────────────
# Tab-separated: <disposition>\t<command>. Tabs are safe here (no raw control
# bytes in the source) and no command below contains one.
corpus=$(cat <<'CORPUS'
allow	gh pr list --repo devantler-tech/monorepo --state open --limit 100 --json number,title,isDraft,headRefName
allow	gh pr view 2927 --repo devantler-tech/monorepo --json number,isDraft,headRefOid,mergeStateStatus,state
allow	gh issue view 108 --repo devantler-tech/agent-plugins --json number,title,state
allow	gh search prs --owner devantler-tech --state open --limit 100
allow	gh search issues --owner devantler-tech --state open --limit 100
allow	gh search issues --owner devantler-tech --state open --commenter devantler --limit 100
allow	gh search prs --owner devantler-tech --merged --merged-at "2026-08-01..2026-08-02" --limit 100
allow	gh run list --repo devantler-tech/monorepo --branch main --limit 50 --json conclusion,path,event
allow	gh repo list devantler-tech --limit 100 --json name,isArchived,visibility
allow	gh api repos/devantler-tech/monorepo/pulls/2927/reviews --paginate
allow	gh api repos/devantler-tech/monorepo/pulls/2927/comments --paginate
allow	gh api repos/devantler-tech/monorepo/pulls/2927/commits
allow	gh api repos/devantler-tech/monorepo/commits/cc7ac05bf8/check-runs
allow	gh api repos/devantler-tech/monorepo/issues/2927/timeline --paginate
allow	gh api repos/devantler-tech/platform/rulesets
allow	gh api repos/devantler-tech/platform/rules/branches/main
allow	gh api "repos/devantler-tech/agent-plugins/contents/plugins/agentic-engineering/agents/portfolio-surveyor.agent.md?ref=a0add262"
allow	gh api "orgs/devantler-tech/repos?type=private" --paginate
allow	gh api rate_limit --jq .resources
allow	gh api graphql -f query='query { repository(owner:"devantler-tech", name:"monorepo") { pullRequest(number:2927) { reviewThreads(first:100) { nodes { isResolved } } } } }'
deny	gh pr merge 2927 --repo devantler-tech/monorepo --squash
deny	gh pr create --repo devantler-tech/monorepo --title x --body y
deny	gh pr review 2927 --repo devantler-tech/monorepo --approve
deny	gh pr edit 2927 --repo devantler-tech/monorepo --add-label x
deny	gh issue comment 2927 --repo devantler-tech/monorepo --body x
deny	gh issue close 2927 --repo devantler-tech/monorepo
deny	gh api repos/devantler-tech/monorepo/issues --method POST
deny	gh api -X PATCH repos/devantler-tech/monorepo/issues/2927
deny	gh api -X DELETE repos/devantler-tech/monorepo/git/refs/heads/x
deny	gh api repos/devantler-tech/monorepo/issues -f title=pwned
deny	gh api -X GET repos/devantler-tech/monorepo/issues -F body=@/etc/passwd
deny	gh api --input /etc/passwd repos/devantler-tech/monorepo/issues
deny	gh api repos/devantler-tech/monorepo/actions/runs --jq '.workflow_runs[]|select(.name == $ENV.RUN_NAME)'
deny	gh api graphql -f query='mutation { addComment(input:{subjectId:"x", body:"y"}) { clientMutationId } }'
allow	git log --oneline -20
allow	git log -1 --format=%cI
allow	git --no-optional-locks -c core.fsmonitor= status --porcelain
deny	git status --porcelain
deny	git push origin HEAD
deny	git fetch origin main && git merge --ff-only origin/main
deny	gh auth status --active --hostname github.com
deny	gh api --include --hostname github.com user
deny	env -u GH_TOKEN -u GITHUB_TOKEN gh auth status --active --hostname github.com
deny	git ls-remote origin refs/heads/main
deny	gh project item-add 5 --owner devantler-tech --url https://github.com/x/y/issues/1
allow	gh api -X GET "repos/devantler-tech/monorepo/activity" -f per_page=100 -f "ref=refs/heads/main"
allow	gh api --method GET "repos/devantler-tech/monorepo/activity" -f per_page=100
allow	gh api -X GET search/issues -f q=org:devantler-tech --paginate
deny	RUN_NAME="$run_name" gh api --paginate "repos/devantler-tech/monorepo/actions/workflows/ci.yaml/runs?branch=main&per_page=100" --jq '[.workflow_runs[]]'
deny	fid_status=$(gh api "orgs/devantler-tech/projectsV2/5/fields?per_page=100" --jq '.[]|select(.name=="Status")|.id')
deny	for T in Epic Feature Bug Security Performance Refactor Docs Spike Kata Chore; do gh api "search/issues?q=org:devantler-tech+is:issue+is:open+type:$T&per_page=100" --paginate --jq '.items[] | [((.repository_url|split("/")|last)+"#"+(.number|tostring)), .created_at[0:10], .user.login, .title, ((.body//"")|gsub("[\\n\\r\\t]";" ")|.[0:300])] | @tsv' | sed "s/^/$T\t/"; done
deny	set -o pipefail; fid_status=$(gh api "orgs/devantler-tech/projectsV2/5/fields?per_page=100" --jq '.[]|select(.name=="Status")|.id')
CORPUS
)

pass=0; fail=0; gaps=0
while IFS=$'\t' read -r want cmd; do
  [ -n "${want:-}" ] || continue
  GH_TELEMETRY=0 "$guard" --command "$cmd" >/dev/null 2>&1 && got=allow || got=deny
  case "$want" in
    allow|deny) expect=$want ;;
    gap)        expect=deny ;;
    *) echo "BAD-DISPOSITION '$want'" >&2; fail=$((fail+1)); continue ;;
  esac
  if [ "$got" = "$expect" ]; then
    pass=$((pass+1))
    [ "$want" = gap ] && gaps=$((gaps+1))
  else
    fail=$((fail+1))
    if [ "$want" = gap ]; then
      echo "PROMOTE  (upstream fix appears to have landed — change 'gap' to 'allow'):"
      echo "         $cmd"
    else
      echo "MISMATCH want=$want got=$got"
      echo "         $cmd"
      [ "$got" = deny ] && echo "         reason: $(GH_TELEMETRY=0 "$guard" --command "$cmd" 2>&1)"
    fi
  fi
done <<< "$corpus"

# ── #3127: the declared classifier is admitted ONLY at the RUNNING checkout's path ─────────────
# The forge hook declares `${REPO_ROOT}/.claude/scripts/pr-ownership-disclosure.sh`, resolving
# REPO_ROOT from its own location — the checkout the survey RUNS IN, which the contract mandates be
# a per-run worktree. The overlay must therefore substitute THAT checkout and never the shared one.
#
# Nothing pinned this before: portfolio-surveyor.test.sh matches the prescribed template TEXT, which
# still contains the literal `<repo-root>`, so it stays green whatever the substitution rule says —
# the #3116 lesson one level up, where a test verified the DECLARATION and not the CALL SITE. Five
# live denials of the shared-checkout form followed the absolute-path fix.
#
# Both directions are asserted deliberately. A one-sided check passes if a future guard or hook
# change made every path allowed, which is the failure that matters (it would silently widen what
# the surveyor may execute); the deny row is what keeps the allow row meaningful.
c3127_declared='/tmp/wt-running/.claude/scripts/pr-ownership-disclosure.sh'
c3127_shared='/tmp/shared-checkout/.claude/scripts/pr-ownership-disclosure.sh'
c3127_read='gh pr view 1 --repo devantler-tech/monorepo --json body --jq .body'
c3127_verdict() {
  SURVEYOR_FORGE_READONLY_CLASSIFIERS="$c3127_declared" GH_TELEMETRY=0 \
    "$guard" --command "$c3127_read | $1 --input -" >/dev/null 2>&1 && echo allow || echo deny
}
if [ "$(c3127_verdict "$c3127_declared")" = allow ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "MISMATCH want=allow got=deny  the classifier at the DECLARED running-checkout path (#3127)"
fi
if [ "$(c3127_verdict "$c3127_shared")" = deny ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "MISMATCH want=deny got=allow  a classifier path other than the declared one (#3127)"
fi

total=$((pass + fail))
echo "surveyor-forge-vocabulary: $pass/$total matched ($gaps tracked gap(s) still denied)"
[ "$fail" -eq 0 ] || exit 1
exit 0
