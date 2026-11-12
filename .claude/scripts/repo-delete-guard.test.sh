#!/usr/bin/env bash
# shellcheck disable=SC2016
# Contract prose uses literal backticks, never shell substitutions.
#
# repo-delete-guard.test.sh — proof for repo-delete-guard.sh (monorepo#4289).
#
# Every case runs the shipped guard against a fixture-driven `gh` on PATH, so no real repository,
# issue or token is touched. Each refusal is paired with the happy path it departs from, so a pass
# cannot come from a check that refuses everything. The guard reads AGENTS.md next to itself, so it
# is copied into a fixture tree whose AGENTS.md is the real one plus one synthetic Stack map row.
set -euo pipefail

# TEMPORARY measurement for monorepo#4394: removed before this change is reviewed.
# Times one process start with TZ unset and with TZ=UTC, so one CI run shows where the
# macOS runner's ~12 seconds per case go.
probe_dir=$(mktemp -d)
printf '#!/usr/bin/env bash\n:\n' >"${probe_dir}/fresh"
chmod +x "${probe_dir}/fresh"
PROBE_FRESH="${probe_dir}/fresh" perl -MTime::HiRes=time -e '
  printf "probe: TZ is %s on %s\n", (exists $ENV{TZ} ? "set to $ENV{TZ}" : "unset"), $^O;
  open(my $out, ">&", \*STDOUT) or die; open(STDOUT, ">", "/dev/null") or die;
  open(STDERR, ">", "/dev/null") or die;
  for my $tz (undef, "UTC") {
    if (defined $tz) { $ENV{TZ} = $tz } else { delete $ENV{TZ} }
    for my $cmd (["/usr/bin/true"], ["bash", "-c", ":"], ["bash", "-c", "x=\$(printf a | sed s/a/b/)"],
                 ["env", "bash", "-c", ":"], [$ENV{PROBE_FRESH}], ["jq", "-n", "1"],
                 ["sed", "-n", "1p", "/dev/null"], ["awk", "BEGIN { }"], ["date", "+%s"]) {
      my $t0 = time; system(@$cmd) for 1 .. 20; my $ms = (time - $t0) * 1000 / 20;
      printf {$out} "probe: TZ=%-7s %-40s %7.1f ms per start\n", ($tz // "<unset>"), join(" ", @$cmd), $ms;
    }
  }' || echo "probe: failed"
rm -rf "${probe_dir}"

# A macOS process left with TZ unset can stall registering for time-zone change notifications on a
# CI runner (#4394). Nothing here reads a clock, so pin the zone, as agent-telemetry.test.sh does.
export TZ=UTC

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${completed}" != 1 ]; then
    echo "repo-delete-guard.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT
failures=0
checks=0

tree="${tmp}/tree"
mkdir -p "${tree}/.claude/scripts" "${tmp}/bin"
cp "${here}/repo-delete-guard.sh" "${tree}/.claude/scripts/"
guard="${tree}/.claude/scripts/repo-delete-guard.sh"
awk '
  { print }
  /^## Stack map$/ { inside = 1 }
  inside && /^\|---\|---\|---\|$/ { print "| Fixture block | a test | `devantler-tech/stack-only` |"; inside = 0 }
' "${root}/AGENTS.md" >"${tree}/AGENTS.md"
grep -Fq '`devantler-tech/stack-only`' "${tree}/AGENTS.md" || {
  echo "FAIL fixture: could not add the synthetic Stack map row" >&2
  exit 1
}

# A fixture-driven gh. `api <path>` serves $FAKE_DIR/api/<key>.json through --jq, or fails with the
# text in <key>.status; `repo delete` marks the repository deleted; every call is traced.
cat >"${tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TRACE"
d=$FAKE_DIR
jqexpr=""
prev=""
for a in "$@"; do
  [ "$prev" = --jq ] && jqexpr=$a
  prev=$a
done
case "$1" in
  issue)
    case "$2" in
      view) cat "$d/issue.json" ;;
      comment)
        [ ! -f "$d/comment-fails" ] || exit 1
        printf '%s\n' "$*" >>"$d/comments"
        ;;
      *) exit 93 ;;
    esac
    ;;
  repo)
    [ "$2" = delete ] || exit 93
    [ ! -f "$d/delete-fails" ] || exit 1
    [ -f "$d/delete-noop" ] || : >"$d/deleted"
    ;;
  api)
    path=$2
    if [ "$path" = "repos/devantler-tech/$FAKE_REPO" ] && [ -f "$d/deleted" ]; then
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
    fi
    key=$(printf '%s' "$path" | sed 's/[^A-Za-z0-9]/_/g')
    f="$d/api/$key"
    if [ -f "$f.status" ]; then
      cat "$f.status" >&2
      exit 1
    fi
    [ -f "$f.json" ] || {
      echo "fake gh: no fixture for $path" >&2
      exit 94
    }
    # <key>.later.json, when present, is served from the second read on: a change during the scan.
    src="$f.json"
    if [ -f "$f.later.json" ]; then
      [ ! -f "$f.seen" ] || src="$f.later.json"
      : >"$f.seen"
    fi
    if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$src"; else cat "$src"; fi
    ;;
  *) exit 93 ;;
