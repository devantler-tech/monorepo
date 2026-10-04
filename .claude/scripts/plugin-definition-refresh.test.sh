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

# The fixtures commit, and a commit inherits the caller's global configuration. Where that turns on
# commit signing, every fixture commit starts gpg, and parallel suite runs then fail inside gpg rather
# than in anything under test. No global or system configuration is read from here on.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; }

[ -x "$SCRIPT" ] || { printf 'plugin-definition-refresh.sh is missing or not executable: %s\n' "$SCRIPT" >&2; exit 1; }

# ── fixture ────────────────────────────────────────────────────────────────────
# A marketplace clone with two commits, a consumer repo whose gitlink names one of them, and a
# stub CLI that records every invocation and moves the clone on `marketplace update`.
# write_manifest <dir> <target-version> <unrelated-version> [<extra target-entry JSON members>]
write_manifest() {
  printf '{"name":"devantler-plugins","metadata":{"version":"%s-%s"},"plugins":[{"name":"agentic-engineering","source":"./plugins/agentic-engineering","version":"%s"%s},{"name":"frontend-design","source":"./plugins/frontend-design","version":"%s"}]}\n' \
    "$2" "$3" "$2" "${4:+,$4}" "$3" > "$1/.claude-plugin/marketplace.json" \
    || { printf 'FIXTURE FAILURE: write manifest\n' >&2; exit 9; }
}
# commit_on <repo> <message>: commit everything staged-able under the marketplace paths, print the sha.
commit_on() {
  git -C "$1" add -A f .claude-plugin plugins >/dev/null 2>&1 \
    && git -C "$1" commit -qm "$2" >/dev/null 2>&1 \
    && git -C "$1" rev-parse HEAD \
    || { printf 'FIXTURE FAILURE: commit %s in %s\n' "$2" "$1" >&2; exit 9; }
}
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

  # Every setup command is checked. An unguarded fixture does not fail the suite — it leaves the
  # assertions running against a tree that was never built, which is how three cases in this file
  # came to pass while testing nothing.
  g() { "$@" || { printf 'FIXTURE FAILURE: %s\n' "$*" >&2; exit 9; }; }

  g git -C "$MK" init -q -b main
  g git -C "$MK" config user.email t@t; g git -C "$MK" config user.name t
  g git -C "$MK" config commit.gpgsign false
  # A real marketplace layout: the manifest, the target plugin's subtree and an unrelated plugin.
  # Commit two moves the TARGET plugin, so OLD vs NEW is a genuine change to what would install.
  g mkdir -p "$MK/.claude-plugin" "$MK/plugins/agentic-engineering/agents" "$MK/plugins/frontend-design"
  echo old > "$MK/f" || { printf 'FIXTURE FAILURE: write f\n' >&2; exit 9; }
  write_manifest "$MK" 1.0.0 1.0.0
  echo old > "$MK/plugins/agentic-engineering/agents/a.md" || { printf 'FIXTURE FAILURE: write a.md\n' >&2; exit 9; }
  # A plugin manifest and a file outside agents/ and skills/: the parts of an install that the
  # currency check does not read, and that the whole-tree comparison after the apply must.
  g mkdir -p "$MK/plugins/agentic-engineering/.claude-plugin" "$MK/plugins/agentic-engineering/resources"
  echo '{"name":"agentic-engineering"}' > "$MK/plugins/agentic-engineering/.claude-plugin/plugin.json" || { printf 'FIXTURE FAILURE: write plugin.json\n' >&2; exit 9; }
  echo res > "$MK/plugins/agentic-engineering/resources/r.md" || { printf 'FIXTURE FAILURE: write r.md\n' >&2; exit 9; }
  echo fd > "$MK/plugins/frontend-design/s.md" || { printf 'FIXTURE FAILURE: write s.md\n' >&2; exit 9; }
  g git -C "$MK" add f .claude-plugin plugins; g git -C "$MK" commit -qm one
  MK_OLD="$(git -C "$MK" rev-parse HEAD)" || { printf 'FIXTURE FAILURE: rev-parse OLD\n' >&2; exit 9; }
  echo new > "$MK/f" || { printf 'FIXTURE FAILURE: rewrite f\n' >&2; exit 9; }
  write_manifest "$MK" 1.0.1 1.0.0
  echo new > "$MK/plugins/agentic-engineering/agents/a.md" || { printf 'FIXTURE FAILURE: rewrite a.md\n' >&2; exit 9; }
  g git -C "$MK" add f .claude-plugin plugins; g git -C "$MK" commit -qm two
  MK_NEW="$(git -C "$MK" rev-parse HEAD)" || { printf 'FIXTURE FAILURE: rev-parse NEW\n' >&2; exit 9; }
  g git -C "$MK" checkout -q "$MK_OLD"      # clone starts STALE, as the real one was

  # consumer repo carrying a gitlink to the marketplace at a chosen revision
  g git -C "$CONSUMER" init -q -b main
  g git -C "$CONSUMER" config user.email t@t; g git -C "$CONSUMER" config user.name t
  g git -C "$CONSUMER" config commit.gpgsign false
  git -C "$CONSUMER" config protocol.file.allow always 2>/dev/null || true
  echo x > "$CONSUMER/x" || { printf 'FIXTURE FAILURE: write x\n' >&2; exit 9; }
  g git -C "$CONSUMER" add x; g git -C "$CONSUMER" commit -qm base

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
  # Optional window so a test can signal the script while it holds the lock.
  [ -n "\${STUB_REFRESH_SLEEP:-}" ] && sleep "\$STUB_REFRESH_SLEEP"
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = update ]; then
  # What the real command does: install the plugin directory of whatever the clone holds NOW. It
  # refreshes the marketplace from its remote first, which STUB_APPLY_MOVE stands in for by moving
  # the clone to another commit before the copy.
  if [ -n "\${STUB_APPLY_MOVE:-}" ]; then git -C "$MK" checkout -q "\$STUB_APPLY_MOVE" || exit 1; fi
  if [ -z "\${STUB_APPLY_NOOP:-}" ]; then
    rm -rf "$INSTALLED"
    cp -R "$MK/plugins/agentic-engineering" "$INSTALLED" || exit 1
    # The runtime's own bookkeeping marker, present on every real install.
    mkdir -p "$INSTALLED/.in_use" && : > "$INSTALLED/.in_use/4242"
    if [ -n "\${STUB_APPLY_EXTRA:-}" ]; then
      mkdir -p "$INSTALLED/\$(dirname "\$STUB_APPLY_EXTRA")" && : > "$INSTALLED/\$STUB_APPLY_EXTRA"
    fi
  fi
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
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "A1 refuses (exit 1) when the refreshed marketplace does not carry the pin"
else bad "A1 refuses (exit 1) when the refreshed marketplace does not carry the pin" "exit was $rc"; fi
if [ ! -e "$ROOT/APPLIED" ]; then ok "A1b does NOT invoke 'plugin update' when the pin is unavailable"
else bad "A1b does NOT invoke 'plugin update' when the pin is unavailable" "it applied an unreviewed revision"; fi
if grep -q 'plugins/agentic-engineering/agents/a.md' <<<"$out" && ! grep -q 'frontend-design' <<<"$out"; then
  ok "A1c names exactly the target plugin's differing file"
