#!/usr/bin/env bash
# plugin-definition-refresh.test.sh — contract test for plugin-definition-refresh.sh
#
# The defect under test (measured 2026-08-16, monorepo#2856):
#   `claude plugin update <plugin>` installs the MARKETPLACE LATEST, not the consumer's PINNED
#   revision — its own `--help` says "Update a plugin to the latest version" and it exposes no
#   ref/version selector. On 2026-08-15 the two coincided (clone HEAD == pin `564a6a0f`), which is
#   the only reason the by-hand refresh appeared to install the pin. On 2026-08-16 they did NOT:
#   pin `11b241cc` (4.3.4) against an upstream `main` already at `73109ad9` (4.3.6). A pre-flight
#   wired to the two commands as #2856 describes them would therefore install definitions this
#   consumer has never reviewed — a strictly worse failure than the stale-install drift it fixes,
#   because drift at least runs a PREVIOUSLY REVIEWED definition.
#
# So the contract is a GATED refresh: refresh the marketplace, then apply the plugin update ONLY
# when the revision it would install is exactly the pinned one. Otherwise refuse and report.
#
# Read-only against the real host: every assertion runs against fixtures in a temp dir with a
# stubbed CLI. The suite never touches the runtime's plugin install.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/plugin-definition-refresh.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; }

[ -x "$SCRIPT" ] || { printf 'plugin-definition-refresh.sh is missing or not executable: %s\n' "$SCRIPT" >&2; exit 1; }

# ── fixture ────────────────────────────────────────────────────────────────────
# A marketplace clone with two commits, a consumer repo whose gitlink names one of them, and a
# stub CLI that records every invocation and moves the clone on `marketplace update`.
make_fixture() {
  ROOT="$(mktemp -d)"
  CONSUMER="$ROOT/consumer"; BIN="$ROOT/bin"
  PLUGINS="$ROOT/plugins"; INSTALLED="$ROOT/installed"
  # The marketplace clone sits at the REAL derived location. The script no longer accepts a
  # `--marketplace-dir` override, because an overridable directory is a decoy vector: a caller could
  # point it at a checkout equal to the pin while both CLI commands still selected the runtime
  # marketplace by name. The fixture therefore uses the same path the script computes.
  MK="$PLUGINS/marketplaces/devantler-plugins"
  mkdir -p "$MK" "$CONSUMER" "$BIN" "$PLUGINS" "$INSTALLED"

  git -C "$MK" init -q -b main
  git -C "$MK" config user.email t@t; git -C "$MK" config user.name t
  echo old > "$MK/f"; git -C "$MK" add f; git -C "$MK" commit -qm one
  MK_OLD="$(git -C "$MK" rev-parse HEAD)"
  echo new > "$MK/f"; git -C "$MK" add f; git -C "$MK" commit -qm two
  MK_NEW="$(git -C "$MK" rev-parse HEAD)"
  git -C "$MK" checkout -q "$MK_OLD"        # clone starts STALE, as the real one was

  # consumer repo carrying a gitlink to the marketplace at a chosen revision
  git -C "$CONSUMER" init -q -b main
  git -C "$CONSUMER" config user.email t@t; git -C "$CONSUMER" config user.name t
  git -C "$CONSUMER" config protocol.file.allow always 2>/dev/null || true
  echo x > "$CONSUMER/x"; git -C "$CONSUMER" add x; git -C "$CONSUMER" commit -qm base

  # runtime registry pointing at an install dir
  cat > "$PLUGINS/installed_plugins.json" <<JSON
{"version":2,"plugins":{"agentic-engineering@devantler-plugins":[
  {"scope":"user","installPath":"$INSTALLED","version":"0.0.0","gitCommitSha":"$MK_OLD"}]}}
JSON

  # Stub post-apply verifier. The real one is plugin-definition-currency.sh; the point of the seam
  # is that the verdict comes from an INDEPENDENT check rather than from `plugin update`'s status.
  VERIFY_LOG="$ROOT/verify.log"; : > "$VERIFY_LOG"
  VERIFY="$BIN/verify-ok"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$VERIFY_LOG" > "$VERIFY"; chmod +x "$VERIFY"
  VERIFY_BAD="$BIN/verify-drift"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$VERIFY_BAD"; chmod +x "$VERIFY_BAD"

  CLI_LOG="$ROOT/cli.log"; : > "$CLI_LOG"
  cat > "$BIN/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CLI_LOG"
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = marketplace ] && [ "\${3:-}" = update ]; then
  git -C "$MK" checkout -q "\${STUB_MARKETPLACE_TARGET:-$MK_OLD}"
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = update ]; then
  touch "$ROOT/APPLIED"