esac
EOF
chmod +x "${tmp}/bin/gh"

fake="${tmp}/fake"
SHA_MAIN=1111111111111111111111111111111111111111
SHA_TAG=2222222222222222222222222222222222222222
SHA_PULL=3333333333333333333333333333333333333333
SHA_TAG_OBJECT=4444444444444444444444444444444444444444
fixture() { # fixture <api path> <json>
  local key
  key=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s\n' "$2" >"${fake}/api/${key}.json"
}
fixture_fails() { # fixture_fails <api path> <stderr text>
  local key
  key=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')
  rm -f "${fake}/api/${key}.json"
  printf '%s\n' "$2" >"${fake}/api/${key}.status"
}
# manifest <file> <yaml>: a Crossplane manifest in devantler-tech/.github, served through the Contents API.
manifest() {
  local encoded
  encoded=$(printf '%b\n' "$2" | base64 | tr -d '\n')
  fixture "repos/devantler-tech/.github/contents/deploy/repositories/$1" "{\"content\":\"${encoded}\"}"
}
# A stray repository every check accepts: private, one commit by a trusted author, nothing else.
scenario() { # scenario [name]
  local name=${1:-stray}
  rm -rf "${fake}"
  mkdir -p "${fake}/api"
  : >"${tmp}/trace"
  FAKE_REPO=$name
  printf '{"author":{"login":"devantler"},"state":"OPEN","title":"Delete the stray repository devantler-tech/%s","body":"Created by mistake.","url":"https://github.com/devantler-tech/monorepo/issues/4289"}\n' \
    "$name" >"${fake}/issue.json"
  fixture "repos/devantler-tech/${name}" \
    "{\"full_name\":\"devantler-tech/${name}\",\"has_wiki\":false,\"has_discussions\":false,\"archived\":false,\"private\":true,\"size\":1,\"created_at\":\"2026-10-17T18:14:58Z\",\"default_branch\":\"main\"}"
  fixture "repos/devantler-tech/.github/contents/deploy/repositories" '[{"type":"file","name":"ksail.yaml"},{"type":"file","name":"client-orders.yaml"}]'
  manifest ksail.yaml "metadata:\n  name: ksail\nspec:\n  forProvider:\n    name: ksail"
  manifest client-orders.yaml "metadata:\n  name: client-orders"
  fixture "repos/devantler-tech/${name}/git/refs?per_page=100" \
    "[{\"ref\":\"refs/heads/main\",\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_MAIN}\"}}]"
  fixture "repos/devantler-tech/${name}/commits?sha=${SHA_MAIN}&per_page=100" \
    '[{"sha":"aaaa","author":{"login":"devantler"},"committer":{"login":"web-flow"}}]'
  fixture "repos/devantler-tech/${name}/issues?state=all&per_page=100" '[]'
  fixture "repos/devantler-tech/${name}/issues/comments?per_page=100" '[]'
  fixture "repos/devantler-tech/${name}/pulls/comments?per_page=100" '[]'
  fixture "repos/devantler-tech/${name}/comments?per_page=100" '[]'
}
out=""
rc=0
run_guard() {
  set +e
  out=$(PATH="${tmp}/bin:${PATH}" FAKE_DIR="${fake}" FAKE_TRACE="${tmp}/trace" FAKE_REPO="${FAKE_REPO}" \
    bash "${guard}" "$@" 2>"${tmp}/stderr")
  rc=$?
  set -e
}
pass() {
  checks=$((checks + 1))
  echo "ok   $1"
}
fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL $1" >&2
}
deleted_nothing() { ! grep -q '^repo delete' "${tmp}/trace"; }
# expect <name> <want-rc> <want-line-ERE> <guard args...>: the exit status, one output line
# matching the pattern, and — unless the case is a real deletion — no delete call at all.
expect() {
  local name=$1 want_rc=$2 want=$3
  shift 3
  run_guard "$@"
  if [ "${rc}" != "${want_rc}" ] || ! grep -Eq -- "${want}" <<<"${out}"; then
    fail "${name}: want rc=${want_rc} and a line matching '${want}', got rc=${rc}: ${out} $(cat "${tmp}/stderr")"
  elif [ "${want_rc}" != 0 ] && ! deleted_nothing; then
    fail "${name}: refused, yet gh repo delete was called"
  else
    pass "${name}"
  fi
}

# --- Happy path: a dry run names what it would delete and deletes nothing ---------------------
scenario
expect "dry run of a stray repository" 0 '^WOULD-DELETE devantler-tech/stray \(private, created 2026-10-17T18:14:58Z, 1 commit\(s\), 0 issue\(s\)' \
  --repo stray --issue 4289
if deleted_nothing; then pass "dry run calls no delete"; else fail "dry run called gh repo delete"; fi
expect "owner-qualified name is the same repository" 0 '^WOULD-DELETE devantler-tech/stray ' --repo devantler-tech/stray --issue 4289

# --- The maps: products are refused before any read of the repository -------------------------
for product in ksail platform monorepo .github world-at-ruin; do
  scenario "${product}"
  expect "Portfolio map product ${product} refused" 1 "^REFUSE devantler-tech/${product} is named in the AGENTS.md Portfolio map" \
    --repo "${product}" --issue 4289
