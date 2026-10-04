#!/usr/bin/env bash
# pr-worktree-holder.sh — is a live process working in a local checkout of a PR's head branch?
# (monorepo#3067)
#
# WHY THIS EXISTS
#   Before a run takes over a PR it asks whether anyone else is working on it, and every signal the
#   active-work test read was a PUBLISHED event: a push, a human comment, a review request, a merge
#   queue run. A session publishes nothing while it reads, builds or waits on CI. On 2026-08-25
#   monorepo#3053 read idle on all four, its last push 3h24m old, while two live sessions worked in
#   its worktree; only a manual `lsof` on that worktree stopped a two-writer collision, the third
#   such near miss. This helper asks the host instead: which live processes have their working
#   directory in a checkout of the head branch.
#
# USAGE
#   gh pr view <n> --repo <owner>/<repo> --json url,headRefName,headRepositoryOwner,headRepository |
#     pr-worktree-holder.sh --input -
#   The same fields from `gh pr list --json` (an array) work too. The forge JSON on stdin is the only
#   input, which is the one shape the surveyor's read-only guard admits for a declared helper; no
#   PR-supplied text ever becomes an argument or a path.
#
# OUTPUT (one line per PR, in input order)
#   <owner>/<repo>#<n> holder=<value>
#   live:<count>:<pid>/<cmd>[,...]  a process OUTSIDE the asking session works in a checkout of the
#                                   head branch, or a live session locked a worktree that serves
#                                   it (at most three are named, sessions first). A lock names the
#                                   session, so the pid can be the ASKER'S OWN session: one of its
#                                   workers holds that worktree, or held it and has returned
#                                   (see WORKTREE LOCKS and SELF)
#   self:<count>:<pid>/<cmd>[,...]  only the asking session itself does, so it is never a rival
#   live:...+self:...               both
#   none                            the process enumeration was complete and nothing holds one
#   fork                            the head is in another owner's repository: no lane on this host
#                                   checks it out, so there is nothing local to examine
#   unknown:<reason>                the helper could not tell, and that is NEVER `none`. Reasons:
#                                   input, lsof-missing, lsof-failed, lsof-empty, ps-failed,
#                                   worktree-list, lock-reason
#
# WHAT HOLDING A CHECKOUT MEANS
#   A process holds the checkout containing its working directory, every populated submodule of
#   that checkout and, when that checkout is a linked (per-session) worktree, the worktrees its
#   submodules register inside their own directories: the per-run product worktrees the
#   git-and-worktrees guide prescribes. A session usually sits at its worktree root while its
#   branch is checked out in a submodule below it, so stopping at the working directory would miss
#   most product PRs. A MAIN checkout never claims worktrees beneath it, because every per-session
#   worktree lives inside the main checkout and one shell there would then hold every branch on the
#   host. A checkout serves a PR when any of its remotes names the PR's head repository and its
#   branch is the head branch, including a branch that is mid-rebase or mid-bisect (HEAD detached,
#   the branch still named in the checkout's git directory).
#   A shell holds a checkout only while something other than a shell runs below it: a terminal tab
#   left open at its prompt in a worktree does no work, and counting it would park that worktree's
#   PR for as long as the tab exists. Any other process holds its checkout for as long as it lives,
#   busy or not: the process table cannot tell an idle session from a thinking one, and the report
#   names the holder so a forgotten one is seen.
#
# WORKTREE LOCKS (monorepo#3780)
#   An isolated subagent works in its own worktree but keeps no process there: its commands come
#   and go, and the long-lived process is the parent session's, whose working directory is the
#   parent's worktree. Between two of the worker's commands nothing has a working directory in its
#   checkout, so its PR read `none` mid-flight. The harness records the owner instead: it locks
#   every worktree it creates, and the lock reason names the owning session process,
#     claude <kind> <name> (pid <pid> start <start>)
#   where <start> is what `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` printed when the lock was taken.
#   A lock holds its worktree, and the checkouts that worktree owns, exactly like a working
#   directory, while that pid is alive AND still has the recorded start time. An exited process
#   holds nothing, and neither does a pid that another process has since been given: its start
#   time differs. The locks read are those of every repository a live process works in, and of
#   the repository the helper is asked from.
#   A lock the helper cannot read as that identity is `unknown:lock-reason` for the PRs its
#   worktree serves, never `none`: a lock with no reason or someone else's reason, a start time in
#   any other shape, and a lock that records no start time while its pid is alive (nothing then
#   tells the owner from a reused pid). A holder found another way still answers `live:`, because
#   an unread lock can only add holders. A lock stays for as long as the harness keeps the
#   worktree, so it also holds after the worker has returned, until its session exits.
#
# SELF
#   The asking session is not its own rival, the same exclusion the contract makes for its own
#   push. The asking session is the nearest `claude`/`codex` process above this helper. A holder is
#   `self` when it is on this helper's ancestry (up to that session, and through the launchers above
#   it, but never past a second session process), descends from this helper, or descends from that
#   session process and works inside the asker's own checkout tree. Another session process in the
#   same worktree, a sibling subagent in a different worktree, and an outer session that launched
#   the asking one all stay `live`. Sessions that share ONE host process cannot be told apart and
#   read as one session. With no session process among the ancestors, only this helper's ancestry
#   and descendants are `self`, so the asker's own background work reads `live`: the conservative
#   direction.
#   A lock names the session, not the worker, and every worker of one session shares that
#   process. So a locked worktree is `self` only when its session is the asker's AND the worktree
#   is inside the asker's own checkout tree: a subagent asking from its own worktree. The same
#   session's lock on any other worktree is a sibling worker's, or a worker of the session that
#   asks, and stays `live`.
#
# SCOPE
#   Only sessions on this host have local processes. A session on another machine does not, so its
#   PRs read `none` here and keep the published-event signals.
#
# EXIT CODES
#   0  every PR was answered
#   2  UNKNOWN: a usage error, unreadable input, or any PR answered `unknown:`. A failed or partial
#      `lsof` (a nonzero exit, or no working directories at all) never yields `none`, and neither
#      does a worktree list or a process start time that could not be read.
set -euo pipefail