fi
exit 0
STUB
  chmod +x "$BIN/claude"
}

# Point the consumer's gitlink at $1 by writing the tree entry directly — no network, no submodule
# machinery, and it is exactly the "160000 commit <sha>" shape the script must read.
# A silently-failed fixture is worse than a failed test: the assertions still run, but against the
# PREVIOUS consumer tree rather than the pin they asked for, so they pass without testing anything.
# Both commands are checked explicitly and stderr is preserved.
set_gitlink() {
  local sha="$1"
  git -C "$CONSUMER" update-index --add --cacheinfo 160000,"$sha",libraries/agent-plugins \
    || { printf 'FIXTURE FAILURE: update-index for %s failed\n' "$sha" >&2; exit 9; }
  git -C "$CONSUMER" commit -qm "pin $sha" >/dev/null \
    || { printf 'FIXTURE FAILURE: commit for %s failed\n' "$sha" >&2; exit 9; }
}

run() {
  CLAUDE_CLI="$BIN/claude" "$SCRIPT" \
    --repo-root "$CONSUMER" --plugins-root "$PLUGINS" \
    --verify-cmd "$VERIFY" "$@" 2>&1
}

cleanup() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }
trap cleanup EXIT

printf '\nplugin-definition-refresh contract\n'

# ── A1 — the measured defect: marketplace latest != pin ⇒ REFUSE, and never apply ─────────────
make_fixture
set_gitlink "$MK_OLD"                      # pin = OLD; marketplace will refresh to NEW
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok "A1 refuses (exit 1) when the refreshed marketplace does not carry the pin"
else bad "A1 refuses (exit 1) when the refreshed marketplace does not carry the pin" "exit was $rc"; fi
if [ ! -e "$ROOT/APPLIED" ]; then ok "A1b does NOT invoke 'plugin update' when the pin is unavailable"
else bad "A1b does NOT invoke 'plugin update' when the pin is unavailable" "it applied an unreviewed revision"; fi
cleanup

# ── A2 — the safe case: marketplace latest == pin ⇒ apply ──────────────────────────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ -e "$ROOT/APPLIED" ] && [ "$rc" -eq 0 ]; then ok "A2 invokes 'plugin update' when the marketplace carries exactly the pin"
else bad "A2 invokes 'plugin update' when the marketplace carries exactly the pin" "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A3 — a runtime-local mutation is backed up BEFORE it happens ───────────────────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if ls "$PLUGINS"/installed_plugins.json.bak-* >/dev/null 2>&1 && [ "$rc" -eq 0 ]; then ok "A3 backs up installed_plugins.json before applying"
else bad "A3 backs up installed_plugins.json before applying" "exit was $rc; no timestamped backup was written"; fi
cleanup

# ── A4 — refresh is attempted BEFORE the gate is evaluated ─────────────────────────────────────
# Clone starts at OLD and the pin is NEW. Only a script that refreshes FIRST can ever apply here;
# one that read the clone HEAD up front would see OLD != NEW and refuse. This is the assertion that
# pins the ORDER, which is the half #2856 got right and is easy to drop when adding the gate.
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if grep -q 'plugin marketplace update' "$CLI_LOG" && [ -e "$ROOT/APPLIED" ] && [ "$rc" -eq 0 ]; then
  ok "A4 refreshes the marketplace before evaluating the gate"
else bad "A4 refreshes the marketplace before evaluating the gate" "exit was $rc; $(tr '\n' '|' < "$CLI_LOG")"; fi
cleanup

# ── A5 — an unresolvable CLI is UNKNOWN (exit 2), never a verdict ──────────────────────────────
make_fixture
set_gitlink "$MK_NEW"
CLAUDE_CLI="$ROOT/nope" "$SCRIPT" --repo-root "$CONSUMER" --plugins-root "$PLUGINS" \
  >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "A5 exits 2 (UNKNOWN) when the CLI cannot be resolved"
else bad "A5 exits 2 (UNKNOWN) when the CLI cannot be resolved" "exit was $rc — 0/1 would be a fabricated verdict"; fi
cleanup