done
# A row that lists several repositories names the later ones bare, in backticks.
scenario update-agent-skills-action
expect "bare name in a multi-repository Portfolio map cell refused" 1 '^REFUSE devantler-tech/update-agent-skills-action is named in the AGENTS.md Portfolio map' \
  --repo update-agent-skills-action --issue 4289
scenario stack-only
expect "Stack map repository refused" 1 '^REFUSE devantler-tech/stack-only is named in the AGENTS.md Stack map' --repo stack-only --issue 4289
# A prefix of a listed name is not that name.
scenario ksai
expect "a prefix of a listed name is not refused by the maps" 0 '^WOULD-DELETE devantler-tech/ksai ' --repo ksai --issue 4289

# --- The request: an open monorepo issue that names the repository exactly ---------------------
scenario
printf '{"author":{"login":"devantler"},"state":"CLOSED","title":"Delete devantler-tech/stray","body":"","url":"u"}\n' >"${fake}/issue.json"
expect "closed request refused" 1 '^REFUSE devantler-tech/monorepo#4289 is CLOSED, not an open request' --repo stray --issue 4289
scenario
printf '{"author":{"login":"devantler"},"state":"OPEN","title":"Tidy up stray repositories","body":"Remove the old ones.","url":"u"}\n' >"${fake}/issue.json"
expect "request that names no repository refused" 1 '^REFUSE devantler-tech/monorepo#4289 does not name devantler-tech/stray' --repo stray --issue 4289
scenario
printf '{"author":{"login":"devantler"},"state":"OPEN","title":"Delete devantler-tech/stray-two","body":"Not devantler-tech/strayer either.","url":"u"}\n' >"${fake}/issue.json"
expect "request naming only a longer name refused" 1 '^REFUSE devantler-tech/monorepo#4289 does not name devantler-tech/stray' --repo stray --issue 4289
scenario
printf '{"author":{"login":"devantler"},"state":"OPEN","title":"Cleanup","body":"See https://github.com/devantler-tech/stray, created by mistake.","url":"u"}\n' >"${fake}/issue.json"
expect "request naming the repository in its body accepted" 0 '^WOULD-DELETE devantler-tech/stray ' --repo stray --issue 4289
scenario
printf '{"author":{"login":"devantler"},"state":"OPEN","title":"Cleanup","body":"Please delete devantler-tech/stray.","url":"u"}\n' >"${fake}/issue.json"
expect "a name that ends its sentence is still named" 0 '^WOULD-DELETE devantler-tech/stray ' --repo stray --issue 4289
printf '{"author":{"login":"devantler"},"state":"OPEN","title":"Cleanup","body":"Please delete devantler-tech/stray.old instead.","url":"u"}\n' >"${fake}/issue.json"
expect "a dotted longer name is not this name" 1 '^REFUSE devantler-tech/monorepo#4289 does not name devantler-tech/stray' --repo stray --issue 4289
# The monorepo is public: a request is only a request when a trusted author opened it. The happy
# path above is the same issue opened by `devantler`, so the author is what each of these refuses.
scenario
printf '{"author":{"login":"drive-by"},"state":"OPEN","title":"Delete the stray repository devantler-tech/stray","body":"Created by mistake.","url":"u"}\n' >"${fake}/issue.json"
expect "request opened by an untrusted author refused" 1 '^REFUSE devantler-tech/monorepo#4289 was opened by drive-by, who is not a trusted author' --repo stray --issue 4289
if grep -q '^api ' "${tmp}/trace"; then fail "an untrusted request still read the repository"; else pass "an untrusted request reads nothing of the repository"; fi
scenario
printf '{"author":{"login":"app/copilot-swe-agent"},"state":"OPEN","title":"Delete devantler-tech/stray","body":"","url":"u"}\n' >"${fake}/issue.json"
expect "request opened by a GitHub App refused" 1 '^REFUSE devantler-tech/monorepo#4289 was opened by app/copilot-swe-agent, who is not a trusted author' --repo stray --issue 4289
scenario
printf '{"author":null,"state":"OPEN","title":"Delete devantler-tech/stray","body":"","url":"u"}\n' >"${fake}/issue.json"
expect "request with no linkable author refused" 1 '^REFUSE devantler-tech/monorepo#4289 has no author GitHub can link' --repo stray --issue 4289
scenario
expect "request by a trusted author names its author" 0 '^CHECK requested by open devantler-tech/monorepo#4289, opened by trusted author devantler$' --repo stray --issue 4289
scenario
rm "${fake}/issue.json"
expect "unreadable request is UNKNOWN" 2 '^UNKNOWN cannot read devantler-tech/monorepo#4289' --repo stray --issue 4289