else bad "A1c names exactly the target plugin's differing file" "$out"; fi
cleanup

# ── B — the gate scope is the TARGET plugin, not the whole marketplace (monorepo#3197) ─────────
# Each case moves the marketplace past the pin in ONE way. `plugin update` installs the latest, so
# it may apply only when the target plugin's entry (apart from its version) and subtree are
# identical; B2–B4 are the negative controls that stop the narrower gate becoming a fail-open.
# move_past_pin <pin> <message> runs after the caller edits the clone, and prints the new commit.
move_past_pin() {
  local sha
  sha="$(commit_on "$MK" "$2")"
  [ -n "$sha" ] || { printf 'FIXTURE FAILURE: no commit for %s\n' "$2" >&2; exit 9; }
  git -C "$MK" checkout -q "$MK_OLD" || { printf 'FIXTURE FAILURE: reset clone\n' >&2; exit 9; }
  printf '%s' "$sha"
}

# B1 — the measured case: only an unrelated plugin (and the target's version string) moved.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
echo fd2 > "$MK/plugins/frontend-design/s.md"
write_manifest "$MK" 1.0.2 1.0.1
B_HEAD="$(move_past_pin "$MK_NEW" unrelated)" || exit 9
out="$(STUB_MARKETPLACE_TARGET="$B_HEAD" run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ] && grep -q -- "--gitlink $MK_NEW" "$VERIFY_LOG"; then
  ok "B1 applies when only an unrelated plugin moved past the pin, and verifies against the pin"
else bad "B1 applies when only an unrelated plugin moved past the pin, and verifies against the pin" "exit $rc, out: $out"; fi
cleanup

# B2 — the load-bearing negative control: the target subtree moved.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
echo added > "$MK/plugins/agentic-engineering/agents/b.md"
B_HEAD="$(move_past_pin "$MK_NEW" target-moved)" || exit 9
out="$(STUB_MARKETPLACE_TARGET="$B_HEAD" run 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'plugins/agentic-engineering/agents/b.md' <<<"$out"; then
  ok "B2 refuses (exit 1), naming the file, when the target plugin's subtree moved"
else bad "B2 refuses (exit 1), naming the file, when the target plugin's subtree moved" "exit $rc, out: $out"; fi
cleanup

# B3 — the target entry moved in a field other than its version (identical subtree).
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
write_manifest "$MK" 1.0.1 1.0.0 '"strict":false'
B_HEAD="$(move_past_pin "$MK_NEW" entry-moved)" || exit 9
out="$(STUB_MARKETPLACE_TARGET="$B_HEAD" run 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'its marketplace entry' <<<"$out"; then
  ok "B3 refuses (exit 1) when the target's marketplace entry changed beyond its version"
else bad "B3 refuses (exit 1) when the target's marketplace entry changed beyond its version" "exit $rc, out: $out"; fi
cleanup

# B4 — the marketplace no longer lists the target plugin at all.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
printf '{"name":"devantler-plugins","plugins":[{"name":"frontend-design","source":"./plugins/frontend-design"}]}\n' \
  > "$MK/.claude-plugin/marketplace.json"
B_HEAD="$(move_past_pin "$MK_NEW" delisted)" || exit 9
out="$(STUB_MARKETPLACE_TARGET="$B_HEAD" run 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'no longer lists' <<<"$out"; then
  ok "B4 refuses (exit 1) when the marketplace no longer lists the target plugin"
else bad "B4 refuses (exit 1) when the marketplace no longer lists the target plugin" "exit $rc, out: $out"; fi
cleanup

# B5 — the runtime clone is shallow, so the pin may be absent from it. A pin found nowhere is
# UNKNOWN; the same pin read from the consumer's submodule decides the gate.
make_fixture
SIDE="$ROOT/side"
git -c advice.detachedHead=false clone -q "$MK" "$SIDE" || { printf 'FIXTURE FAILURE: clone side\n' >&2; exit 9; }
git -C "$SIDE" config user.email t@t; git -C "$SIDE" config user.name t
git -C "$SIDE" checkout -q "$MK_NEW" || exit 9
echo fd-side > "$SIDE/plugins/frontend-design/s.md"
PIN_SIDE="$(commit_on "$SIDE" side-only)"; [ -n "$PIN_SIDE" ] || exit 9
set_gitlink "$PIN_SIDE"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ]; then
  ok "B5 is UNKNOWN (exit 2) when the pin is in neither the clone nor the consumer's submodule"
else bad "B5 is UNKNOWN (exit 2) when the pin is in neither the clone nor the consumer's submodule" "exit $rc, out: $out"; fi
git -c advice.detachedHead=false clone -q "$SIDE" "$CONSUMER/libraries/agent-plugins" || { printf 'FIXTURE FAILURE: clone submodule\n' >&2; exit 9; }
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ]; then
  ok "B5b reads the pin from the consumer's submodule and applies an identical target subtree"
else bad "B5b reads the pin from the consumer's submodule and applies an identical target subtree" "exit $rc, out: $out"; fi
cleanup

# B6 — a symlink keeps the subtree's tree id while the bytes it installs change: Claude Code
# dereferences a link into the marketplace when it copies the plugin. Only the moved TARGET
# file differs here, so the subtree is identical and the shortcut must still refuse.
make_fixture
git -C "$MK" checkout -q "$MK_NEW"
ln -s ../../frontend-design/s.md "$MK/plugins/agentic-engineering/agents/shared.md" || exit 9
B_PIN="$(commit_on "$MK" linked)"; [ -n "$B_PIN" ] || exit 9
set_gitlink "$B_PIN"
git -C "$MK" checkout -q "$B_PIN"
echo unreviewed > "$MK/plugins/frontend-design/s.md"
B_HEAD="$(move_past_pin "$B_PIN" link-target-moved)" || exit 9
out="$(STUB_MARKETPLACE_TARGET="$B_HEAD" run 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'plugins/agentic-engineering/agents/shared.md' <<<"$out"; then
  ok "B6 refuses (exit 1), naming the link, when the target subtree holds a symlink"
else bad "B6 refuses (exit 1), naming the link, when the target subtree holds a symlink" "exit $rc, out: $out"; fi
cleanup