# ── A12 — the gate binds the clone it READS to the plugin the CLI UPDATES ──────────────────────
# `--marketplace staging` would refresh and gate on the staging clone while the default plugin id
# still installed `…@devantler-plugins`: the gate passes against one marketplace, the install comes
# from another. That is the fail-open this whole script exists to prevent, so a mismatch is UNKNOWN
# (2) and must never reach 'plugin update'.
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run --marketplace staging 2>&1)"; rc=$?
# Assert the REASON, not merely the code: exit 2 covers eight distinct conditions, so a regression
# that exits 2 earlier for an unrelated reason would keep this green while the guard never ran.
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && printf '%s' "$out" | grep -q 'refusing to gate on one marketplace and install from another'; then
  ok "A12 refuses (exit 2, named reason) when --marketplace and --plugin-id name different marketplaces"
else bad "A12 refuses (exit 2, named reason) when --marketplace and --plugin-id name different marketplaces" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── A13 — an unqualified plugin id is UNKNOWN, never a silent default ──────────────────────────
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run --plugin-id agentic-engineering 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && printf '%s' "$out" | grep -q 'is not marketplace-qualified'; then
  ok "A13 refuses (exit 2, named reason) when the plugin id is not marketplace-qualified"
else bad "A13 refuses (exit 2, named reason) when the plugin id is not marketplace-qualified" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── A14 — a malformed registry must not turn a SUCCESSFUL apply into a failure ─────────────────
# The post-apply registry read is a reporting nicety. Under `set -e` + `pipefail` a malformed
# registry aborted the script after 'plugin update' had already run and before the declared
# `exit 0`, reporting a completed apply as a failure.
make_fixture
set_gitlink "$MK_NEW"
printf '%s\n' 'this is not json {{{' > "$PLUGINS/installed_plugins.json"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ -e "$ROOT/APPLIED" ] && [ "$rc" -eq 0 ]; then
  ok "A14 still exits 0 after applying when the registry is malformed"
else bad "A14 still exits 0 after applying when the registry is malformed" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A15 — refresh → read → apply is serialized against an overlapping run ──────────────────────
# Both machine-local lanes dispatch hourly and 46% of runs exceed the hour, so a sibling refreshing
# the same clone between this run's read and its install would have it apply an ungated revision.
make_fixture
set_gitlink "$MK_NEW"
mkdir -p "$PLUGINS/.plugin-definition-refresh.lock"
# The owner must be a LIVE pid, or the liveness reaper correctly treats the lock as abandoned and
# takes it — which is what this fixture did on its first version, failing for the right reason.
printf '%s\n' "$$" > "$PLUGINS/.plugin-definition-refresh.lock/pid"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" PLUGIN_REFRESH_LOCK_WAIT=2 run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && printf '%s' "$out" | grep -q 'holds .* after'; then
  ok "A15 exits 2 (UNKNOWN, named reason) rather than applying while a LIVE run holds the lock"
else bad "A15 exits 2 (UNKNOWN, named reason) rather than applying while a LIVE run holds the lock" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
rm -f "$PLUGINS/.plugin-definition-refresh.lock/pid"
rmdir "$PLUGINS/.plugin-definition-refresh.lock" 2>/dev/null || true
cleanup

# ── A15c — a briefly OWNERLESS lock is acquisition-in-progress, not debris ─────────────────────
# `mkdir` is atomic but publishing the pid is a separate step. A rival that reads the lock inside
# that window sees no owner; treating THAT as abandoned lets it delete a live lock and put two runs
# in the section — the failure the lock exists to prevent, reintroduced by the reaper.
make_fixture
set_gitlink "$MK_NEW"
mkdir -p "$PLUGINS/.plugin-definition-refresh.lock"          # fresh, no pid published yet
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" PLUGIN_REFRESH_LOCK_WAIT=2 run 2>&1)"; rc=$?
# The reason matters here too: exit 2 covers eight conditions, so a regression that exits 2 before
# the lock code runs would keep this green while the guard under test never executed.
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && printf '%s' "$out" | grep -q 'holds .* after'; then
  ok "A15c does not steal a freshly-created lock that has not published its owner yet"
else bad "A15c does not steal a freshly-created lock that has not published its owner yet" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
rmdir "$PLUGINS/.plugin-definition-refresh.lock" 2>/dev/null || true
cleanup