# --- The repository: archived, Crossplane-managed, missing or unreadable -----------------------
scenario
fixture "repos/devantler-tech/stray" '{"full_name":"devantler-tech/stray","has_wiki":false,"has_discussions":false,"archived":true,"private":true,"size":1,"created_at":"2026-10-17T18:14:58Z","default_branch":"main"}'
expect "archived repository refused" 1 '^REFUSE devantler-tech/stray is archived' --repo stray --issue 4289
scenario client-orders
printf '{"author":{"login":"devantler"},"state":"OPEN","title":"Delete devantler-tech/client-orders","body":"","url":"u"}\n' >"${fake}/issue.json"
expect "Crossplane-managed repository refused" 1 '^REFUSE devantler-tech/client-orders is managed by Crossplane' --repo client-orders --issue 4289
scenario
fixture_fails "repos/devantler-tech/stray" 'gh: Not Found (HTTP 404)'
expect "missing repository is UNKNOWN" 2 '^UNKNOWN devantler-tech/stray was not found' --repo stray --issue 4289
scenario
fixture_fails "repos/devantler-tech/stray" 'gh: Server Error (HTTP 502)'
expect "unreadable repository is UNKNOWN" 2 '^UNKNOWN cannot read devantler-tech/stray$' --repo stray --issue 4289
scenario
fixture_fails "repos/devantler-tech/.github/contents/deploy/repositories" 'gh: Server Error (HTTP 502)'
expect "unreadable manifest list is UNKNOWN" 2 '^UNKNOWN cannot list the Crossplane repository manifests' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/.github/contents/deploy/repositories" '[]'
expect "empty manifest list is UNKNOWN, never 'not managed'" 2 '^UNKNOWN the Crossplane repository manifest list' --repo stray --issue 4289
# A manifest's file name need not match the repository it manages (dot-github.yaml manages .github).
for key in "metadata:\n  name: stray" "metadata:\n  annotations:\n    crossplane.io/external-name: \"stray\"" \
  "spec:\n  forProvider:\n    name: 'stray' # adopted"; do
  scenario
  fixture "repos/devantler-tech/.github/contents/deploy/repositories" '[{"type":"file","name":"ksail.yaml"},{"type":"file","name":"stray-repo.yaml"}]'
  manifest stray-repo.yaml "$key"
  expect "a manifest under another file name that names the repository is refused ($(printf '%b' "$key" | tail -n 1 | tr -s ' '))" \
    1 '^REFUSE devantler-tech/stray is managed by Crossplane in devantler-tech/.github \(stray-repo.yaml\)' --repo stray --issue 4289
done
scenario
fixture "repos/devantler-tech/.github/contents/deploy/repositories" '[{"type":"file","name":"ksail.yaml"},{"type":"file","name":"stray-repo.yaml"}]'
manifest stray-repo.yaml "metadata:\n  name: stray-repo\nspec:\n  forProvider:\n    name: stray-repo"
expect "a manifest naming another repository is not a refusal" 0 '^WOULD-DELETE devantler-tech/stray ' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/.github/contents/deploy/repositories" '[{"type":"file","name":"ksail.yaml"},{"type":"dir","name":"extra"}]'
expect "a manifest directory entry that is not a file is UNKNOWN" 2 '^UNKNOWN devantler-tech/.github deploy/repositories holds extra' --repo stray --issue 4289
scenario
fixture_fails "repos/devantler-tech/.github/contents/deploy/repositories/client-orders.yaml" 'gh: Server Error (HTTP 502)'
expect "an unreadable manifest is UNKNOWN" 2 '^UNKNOWN cannot read the Crossplane manifest client-orders.yaml' --repo stray --issue 4289
# Discussions and a wiki hold content the guard does not read, so either one switched on is refused.
scenario
fixture "repos/devantler-tech/stray" '{"full_name":"devantler-tech/stray","has_wiki":false,"has_discussions":true,"archived":false,"private":true,"size":1,"created_at":"2026-10-17T18:14:58Z","default_branch":"main"}'
expect "a repository with Discussions on is refused" 1 '^REFUSE devantler-tech/stray has Discussions turned on' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/stray" '{"full_name":"devantler-tech/stray","has_wiki":true,"has_discussions":false,"archived":false,"private":true,"size":1,"created_at":"2026-10-17T18:14:58Z","default_branch":"main"}'
expect "a repository with its wiki on is refused" 1 '^REFUSE devantler-tech/stray has its wiki turned on' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/stray" '{"full_name":"devantler-tech/stray","archived":false,"private":true,"size":1,"created_at":"2026-10-17T18:14:58Z","default_branch":"main"}'
expect "an unreadable Discussions setting is UNKNOWN" 2 '^UNKNOWN cannot read whether devantler-tech/stray has Discussions' --repo stray --issue 4289

# --- Who wrote it: anyone outside the trust gate's trusted authors is refused ------------------
scenario
fixture "repos/devantler-tech/stray/commits?sha=${SHA_MAIN}&per_page=100" \
  '[{"sha":"aaaa","author":{"login":"devantler"},"committer":{"login":"web-flow"}},{"sha":"bbbb","author":{"login":"someone-else"},"committer":{"login":"someone-else"}}]'
