#!/usr/bin/env bash
# claude-task-live-runs.test.sh — RED/GREEN coverage for claude-task-live-runs.sh (monorepo#3536).
#
# The cases that matter most are the fail-closed ones: a session that cannot be attributed must
# never read as "no other run", because a run seconds old is exactly the overlap the check is for.
#
# Fixtures are synthetic and hermetic: every case reads a process snapshot and a working-directory
# table written here, so neither `ps` nor `lsof` is invoked and no real transcript is read.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/claude-task-live-runs.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0

BIN='/Users/someone/Library/Application Support/Claude/claude-code/2.1.288/48d54124d3c3/claude.app/Contents/MacOS/claude'
WRAPPER="/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- $BIN"
PROJECTS="$FIX/projects"
mkdir -p "$PROJECTS"

# transcript <working directory> <name> <first-line JSON> — writes one transcript where the runtime
# would keep it for a session in that working directory.
transcript() {
  local slug
  slug=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')
  mkdir -p "$PROJECTS/$slug"
  printf '%s\n' "$3" > "$PROJECTS/$slug/$2.jsonl"
}

enqueue() { jq -cn --arg content "$1" '{type: "queue-operation", operation: "enqueue", content: $content}'; }
scheduled() { enqueue "<scheduled-task name=\"$1\" file=\"/x/SKILL.md\">
This is an automated run."; }

transcript /work/engineer-a aaaa "$(scheduled daily-ai-assistant)"
transcript /work/engineer-b bbbb "$(scheduled daily-ai-assistant)"
transcript /work/improver cccc "$(scheduled agent-improver)"
transcript /work/interactive dddd "$(enqueue 'please fix the build')"
transcript /work/quoted eeee "$(enqueue 'what does <scheduled-task name="daily-ai-assistant" file="x"> mean?')"
transcript /work/reminder ffff "$(enqueue "<system-reminder>
You are operating in a git worktree.
</system-reminder>

<scheduled-task name=\"daily-ai-assistant\" file=\"/x/SKILL.md\">")"
transcript /work/user-message gggg "$(jq -cn '{type: "user", message: {role: "user",
  content: "<scheduled-task name=\"daily-ai-assistant\" file=\"/x/SKILL.md\">"}}')"
transcript /work/broken hhhh 'not json'
# A directory reused by a later interactive session: the older transcript names the task, the
# newest does not, and the newest is the live one.
transcript /work/reused old "$(scheduled daily-ai-assistant)"
touch -t 202601010000 "$PROJECTS/-work-reused/old.jsonl"
transcript /work/reused new "$(enqueue 'hello')"

cat > "$FIX/cwd.tsv" <<EOF
100	/work/engineer-a
200	/work/engineer-b
300	/work/improver
400	/work/interactive
500	/work/quoted
600	/work/reminder
700	/work/user-message
800	/work/broken
900	/work/reused
950	/work/never-written
EOF

# snapshot <file> <"pid ppid etime kind">... — kind is `session`, `wrapper` or any other command.
snapshot() {
  local out=$1 row pid parent elapsed kind; shift
  : > "$out"
  for row in "$@"; do
    read -r pid parent elapsed kind <<EOF2
$row
EOF2
    case "$kind" in
      session) printf '%5s %5s %8s %s --output-format stream-json\n' "$pid" "$parent" "$elapsed" "$BIN" ;;
      wrapper) printf '%5s %5s %8s %s --output-format stream-json\n' "$pid" "$parent" "$elapsed" "$WRAPPER" ;;
      *) printf '%5s %5s %8s %s\n' "$pid" "$parent" "$elapsed" "$kind" ;;
    esac >> "$out"
  done
}

# check <name> <expected exit> <expected stdout pattern, or -> <snapshot rows...>
# The caller's own session is always pid 100, reached from the shell 110 the script "runs" in.
check() {
  local name=$1 want=$2 pattern=$3 out rc=0; shift 3
  snapshot "$FIX/ps.txt" "$@"
  out=$(bash "$SCRIPT" --task "${T_TASK:-daily-ai-assistant}" --projects "$PROJECTS" --self-pid 110 \
    --ps-file "$FIX/ps.txt" --cwd-file "$FIX/cwd.tsv" 2>/dev/null) || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $name -- exit $rc, want $want"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1)); return
  fi
  if [ "$pattern" != "-" ] && ! printf '%s\n' "$out" | grep -Eq -- "$pattern"; then
    echo "FAIL: $name -- output lacks /$pattern/"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1)); return
  fi
  pass=$((pass + 1))
}

SELF='99 1 20:00 wrapper' ; OWN='100 99 20:00 session' ; SHELL_ROW='110 100 00:01 /bin/zsh -c x'

check "own session alone is clean" 0 '^CHECKED sessions=1 other=0 task=daily-ai-assistant live=0$' \
  "$SELF" "$OWN" "$SHELL_ROW"
check "another run of the task is reported" 1 '^LIVE task=daily-ai-assistant pid=200 elapsed=1-02:03:04 session=bbbb$' \
  "$SELF" "$OWN" "$SHELL_ROW" '199 1 1-02:03:04 wrapper' '200 199 1-02:03:04 session'
check "the launcher wrapper is not a second session" 1 '^CHECKED sessions=2 other=1 .* live=1$' \
  "$SELF" "$OWN" "$SHELL_ROW" '199 1 05:00 wrapper' '200 199 05:00 session'