# ── A19b — a dry run cannot produce a NOT-ON-PIN verdict either ────────────────────────────────
# --dry-run skips the refresh, so a stale clone is compared against the pin. An actual refresh may
# bring it exactly to that pin, so this proves nothing about whether the marketplace can supply it;
# emitting exit 1 here would point the caller at a gitlink bump it may not need.
make_fixture
set_gitlink "$MK_NEW"                        # clone is still at OLD; refresh is skipped in dry-run
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && printf '%s' "$out" | grep -q 'NOT evidence the marketplace lacks the pin'; then
  ok "A19b --dry-run against a stale clone exits 2, never a false NOT-ON-PIN"
else bad "A19b --dry-run against a stale clone exits 2, never a false NOT-ON-PIN" \
  "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── A15b — a lock whose owner is GONE is reaped; age is deliberately not the test ───────────────
# Reaping on age would let a sibling steal the lock from a refresh that legitimately ran long,
# putting two runs in the section at once — the failure the lock exists to prevent, caused by the
# reaper. Liveness is the correct test, and a crashed run must still not park the lock forever.
make_fixture
set_gitlink "$MK_NEW"
mkdir -p "$PLUGINS/.plugin-definition-refresh.lock"
# A pid that is certainly not running: claim one, then let it exit.
dead_pid="$( (exec sh -c 'echo $$') )"
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
printf '%s\n' "$dead_pid" > "$PLUGINS/.plugin-definition-refresh.lock/pid"
STUB_MARKETPLACE_TARGET="$MK_NEW" PLUGIN_REFRESH_LOCK_WAIT=2 run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ]; then
  ok "A15b reaps a lock whose owner process is gone, rather than parking forever"
else bad "A15b reaps a lock whose owner process is gone, rather than parking forever" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A16 — the lock is RELEASED on a normal apply, so the next run is not parked ────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$PLUGINS/.plugin-definition-refresh.lock" ]; then
  ok "A16 releases the lock after a successful apply"
else bad "A16 releases the lock after a successful apply" \
  "exit was $rc, lock still present=$([ -d "$PLUGINS/.plugin-definition-refresh.lock" ] && echo yes || echo no)"; fi
cleanup

# ── A17 — INT/TERM must TERMINATE the run, not merely clean up and resume ──────────────────────
# A bash handler that returns normally resumes at the point of interruption, so a combined
# `trap release_lock EXIT INT TERM` would surrender the lock and then carry on into 'plugin update'
# — an unserialized apply, which is the very thing the lock exists to prevent.
if grep -Eq '^trap release_lock EXIT$' "$SCRIPT" \
  && grep -Eq "^trap 'exit 130' INT$" "$SCRIPT" \
  && grep -Eq "^trap 'exit 143' TERM$" "$SCRIPT" \
  && ! grep -Eq '^trap release_lock EXIT INT TERM$' "$SCRIPT"; then
  ok "A17 INT/TERM exit instead of resuming after releasing the lock"
else bad "A17 INT/TERM exit instead of resuming after releasing the lock" \
  "$(grep -n '^trap ' "$SCRIPT" | tr '\n' '|')"; fi

# ── A18 — HEAD == pin does NOT establish the BYTES; a dirty marketplace must not be installed ──
# A non-conflicting tracked modification leaves `rev-parse HEAD` equal to the pin while the files
# 'plugin update' copies differ from the reviewed commit.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"                                 # clone already carries the pin
echo tampered > "$MK/f"                                            # HEAD still == pin, bytes differ
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ]; then
  ok "A18 refuses (exit 2) when the marketplace worktree is dirty at the pinned commit"
else bad "A18 refuses (exit 2) when the marketplace worktree is dirty at the pinned commit" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A18b — a clean FILTER defeats status and the index; only the byte check catches it ─────────
# The equal-length detail is what makes this reachable, and it took a measurement to find: with
# differing lengths `status` still reports the file modified on its stat check, so the dirty-status
# guard fires first and the byte loop is never reached. With the filtered and raw forms the SAME
# length, status is clean, no index flags are set, and `hash-object --no-filters` is the only thing
# that can tell the worktree bytes from the pinned blob. This is the case the byte check exists for.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
git -C "$MK" config filter.fake.clean 'tr A-Z a-z'
printf 'f filter=fake\n' > "$MK/.git/info/attributes"
printf 'NEW\n' > "$MK/f"                       # cleans to "new\n" (the pinned blob); same length
git -C "$MK" diff >/dev/null 2>&1              # settle the stat cache so status is genuinely clean
if [ -n "$(git -C "$MK" status --porcelain)" ]; then
  bad "A18b fixture precondition: status must be clean for this case to reach the byte check" \
    "status=[$(git -C "$MK" status --porcelain)]"