expect "commit by an outsider refused" 1 '^REFUSE devantler-tech/stray has a commit by someone-else' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/stray/commits?sha=${SHA_MAIN}&per_page=100" '[{"sha":"aaaa","author":null,"committer":{"login":"web-flow"}}]'
expect "commit by an unlinked account refused" 1 '^REFUSE devantler-tech/stray has a commit by an account GitHub cannot link' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/stray/commits?sha=${SHA_MAIN}&per_page=100" '[{"sha":"aaaa","author":{"login":"dependabot[bot]"},"committer":{"login":"copilot-swe-agent[bot]"}}]'
expect "commit committed by an untrusted bot refused" 1 '^REFUSE devantler-tech/stray has a commit committed by copilot-swe-agent\[bot\]' --repo stray --issue 4289
# History reachable only through a tag, a pull-request head or an annotated tag is walked too: a
# branch-only walk would pass a repository whose outsider commits outlived their branch.
outsider_rows='[{"sha":"cccc","author":{"login":"outsider"},"committer":{"login":"outsider"}}]'
refs_with() { # refs_with <extra ref json>: main plus one more ref
  fixture "repos/devantler-tech/stray/git/refs?per_page=100" \
    "[{\"ref\":\"refs/heads/main\",\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_MAIN}\"}},$1]"
}
scenario
refs_with "{\"ref\":\"refs/tags/v1.0.0\",\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_TAG}\"}}"
fixture "repos/devantler-tech/stray/commits?sha=${SHA_TAG}&per_page=100" "${outsider_rows}"
expect "outsider commit reachable only from a tag refused" 1 '^REFUSE devantler-tech/stray has a commit by outsider' --repo stray --issue 4289
scenario
refs_with "{\"ref\":\"refs/pull/3/head\",\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_PULL}\"}}"
fixture "repos/devantler-tech/stray/commits?sha=${SHA_PULL}&per_page=100" "${outsider_rows}"
expect "outsider commit reachable only from a pull-request head refused" 1 '^REFUSE devantler-tech/stray has a commit by outsider' --repo stray --issue 4289
scenario
refs_with "{\"ref\":\"refs/tags/v2\",\"object\":{\"type\":\"tag\",\"sha\":\"${SHA_TAG_OBJECT}\"}}"
fixture "repos/devantler-tech/stray/git/tags/${SHA_TAG_OBJECT}" "{\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_TAG}\"}}"
fixture "repos/devantler-tech/stray/commits?sha=${SHA_TAG}&per_page=100" "${outsider_rows}"
expect "outsider commit behind an annotated tag refused" 1 '^REFUSE devantler-tech/stray has a commit by outsider' --repo stray --issue 4289
# The same annotated tag over trusted history passes, so the peel is what reached the outsider.
fixture "repos/devantler-tech/stray/commits?sha=${SHA_TAG}&per_page=100" \
  '[{"sha":"dddd","author":{"login":"devantler"},"committer":{"login":"web-flow"}}]'
expect "annotated tag over trusted history accepted" 0 '^WOULD-DELETE devantler-tech/stray \(private, created [^,]+, 2 commit' --repo stray --issue 4289
scenario
refs_with "{\"ref\":\"refs/tags/tree\",\"object\":{\"type\":\"tag\",\"sha\":\"${SHA_TAG_OBJECT}\"}}"
fixture "repos/devantler-tech/stray/git/tags/${SHA_TAG_OBJECT}" "{\"object\":{\"type\":\"tree\",\"sha\":\"${SHA_TAG}\"}}"
expect "a tag pointing at a tree is refused, never skipped" 1 '^REFUSE devantler-tech/stray has refs/tags/tree pointing at a tree' --repo stray --issue 4289
scenario
refs_with "{\"ref\":\"refs/tags/v3\",\"object\":{\"type\":\"tag\",\"sha\":\"${SHA_TAG_OBJECT}\"}}"
fixture_fails "repos/devantler-tech/stray/git/tags/${SHA_TAG_OBJECT}" 'gh: Server Error (HTTP 502)'
expect "an unreadable annotated tag is UNKNOWN" 2 '^UNKNOWN cannot read the annotated tag behind refs/tags/v3' --repo stray --issue 4289
scenario
refs_with "{\"ref\":\"refs/notes/commits\",\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_TAG}\"}}"
expect "an unreadable history behind any ref is UNKNOWN" 2 '^UNKNOWN cannot list the commits of devantler-tech/stray reachable from refs/notes/commits' --repo stray --issue 4289
scenario
fixture_fails "repos/devantler-tech/stray/git/refs?per_page=100" 'gh: Server Error (HTTP 502)'
expect "an unreadable ref list is UNKNOWN" 2 '^UNKNOWN cannot list the refs of devantler-tech/stray' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/stray/issues?state=all&per_page=100" '[{"number":1,"user":{"login":"devantler"}},{"number":2,"user":{"login":"drive-by"}}]'
expect "issue by an outsider refused" 1 '^REFUSE devantler-tech/stray has an issue or pull request by drive-by' --repo stray --issue 4289
# A review's own body is on none of the comment lists, so each pull request's reviews are read.
scenario
fixture "repos/devantler-tech/stray/issues?state=all&per_page=100" '[{"number":3,"user":{"login":"devantler"},"pull_request":{}}]'
fixture "repos/devantler-tech/stray/pulls/3/reviews?per_page=100" '[{"user":{"login":"devantler"}},{"user":{"login":"reviewer"}}]'
expect "an outsider's review body refused" 1 '^REFUSE devantler-tech/stray has a pull-request review by reviewer' --repo stray --issue 4289
fixture "repos/devantler-tech/stray/pulls/3/reviews?per_page=100" '[{"user":{"login":"devantler"}}]'
expect "a pull request reviewed only by trusted authors accepted" 0 '^WOULD-DELETE devantler-tech/stray \(private, created [^,]+, 1 commit\(s\), 1 issue' --repo stray --issue 4289
fixture_fails "repos/devantler-tech/stray/pulls/3/reviews?per_page=100" 'gh: Server Error (HTTP 502)'
expect "unreadable reviews are UNKNOWN" 2 '^UNKNOWN cannot list the reviews of devantler-tech/stray#3' --repo stray --issue 4289
for kind in issues/comments pulls/comments comments; do
  scenario
  fixture "repos/devantler-tech/stray/${kind}?per_page=100" '[{"user":{"login":"commenter"}}]'
  expect "${kind} by an outsider refused" 1 '^REFUSE devantler-tech/stray has a comment by commenter' --repo stray --issue 4289