# B7 — the pin must be an object id. `HEAD` would resolve inside the marketplace clone and the
# gate would compare the marketplace with itself.
make_fixture
set_gitlink "$MK_OLD"
for expr in HEAD main; do
  out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run --gitlink "$expr" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'not a full object id' <<<"$out"; then
    ok "B7 refuses --gitlink $expr as UNKNOWN (exit 2) rather than resolving it"
  else bad "B7 refuses --gitlink $expr as UNKNOWN (exit 2) rather than resolving it" "exit $rc, out: $out"; fi
done
cleanup

# B8 — a failed read of the marketplace subtree is UNKNOWN, never "absent" (which would say NOT-ON-PIN
# and point the caller at a gitlink bump). The pin is read from the consumer's submodule, as on a
# shallow runtime clone, and every object read inside the marketplace clone fails.
make_fixture
SIDE="$ROOT/side"
git -c advice.detachedHead=false clone -q "$MK" "$SIDE" || { printf 'FIXTURE FAILURE: clone side\n' >&2; exit 9; }
git -C "$SIDE" config user.email t@t; git -C "$SIDE" config user.name t
git -C "$SIDE" checkout -q "$MK_NEW" || exit 9
echo fd-side > "$SIDE/plugins/frontend-design/s.md"
PIN_SIDE="$(commit_on "$SIDE" side-only)"; [ -n "$PIN_SIDE" ] || exit 9
set_gitlink "$PIN_SIDE"
git -c advice.detachedHead=false clone -q "$SIDE" "$CONSUMER/libraries/agent-plugins" || exit 9
mkdir -p "$ROOT/gitshim"
cat > "$ROOT/gitshim/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = -C ] && [ "\$2" = "$MK" ] && [ "\$4" = cat-file ]; then exit 128; fi
exec "$(command -v git)" "\$@"
SHIM
chmod +x "$ROOT/gitshim/git"
out="$(PATH="$ROOT/gitshim:$PATH" STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q "cannot read the 'agentic-engineering' subtree" <<<"$out"; then
  ok "B8 reports a failed marketplace read as UNKNOWN (exit 2), not as an absent subtree"
else bad "B8 reports a failed marketplace read as UNKNOWN (exit 2), not as an absent subtree" "exit $rc, out: $out"; fi
cleanup

# B9 — git reads a path argument as a pathspec, where `:/` is top magic. A reviewed source of
# `./:/plugins/agentic-engineering` would be compared through the `plugins/agentic-engineering`
# decoy while the runtime copies the literal directory, so such a source is refused outright.
make_fixture
git -C "$MK" checkout -q "$MK_NEW"
mkdir -p "$MK/:/plugins/agentic-engineering/agents" || exit 9
echo reviewed > "$MK/:/plugins/agentic-engineering/agents/a.md"
write_manifest "$MK" 1.0.1 1.0.0
sed 's|"source":"./plugins/agentic-engineering"|"source":"./:/plugins/agentic-engineering"|' \
  "$MK/.claude-plugin/marketplace.json" > "$MK/.claude-plugin/m.tmp" && mv "$MK/.claude-plugin/m.tmp" "$MK/.claude-plugin/marketplace.json"
git -C "$MK" --literal-pathspecs add -- ':' >/dev/null 2>&1 || exit 9
B_PIN="$(commit_on "$MK" magic-source)"; [ -n "$B_PIN" ] || exit 9
set_gitlink "$B_PIN"
git -C "$MK" checkout -q "$B_PIN"
echo unreviewed > "$MK/:/plugins/agentic-engineering/agents/a.md"
git -C "$MK" --literal-pathspecs add -- ':' >/dev/null 2>&1 || exit 9
B_HEAD="$(move_past_pin "$B_PIN" magic-literal-moved)" || exit 9
out="$(STUB_MARKETPLACE_TARGET="$B_HEAD" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'is not a plain relative path' <<<"$out"; then
  ok "B9 refuses a source path git would read as pathspec magic (exit 2), never comparing a decoy"
else bad "B9 refuses a source path git would read as pathspec magic (exit 2), never comparing a decoy" "exit $rc, out: $out"; fi
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
out="$(CLAUDE_CLI="$ROOT/nope" "$SCRIPT" --repo-root "$CONSUMER" --plugins-root "$PLUGINS" 2>&1)"; rc=$?
# The reason, not just the code: exit 2 covers eight conditions here, so a regression that exits 2
# earlier for an unrelated reason would keep this green while the CLI resolution never ran.
if [ "$rc" -eq 2 ] && grep -q 'cannot resolve an executable claude CLI' <<<"$out"; then
  ok "A5 exits 2 (UNKNOWN, named reason) when the CLI cannot be resolved"
else bad "A5 exits 2 (UNKNOWN, named reason) when the CLI cannot be resolved" \
  "exit was $rc — 0/1 would be a fabricated verdict; out=$(printf '%s' "$out" | tr '\n' '|')"; fi
# A CLI that was NAMED is never looked up anywhere else, so the message names it and its source
# instead of listing lookups that did not happen.
if grep -qF "'$ROOT/nope' (from --cli or \$CLAUDE_CLI) is not an executable file" <<<"$out"; then
  ok "A5b names the CLI that was given and where it came from"
else bad "A5b names the CLI that was given and where it came from" "out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── A22 — --help prints the WHOLE header, including the exit-code contract ─────────────────────
# It was truncating at a hardcoded line count as the header grew, dropping the exit-2 explanation —
# the part the contract most turns on. Behavioural, not a grep of the source.
help_out="$("$SCRIPT" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q 'Exit 2 is deliberately not exit 1' <<<"$help_out" \
  && grep -q 'Usage: plugin-definition-refresh.sh' <<<"$help_out" \
  && ! grep -q '^set -euo pipefail' <<<"$help_out"; then
  ok "A22 --help prints the full header including the exit-code contract, and stops before the code"
else bad "A22 --help prints the full header including the exit-code contract, and stops before the code" \
  "exit was $rc; lines=$(printf '%s' "$help_out" | wc -l | tr -d ' ')"; fi

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
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'refusing to gate on one marketplace and install from another' <<<"$out"; then
  ok "A12 refuses (exit 2, named reason) when --marketplace and --plugin-id name different marketplaces"
else bad "A12 refuses (exit 2, named reason) when --marketplace and --plugin-id name different marketplaces" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── A13 — an unqualified plugin id is UNKNOWN, never a silent default ──────────────────────────
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run --plugin-id agentic-engineering 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'is not marketplace-qualified' <<<"$out"; then
  ok "A13 refuses (exit 2, named reason) when the plugin id is not marketplace-qualified"