else
  out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && printf '%s' "$out" | grep -q 'differ from the pinned blobs'; then
    ok "A18b refuses (exit 2) when a clean filter hides differing bytes from status and the index"
  else bad "A18b refuses (exit 2) when a clean filter hides differing bytes from status and the index" \
    "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
fi
cleanup

# ── A18c — a gitlink must NOT make a clean pinned marketplace refuse ───────────────────────────
# `ls-tree --name-only` also C-quotes non-ASCII names, and a gitlink is a directory that cannot be
# byte-hashed: either would turn a perfectly clean marketplace into exit 2. Both are availability
# bugs in the guard itself, which is worse than the drift it protects against.
make_fixture
SUB="$ROOT/sub"; mkdir -p "$SUB"
git -C "$SUB" init -q -b main; git -C "$SUB" config user.email t@t; git -C "$SUB" config user.name t
echo s > "$SUB/s"; git -C "$SUB" add s; git -C "$SUB" commit -qm sub
SUB_SHA="$(git -C "$SUB" rev-parse HEAD)"
git -C "$MK" checkout -q "$MK_NEW"
# ANSI-C quoting, NOT double quotes: bash does not expand \xNN inside "…", so `"na\xc3\xafve"` is
# the literal 12-character ASCII name `na\xc3\xafve`. That name is still C-quoted by git (it contains
# backslashes), so the case passed while testing something other than what it claimed. $'…' emits the
# actual UTF-8 bytes.
NONASCII=$'na\xc3\xafve'
printf 'x\n' > "$MK/$NONASCII"
git -C "$MK" add -- "$NONASCII" \
  || { printf 'FIXTURE FAILURE: could not add the non-ASCII name\n' >&2; exit 9; }
# A symlink's blob is its TARGET TEXT while `hash-object` on the link hashes the target's contents,
# so an unhandled symlink also makes a clean marketplace refuse.
ln -s f "$MK/alias"
git -C "$MK" add -- alias \
  || { printf 'FIXTURE FAILURE: could not add the symlink\n' >&2; exit 9; }
# NOT `git add -A`: that stages the DELETION of the gitlink (its directory is absent at this point),
# which silently produced a tree with zero gitlinks — a fixture that tested nothing. Caught by
# ablating the gitlink skip and watching this assertion stay green.
git -C "$MK" update-index --add --cacheinfo 160000,"$SUB_SHA",vendored
git -C "$MK" commit -qm "gitlink + non-ascii" >/dev/null 2>&1
MK_SUB="$(git -C "$MK" rev-parse HEAD)"
# Materialise the submodule so the worktree is genuinely CLEAN; otherwise the dirty-status guard
# fires first and this case never reaches the byte loop it is meant to exercise.
git -c protocol.file.allow=always -C "$MK" clone -q "$SUB" vendored 2>/dev/null
git -C "$MK/vendored" checkout -q "$SUB_SHA" 2>/dev/null
set_gitlink "$MK_SUB"
gl_count="$(git -C "$MK" ls-tree -r HEAD | awk '$1=="160000"' | wc -l | tr -d ' ')"
sl_count="$(git -C "$MK" ls-tree -r HEAD | awk '$1=="120000"' | wc -l | tr -d ' ')"
# Prove the name really is C-quoted by `--name-only`; that quoting is what the -z streaming exists
# to avoid, so if it is absent this case is not exercising the path it claims to.
quoted="$(git -C "$MK" ls-tree -r --name-only HEAD | grep -c '^"' | tr -d ' ')"
if [ "$gl_count" != "1" ] || [ "$sl_count" != "1" ] || [ "$quoted" -lt 1 ] \
  || [ -n "$(git -C "$MK" status --porcelain)" ]; then
  bad "A18c fixture precondition: one gitlink, one symlink, a C-quoted name and a clean worktree" \
    "gitlinks=$gl_count symlinks=$sl_count quoted-names=$quoted status=[$(git -C "$MK" status --porcelain)]"
else
  out="$(STUB_MARKETPLACE_TARGET="$MK_SUB" run 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ]; then
    ok "A18c a gitlink, a symlink and a non-ASCII name do not make a clean marketplace refuse"
  else bad "A18c a gitlink, a symlink and a non-ASCII name do not make a clean marketplace refuse" \
    "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