done
# Every trusted author from the AGENTS.md trust gate is accepted, so the list is read, not guessed.
scenario
fixture "repos/devantler-tech/stray/commits?sha=${SHA_MAIN}&per_page=100" \
  '[{"sha":"a1","author":{"login":"ksail-bot[bot]"},"committer":{"login":"web-flow"}},{"sha":"a2","author":{"login":"renovate[bot]"},"committer":{"login":"renovate[bot]"}},{"sha":"a3","author":{"login":"github-actions[bot]"},"committer":{"login":"devantler"}}]'
expect "commits by every trusted author accepted" 0 '^WOULD-DELETE devantler-tech/stray \(private, created [^,]+, 3 commit' --repo stray --issue 4289
# More history than one page could hold is refused, never judged on the rows that were read.
scenario
rows=$(jq -nc '[range(100) | {sha: "s\(.)", author: {login: "devantler"}, committer: {login: "web-flow"}}]')
fixture "repos/devantler-tech/stray/commits?sha=${SHA_MAIN}&per_page=100" "${rows}"
expect "a full page of commits refused" 1 '^REFUSE devantler-tech/stray has at least 100 commits reachable from refs/heads/main' --repo stray --issue 4289
scenario
fixture "repos/devantler-tech/stray/git/refs?per_page=100" \
  "$(jq -nc --arg s "${SHA_MAIN}" '[range(31) | {ref: "refs/heads/b\(.)", object: {type: "commit", sha: $s}}]')"
expect "more than thirty refs refused" 1 '^REFUSE devantler-tech/stray has more than 30 refs' --repo stray --issue 4289
scenario
fixture_fails "repos/devantler-tech/stray/pulls/comments?per_page=100" 'gh: Server Error (HTTP 502)'
expect "unreadable review comments are UNKNOWN" 2 '^UNKNOWN cannot list the pulls/comments of devantler-tech/stray' --repo stray --issue 4289
# An empty repository has no refs, which GitHub reports as a 409, so no commit read is needed.
scenario
fixture_fails "repos/devantler-tech/stray/git/refs?per_page=100" 'gh: Git Repository is empty. (HTTP 409)'
expect "empty repository accepted" 0 '^WOULD-DELETE devantler-tech/stray \(private, created [^,]+, 0 commit' --repo stray --issue 4289

# --- The contract the guard reads must be intact, or nothing is judged ---------------------------
for broken in 'stack-map-heading' 'trusted-authors'; do
  scenario
  # Each break must be refused for its own reason, before any gh call: a bare '^UNKNOWN ' would
  # also pass on a missing tool or an unreadable contract file.
  case "${broken}" in
    stack-map-heading)
      sed 's/^## Stack map$/## Stack list/' "${tree}/AGENTS.md" >"${tmp}/agents.md"
      want="^UNKNOWN AGENTS.md has no 'Stack map' section to check against$"
      ;;
    trusted-authors)
      sed 's/Trusted authors, exact login match only/Trusted authors/' "${tree}/AGENTS.md" >"${tmp}/agents.md"
      want='^UNKNOWN cannot read the trusted authors from the AGENTS.md trust gate$'
      ;;
  esac
  cp "${tree}/AGENTS.md" "${tmp}/agents.saved"
  cp "${tmp}/agents.md" "${tree}/AGENTS.md"
  expect "a contract without its ${broken} is UNKNOWN" 2 "${want}" --repo stray --issue 4289
  if [ -s "${tmp}/trace" ]; then
    fail "a contract without its ${broken}: gh was called before the contract was judged"
  else
    pass "a contract without its ${broken} makes no gh call"
  fi
  cp "${tmp}/agents.saved" "${tree}/AGENTS.md"
done

# The next trust-gate bullet names the UNTRUSTED authors in the same backtick form. A trusted-author
# bullet reworded to end without a sentence stop must not run on into it and trust them.
scenario
cp "${tree}/AGENTS.md" "${tmp}/agents.saved"
awk '
  /^- \*\*Trusted authors, exact login match only:\*\*/ { print; getline; print "  `github-actions[bot]`, `renovate[bot]`"; getline; next }
  { print }