else bad "A13 refuses (exit 2, named reason) when the plugin id is not marketplace-qualified" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── A14 — a malformed registry after the apply is UNKNOWN, never a verdict in either direction ─
# The registry is where the install is located, so one that cannot be parsed leaves nothing to
# compare with the gated tree: that is exit 2 with the reason named. It must not be exit 0 (nothing
# was verified), and it must not be the exit 1 that `set -e` + `pipefail` produce when a failing `jq`
# aborts the script — a "not on the pin" verdict fabricated by a parse error.
make_fixture
set_gitlink "$MK_NEW"
printf '%s\n' 'this is not json {{{' > "$PLUGINS/installed_plugins.json"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ -e "$ROOT/APPLIED" ] && [ "$rc" -eq 2 ] && grep -q 'APPLIED, BUT UNVERIFIED — the registry' <<<"$out"; then
  ok "A14 exits 2 (UNKNOWN, named reason) after applying when the registry is malformed"
else bad "A14 exits 2 (UNKNOWN, named reason) after applying when the registry is malformed" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
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
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'holds .* after' <<<"$out"; then
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
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'holds .* after' <<<"$out"; then
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
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'NOT evidence the marketplace lacks the pin' <<<"$out"; then
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
# A pid that WAS OURS and has since exited. Scanning for a pid that `kill -0` rejects does not
# prove absence: that also fails with EPERM for a LIVE process owned by another user.
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
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

# ── A16b — registry backups are RETAINED to a bound, and the survivors are the NEWEST ──────────
# Two lanes dispatch hourly, so an unbounded backup set grows forever while nothing reads the old
# copies. Both halves are asserted: a count alone would pass a prune that kept the OLDEST, which is
# the one outcome that loses the copy an operator would actually want.
make_fixture
set_gitlink "$MK_NEW"
for stamp in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do
  echo stale > "$PLUGINS/installed_plugins.json.bak-$stamp-plugin-definition-refresh"
done
# An unrelated neighbour must survive: the prune matches only this script's own suffix.
echo other > "$PLUGINS/installed_plugins.json.bak-20260101T000000Z-someone-else"
PLUGIN_REFRESH_BACKUP_KEEP=2 STUB_MARKETPLACE_TARGET="$MK_NEW" run >/dev/null 2>&1; rc=$?
kept="$(ls -1 "$PLUGINS"/installed_plugins.json.bak-*-plugin-definition-refresh 2>/dev/null | wc -l | tr -d ' ')"
oldest_gone=yes
[ -e "$PLUGINS/installed_plugins.json.bak-20260101T000000Z-plugin-definition-refresh" ] && oldest_gone=no
# Name the survivors, never just count them: with KEEP=2 the run's own fresh backup takes one slot,
# so exactly 20260103 may hold the other. A prune that dropped 20260101 and 20260103 while keeping
# 20260102 satisfies the count AND oldest_gone, and is precisely the wrong-pair retention this case
# exists to catch.
middle_gone=yes
[ -e "$PLUGINS/installed_plugins.json.bak-20260102T000000Z-plugin-definition-refresh" ] && middle_gone=no
newest_fixture_kept=yes
[ -e "$PLUGINS/installed_plugins.json.bak-20260103T000000Z-plugin-definition-refresh" ] || newest_fixture_kept=no
neighbour=yes
[ -e "$PLUGINS/installed_plugins.json.bak-20260101T000000Z-someone-else" ] || neighbour=no
if [ "$rc" -eq 0 ] && [ "$kept" = "2" ] && [ "$oldest_gone" = yes ] \
  && [ "$middle_gone" = yes ] && [ "$newest_fixture_kept" = yes ] && [ "$neighbour" = yes ]; then
  ok "A16b prunes registry backups to the bound, keeping the newest and sparing other files"
else bad "A16b prunes registry backups to the bound, keeping the newest and sparing other files" \
  "exit was $rc, kept=$kept (want 2), oldest_removed=$oldest_gone, middle_removed=$middle_gone," \
  "newest_fixture_kept=$newest_fixture_kept, unrelated_file_survived=$neighbour"; fi
cleanup

# ── A17 — INT/TERM must TERMINATE the run, not merely clean up and resume ──────────────────────
# A bash handler that returns normally resumes at the point of interruption, so a combined
# `trap release_lock EXIT INT TERM` would surrender the lock and then carry on into 'plugin update'
# — an unserialized apply, which is the very thing the lock exists to prevent.
# ── A17b — BEHAVIOURAL: a TERM while holding the lock must terminate, not resume ───────────────
# A17 below asserts the trap lines; this asserts what they are for. The script is signalled while it
# holds the lock inside the refresh, and must (a) not go on to apply, and (b) leave no lock behind.
# A handler that merely released and returned would resume into 'plugin update' — an unserialized
# apply with the lock already surrendered.
make_fixture
set_gitlink "$MK_NEW"
STUB_MARKETPLACE_TARGET="$MK_NEW" STUB_REFRESH_SLEEP=5 CLAUDE_CLI="$BIN/claude" "$SCRIPT" \
  --repo-root "$CONSUMER" --plugins-root "$PLUGINS" --verify-cmd "$VERIFY" >/dev/null 2>&1 &
sig_pid=$!
lockdir="$PLUGINS/.plugin-definition-refresh.lock"
for _ in $(seq 1 40); do [ -s "$lockdir/pid" ] && break; sleep 0.25; done
if [ ! -s "$lockdir/pid" ]; then
  bad "A17b fixture precondition: the script must be holding the lock before it is signalled" \
    "no lock published within 10s"
  kill "$sig_pid" 2>/dev/null || true; wait "$sig_pid" 2>/dev/null
else
  kill -TERM "$sig_pid" 2>/dev/null
  wait "$sig_pid" 2>/dev/null; trc=$?
  # 143 is the DECLARED status (`trap 'exit 143' TERM`), not merely "abnormal". A regression that
  # removes that trap lets the default TERM disposition end the process, and `wait` reports a
  # non-zero status for that too — so `-ne 0` would stay green while the signal contract this
  # asserts had been deleted. Pin the exact status.
  if [ "$trc" -eq 143 ] && [ ! -e "$ROOT/APPLIED" ] && [ ! -d "$lockdir" ]; then
    ok "A17b a TERM while holding the lock terminates without applying and releases the lock"
  else bad "A17b a TERM while holding the lock terminates without applying and releases the lock" \
    "exit was $trc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), lock_left=$([ -d "$lockdir" ] && echo yes || echo no)"; fi
fi
cleanup

