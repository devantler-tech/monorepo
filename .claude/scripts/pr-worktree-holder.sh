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
#   gh pr view <n> --repo <owner>/<repo> --json url,headRefName,headRepositoryOwner |
#     pr-worktree-holder.sh --input -
#   `gh pr list --json url,headRefName,headRepositoryOwner` (an array) works too. The forge JSON on
#   stdin is the only input, which is the one shape the surveyor's read-only guard admits for a
#   declared helper; no PR-supplied text ever becomes an argument or a path.
#
# OUTPUT (one line per PR, in input order)
#   <owner>/<repo>#<n> holder=<value>
#   live:<count>:<pid>/<cmd>[,...]  a process OUTSIDE the asking session works in a checkout of the
#                                   head branch (at most three are named, sessions first)
#   self:<count>:<pid>/<cmd>[,...]  only the asking session itself does, so it is never a rival
#   live:...+self:...               both
#   none                            the process enumeration was complete and nothing holds one
#   fork                            the head is in another owner's repository: no lane on this host
#                                   checks it out, so there is nothing local to examine
#   unknown:<reason>                the helper could not tell, and that is NEVER `none`. Reasons:
#                                   input, lsof-missing, lsof-failed, lsof-empty, ps-failed
#
# WHAT HOLDING A CHECKOUT MEANS
#   A process holds the checkout containing its working directory, every populated submodule of
#   that checkout and, when that checkout is a linked (per-session) worktree, the worktrees its
#   submodules register inside their own directories: the per-run product worktrees the
#   git-and-worktrees guide prescribes. A session usually sits at its worktree root while its
#   branch is checked out in a submodule below it, so stopping at the working directory would miss
#   most product PRs. A MAIN checkout never claims worktrees beneath it, because every per-session
#   worktree lives inside the main checkout and one shell there would then hold every branch on the
#   host. A checkout serves a PR when its `origin` names the PR's repository and its checked-out
#   branch is the head branch.
#
# SELF
#   The asking session is not its own rival, the same exclusion the contract makes for its own
#   push. A holder is `self` when it is this helper, one of its ancestors or descendants, or a
#   descendant of the asking session's `claude`/`codex` process that works inside the asker's own
#   checkout tree. Another session in the same worktree, or a sibling subagent in a different
#   worktree, stays `live`. With no session process among the ancestors, only the helper's own
#   ancestors and descendants are `self`.
#
# SCOPE
#   Only lanes on this host have local processes. The Cursor cloud lane does not, so its PRs read
#   `none` here and keep the published-event signals.
#
# EXIT CODES
#   0  every PR was answered
#   2  UNKNOWN: a usage error, unreadable input, or any PR answered `unknown:`. A failed or partial
#      `lsof` (a nonzero exit, or no working directories at all) never yields `none`.
set -euo pipefail

# Every git call names its directory. An inherited location variable would redirect them all.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE GIT_CEILING_DIRECTORIES
export GIT_OPTIONAL_LOCKS=0

if [ "$#" -ne 2 ] || [ "$1" != "--input" ] || [ "$2" != "-" ]; then
  echo "usage: gh pr view <n> --repo <owner>/<repo> --json url,headRefName,headRepositoryOwner | pr-worktree-holder.sh --input -" >&2
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
# bash 3.2 can report a `set -u` abort as exit 0 from an EXIT trap, so completion is explicit.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status="$1"
  rm -rf -- "${work}"
  if [ "${finished}" != 1 ] && [ "${status}" = 0 ]; then status=2; fi
  exit "${status}"
}
trap 'on_exit "$?"' EXIT

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

# One TSV row per PR: <id> <input|fork|key> <owner/repo, lower-cased> <head branch>.
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
      else [$id, "key", ("\($m.o)/\($m.r)" | ascii_downcase), $p.headRefName] end
    end
  | @tsv
' <<<"${payload}" >"${work}/prs" 2>/dev/null || unreadable "stdin is not the JSON of gh pr view/list --json url,headRefName,headRepositoryOwner"

# physical_path <dir> — the kernel's spelling of a directory, so two names for one checkout compare equal.
physical_path() { (CDPATH='' cd -- "$1" 2>/dev/null && /bin/pwd -P); }

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

# emit <holder-top> <checkout> — one entry: the checkout and the `owner/repo:branch` it serves, if any.
emit() {
  local top="$1" dir="$2" ref url slug key=''
  ref="$(git -C "${dir}" symbolic-ref -q HEAD 2>/dev/null)" || ref=''
  case "${ref}" in
    refs/heads/?*)
      url="$(git -C "${dir}" config --get remote.origin.url 2>/dev/null)" || url=''
      slug="$(repo_slug "${url}")"
      if [ -n "${slug}" ]; then key="${slug}:${ref#refs/heads/}"; fi
      ;;
  esac
  printf '%s\t%s\t%s\n' "${top}" "${dir}" "${key}"
}

# expand_nested <holder-top> <submodule> — worktrees the submodule's repository registers INSIDE it.
expand_nested() {
  local top="$1" sub="$2" list line wt
  list="$(git -C "${sub}" worktree list --porcelain 2>/dev/null)" || return 0
  while IFS= read -r line; do
    case "${line}" in
      'worktree '*)
        wt="$(physical_path "${line#worktree }")" || continue
        case "${wt}" in
          "${sub}"/?*) emit "${top}" "${wt}" ;;
        esac
        ;;
    esac
  done <<<"${list}"
}