' "${tmp}/agents.saved" >"${tree}/AGENTS.md"
if grep -Fq '`renovate[bot]`. Agent work' "${tree}/AGENTS.md" || ! grep -Fq '`copilot-swe-agent[bot]`' "${tree}/AGENTS.md"; then
  fail "fixture: could not reword the trusted-author bullet to end without a sentence stop"
fi
fixture "repos/devantler-tech/stray/commits?sha=${SHA_MAIN}&per_page=100" '[{"sha":"aaaa","author":{"login":"copilot-swe-agent[bot]"},"committer":{"login":"web-flow"}}]'
expect "an untrusted author named in the next trust-gate bullet stays untrusted" 1 '^REFUSE devantler-tech/stray has a commit by copilot-swe-agent\[bot\]' --repo stray --issue 4289
cp "${tmp}/agents.saved" "${tree}/AGENTS.md"

# --- Usage: refused before anything is read -------------------------------------------------------
for args in "--repo stray" "--issue 4289" "--repo other-owner/stray --issue 4289" "--repo ../stray --issue 4289" \
  "--repo .. --issue 4289" "--repo stray --issue 12a" "--repo stray --issue 4289 --actor maintainer"; do
  scenario
  # shellcheck disable=SC2086 # the cases are word lists on purpose
  run_guard ${args}
  if [ "${rc}" = 2 ] && [ ! -s "${tmp}/trace" ]; then pass "usage refused: ${args}"; else
    fail "usage: ${args}: want rc=2 and no gh call, got rc=${rc}"
  fi
done

# --- Apply: delete once, read the absence back, record it with a disclosure line -----------------
scenario
expect "apply deletes a stray repository" 0 '^DELETED devantler-tech/stray \(private' --repo stray --issue 4289 --apply
if [ "$(grep -c '^repo delete devantler-tech/stray --yes$' "${tmp}/trace")" = 1 ]; then pass "apply calls gh repo delete exactly once"; else
  fail "apply: want exactly one 'repo delete devantler-tech/stray --yes' call"
fi
if grep -q '^issue comment 4289 --repo devantler-tech/monorepo --body > 🤖 Generated by the Agentic Engineer' "${fake}/comments" &&
  grep -q 'restore it for 90 days' "${fake}/comments"; then
  pass "apply records the deletion and its restore window, opening with the disclosure line"
else
  fail "apply: the record on the issue lacks the disclosure line or the restore window: $(cat "${fake}/comments" 2>/dev/null)"
fi
scenario
run_guard --repo stray --issue 4289 --apply --actor improver
if [ "${rc}" = 0 ] && grep -q -- '--body > 🤖 Generated by the Agent Improver' "${fake}/comments"; then pass "the improver's record carries its own disclosure line"; else
  fail "improver record: rc=${rc} $(cat "${fake}/comments" 2>/dev/null)"
fi
scenario
: >"${fake}/delete-noop"
run_guard --repo stray --issue 4289 --apply
if [ "${rc}" = 1 ] && grep -q '^FAILED devantler-tech/stray: it is still readable after the delete' <<<"${out}" && [ ! -f "${fake}/comments" ]; then
  pass "a repository still readable after the delete is a failure, and nothing is recorded"
else
  fail "delete no-op: rc=${rc} ${out}"
fi
scenario
: >"${fake}/delete-fails"
run_guard --repo stray --issue 4289 --apply
if [ "${rc}" = 1 ] && grep -q '^FAILED devantler-tech/stray: gh repo delete did not succeed' <<<"${out}"; then pass "a failed delete is reported"; else
  fail "failed delete: rc=${rc} ${out}"
fi
scenario
: >"${fake}/comment-fails"
run_guard --repo stray --issue 4289 --apply
if [ "${rc}" = 1 ] && grep -q '^FAILED devantler-tech/stray: deleted and read back, but the record' <<<"${out}"; then
  pass "a deletion whose record cannot be posted is reported, not hidden"
else
  fail "record failure: rc=${rc} ${out}"
fi
fixture_later() { # fixture_later <api path> <json>: served from the second read of that path on
  local key
  key=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')
  printf '%s\n' "$2" >"${fake}/api/${key}.later.json"
}
scenario
fixture_later "repos/devantler-tech/stray/issues?state=all&per_page=100" '[{"number":5,"user":{"login":"devantler"}}]'
expect "an issue opened during the scan stops the delete" 2 '^UNKNOWN devantler-tech/stray changed while it was being examined' --repo stray --issue 4289 --apply
scenario
fixture_later "repos/devantler-tech/stray/issues?state=all&per_page=100" '[{"number":5,"user":{"login":"drive-by"}}]'
expect "an outsider's issue opened during the scan is refused" 1 '^REFUSE devantler-tech/stray has an issue or pull request by drive-by' --repo stray --issue 4289 --apply
scenario
fixture_later "repos/devantler-tech/stray/git/refs?per_page=100" \
  "[{\"ref\":\"refs/heads/main\",\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_MAIN}\"}},{\"ref\":\"refs/heads/new\",\"object\":{\"type\":\"commit\",\"sha\":\"${SHA_PULL}\"}}]"