# The EXIT handler is the fail-closed cleanup (monorepo#3414), so the lock release is asserted where
# it now happens: inside that handler, which must be the only thing the EXIT trap runs.
exit_handler="$(sed -n '/^plugin_definition_refresh_cleanup() {$/,/^}$/p' "$SCRIPT")"
if grep -Eq '^trap plugin_definition_refresh_cleanup EXIT$' "$SCRIPT" \
  && grep -Eq '^  release_lock$' <<<"$exit_handler" \
  && grep -Eq "^trap 'exit 130' INT$" "$SCRIPT" \
  && grep -Eq "^trap 'exit 143' TERM$" "$SCRIPT" \
  && ! grep -Eq '^trap [A-Za-z_]+ EXIT INT TERM$' "$SCRIPT"; then
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
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
# Assert the REASON, as A5/A12/A13/A15/A15c/A18b/A19b already do. Exit 2 covers eight conditions in
# the script and almost none of them apply the update, so `rc -eq 2` plus "no APPLIED" discriminates
# weakly: a regression that exits 2 anywhere earlier keeps this green while the dirty-worktree guard
# under test never runs.
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'is not clean at' <<<"$out"; then
  ok "A18 refuses (exit 2) when the marketplace worktree is dirty at the pinned commit"
else bad "A18 refuses (exit 2) when the marketplace worktree is dirty at the pinned commit" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
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
  if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'differ from the blobs of the gated revision' <<<"$out"; then
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
# Routed through `g` (defined by make_fixture, which has already run, so it is in scope): an
# unchecked setup command reports its failure as a downstream symptom — `gitlinks=0` in the
# precondition — rather than naming the command that actually failed. stderr is kept for the same
# reason.
g git -C "$SUB" init -q -b main; g git -C "$SUB" config user.email t@t; g git -C "$SUB" config user.name t
echo s > "$SUB/s"; g git -C "$SUB" add s; g git -C "$SUB" commit -qm sub
SUB_SHA="$(git -C "$SUB" rev-parse HEAD)"
g git -C "$MK" checkout -q "$MK_NEW"
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
# A target ending in a NEWLINE is the case the script's `perl` branch exists for, and `ln -s f` does
# not reach it: command substitution strips trailing newlines, so `printf '%s' "$(readlink …)"`
# hashes `f` for both links and stays green. Only a target whose bytes end in \n makes the shell
# form differ from the blob — without this link, reverting that branch to the shell form would not
# fail any assertion here.
ln -s $'f\n' "$MK/alias-nl"
g git -C "$MK" add -- alias-nl
# NOT `git add -A`: that stages the DELETION of the gitlink (its directory is absent at this point),
# which silently produced a tree with zero gitlinks — a fixture that tested nothing. Caught by
# ablating the gitlink skip and watching this assertion stay green.
g git -C "$MK" update-index --add --cacheinfo 160000,"$SUB_SHA",vendored
g git -C "$MK" commit -qm "gitlink + non-ascii"
MK_SUB="$(git -C "$MK" rev-parse HEAD)"
# Materialise the submodule so the worktree is genuinely CLEAN; otherwise the dirty-status guard
# fires first and this case never reaches the byte loop it is meant to exercise.
g git -c protocol.file.allow=always -C "$MK" clone -q "$SUB" vendored
g git -C "$MK/vendored" checkout -q "$SUB_SHA"
set_gitlink "$MK_SUB"
gl_count="$(git -C "$MK" ls-tree -r HEAD | awk '$1=="160000"' | wc -l | tr -d ' ')"
sl_count="$(git -C "$MK" ls-tree -r HEAD | awk '$1=="120000"' | wc -l | tr -d ' ')"
# Prove the name really is C-quoted by `--name-only`; that quoting is what the -z streaming exists
# to avoid, so if it is absent this case is not exercising the path it claims to.
quoted="$(git -C "$MK" ls-tree -r --name-only HEAD | grep -c '^"' | tr -d ' ')"
if [ "$gl_count" != "1" ] || [ "$sl_count" != "2" ] || [ "$quoted" -lt 1 ] \
  || [ -n "$(git -C "$MK" status --porcelain)" ]; then
  bad "A18c fixture precondition: one gitlink, two symlinks (one newline-terminated), a C-quoted name and a clean worktree" \
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
if [ "$rc" -eq 2 ] && [ -e "$ROOT/APPLIED" ] && grep -q 'VERIFICATION IS UNKNOWN' <<<"$out"; then
  ok "A18e preserves the verifier's UNKNOWN (exit 2) instead of reporting a false drift"
else bad "A18e preserves the verifier's UNKNOWN (exit 2) instead of reporting a false drift" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── C — the clone can move AFTER the gate, and nothing ungated may be applied (monorepo#3783) ──
# The clone is shared with the runtime, whose own marketplace auto-update takes no lock of this
# script's: started by any other session on the host, it moves the clone between the gate and the
# apply. `plugin update` installs whatever the clone holds, so every read after the gate must be
# bound to the revision the gate approved, and HEAD must be read again right before the apply.
# Each shim stands in for that auto-update by moving the clone at one fixed point, once.

# C1 — moved BEFORE the byte check. A worktree compared against the HEAD it just moved to always
# matches, so a check that reads the live HEAD passes and the run installs the moved revision. The
# reason is asserted: it must be the byte check that refuses, against the gated revision.
make_fixture
set_gitlink "$MK_NEW"
REAL_GIT="$(command -v git)"
mkdir -p "$ROOT/gitshim"
cat > "$ROOT/gitshim/git" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = "$MK" ] && [ "\${3:-}" = ls-files ] && [ ! -e "$ROOT/MOVED" ]; then
  : > "$ROOT/MOVED"
  "$REAL_GIT" -C "$MK" checkout -q "$MK_OLD"
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$ROOT/gitshim/git"
out="$(PATH="$ROOT/gitshim:$PATH" STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ ! -e "$ROOT/MOVED" ]; then
  bad "C1 fixture precondition: the clone must move after the gate" "the shim never fired; out=$(printf '%s' "$out" | tr '\n' '|')"
elif [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && ! grep -q '^plugin update ' "$CLI_LOG" \
  && grep -q "differ from the blobs of the gated revision $MK_NEW" <<<"$out"; then
  ok "C1 the byte check reads the gated revision, so a clone moved after the gate is UNKNOWN (exit 2) and never applied"
else bad "C1 the byte check reads the gated revision, so a clone moved after the gate is UNKNOWN (exit 2) and never applied" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# C1b — the same move, to a revision that only DELETES a file. C1's two revisions hold the same file
# set, so it pins only which revision each blob is read from; a check that took its file LIST from
# the live HEAD would walk the moved revision's shorter list, find every file on it unchanged, and
# print "verified against <gated>" having never looked for the file that is gone. The byte check's
# own refusal is asserted, so the HEAD re-read before the apply cannot stand in for it.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
git -C "$MK" rm -q plugins/frontend-design/s.md || { printf 'FIXTURE FAILURE: remove s.md\n' >&2; exit 9; }
MK_DEL="$(move_past_pin "$MK_NEW" file-deleted)" || exit 9
REAL_GIT="$(command -v git)"
mkdir -p "$ROOT/gitshim"
cat > "$ROOT/gitshim/git" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = "$MK" ] && [ "\${3:-}" = ls-files ] && [ ! -e "$ROOT/MOVED" ]; then
  : > "$ROOT/MOVED"
  "$REAL_GIT" -C "$MK" checkout -q "$MK_DEL"
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$ROOT/gitshim/git"
out="$(PATH="$ROOT/gitshim:$PATH" STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ ! -e "$ROOT/MOVED" ] || [ -e "$MK/plugins/frontend-design/s.md" ]; then
  bad "C1b fixture precondition: the clone must move, after the gate, to a revision without the file" "out=$(printf '%s' "$out" | tr '\n' '|')"