# expand_submodules <holder-top> <checkout> <linked> <depth> — every populated submodule below it.
expand_submodules() {
  local top="$1" dir="$2" linked="$3" depth="$4" paths rel sub subtop
  [ "${depth}" -lt 4 ] || return 0
  [ -f "${dir}/.gitmodules" ] || return 0
  paths="$(git config -f "${dir}/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | cut -d' ' -f2-)" || paths=''
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    [ -e "${dir}/${rel}/.git" ] || continue
    sub="$(physical_path "${dir}/${rel}")" || continue
    # A `.gitmodules` path is repository content: never follow one out of the checkout.
    case "${sub}" in
      "${dir}"/?*) ;;
      *) continue ;;
    esac
    subtop="$(git -C "${sub}" rev-parse --show-toplevel 2>/dev/null)" || continue
    subtop="$(physical_path "${subtop}")" || continue
    # An unpopulated submodule directory resolves to the superproject, which is not a checkout of it.
    [ "${subtop}" = "${sub}" ] || continue
    emit "${top}" "${sub}"
    if [ "${linked}" = 1 ]; then expand_nested "${top}" "${sub}"; fi
    expand_submodules "${top}" "${sub}" "${linked}" "$((depth + 1))"
  done <<<"${paths}"
}

# expand <top> — the checkout at <top> and everything it owns, as emit lines.
expand() {
  local top="$1" linked=0 gitdir common
  gitdir="$(git -C "${top}" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || gitdir=''
  common="$(git -C "${top}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=''
  if [ -n "${gitdir}" ] && [ -n "${common}" ]; then
    gitdir="$(physical_path "${gitdir}")" || gitdir=''
    common="$(physical_path "${common}")" || common=''
    if [ -n "${gitdir}" ] && [ "${gitdir}" != "${common}" ]; then linked=1; fi
  fi
  emit "${top}" "${top}"
  expand_submodules "${top}" "${top}" "${linked}" 0
}

: >"${work}/ps"
: >"${work}/holders"
: >"${work}/entries"
: >"${work}/asker"
probe_error=''
if awk -F'\t' '$2 == "key" { found = 1 } END { exit found ? 0 : 1 }' "${work}/prs"; then
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
    : >"${work}/tops"
    while IFS= read -r dir; do
      [ -d "${dir}" ] || continue
      top="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null)" || continue
      [ -n "${top}" ] || continue
      top="$(physical_path "${top}")" || continue
      printf '%s\t%s\n' "${dir}" "${top}" >>"${work}/tops"
    done < <(cut -f2- "${work}/live" | LC_ALL=C sort -u)
    awk -F'\t' 'NR == FNR { top[$1] = $2; next } ($2 in top) { print $1 "\t" top[$2] }' \
      "${work}/tops" "${work}/live" | LC_ALL=C sort -n -k1,1 >"${work}/holders"
    while IFS= read -r top; do
      expand "${top}" >>"${work}/entries"
    done < <(cut -f2- "${work}/holders" | LC_ALL=C sort -u)
    # The asker's own tree, from the topmost superproject of the directory it asks from.
    asker="$(git rev-parse --show-toplevel 2>/dev/null)" || asker=''
    hops=0
    while [ -n "${asker}" ] && [ "${hops}" -lt 8 ]; do
      super="$(git -C "${asker}" rev-parse --show-superproject-working-tree 2>/dev/null)" || super=''
      [ -n "${super}" ] || break
      asker="${super}"
      hops=$((hops + 1))
    done
    if [ -n "${asker}" ] && asker="$(physical_path "${asker}")"; then
      expand "${asker}" | cut -f2 >"${work}/asker"
    fi
  fi
fi

rc=0
awk -F'\t' -v me="$$" -v probe_error="${probe_error}" \
  -v psf="${work}/ps" -v askf="${work}/asker" -v entf="${work}/entries" -v holdf="${work}/holders" '
  function is_session(p) { return comm[p] == "claude" || comm[p] == "codex" }
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
  function init(   p, n) {
    inited = 1
    for (p = me; p != "" && n < 256; n++) {
      ancestor[p] = 1
      if (session == "" && p != me && is_session(p)) session = p
      if (!(p in ppid) || ppid[p] == p) break
      p = ppid[p]
    }
  }
  FILENAME == psf { ppid[$1] = $2; comm[$1] = $3; next }
  FILENAME == askf { asker[$1] = 1; next }
  FILENAME == entf { if ($3 != "") owns[$1, $3] = 1; next }
  FILENAME == holdf { holders++; hpid[holders] = $1; htop[holders] = $2; next }
  {
    if (!inited) init()
    id = $1
    if ($2 == "fork") { print id " holder=fork"; next }
    if ($2 != "key") { print id " holder=unknown:input"; unknown = 1; next }
    if (probe_error != "") { print id " holder=unknown:" probe_error; unknown = 1; next }
    key = $3 ":" $4
    lives = 0; selfs = 0; live_names = ""; self_names = ""
    for (pass = 1; pass <= 2; pass++) {
      for (i = 1; i <= holders; i++) {
        p = hpid[i]
        if (!((htop[i], key) in owns)) continue
        if ((pass == 1) != is_session(p)) continue
        if ((p in ancestor) || descends(p, me) ||
            (session != "" && descends(p, session) && (htop[i] in asker))) {
          if (++selfs <= 3) self_names = self_names (selfs > 1 ? "," : "") label(p)
        } else if (++lives <= 3) {
          live_names = live_names (lives > 1 ? "," : "") label(p)
        }
      }
    }
    value = ""
    if (lives > 0) value = "live:" lives ":" live_names
    if (selfs > 0) value = value (value != "" ? "+" : "") "self:" selfs ":" self_names
    print id " holder=" (value != "" ? value : "none")
  }
  END { exit unknown ? 2 : 0 }
' "${work}/ps" "${work}/asker" "${work}/entries" "${work}/holders" "${work}/prs" || rc=$?
finished=1
exit "${rc}"