# Every git call names its directory. An inherited location variable would redirect them all.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE GIT_CEILING_DIRECTORIES
export GIT_OPTIONAL_LOCKS=0

if [ "$#" -ne 2 ] || [ "$1" != "--input" ] || [ "$2" != "-" ]; then
  echo "usage: gh pr view <n> --repo <owner>/<repo> --json url,headRefName,headRepositoryOwner,headRepository | pr-worktree-holder.sh --input -" >&2
  exit 2
fi
for tool in jq git awk; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "pr-worktree-holder: ${tool} is required" >&2
    exit 2
  }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/pr-worktree-holder.XXXXXX")" || exit 2
finished=0
# bash 3.2 can report a `set -u` abort as exit 0 from an EXIT trap, so completion is explicit: any
# exit before the verdict is printed is UNKNOWN. Inline rather than a handler function, because
# the linter versions in CI and on the agent host disagree about a trap-only function.
trap 'rm -rf -- "${work}"; if [ "${finished}" != 1 ]; then exit 2; fi' EXIT

unreadable() {
  echo "pr-worktree-holder: $1" >&2
  printf '? holder=unknown:input\n'
  exit 2
}

payload="$(cat)" || unreadable "cannot read stdin"
case "${payload}" in
  *[![:space:]]*) ;;
  *) unreadable "stdin is empty" ;;
esac

# One TSV row per PR: <id> <input|fork|key> <head owner/repo, lower-cased> <head branch>. The key is
# the HEAD repository, so a cross-repository PR inside the organisation matches its own checkout.
jq -r '
  (if type == "array" then to_entries[]
   elif type == "object" then {key: 0, value: .}
   else error("stdin is not a PR object or array") end)
  | .key as $i
  | (if (.value | type) == "object" then .value else {} end) as $p
  | ([$p.url | strings
      | capture("^https://github\\.com/(?<o>[A-Za-z0-9_.-]+)/(?<r>[A-Za-z0-9_.-]+)/pull/(?<n>[0-9]+)$")]
     | .[0]) as $m
  | if $m == null then ["pr[\($i)]", "input", "", ""]
    else "\($m.o)/\($m.r)#\($m.n)" as $id
    | if ($p.headRefName | type) != "string" or $p.headRefName == "" then [$id, "input", "", ""]
      elif ($p.headRepositoryOwner | type) != "object"
        or ($p.headRepositoryOwner.login | type) != "string" then [$id, "input", "", ""]
      elif ($p.headRepositoryOwner.login | ascii_downcase) != ($m.o | ascii_downcase) then [$id, "fork", "", ""]
      elif ($p.headRepository | type) != "object"
        or ($p.headRepository.name | type) != "string" or $p.headRepository.name == "" then [$id, "input", "", ""]
      else [$id, "key", ("\($m.o)/\($p.headRepository.name)" | ascii_downcase), $p.headRefName] end
    end
  | @tsv