elif [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && ! grep -q '^plugin update ' "$CLI_LOG" \
  && grep -q '1 marketplace file(s) could not be byte-verified' <<<"$out" \
  && ! grep -q 'marketplace bytes ....... verified against' <<<"$out"; then
  ok "C1b the byte check lists the gated revision's files, so a move that only deletes one is refused by the byte check itself"
else bad "C1b the byte check lists the gated revision's files, so a move that only deletes one is refused by the byte check itself" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# C2 — moved AFTER the byte check, at the last step before the apply (the registry backup's
# timestamp). Every earlier guard has already passed for the gated revision, so only re-reading
# HEAD immediately before `plugin update` can catch it.
make_fixture
set_gitlink "$MK_NEW"
REAL_DATE="$(command -v date)"
mkdir -p "$ROOT/dateshim"
cat > "$ROOT/dateshim/date" <<SHIM
#!/usr/bin/env bash
if [ ! -e "$ROOT/MOVED" ]; then
  : > "$ROOT/MOVED"
  git -C "$MK" checkout -q "$MK_OLD"
fi
exec "$REAL_DATE" "\$@"
SHIM
chmod +x "$ROOT/dateshim/date"
out="$(PATH="$ROOT/dateshim:$PATH" STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ ! -e "$ROOT/MOVED" ]; then
  bad "C2 fixture precondition: the clone must move between the byte check and the apply" "the shim never fired; out=$(printf '%s' "$out" | tr '\n' '|')"
elif ! grep -q "marketplace bytes ....... verified against $MK_NEW" <<<"$out"; then
  bad "C2 fixture precondition: the byte check must have passed before the clone moved" "out=$(printf '%s' "$out" | tr '\n' '|')"
elif [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && ! grep -q '^plugin update ' "$CLI_LOG" \
  && grep -q "moved from $MK_NEW to $MK_OLD after the gate" <<<"$out"; then
  ok "C2 a clone that moved after every check is UNKNOWN (exit 2), and 'plugin update' is never called"
else bad "C2 a clone that moved after every check is UNKNOWN (exit 2), and 'plugin update' is never called" \
  "exit was $rc, applied=$([ -e "$ROOT/APPLIED" ] && echo yes || echo no), out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── E — the apply itself can install an UNGATED revision, and that is never a success ──────────
# `plugin update` does not install from the clone as the script last saw it: it refreshes the
# marketplace from its remote first and replaces the clone when the remote has moved. So no check
# placed before the apply bounds what gets installed. The stub stands in for that by moving the clone
# inside `plugin update`, then installing what the clone holds. The post-apply verifier is the
# ALWAYS-GREEN stub throughout, standing in for the real one, which reads only the agent and skill
# definitions and the declared runtime assets — every difference below lies outside those.
#
# apply_moved <label> <expected exit> <expected line> runs with the clone moved, during the apply, to
# the commit the caller just made, and asserts the exit, the named file and that no success is printed.
apply_moved() {
  local label="$1" want_rc="$2" want_line="$3" head
  head="$(move_past_pin "$MK_NEW" "$label")" || exit 9
  out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" STUB_APPLY_MOVE="$head" run 2>&1)"; rc=$?
  if [ "$(git -C "$MK" rev-parse HEAD)" != "$head" ] || [ ! -e "$ROOT/APPLIED" ]; then
    bad "$label fixture precondition: 'plugin update' must have run and moved the clone" "out=$(printf '%s' "$out" | tr '\n' '|')"
  elif [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want_line" <<<"$out" \
    && ! grep -q 'APPLIED — the runtime install now points at the pinned revision' <<<"$out"; then
    ok "$label (exit $want_rc), naming it, and never reports the apply as on the pin"
  else bad "$label (exit $want_rc), naming it, and never reports the apply as on the pin" \
    "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
}

# E1 — the moved-to revision ADDS a hook: a file the gated tree does not hold.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
mkdir -p "$MK/plugins/agentic-engineering/hooks"
echo '{"hooks":{}}' > "$MK/plugins/agentic-engineering/hooks/hooks.json"
apply_moved "E1 an apply that installed an added hooks file is NOT the gated revision" 1 'extra    hooks/hooks.json'
if grep -q 'APPLIED, BUT NOT THE GATED REVISION — 1 installed file(s) differ' <<<"$out" \
  && grep -q 'THE UNGATED REVISION IS INSTALLED' <<<"$out"; then
  ok "E1b says plainly that the ungated revision is installed and counts the differing files"
else bad "E1b says plainly that the ungated revision is installed and counts the differing files" "out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# E2 — the moved-to revision CHANGES the plugin manifest.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
echo '{"name":"agentic-engineering","hooks":"./elsewhere.json"}' > "$MK/plugins/agentic-engineering/.claude-plugin/plugin.json"
apply_moved "E2 an apply that installed a changed plugin manifest is NOT the gated revision" 1 'changed  .claude-plugin/plugin.json'
cleanup

# E3 — the moved-to revision DELETES a file.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
git -C "$MK" rm -q plugins/agentic-engineering/resources/r.md || { printf 'FIXTURE FAILURE: remove r.md\n' >&2; exit 9; }
apply_moved "E3 an apply that installed a tree missing a file is NOT the gated revision" 1 'missing  resources/r.md'
cleanup

# E4 — the clone moved during the apply but this plugin's files are the gated ones (only an unrelated
# plugin changed). Nothing differs, yet the marketplace the runtime now reads was never gated: UNKNOWN.
make_fixture
set_gitlink "$MK_NEW"
git -C "$MK" checkout -q "$MK_NEW"
echo fd3 > "$MK/plugins/frontend-design/s.md"
apply_moved "E4 a clone that moved during the apply is UNKNOWN even when the installed files match" 2 'APPLIED, BUT THE MARKETPLACE MOVED'
cleanup

# E5 — the control: the apply installs exactly the gated revision. The runtime's own `.in_use` marker
# is present (the stub writes it, as every real install has it) and is the one thing allowed beyond
# the tree. The count is asserted so a comparison that examined nothing cannot pass.
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$INSTALLED/.in_use/4242" ] \
  && grep -q "installed tree .......... 3 file(s) identical to plugins/agentic-engineering at $MK_NEW" <<<"$out" \
  && grep -q 'APPLIED — the runtime install now points at the pinned revision' <<<"$out"; then
  ok "E5 exits 0 when the apply installed exactly the gated tree, allowing the runtime's own marker"
else bad "E5 exits 0 when the apply installed exactly the gated tree, allowing the runtime's own marker" \
  "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# E6 — the allowance is the top-level marker names only. The same name any deeper is an extra file.
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" STUB_APPLY_EXTRA=".orphaned_at" run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$INSTALLED/.orphaned_at" ]; then
  ok "E6 allows the runtime's top-level .orphaned_at marker"
else bad "E6 allows the runtime's top-level .orphaned_at marker" "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" STUB_APPLY_EXTRA="skills/.in_use/hook.sh" run 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'extra    skills/.in_use/hook.sh' <<<"$out"; then
  ok "E6b a marker name below the top level is an extra file (exit 1), not an allowance"
else bad "E6b a marker name below the top level is an extra file (exit 1), not an allowance" "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# E7 — `plugin update` exits 0 having installed nothing: every gated file is missing.
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" STUB_APPLY_NOOP=1 run 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q '3 installed file(s) differ' <<<"$out" && grep -qF 'missing  agents/a.md' <<<"$out"; then
  ok "E7 an apply that installed nothing is exit 1, naming the missing files"
else bad "E7 an apply that installed nothing is exit 1, naming the missing files" "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# ── D — the app-bundle fallback finds the CLI in the layout releases install (monorepo#3783) ───
# With no --cli, no $CLAUDE_CLI and no `claude` on PATH, the script falls back to the app bundle.
# It looked only for <version>/claude.app/…, while the installed layout is
# <version>/<build>/claude.app/…, so on the agent host every unattended run ended UNKNOWN before
# doing anything. Each bundle here is a wrapper that records its own tag and then runs the stub CLI,
# so the assertion is WHICH bundle drove the run, not merely that one was found.
make_bundle_fixture() {
  make_fixture
  set_gitlink "$MK_NEW"
  FAKE_HOME="$ROOT/home"
  BUNDLE_BASE="$FAKE_HOME/Library/Application Support/Claude/claude-code"
  BUNDLE_LOG="$ROOT/bundle.log"; : > "$BUNDLE_LOG"
  mkdir -p "$BUNDLE_BASE" "$ROOT/toolbin"
  # A PATH on which `claude` does not resolve. A tool the script needs may share a directory with
  # it, so anything that stops resolving once that directory is dropped is linked in privately.
  PATH_NO_CLAUDE=""
  local dir tool old_ifs="$IFS"
  IFS=:
  for dir in $PATH; do
    [ -x "$dir/claude" ] && continue
    PATH_NO_CLAUDE="${PATH_NO_CLAUDE}${PATH_NO_CLAUDE:+:}${dir}"
  done
  IFS="$old_ifs"
  for tool in bash git jq perl; do
    PATH="$PATH_NO_CLAUDE" command -v "$tool" >/dev/null 2>&1 && continue
    ln -s "$(command -v "$tool")" "$ROOT/toolbin/$tool" \
      || { printf 'FIXTURE FAILURE: link %s\n' "$tool" >&2; exit 9; }
  done
  PATH_NO_CLAUDE="$ROOT/toolbin:$PATH_NO_CLAUDE"
  if PATH="$PATH_NO_CLAUDE" command -v claude >/dev/null 2>&1; then
    printf 'FIXTURE FAILURE: claude still resolves on the stripped PATH\n' >&2; exit 9
  fi
}
# make_bundle <path under the bundle base> <tag>
make_bundle() {
  local dir="$BUNDLE_BASE/$1/claude.app/Contents/MacOS"
  mkdir -p "$dir" || { printf 'FIXTURE FAILURE: mkdir %s\n' "$dir" >&2; exit 9; }
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$2" "$BUNDLE_LOG" "$BIN/claude" \
    > "$dir/claude" || { printf 'FIXTURE FAILURE: write bundle %s\n' "$1" >&2; exit 9; }
  chmod +x "$dir/claude"
}
run_bundled() {
  STUB_MARKETPLACE_TARGET="$MK_NEW" env -u CLAUDE_CLI HOME="$FAKE_HOME" PATH="$PATH_NO_CLAUDE" \
    "$SCRIPT" --repo-root "$CONSUMER" --plugins-root "$PLUGINS" --verify-cmd "$VERIFY" 2>&1
}
bundles_used() { sort -u "$BUNDLE_LOG" | tr '\n' ' '; }

# D1 — the current layout, two versions installed. 2.1.10 is the higher version and sorts BELOW
# 2.1.9 lexically, so this also pins that the choice is by version, not by name.
make_bundle_fixture
make_bundle "2.1.9/0a1b2c3d4e5f" previous-version
make_bundle "2.1.10/6f7e8d9c0b1a" current-version
out="$(run_bundled)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ] && [ "$(bundles_used)" = "current-version " ]; then
  ok "D1 resolves the CLI from <version>/<build>/claude.app, taking the highest version"
else bad "D1 resolves the CLI from <version>/<build>/claude.app, taking the highest version" \
  "exit was $rc, used=[$(bundles_used)], out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D2 — one version holding two builds. Build names carry no order, so the most recently installed
# is taken; the newer build is named to sort LAST, so a lexical pick would take the stale one.
make_bundle_fixture
make_bundle "2.1.10/aaaaaaaaaaaa" stale-build
make_bundle "2.1.10/zzzzzzzzzzzz" newest-build
touch -t 202601010000 "$BUNDLE_BASE/2.1.10/aaaaaaaaaaaa"
touch -t 202602010000 "$BUNDLE_BASE/2.1.10/zzzzzzzzzzzz"
out="$(run_bundled)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ] && [ "$(bundles_used)" = "newest-build " ]; then
  ok "D2 takes the most recently installed build when one version holds several"
else bad "D2 takes the most recently installed build when one version holds several" \
  "exit was $rc, used=[$(bundles_used)], out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D3 — the earlier layout still resolves, so a host that has not updated keeps working.
make_bundle_fixture
make_bundle "2.1.10" direct-layout
out="$(run_bundled)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ] && [ "$(bundles_used)" = "direct-layout " ]; then
  ok "D3 still resolves the CLI from <version>/claude.app"
else bad "D3 still resolves the CLI from <version>/claude.app" \
  "exit was $rc, used=[$(bundles_used)], out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D4 — a layout this script does not know is UNKNOWN, and the message says exactly what was tried
# and what it found, so the next layout change is diagnosable from the message alone.
make_bundle_fixture
make_bundle "2.3.0/channel/0a1b2c3d4e5f" unknown-layout
out="$(run_bundled)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && [ ! -s "$BUNDLE_LOG" ] \
  && grep -q 'cannot resolve an executable claude CLI' <<<"$out" \
  && grep -qF '<version>/claude.app/Contents/MacOS/claude' <<<"$out" \
  && grep -qF '<version>/<build>/claude.app/Contents/MacOS/claude' <<<"$out" \
  && grep -q 'version directories seen: 2.3.0' <<<"$out"; then
  ok "D4 an unrecognised bundle layout exits 2 and names both layouts tried and the versions seen"
else bad "D4 an unrecognised bundle layout exits 2 and names both layouts tried and the versions seen" \
  "exit was $rc, used=[$(bundles_used)], out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D5 — no bundle at all reads the same way, with nothing seen.
make_bundle_fixture
rmdir "$BUNDLE_BASE"
out="$(run_bundled)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'version directories seen: none' <<<"$out"; then
  ok "D5 a host with no app bundle exits 2 and says no version directory was seen"
else bad "D5 a host with no app bundle exits 2 and says no version directory was seen" \
  "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D6 — $HOME is needed only for the two defaults it supplies. With the plugins directory given by
# $CLAUDE_CONFIG_DIR and the CLI named, an unset $HOME must not matter: expanding it anyway aborts
# under `set -u` with exit 1, which this script defines as "not on the pin".
make_fixture
set_gitlink "$MK_NEW"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" env -u HOME -u CLAUDE_CLI CLAUDE_CONFIG_DIR="$ROOT" \
  "$SCRIPT" --repo-root "$CONSUMER" --cli "$BIN/claude" --verify-cmd "$VERIFY" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ]; then
  ok "D6 runs with \$HOME unset when \$CLAUDE_CONFIG_DIR and --cli supply everything it needs"
else bad "D6 runs with \$HOME unset when \$CLAUDE_CONFIG_DIR and --cli supply everything it needs" \
  "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D6b — and where $HOME IS needed, an unset one is UNKNOWN with the reason named, never exit 1.
make_bundle_fixture
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" env -u HOME -u CLAUDE_CLI PATH="$PATH_NO_CLAUDE" \
  "$SCRIPT" --repo-root "$CONSUMER" --plugins-root "$PLUGINS" --verify-cmd "$VERIFY" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -qF "\$HOME is unset so the app bundle cannot be located" <<<"$out"; then
  ok "D6b exits 2, naming the reason, when the app bundle is needed and \$HOME is unset"
else bad "D6b exits 2, naming the reason, when the app bundle is needed and \$HOME is unset" \
  "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" env -u HOME -u CLAUDE_CLI -u CLAUDE_CONFIG_DIR \
  "$SCRIPT" --repo-root "$CONSUMER" --cli "$BIN/claude" --verify-cmd "$VERIFY" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -q 'cannot locate the runtime plugins directory' <<<"$out"; then
  ok "D6c exits 2, naming the reason, when nothing locates the plugins directory"
else bad "D6c exits 2, naming the reason, when nothing locates the plugins directory" \
  "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D7 — a DIRECTORY named `claude` passes an executable test. In the newest build it would be taken
# as the CLI and end the search before the older, valid build was tried.
make_bundle_fixture
make_bundle "2.1.9/0a1b2c3d4e5f" older-valid-build
mkdir -p "$BUNDLE_BASE/2.1.10/6f7e8d9c0b1a/claude.app/Contents/MacOS/claude" \
  || { printf 'FIXTURE FAILURE: mkdir directory-named-claude\n' >&2; exit 9; }
out="$(run_bundled)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$ROOT/APPLIED" ] && [ "$(bundles_used)" = "older-valid-build " ]; then
  ok "D7 skips a directory named claude and resolves the older build that holds a real CLI"
else bad "D7 skips a directory named claude and resolves the older build that holds a real CLI" \
  "exit was $rc, used=[$(bundles_used)], out=$(printf '%s' "$out" | tr '\n' '|')"; fi
cleanup

# D7b — the same for a CLI that was named: a directory is not a CLI.
make_fixture
set_gitlink "$MK_NEW"
mkdir -p "$ROOT/dir-cli/claude"
out="$(STUB_MARKETPLACE_TARGET="$MK_NEW" run --cli "$ROOT/dir-cli/claude" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/APPLIED" ] && grep -qF "'$ROOT/dir-cli/claude' (from --cli or \$CLAUDE_CLI) is not an executable file" <<<"$out"; then
  ok "D7b refuses a named CLI that is a directory (exit 2, named reason)"