check "a run of a different task is not reported" 0 'other=1 task=daily-ai-assistant live=0$' \
  "$SELF" "$OWN" "$SHELL_ROW" '300 1 05:00 session'
T_TASK=agent-improver check "the other task is found when asked for" 1 '^LIVE task=agent-improver pid=300 ' \
  "$SELF" "$OWN" "$SHELL_ROW" '300 1 05:00 session'
check "an interactive session is not a run of the task" 0 'other=1 .* live=0$' \
  "$SELF" "$OWN" "$SHELL_ROW" '400 1 05:00 session'
check "a marker quoted inside a message names no task" 0 'live=0$' \
  "$SELF" "$OWN" "$SHELL_ROW" '500 1 05:00 session'
check "a marker after the worktree reminder is recognised" 1 '^LIVE .* pid=600 .* session=ffff$' \
  "$SELF" "$OWN" "$SHELL_ROW" '600 1 05:00 session'
check "a marker opening the first user message is recognised" 1 '^LIVE .* pid=700 ' \
  "$SELF" "$OWN" "$SHELL_ROW" '700 1 05:00 session'
check "the newest transcript in a reused directory decides" 0 'live=0$' \
  "$SELF" "$OWN" "$SHELL_ROW" '900 1 05:00 session'
check "a session started from inside the caller's is its own" 0 'sessions=2 other=0 .* live=0$' \
  "$SELF" "$OWN" "$SHELL_ROW" '120 110 00:30 session'
check "an unrelated process whose arguments mention the binary is ignored" 0 'sessions=1 other=0' \
  "$SELF" "$OWN" "$SHELL_ROW" "130 1 00:30 grep $BIN"

# Fail-closed: none of these may read as "no other run".
check "a session with no working directory is UNKNOWN" 2 '^UNATTRIBUTED pid=960 .* reason=no-working-directory$' \
  "$SELF" "$OWN" "$SHELL_ROW" '960 1 00:02 session'
check "a session with no transcript yet is UNKNOWN" 2 '^UNATTRIBUTED pid=950 .* reason=no-transcript$' \
  "$SELF" "$OWN" "$SHELL_ROW" '950 1 00:02 session'
check "a session with an unreadable transcript is UNKNOWN" 2 'reason=unreadable-transcript$' \
  "$SELF" "$OWN" "$SHELL_ROW" '800 1 00:02 session'
check "a live run outranks an unattributed session" 1 '^LIVE .* pid=200 ' \
  "$SELF" "$OWN" "$SHELL_ROW" '200 1 05:00 session' '950 1 00:02 session'
check "a snapshot with no session at all is UNKNOWN" 2 - "$SHELL_ROW" '130 1 00:30 sleep 5'

# expect_exit <name> <expected exit> <args...>
expect_exit() {
  local name=$1 want=$2 rc=0; shift 2
  bash "$SCRIPT" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass + 1)); else echo "FAIL: $name -- exit $rc, want $want"; fail=$((fail + 1)); fi
}

snapshot "$FIX/ok.txt" "$SELF" "$OWN" "$SHELL_ROW"
: > "$FIX/empty.txt"
COMMON=(--projects "$PROJECTS" --self-pid 110 --cwd-file "$FIX/cwd.tsv")
expect_exit "control: the shared arguments pass" 0 --task daily-ai-assistant --ps-file "$FIX/ok.txt" "${COMMON[@]}"
expect_exit "a missing task is a usage error" 2 --ps-file "$FIX/ok.txt" "${COMMON[@]}"
expect_exit "a task that is not an id is refused" 2 --task 'a b' --ps-file "$FIX/ok.txt" "${COMMON[@]}"
expect_exit "an empty process list is UNKNOWN" 2 --task daily-ai-assistant --ps-file "$FIX/empty.txt" "${COMMON[@]}"
expect_exit "an unreadable process list is UNKNOWN" 2 --task daily-ai-assistant --ps-file "$FIX/absent.txt" "${COMMON[@]}"
expect_exit "a missing projects root is UNKNOWN" 2 --task daily-ai-assistant --ps-file "$FIX/ok.txt" \
  --projects "$FIX/absent" --self-pid 110 --cwd-file "$FIX/cwd.tsv"
expect_exit "a self pid that is not a number is refused" 2 --task daily-ai-assistant --ps-file "$FIX/ok.txt" \
  --projects "$PROJECTS" --self-pid abc --cwd-file "$FIX/cwd.tsv"
expect_exit "an unknown argument is refused" 2 --task daily-ai-assistant --frobnicate


# Contract: the cadence guide states the method at its point of use (monorepo#3536). The section is
# extracted first and must be non-empty, because an empty extraction passes every substring check.
GUIDE="$SCRIPT_DIR/../guides/cadence.md"
rule=$(awk '/^\*\*Whether another run of your own task is live/ { on = 1 } on && /^$/ { exit } on' "$GUIDE")
if [ -z "$rule" ]; then
  echo "FAIL: contract -- the same-task rule was not found in the cadence guide"; fail=$((fail + 1))
else
  for needle in 'claude-task-live-runs.sh --task' 'is not a' 'Exit `2` is UNKNOWN' 'never as exit `0`'; do
    if printf '%s\n' "$rule" | grep -Fq -- "$needle"; then pass=$((pass + 1))
    else echo "FAIL: contract -- the cadence guide rule lacks: $needle"; fail=$((fail + 1)); fi
  done
fi

echo "claude-task-live-runs.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