' <<<"${payload}" >"${work}/prs" 2>/dev/null ||
  unreadable "stdin is not the JSON of gh pr view/list --json url,headRefName,headRepositoryOwner,headRepository"

# The head branches worth resolving remotes for, newline-delimited with sentinels at both ends.
heads=$'\n'"$(awk -F'\t' '$2 == "key" { print $4 }' "${work}/prs")"$'\n'
wanted() {
  case "${heads}" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# repo_slug <remote-url> — `owner/name`, lower-cased, for scp-style, https, ssh and path remotes.
repo_slug() {
  local url="$1" name rest owner
  url="${url%/}"
  url="${url%.git}"
  case "${url}" in
    */*) ;;
    *) return 0 ;;
  esac
  name="${url##*/}"
  rest="${url%/*}"
  owner="${rest##*[/:]}"
  if [ -n "${name}" ] && [ -n "${owner}" ]; then
    printf '%s/%s' "${owner}" "${name}" | tr '[:upper:]' '[:lower:]'
  fi
}

# resolve <dir> — the checkout containing <dir>, in ONE git call (git startup dominates the cost):
# R_TOP, R_GITDIR, R_COMMON (the git directory its repository's worktrees share), R_LINKED (1 for a
# linked worktree) and R_BRANCH (empty when none can be named).
resolve() {
  local out top gitdir common head='' f
  if ! out="$(git -C "$1" rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir \
    --symbolic-full-name HEAD 2>/dev/null)"; then
    # An unborn branch has no HEAD to name; the checkout still exists.
    out="$(git -C "$1" rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir \
      2>/dev/null)" || return 1
  fi
  {
    IFS= read -r top || top=''
    IFS= read -r gitdir || gitdir=''
    IFS= read -r common || common=''
    IFS= read -r head || head=''
  } <<<"${out}"
  if [ -z "${top}" ] || [ -z "${gitdir}" ]; then return 1; fi
  R_TOP="${top}"
  R_GITDIR="${gitdir}"
  R_COMMON="${common}"
  R_LINKED=0
  if [ "${gitdir}" != "${common}" ]; then R_LINKED=1; fi
  R_BRANCH=''
  case "${head}" in
    refs/heads/?*) R_BRANCH="${head#refs/heads/}" ;;
    *)
      # Detached mid-rebase or mid-bisect: the checkout is still working on the branch it names.
      # Read with $(...), which keeps a value whose file lacks a trailing newline; `read` would not.
      for f in rebase-merge/head-name rebase-apply/head-name; do
        if [ -f "${gitdir}/${f}" ] && head="$(cat -- "${gitdir}/${f}" 2>/dev/null)"; then
          case "${head}" in
            refs/heads/?*) R_BRANCH="${head#refs/heads/}" && break ;;
          esac
        fi
      done
      if [ -z "${R_BRANCH}" ] && [ -f "${gitdir}/BISECT_START" ] &&
        head="$(cat -- "${gitdir}/BISECT_START" 2>/dev/null)"; then
        case "${head}" in
          '' | *[!0-9a-f]*) R_BRANCH="${head}" ;;
        esac
      fi
      ;;
  esac
  return 0
}

# record <holder-top> <checkout> <branch> — the checkout's path line, then one key line per remote
# when its branch is a head branch some PR asks about.
record() {
  local top="$1" dir="$2" branch="$3" remotes url slug
  printf '%s\t%s\t\n' "${top}" "${dir}"
  if [ -z "${branch}" ] || ! wanted "${branch}"; then return 0; fi
  remotes="$(git -C "${dir}" config --get-regexp '^remote\..*\.url$' 2>/dev/null)" || return 0
  while IFS=' ' read -r _ url; do
    slug="$(repo_slug "${url}")"
    if [ -n "${slug}" ]; then printf '%s\t%s\t%s\n' "${top}" "${dir}" "${slug}:${branch}"; fi
  done <<<"${remotes}"
}

