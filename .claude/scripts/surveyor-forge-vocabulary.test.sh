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
# The two `gh search` gaps are pure query FILTERS — `--commenter` selects issues a
# user commented on, `--merged-at` bounds a merge window — so both are reads the
# guard should allow. Both are prescribed by the surveyor definition today, so
# with the guard enforcing, the maintainer-comment sweep and the merged-PR
# retrospective would each fail closed mid-run. Tracked upstream as
# agent-plugins#146. They were found by the sources-to-corpus coverage check in
# `surveyor-vocabulary-coverage.test.sh`, which is the companion to this file.
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
if ! "$guard" --command 'gh pr list --repo devantler-tech/monorepo --state open' >/dev/null 2>&1; then
  echo "surveyor-forge-vocabulary: UNKNOWN — guard denied its own smoke-test read" >&2
  exit 2
fi
if "$guard" --command 'gh pr merge 1 --repo devantler-tech/monorepo --squash' >/dev/null 2>&1; then
  echo "surveyor-forge-vocabulary: UNKNOWN — guard allowed a merge; it is not discriminating" >&2
  exit 2
fi

# ── Corpus ───────────────────────────────────────────────────────────────────
# Tab-separated: <disposition>\t<command>. Tabs are safe here (no raw control
# bytes in the source) and no command below contains one.
corpus=$(cat <<'CORPUS'
allow	gh pr list --repo devantler-tech/monorepo --state open --limit 100 --json number,title,isDraft,headRefName
allow	gh pr view 2927 --repo devantler-tech/monorepo --json number,isDraft,headRefOid,mergeStateStatus,state
allow	gh issue view 108 --repo devantler-tech/agent-plugins --json number,title,state
allow	gh search prs --owner devantler-tech --state open --limit 100
allow	gh search issues --owner devantler-tech --state open --limit 100
gap	gh search issues --owner devantler-tech --state open --commenter devantler --limit 100
gap	gh search prs --owner devantler-tech --merged --merged-at "2026-08-01..2026-08-02" --limit 100
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
deny	gh api graphql -f query='mutation { addComment(input:{subjectId:"x", body:"y"}) { clientMutationId } }'
allow	git log --oneline -20
allow	git log -1 --format=%cI
allow	git --no-optional-locks -c core.fsmonitor= status --porcelain
deny	git status --porcelain
deny	git push origin HEAD
deny	git fetch origin main && git merge --ff-only origin/main
deny	git ls-remote origin refs/heads/main
deny	gh project item-add 5 --owner devantler-tech --url https://github.com/x/y/issues/1
allow	gh api -X GET "repos/devantler-tech/monorepo/activity" -f per_page=100 -f "ref=refs/heads/main"
allow	gh api --method GET "repos/devantler-tech/monorepo/activity" -f per_page=100
allow	gh api -X GET search/issues -f q=org:devantler-tech --paginate
CORPUS
)

pass=0; fail=0; gaps=0
while IFS=$'\t' read -r want cmd; do
  [ -n "${want:-}" ] || continue
  "$guard" --command "$cmd" >/dev/null 2>&1 && got=allow || got=deny
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
      [ "$got" = deny ] && echo "         reason: $("$guard" --command "$cmd" 2>&1)"
    fi
  fi
done <<< "$corpus"

total=$((pass + fail))
echo "surveyor-forge-vocabulary: $pass/$total matched ($gaps tracked gap(s) still denied)"
[ "$fail" -eq 0 ] || exit 1
exit 0