fixture "repos/devantler-tech/stray/commits?sha=${SHA_PULL}&per_page=100" '[{"sha":"bbbb","author":{"login":"devantler"},"committer":{"login":"web-flow"}}]'
expect "a ref pushed during the scan stops the delete" 2 '^UNKNOWN devantler-tech/stray changed while it was being examined' --repo stray --issue 4289 --apply
# Every check the first pass makes is made again before the delete, not only the ones listed by name.
scenario
fixture_later "repos/devantler-tech/stray" '{"full_name":"devantler-tech/stray","has_wiki":false,"has_discussions":false,"archived":true,"private":true,"size":1,"created_at":"2026-10-17T18:14:58Z","default_branch":"main"}'
expect "a repository archived during the scan is refused" 1 '^REFUSE devantler-tech/stray is archived' --repo stray --issue 4289 --apply
scenario
fixture_later "repos/devantler-tech/.github/contents/deploy/repositories" '[{"type":"file","name":"ksail.yaml"},{"type":"file","name":"stray.yaml"}]'
expect "a Crossplane manifest added during the scan is refused" 1 '^REFUSE devantler-tech/stray is managed by Crossplane' --repo stray --issue 4289 --apply
scenario
fixture_later "repos/devantler-tech/stray" '{"full_name":"devantler-tech/stray","has_wiki":false,"has_discussions":false,"archived":false,"private":false,"size":1,"created_at":"2026-10-17T18:14:58Z","default_branch":"main"}'
expect "any other change to the repository during the scan stops the delete" 2 '^UNKNOWN devantler-tech/stray changed while it was being examined' --repo stray --issue 4289 --apply
scenario
fixture_later "repos/devantler-tech/stray/comments?per_page=100" '[{"id":7,"user":{"login":"devantler"}}]'
expect "a commit comment posted during the scan stops the delete" 2 '^UNKNOWN devantler-tech/stray changed while it was being examined' --repo stray --issue 4289 --apply
scenario
fixture_later "repos/devantler-tech/stray/issues/comments?per_page=100" '[{"id":8,"user":{"login":"drive-by"}}]'
expect "an outsider's comment posted during the scan stops the delete" 1 '^REFUSE devantler-tech/stray has a comment by drive-by' --repo stray --issue 4289 --apply
scenario
fixture "repos/devantler-tech/stray/issues?state=all&per_page=100" '[{"number":3,"user":{"login":"devantler"},"pull_request":{}}]'
fixture "repos/devantler-tech/stray/pulls/3/reviews?per_page=100" '[{"id":1,"user":{"login":"devantler"}}]'
fixture_later "repos/devantler-tech/stray/pulls/3/reviews?per_page=100" '[{"id":1,"user":{"login":"devantler"}},{"id":2,"user":{"login":"devantler"}}]'
expect "a review submitted during the scan stops the delete" 2 '^UNKNOWN devantler-tech/stray changed while it was being examined' --repo stray --issue 4289 --apply
if [ -f "${fake}/deleted" ]; then fail "a moved discussion still deleted the repository"; else
  pass "a moved discussion leaves the repository undeleted"
fi
scenario
run_guard --repo stray --issue 4289 --apply
item_reads=$(grep -cF 'api repos/devantler-tech/stray/issues?state=all&per_page=100' "${tmp}/trace" || true)
ref_reads=$(grep -cF 'api repos/devantler-tech/stray/git/refs?per_page=100' "${tmp}/trace" || true)
comment_reads=$(grep -cF 'api repos/devantler-tech/stray/comments?per_page=100' "${tmp}/trace" || true)
if [ "${rc}" = 0 ] && grep -q '^DELETED devantler-tech/stray' <<<"${out}" && [ "${item_reads}" = 2 ] && [ "${ref_reads}" = 2 ] &&
  [ "${comment_reads}" = 2 ]; then
  pass "an unchanged recheck still deletes, and the recheck really re-read the list"
else
  fail "unchanged recheck: rc=${rc} ${out}"
fi
scenario
fixture "repos/devantler-tech/stray/issues?state=all&per_page=100" '[{"number":2,"user":{"login":"drive-by"}}]'
expect "apply still refuses an outsider's repository" 1 '^REFUSE devantler-tech/stray has an issue or pull request by drive-by' --repo stray --issue 4289 --apply

# --- The contract names the guard as the only deletion path ---------------------------------------
guide="${root}/.claude/guides/github-artifacts.md"
flat="$(tr '\n' ' ' <"${guide}" | tr -s ' ')"
for phrase in '[`repo-delete-guard.sh`](../scripts/repo-delete-guard.sh)' 'never a bare `gh repo delete`' \
  'never with `gh repo create`' '`deploy/repositories/<name>.yaml`'; do
  case "${flat}" in
    *"${phrase}"*) pass "contract: github-artifacts.md says ${phrase}" ;;
    *) fail "contract: github-artifacts.md must say ${phrase}" ;;
  esac
done

completed=1
echo "repo-delete-guard: ${checks} checks, ${failures} failures"
[ "${failures}" -eq 0 ]