# expand_nested <holder-top> <submodule> <its git dir> — worktrees its repository registers INSIDE it.
expand_nested() {
  local top="$1" sub="$2" gitdir="$3" list line
  # Only a repository that has linked worktrees keeps this directory, so most submodules cost no call.
  [ -d "${gitdir}/worktrees" ] || return 0
  list="$(git -C "${sub}" worktree list --porcelain 2>/dev/null)" || return 0
  while IFS= read -r line; do
    case "${line}" in
      'worktree '*)
        # Resolved by git, so the path compares in the same spelling as <sub>; a pruned one fails.
        resolve "${line#worktree }" || continue
        case "${R_TOP}" in
          "${sub}"/?*) record "${top}" "${R_TOP}" "${R_BRANCH}" ;;
        esac
        ;;
    esac
  done <<<"${list}"
}

# expand_submodules <holder-top> <checkout> <linked> <depth> — every populated submodule below it.
expand_submodules() {
  local top="$1" dir="$2" linked="$3" depth="$4" paths rel sub gitdir
  [ "${depth}" -lt 4 ] || return 0
  [ -f "${dir}/.gitmodules" ] || return 0
  paths="$(git config -f "${dir}/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | cut -d' ' -f2-)" || paths=''
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    sub="${dir}/${rel}"
    [ -e "${sub}/.git" ] || continue
    # An unpopulated submodule resolves to the superproject, and a `.gitmodules` path that leaves the
    # checkout (it is repository content) resolves elsewhere: both fail this equality.
    resolve "${sub}" || continue
    [ "${R_TOP}" = "${sub}" ] || continue
    gitdir="${R_GITDIR}"
    record "${top}" "${sub}" "${R_BRANCH}"
    if [ "${linked}" = 1 ]; then expand_nested "${top}" "${sub}" "${gitdir}"; fi
    expand_submodules "${top}" "${sub}" "${linked}" "$((depth + 1))"
  done <<<"${paths}"
}

# expand <dir> — the checkout containing <dir> and everything it owns, as record lines.
expand() {
  resolve "$1" || return 0
  expand_resolved
}

# expand_resolved — the same, for the checkout `resolve` named last.
expand_resolved() {
  local top="${R_TOP}" linked="${R_LINKED}"
  record "${top}" "${top}" "${R_BRANCH}"
  expand_submodules "${top}" "${top}" "${linked}" 0
}