fi
cleanup

# ── A18d — the post-apply verifier is told WHICH target to check ───────────────────────────────
# Without the explicit arguments the verifier resolves its own defaults, so under any override it
# would check a different repo/plugins-root/plugin than the one this run just updated.
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1
if grep -q -- "--repo-root $CONSUMER" "$VERIFY_LOG" \
  && grep -q -- "--plugins-root $PLUGINS" "$VERIFY_LOG" \
  && grep -q -- "--plugin-id agentic-engineering@devantler-plugins" "$VERIFY_LOG" \
  && grep -q -- "--gitlink $MK_NEW" "$VERIFY_LOG" \
  && grep -q -- "--plugin-name agentic-engineering" "$VERIFY_LOG" \
  && grep -q -- "--submodule-path libraries/agent-plugins" "$VERIFY_LOG"; then
  ok "A18d passes the gated repo, plugins root, plugin id, PIN and submodule path to the verifier"
else bad "A18d passes the gated repo, plugins root, plugin id, PIN and submodule path to the verifier" \
  "verifier args were: [$(tr '\n' '|' < "$VERIFY_LOG")]"; fi
cleanup

# ── A18e — the verifier's own UNKNOWN must survive, not become a drift verdict ──────────────────
# `if ! cmd` collapses every non-zero status into one branch, so a verifier that exits 2 because it
# could not read its evidence would be reported as "the install is not on the pin" — turning "I
# could not check" into a false verdict and pointing the caller at the wrong remedy. That is the
# exact conflation this script's own exit contract forbids.
make_fixture
set_gitlink "$MK_NEW"
VERIFY_UNK="$BIN/verify-unknown"
printf '#!/usr/bin/env bash\nexit 2\n' > "$VERIFY_UNK"; chmod +x "$VERIFY_UNK"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" CLAUDE_CLI="$BIN/claude" "$SCRIPT" \
  --repo-root "$CONSUMER" --plugins-root "$PLUGINS" --verify-cmd "$VERIFY_UNK" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ -e "$ROOT/APPLIED" ] && printf '%s' "$out" | grep -q 'VERIFICATION IS UNKNOWN'; then
  ok "A18e preserves the verifier's UNKNOWN (exit 2) instead of reporting a false drift"
else bad "A18e preserves the verifier's UNKNOWN (exit 2) instead of reporting a false drift" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── A19 — --dry-run asserts nothing about the install, so it is never a 0 verdict ──────────────
# --dry-run deliberately skips the marketplace refresh, so the clone must ALREADY carry the pin to
# reach the would-apply branch at all; otherwise the gate correctly refuses first with exit 1.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" run --dry-run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ]; then
  ok "A19 --dry-run exits 2 (no verdict) and never applies"
else bad "A19 --dry-run exits 2 (no verdict) and never applies" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A20 — the CLI's exit 0 is not the verdict; an independent check decides ────────────────────
# 'plugin update' can exit 0 having repaired nothing (byte-level drift under an already-current
# version string). The post-apply check, not the tool's status, decides.
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" CLAUDE_CLI="$BIN/claude" "$SCRIPT" \
  --repo-root "$CONSUMER" --plugins-root "$PLUGINS" \
  --verify-cmd "$VERIFY_BAD" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ] && [ -e "$ROOT/APPLIED" ]; then
  ok "A20 exits 1 when the post-apply check still does not report CURRENT"
else bad "A20 exits 1 when the post-apply check still does not report CURRENT" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A21 — an unavailable verifier is UNKNOWN, never a success verdict ──────────────────────────
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" CLAUDE_CLI="$BIN/claude" "$SCRIPT" \
  --repo-root "$CONSUMER" --plugins-root "$PLUGINS" \
  --verify-cmd "$ROOT/no-such-verifier" >/dev/null 2>&1; rc=$?
# The contract for this path is "the apply HAPPENED, only the verdict is unknown" — so asserting the
# code alone would also pass if the script refused before ever applying, a different outcome.
if [ "$rc" -eq 2 ] && [ -e "$ROOT/APPLIED" ]; then
  ok "A21 exits 2 (UNKNOWN) after applying when the post-apply verifier is unavailable"
else bad "A21 exits 2 (UNKNOWN) after applying when the post-apply verifier is unavailable" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no)"; fi
cleanup