else bad "D7b refuses a named CLI that is a directory (exit 2, named reason)" \
  "exit was $rc, out=$(printf '%s' "$out" | tr '\n' '|')"; fi
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
if grep -qi 'restart' <<<"$out"; then
  ok "A8 states that the applying run still executes the previous definition"
else bad "A8 states that the applying run still executes the previous definition" "$(printf '%s' "$out" | tail -3 | tr '\n' '|')"; fi
cleanup

# ── A9–A11 — the CONTRACT carries the rule, not just this script ───────────────────────────────
# A script nobody is told to run is decoration, and the marketplace-latest hazard is the one fact
# that makes the gate look like needless friction if it is not written down. Scoped to the plugin
# contract section, matching the currency suite: these phrases also appear in this file and in the
# script header, so a file-wide match would pass while the operative section said nothing.
CONSTITUTION="$(cd "$HERE/../.." && pwd)/.claude/guides/definition-and-plugin.md"
if [ -r "$CONSTITUTION" ]; then
  section="$(awk '
      /^## Agentic engineering plugin contract$/ { ins = 1; next }
      ins && /^## / { exit }
      ins { print }
    ' "$CONSTITUTION" | tr '\n' ' ')"
  [ -n "$section" ] || bad "A9-A11 could not extract the plugin contract section from the definition-and-plugin guide"

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
  # The gate approves a revision; the contract has to say the apply is bound to it, or the next
  # reader takes the script's own lock for the whole protection and drops the re-read as redundant.
  case "$section" in
    *"never the live \`HEAD\`"*"read again immediately before the apply"*"a clone that moved is \`2\`, never an apply"*)
      ok "A23 the contract binds the byte check and the apply to the gated revision" ;;
    *) bad "A23 the contract binds the byte check and the apply to the gated revision" "a clone moved after the gate is not covered by the contract" ;;
  esac
  # And it must not claim more than that. The apply itself can install an ungated revision; what is
  # guaranteed is a non-zero exit afterwards. A contract that reads as prevention teaches the next
  # reader that a completed apply needs no report.
  case "$section" in
    *"detected afterwards, not prevented"*"whole installed plugin directory"*"the ungated revision is already installed"*)
      ok "A24 the contract states that an ungated install is detected after the apply, not prevented" ;;
    *) bad "A24 the contract states that an ungated install is detected after the apply, not prevented" "the contract overstates what the gate guarantees" ;;
  esac
else
  bad "A9-A11 the definition-and-plugin guide is unreadable at $CONSTITUTION"
fi

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