# lock_rows — `git worktree list --porcelain` on stdin; one row per LOCKED worktree:
# <path> <pid> <start>. The pid is empty unless the reason is the harness's own form, and the start
# is empty when that form records none. The form is matched whole and the start time by its exact
# `ps -o lstart=` shape: a reason that drifted would otherwise compare unequal to every live process
# and read as a reused pid, which holds nothing. git quotes a reason holding unusual characters, so
# such a reason never matches either.
lock_rows() {
  awk '
    /^worktree / { path = substr($0, 10); next }
    /^$/ { path = ""; next }
    /^locked( |$)/ {
      if (path == "") next
      reason = substr($0, 8)
      pid = ""; start = ""
      if (reason ~ /^claude [a-z]+ [^ ()]+ \(pid [1-9][0-9]*( start [A-Z][a-z][a-z] [A-Z][a-z][a-z] +[0-9][0-9]? [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [0-9][0-9][0-9][0-9])?\)$/) {
        sub(/^.* \(pid /, "", reason)
        sub(/\)$/, "", reason)
        pid = reason
        if (sub(/ start .*$/, "", pid)) {
          start = substr(reason, length(pid) + 8)
          gsub(/ +/, " ", start)
        }
      }
      print path "\t" pid "\t" start
    }'
}

# registered <path> — resolve a path the worktree registry names, and fail unless it is still its
# own checkout. A registration outlives its directory, and a directory whose `.git` entry is gone
# resolves to the checkout around it: neither is a checkout anyone can be working in.
registered() {
  local path="$1" physical
  resolve "${path}" || return 1
  [ "${R_TOP}" != "${path}" ] || return 0
  physical="$(cd "${path}" 2>/dev/null && pwd -P)" || return 1
  [ "${R_TOP}" = "${physical}" ]
}

# nearest_checkout <dir> — the nearest directory at or above <dir> that holds a `.git` entry, found
# without starting git: most working directories on a host are in no repository at all.
nearest_checkout() {
  local dir="$1"
  while [ -n "${dir}" ] && [ "${dir}" != / ]; do
    if [ -e "${dir}/.git" ]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    dir="${dir%/*}"
  done
  return 1
}

: >"${work}/ps"
: >"${work}/holders"
: >"${work}/lockholders"
: >"${work}/unread"
: >"${work}/entries"
: >"${work}/asker"
tab=$'\t'
probe_error=''
if [ "${heads}" != $'\n\n' ]; then
  # lsof's own exit status is checked SEPARATELY from the parsing: a partial enumeration can print
  # plenty of working directories while exiting nonzero, and a truncated list read as complete
  # would drop a live session and report `none`.
  if ! command -v lsof >/dev/null 2>&1; then
    probe_error=lsof-missing
  elif ! lsof_raw="$(lsof -d cwd -F pn 2>/dev/null)"; then
    probe_error=lsof-failed
  else
    printf '%s\n' "${lsof_raw}" |
      awk '/^p/ { pid = substr($0, 2); next } /^n/ { if (pid != "") print pid "\t" substr($0, 2) }' \
        >"${work}/cwds"
    [ -s "${work}/cwds" ] || probe_error=lsof-empty
  fi
  # The process table is read AFTER lsof, so a process that exited in between (lsof itself among
  # them) holds nothing, and every holder's ancestry is known.
  if [ -z "${probe_error}" ]; then
    if ps_raw="$(ps -A -o pid= -o ppid= -o comm= 2>/dev/null)"; then
      printf '%s\n' "${ps_raw}" | awk '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
          pid = $1; ppid = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); name = $0; sub(/.*\//, "", name)
          print pid "\t" ppid "\t" name
        }' >"${work}/ps"
    fi
    [ -s "${work}/ps" ] || probe_error=ps-failed
  fi
  if [ -z "${probe_error}" ]; then
    awk -F'\t' 'NR == FNR { alive[$1] = 1; next } ($1 in alive)' "${work}/ps" "${work}/cwds" >"${work}/live"
    # Working directory -> nearest checkout candidate (no git), candidate -> checkout top (one git call).
    : >"${work}/near"
    while IFS= read -r dir; do
      if near="$(nearest_checkout "${dir}")"; then printf '%s\t%s\n' "${dir}" "${near}" >>"${work}/near"; fi
    done < <(cut -f2- "${work}/live" | LC_ALL=C sort -u)
    # Each checkout's repository is kept beside it (its shared git directory, then the checkout), so
    # the lock scan below lists a repository's worktrees once however many of them are worked in.
    : >"${work}/tops"
    : >"${work}/repos"
    while IFS= read -r near; do
      if resolve "${near}"; then
        printf '%s\t%s\n' "${near}" "${R_TOP}" >>"${work}/tops"
        printf '%s\t%s\n' "${R_COMMON}" "${R_TOP}" >>"${work}/repos"
      fi
    done < <(cut -f2- "${work}/near" | LC_ALL=C sort -u)
    awk -F'\t' '
      FILENAME == ARGV[1] { top[$1] = $2; next }
      FILENAME == ARGV[2] { if ($2 in top) dirtop[$1] = top[$2]; next }
      ($2 in dirtop) { print $1 "\t" dirtop[$2] }
    ' "${work}/tops" "${work}/near" "${work}/live" | LC_ALL=C sort -n -k1,1 >"${work}/holders"
    asker=''
    if resolve "${PWD}"; then
      asker="${R_TOP}"
      printf '%s\t%s\n' "${R_COMMON}" "${R_TOP}" >>"${work}/repos"
    fi
    # Worktree locks (monorepo#3780): every locked worktree of those repositories, with the
    # process identity its reason records. A list that cannot be read is UNKNOWN, since a lock in
    # it may hold any of the PRs asked about.
    : >"${work}/locks"
    while IFS="${tab}" read -r common top; do
      # Only a repository that has linked worktrees keeps this directory, and only those are locked.
      [ -d "${common}/worktrees" ] || continue
      if ! list="$(git -C "${top}" worktree list --porcelain 2>/dev/null)"; then
        probe_error=worktree-list
        break
      fi
      lock_rows <<<"${list}" >>"${work}/locks"
    done < <(LC_ALL=C sort -u -t "${tab}" -k1,1 "${work}/repos")
  fi
  if [ -z "${probe_error}" ] && [ -s "${work}/locks" ]; then
    # The start times are read once, only when a lock records one, and in the spelling the harness
    # recorded them: the C locale and UTC. `ps -o lstart=` prints local time in the caller's language.
    : >"${work}/starts"
    if awk -F'\t' '$3 != "" { found = 1 } END { exit !found }' "${work}/locks"; then
      if starts_raw="$(TZ=UTC LC_ALL=C ps -A -o pid= -o lstart= 2>/dev/null)"; then
        printf '%s\n' "${starts_raw}" |
          awk '$1 ~ /^[0-9]+$/ && NF > 1 { pid = $1; $1 = ""; sub(/^ +/, ""); print pid "\t" $0 }' \
            >"${work}/starts"
      fi
      [ -s "${work}/starts" ] || probe_error=ps-failed
    fi
  fi
  if [ -z "${probe_error}" ] && [ -s "${work}/locks" ]; then
    # One verdict per lock: `<pid>` when it holds, `unread` when the helper cannot tell, nothing
    # when its process exited or the pid now belongs to a process with another start time. A start
    # time is compared only when both sides have the `lstart` shape, so an unexpected spelling
    # from this host's `ps` is unread rather than a reused pid.
    awk -F'\t' '
      function lstart(s) {
        return s ~ /^[A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9][0-9]? [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [0-9][0-9][0-9][0-9]$/
      }
      FILENAME == ARGV[1] { alive[$1] = 1; next }
      FILENAME == ARGV[2] { started[$1] = $2; next }
      $2 == "" { print "unread\t" $1; next }
      !($2 in alive) { next }
      $3 == "" { print "unread\t" $1; next }
      # Alive in the process table but absent from the start-time read: either it exited between
      # the two reads or that read was partial. Nothing here can tell which, so it is unread.
      !($2 in started) { print "unread\t" $1; next }
      !lstart(started[$2]) { print "unread\t" $1; next }
      started[$2] == $3 { print $2 "\t" $1 }
    ' "${work}/ps" "${work}/starts" "${work}/locks" >"${work}/verdicts"
    while IFS="${tab}" read -r who path; do
      registered "${path}" || continue
      if [ "${who}" = unread ]; then
        printf '%s\n' "${R_TOP}" >>"${work}/unread"
      else
        printf '%s\t%s\n' "${who}" "${R_TOP}" >>"${work}/lockholders"
      fi
      expand_resolved >>"${work}/entries"
    done <"${work}/verdicts"
  fi
  if [ -z "${probe_error}" ]; then
    while IFS= read -r top; do
      expand "${top}" >>"${work}/entries"
    done < <(cut -f2- "${work}/holders" | LC_ALL=C sort -u)
    # The asker's own tree, from the topmost superproject of the directory it asks from.
    hops=0
    while [ -n "${asker}" ] && [ "${hops}" -lt 8 ]; do
      super="$(git -C "${asker}" rev-parse --show-superproject-working-tree 2>/dev/null)" || super=''
      [ -n "${super}" ] || break
      asker="${super}"
      hops=$((hops + 1))
    done
    if [ -n "${asker}" ]; then expand "${asker}" | cut -f2 | LC_ALL=C sort -u >"${work}/asker"; fi
  fi
fi

rc=0
awk -F'\t' -v me="$$" -v probe_error="${probe_error}" \
  -v psf="${work}/ps" -v askf="${work}/asker" -v entf="${work}/entries" -v holdf="${work}/holders" \
  -v lockf="${work}/lockholders" -v unreadf="${work}/unread" '
  function is_session(p) { return comm[p] == "claude" || comm[p] == "codex" }
  function is_shell(p,   name) {
    name = comm[p]
    sub(/^-/, "", name)
    return name ~ /^(sh|bash|zsh|fish|dash|ksh|mksh|tcsh|csh)( |$)/
  }
  # A shell is busy while something other than a shell runs below it. A shell waiting at its prompt
  # (a terminal tab left open in a worktree, a prompt helper under it) does no work and holds nothing.
  function mark_busy(   p, q, n) {
    for (p in ppid) {
      if (is_shell(p)) continue
      q = ppid[p]
      for (n = 0; q != "" && (q in ppid) && !(q in busy) && n < 256; n++) {
        busy[q] = 1
        q = ppid[q]
      }
    }
  }
  function descends(p, a,   n) {
    for (n = 0; p != "" && n < 256; n++) {
      if (p == a) return 1
      if (!(p in ppid) || ppid[p] == p) return 0
      p = ppid[p]
    }
    return 0
  }
  function label(p,   name) {
    name = comm[p]
    gsub(/[^A-Za-z0-9._-]/, "_", name)
    return p "/" substr(name, 1, 32)
  }
  # The asker is this helper and its ancestry up to the nearest session process, plus the launchers
  # above that session (its wrapper, the app). A SECOND session process further up is an outer
  # session that launched this one: neither it nor anything above it is the asker.
  function init(   p, n) {
    inited = 1
    mark_busy()
    for (p = me; p != "" && n < 256; n++) {
      if (p != me && is_session(p)) {
        if (session != "") break
        session = p
      }
      chain[p] = 1
      if (!(p in ppid) || ppid[p] == p) break
      p = ppid[p]
    }
  }
  FILENAME == psf { ppid[$1] = $2; comm[$1] = $3; next }
  FILENAME == askf { asker[$1] = 1; next }
  FILENAME == entf { if ($3 != "") owns[$1, $3] = 1; next }
  FILENAME == holdf { holders++; hpid[holders] = $1; htop[holders] = $2; next }
  FILENAME == lockf { holders++; hpid[holders] = $1; htop[holders] = $2; hlock[holders] = 1; next }
  FILENAME == unreadf { unread[$1] = 1; next }
  {
    if (!inited) init()
    id = $1
    if ($2 == "fork") { print id " holder=fork"; next }
    if ($2 != "key") { print id " holder=unknown:input"; unknown = 1; next }
    if (probe_error != "") { print id " holder=unknown:" probe_error; unknown = 1; next }
    key = $3 ":" $4
    # One verdict per process, working directories first: a process counts once however many of
    # its checkouts serve this PR, and it is a rival when any of them makes it one.
    found = 0
    split("", mine)
    split("", sits)
    for (i = 1; i <= holders; i++) {
      p = hpid[i]
      top = htop[i]
      if (!((top, key) in owns)) continue
      if (i in hlock) {
        # The process works in the very worktree it locked: its working directory already answered.
        if ((p, top) in sits) continue
        # A lock names the session, and every worker of that session shares the process, so the
        # asker owns only the locked worktree it asks from.
        own = (top in asker) && ((p in chain) || descends(p, me) || (session != "" && descends(p, session)))
      } else {
        if (is_shell(p) && !(p in busy)) continue
        sits[p, top] = 1
        own = (p in chain) || descends(p, me) ||
          (session != "" && descends(p, session) && (top in asker))
      }
      if (!(p in mine)) { order[++found] = p; mine[p] = own }
      else if (!own) mine[p] = 0
    }
    lives = 0; selfs = 0; live_names = ""; self_names = ""
    for (pass = 1; pass <= 2; pass++) {
      for (i = 1; i <= found; i++) {
        p = order[i]
        if ((pass == 1) != is_session(p)) continue
        if (mine[p]) {
          if (++selfs <= 3) self_names = self_names (selfs > 1 ? "," : "") label(p)
        } else if (++lives <= 3) {
          live_names = live_names (lives > 1 ? "," : "") label(p)
        }
      }
    }
    # A lock the helper could not read may name a rival. A rival found another way already answers.
    if (lives == 0) {
      for (top in unread) {
        if ((top, key) in owns) { print id " holder=unknown:lock-reason"; unknown = 1; next }
      }
    }
    value = ""
    if (lives > 0) value = "live:" lives ":" live_names
    if (selfs > 0) value = value (value != "" ? "+" : "") "self:" selfs ":" self_names
    print id " holder=" (value != "" ? value : "none")
  }
  END { exit unknown ? 2 : 0 }
' "${work}/ps" "${work}/asker" "${work}/entries" "${work}/holders" "${work}/lockholders" "${work}/unread" \
  "${work}/prs" || rc=$?
finished=1
exit "${rc}"