# ── A6 — no hardcoded claude-code version directory ────────────────────────────────────────────
# The by-hand invocation that worked on 2026-08-15 hardcoded `claude-code/2.1.229/`. Baking that in
# breaks silently on the next runtime upgrade, which is the same unbounded-staleness class this
# script exists to close.
if ! grep -Eq 'claude-code/[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT"; then
  ok "A6 does not hardcode a claude-code version directory"
else bad "A6 does not hardcode a claude-code version directory" "$(grep -Eon 'claude-code/[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT" | head -1)"; fi

# ── A7 — the pin is resolved with --no-replace-objects ─────────────────────────────────────────
# AGENTS.md *Git safety*: a refs/replace entry makes HEAD:<path> resolve through a replacement
# commit while `git rev-parse HEAD` still prints the expected value, so the pin silently names an
# unreviewed revision — a fail-open on the one value everything downstream trusts.
#
# Matched on the INVOCATION line — both `--no-replace-objects` and `rev-parse` on one line — not
# anywhere in the file. Ablation caught the loose form passing vacuously: stripping the flag from
# the command still left the phrase in the comment explaining it, so the assertion could never fail
# while the rationale was documented. An assertion a comment can satisfy tests the prose.
if grep -Eq -- '--no-replace-objects[^\n]*rev-parse|rev-parse[^\n]*--no-replace-objects' "$SCRIPT"; then
  ok "A7 resolves the pinned revision with --no-replace-objects"
else bad "A7 resolves the pinned revision with --no-replace-objects" "the gate can be pointed at an unreviewed revision"; fi

# ── A8 — the restart semantics are stated on the applying path ─────────────────────────────────
# `plugin update` says "restart required to apply". The applying run keeps executing the OLD
# definition, so an exit 0 that reads as "this run used the new definition" is the same fail-open
# as the drift itself (#2856 acceptance criterion 2).
make_fixture
set_gitlink "$MK_NEW"
#
# Keyed on the CLI's own word, `restart`. The first draft also accepted "next dispatch" and "this
# run"; ablation showed that set survived deleting the restart sentence outright, because those
# phrases recur throughout the surrounding prose. A needle that common asserts the topic, not the
# statement.
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"
if printf '%s' "$out" | grep -qi 'restart'; then
  ok "A8 states that the applying run still executes the previous definition"
else bad "A8 states that the applying run still executes the previous definition" "$(printf '%s' "$out" | tail -3 | tr '\n' '|')"; fi
cleanup

# ── A9–A11 — the CONTRACT carries the rule, not just this script ───────────────────────────────
# A script nobody is told to run is decoration, and the marketplace-latest hazard is the one fact
# that makes the gate look like needless friction if it is not written down. Scoped to the plugin
# contract section, matching the currency suite: these phrases also appear in this file and in the
# script header, so a file-wide match would pass while the operative section said nothing.
CONSTITUTION="$(cd "$HERE/../.." && pwd)/AGENTS.md"
if [ -r "$CONSTITUTION" ]; then
  section="$(awk '
      /^### Agentic engineering plugin contract$/ { ins = 1; next }
      ins && /^### / { exit }
      ins { print }
    ' "$CONSTITUTION" | tr '\n' ' ')"
  [ -n "$section" ] || bad "A9-A11 could not extract the plugin contract section from AGENTS.md"

  case "$section" in
    *"plugin-definition-refresh.sh"*) ok "A9 the contract names the gated refresh script" ;;
    *) bad "A9 the contract names the gated refresh script" "pre-flight has no prescribed way to apply the pin" ;;
  esac
  # The hazard, not merely the gate: without it the refusal reads as over-caution and the next
  # reader "fixes" it by dropping the gate — which is precisely the fail-open.
  case "$section" in
    *"installs the MARKETPLACE LATEST"*) ok "A10 the contract states that plugin update installs the marketplace latest" ;;
    *) bad "A10 the contract states that plugin update installs the marketplace latest" "the reason for the gate is unrecorded" ;;
  esac
  case "$section" in
    *"requires a restart"*) ok "A11 the contract states the restart semantics of an apply" ;;
    *) bad "A11 the contract states the restart semantics of an apply" "an apply-time exit 0 could be read as 'this run is current'" ;;
  esac
else
  bad "A9-A11 AGENTS.md is unreadable at $CONSTITUTION"
fi

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
