#!/usr/bin/env bash
# plugin-definition-currency.sh — is the definition the runtime LOADED the one the consumer PINNED?
#
# The deployment verifies that chain everywhere except its last link. `agent-role-delivery-contract`
# hashes the desired state against the repository submodule at the gitlink, and monorepo#2736 tracks
# the gitlink against upstream `main` — but the machine-local copy the agent and skill entrypoints are
# actually served from is a runtime-managed install. Its staleness can therefore be unbounded.
# Measured 2026-08-14 on the Claude instance, 7 of 9 definition files differed from the pin and had
# not moved in 20 days, while both existing controls read clean. See monorepo#2847. Cursor instead
# loads a submodule ref, so that lane verifies the loaded revision rather than inventing an install.
#
# READ-ONLY. It never edits, and never needs write access to, the runtime's plugin install. Refresh
# is a runtime control-plane action (the `/plugin` marketplace update), never a cache edit.
#
# Comparison is by GIT BLOB IDENTITY, not by version string: a version can be bumped without the
# loaded files moving, and — the case that actually bit — the definitions can be superseded while the
# installed version string still looks plausible. The loaded surface is every agent and skill file
# plus every provider-neutral requiredRuntimeAsset declared by this consumer.
#
# Usage: plugin-definition-currency.sh [--runtime claude|codex|cursor] [--repo-root DIR]
#                                      [--plugins-root DIR] [--codex-home DIR] [--gitlink SHA]
#                                      [--installed DIR] [--submodule-path PATH]
#                                      [--cursor-ref REF] [--quiet]
#
# Exit 0  every pinned loaded file was CLASSIFIED and MATCHED
#      1  DRIFT — at least one differs, is missing, or is unexpected
#      2  UNKNOWN — could not determine (usage error, unresolvable install, unreachable revision,
#         or a path inside the definition directories this script cannot classify)
#
# Any OTHER non-zero status is an unexpected internal failure under `set -e` and also means UNKNOWN.
# Only 0 and 1 are verdicts; a caller must not read anything else as "current". The lone exception
# is `--help`, which exits 0 without checking anything.
#
# Exit 0 is deliberately narrow: every pinned path under the definition directories was recognised
# AND matched, never "everything I happened to recognise matched".
#
# Exit 2 is deliberately NOT exit 0. "I could not check" and "it is current" are different answers,
# and collapsing them is how a currency check becomes decoration.

set -euo pipefail

REPO_ROOT=""
PLUGINS_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
GITLINK=""
INSTALLED=""
SUBMODULE_PATH="libraries/agent-plugins"
PLUGIN_ID="agentic-engineering@devantler-plugins"
PLUGIN_NAME="agentic-engineering"
RUNTIME="claude"
CURSOR_REF="refs/remotes/origin/main"
QUIET=0

# Named beside every UNKNOWN that a fresh worktree can actually hit. A guard that blocks without
# naming the resolving action is a friction tax the deployment's own hardening rule forbids — and it
# was named on the DRIFT path but not here, which is the path an unattended run reaches first.
RECOVERY="
  To resolve: populate the pinned plugin submodule with .claude/scripts/submodule-init.sh
  libraries/agent-plugins, or make gh available so the pinned tree can be read from the forge.
  UNKNOWN means UNCHECKED: never read it as current, report it, and carry on against the reviewed
  definition at the pinned gitlink — it must never halt a run."

die() { printf 'plugin-definition-currency: %s\n' "$*" >&2; exit 2; }
# `shift 2` on a lone trailing flag returns 1, and under `set -e` that exits the script with 1 — the
# code that means DRIFT. A typo would otherwise produce a silent, evidence-free stale verdict.
need() { [ "$1" -ge 2 ] || die "missing value for $2"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) need $# "$1"; RUNTIME="$2"; shift 2 ;;
    --repo-root) need $# "$1"; REPO_ROOT="$2"; shift 2 ;;
    --plugins-root) need $# "$1"; PLUGINS_ROOT="$2"; shift 2 ;;
    --codex-home) need $# "$1"; CODEX_HOME_DIR="$2"; shift 2 ;;
    --gitlink) need $# "$1"; GITLINK="$2"; shift 2 ;;
    --installed) need $# "$1"; INSTALLED="$2"; shift 2 ;;
    --submodule-path) need $# "$1"; SUBMODULE_PATH="$2"; shift 2 ;;
    --plugin-id) need $# "$1"; PLUGIN_ID="$2"; shift 2 ;;
    --plugin-name) need $# "$1"; PLUGIN_NAME="$2"; shift 2 ;;
    --cursor-ref) need $# "$1"; CURSOR_REF="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) awk '/^set -euo pipefail$/ { exit } { print }' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required"
case "$RUNTIME" in
  claude|codex|cursor) ;;
  *) die "unsupported runtime '$RUNTIME' (expected claude, codex, or cursor)" ;;
esac
if [ "$RUNTIME" != claude ] && [ -n "$INSTALLED" ]; then
  die "runtime '$RUNTIME' does not accept --installed; resolve the copy that lane actually loaded"
fi

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }


# ── the PINNED revision ────────────────────────────────────────────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
[ -d "$REPO_ROOT" ] || die "repo root does not exist: $REPO_ROOT"

if [ -z "$GITLINK" ]; then
  # `ls-tree` prints "160000 commit <sha>\t<path>" for a gitlink. Read the sha field.
  # Guarded: an explicitly-passed --repo-root that is not a git repository would otherwise abort
  # with git's own 128 rather than the documented UNKNOWN, and that is the path every caller uses.
  gitlink_line="$(git -C "$REPO_ROOT" --no-replace-objects ls-tree HEAD "$SUBMODULE_PATH" 2>/dev/null)" \
    || die "cannot read HEAD in $REPO_ROOT — is it a git repository?"
  GITLINK="$(printf '%s\n' "$gitlink_line" | awk '$2=="commit"{print $3}')"
fi
[ -n "$GITLINK" ] || die "no gitlink for '$SUBMODULE_PATH' at HEAD — cannot establish the pinned revision"

# Cursor has no runtime-managed install. Its deployment loader fetches and reads origin/main
# directly from this submodule's object database, so the commit behind that exact ref is the loaded
# definition source. Comparing any Claude or Codex cache here would inspect another lane's copy.
if [ "$RUNTIME" = cursor ]; then
  cursor_sub="$REPO_ROOT/$SUBMODULE_PATH"
  [ -e "$cursor_sub/.git" ] \
    || die "Cursor plugin submodule is not initialised: $cursor_sub"
  # The loader reads its definition with a plain `git show <ref>:<path>`, which resolves THROUGH
  # refs/replace. A revision comparison made with --no-replace-objects therefore cannot establish the
  # bytes it loads: a replacement inside THIS submodule changes the loaded content without changing
  # either compared revision, so an equality check here would report CURRENT over unreviewed bytes.
  # There is no safe verdict available from a revision comparison, so refuse to produce one.
  # Git's replacement namespace is CONFIGURABLE: GIT_REPLACE_REF_BASE moves it off refs/replace/,
  # and git then honours only that namespace. A scan hard-coded to the default therefore returns
  # nothing while a plain `git show` still resolves through the replacement — the enumeration reads
  # clean and the verdict is issued over unreviewed bytes. Follow the namespace git is actually
  # honouring, and keep scanning the default too so neither placement can hide a replacement.
  replace_base="${GIT_REPLACE_REF_BASE:-refs/replace/}"
  replace_base="${replace_base%/}"
  if [ "$replace_base" = "refs/replace" ]; then
    replaced="$(git -C "$cursor_sub" for-each-ref --format='%(refname)' 'refs/replace/*' 2>/dev/null)" \
      || die "cannot enumerate replacement refs in $cursor_sub"
  else
    replaced="$(git -C "$cursor_sub" for-each-ref --format='%(refname)' \
        'refs/replace/*' "$replace_base/*" 2>/dev/null)" \
      || die "cannot enumerate replacement refs in $cursor_sub"
  fi
  if [ -n "$replaced" ]; then
    # UNKNOWN reasons must survive --quiet: say() is suppressed when QUIET=1, and every other
    # UNKNOWN path uses die() → stderr. Keep this multi-line explanation on stderr so a quiet
    # caller still sees why the Cursor lane refused a verdict.
    {
      printf 'pinned revision        : %s\n\n' "$GITLINK"
      printf 'UNKNOWN — the plugin submodule carries replacement ref(s):\n'
      printf '%s\n' "$replaced" | while IFS= read -r r; do
        [ -n "$r" ] && printf '  %s\n' "$r"
      done
      printf '\nThe Cursor loader reads content with a plain '\''git show'\'', which resolves through\n'
      printf 'refs/replace, so comparing revisions cannot establish what it actually loads. Remove the\n'
      printf 'replacement ref, or verify the loaded blobs against the pinned tree directly.\n'
    } >&2
    exit 2
  fi
  loaded_revision="$(git -C "$cursor_sub" --no-replace-objects rev-parse "$CURSOR_REF^{commit}" 2>/dev/null)" \
    || die "cannot resolve Cursor loaded revision '$CURSOR_REF' in $cursor_sub"
  say "pinned revision        : $GITLINK"
  say "Cursor loaded revision : $loaded_revision ($CURSOR_REF)"
  say ""
  if [ "$loaded_revision" = "$GITLINK" ]; then
    say "CURRENT — Cursor loaded revision matches the pinned gitlink."
    exit 0
  fi
  say "DRIFT — Cursor loaded revision $loaded_revision differs from pinned gitlink $GITLINK."
  say ""
  say "Do not inspect another runtime's cache. Follow the reviewed definition at $GITLINK and"
  say "report that the Cursor loader's $CURSOR_REF must be reconciled with the consumer pin."
  exit 1
fi

# ── the INSTALLED copy ─────────────────────────────────────────────────────────
if [ -z "$INSTALLED" ] && [ "$RUNTIME" = codex ]; then
  config="$CODEX_HOME_DIR/config.toml"
  [ -r "$config" ] || die "cannot read the Codex runtime config: $config"
  # Enablement is an EFFECTIVE-STATE question, so ask the runtime first: `codex plugin list --json`
  # reports what Codex actually loaded. CODEX_HOME is passed explicitly so this reads the home under
  # test and never the host's. A VALID response is authoritative in both directions — an empty
  # `installed` array means the runtime did not load this plugin (its plugin feature can be off while
  # the table and cache remain present), so it must NOT fall through to the static table, which would
  # report CURRENT for a definition the runtime never executed.
  enabled=""
  if command -v codex >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    codex_json="$(CODEX_HOME="$CODEX_HOME_DIR" codex plugin list --json 2>/dev/null)" || codex_json=""
    if [ -n "$codex_json" ]; then
      enabled="$(printf '%s' "$codex_json" | jq -r --arg id "$PLUGIN_ID" '
          if (.installed | type) != "array" then "unparseable"
          else [ .installed[] | select(.pluginId == $id) | .enabled ]
               | if length == 0 then "false" elif any(. == true) then "true" else "false" end
          end
        ' 2>/dev/null)" || enabled=""
      if [ "$enabled" = unparseable ]; then enabled=""; fi
    fi
  fi
  # Fallback: parse the serialized config. Preserve BOTH layers of effective state: a stale enabled
  # plugin table may remain when `[features] plugins = false`, and reporting CURRENT in that state
  # would describe bytes the runtime cannot load. Deliberately tolerate whitespace and trailing TOML
  # comments around both table headers and values; an exact-line match would report UNKNOWN for a
  # correctly-configured lane.
  if [ -z "$enabled" ]; then
    enabled="$(awk -v target="[plugins.\"$PLUGIN_ID\"]" '
        { line = $0
          sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
          # TOML permits every key segment to be quoted. Normalise only the two literal feature-gate
          # segments before matching their complete assignment; values and unrelated keys remain
          # untouched. sprintf keeps a literal single quote out of this shell single-quoted program.
          sq = sprintf("%c", 39)
          gsub(/"features"/, "features", line); gsub(/"plugins"/, "plugins", line)
          gsub(sq "features" sq, "features", line); gsub(sq "plugins" sq, "plugins", line)
          # Match the header by PREFIX and then require the remainder to be a comment, rather than
          # interpolating the plugin id into a regex: the id is a quoted TOML key that may contain
          # regex metacharacters, and escaping it here is what would actually break. An unrelated
          # trailing token is not a comment, so it still fails to match.
          header = line
          if (substr(header, 1, length(target)) == target) {
            rest = substr(header, length(target) + 1)
            if (rest == "" || rest ~ /^[[:space:]]*#/) header = target
          }
          features = "[features]"
          if (substr(header, 1, length(features)) == features) {
            rest = substr(header, length(features) + 1)
            if (rest == "" || rest ~ /^[[:space:]]*#/) header = features
          }
          # TOML dotted keys at the document root are equivalent to a [features] table. Once a table
          # header has appeared, the same spelling is relative to that table and must not be mistaken
          # for the global gate.
          if (!saw_table && line ~ /^features[[:space:]]*[.][[:space:]]*plugins[[:space:]]*=[[:space:]]*false([[:space:]]*#.*)?$/) {
            feature_disabled = 1
          }
          if (line ~ /^\[/) {
            saw_table = 1
            in_plugin = (header == target)
            in_features = (header == features)
            next
          }
          if (in_features && line ~ /^plugins[[:space:]]*=[[:space:]]*false([[:space:]]*#.*)?$/) {
            feature_disabled = 1
          }
          if (in_plugin && line ~ /^enabled[[:space:]]*=[[:space:]]*true([[:space:]]*#.*)?$/) {
            plugin_enabled = 1
          }
        }
        END {
          if (feature_disabled) print "false"
          else if (plugin_enabled) print "true"
        }
      ' "$config")"
  fi
  [ "$enabled" = true ] \
    || die "plugin '$PLUGIN_ID' is not enabled in the Codex runtime config: $config"

  marketplace="${PLUGIN_ID#*@}"
  [ "$marketplace" != "$PLUGIN_ID" ] \
    || die "Codex plugin id '$PLUGIN_ID' has no marketplace suffix"
  codex_cache="$CODEX_HOME_DIR/plugins/cache/$marketplace/$PLUGIN_NAME"
  [ -d "$codex_cache" ] \
    || die "Codex plugin cache does not exist: $codex_cache"
  paths="$(find "$codex_cache" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)" \
    || die "could not enumerate the Codex plugin cache: $codex_cache"
  [ -n "$paths" ] || die "Codex plugin '$PLUGIN_ID' has no cached copy in $codex_cache"
  count="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] \
    || die "Codex plugin '$PLUGIN_ID' has $count cached copies; cannot identify the loaded one"
  INSTALLED="$paths"
elif [ -z "$INSTALLED" ]; then
  # Claude resolves from the runtime's own record rather than guessing from a directory listing: its
  # cache can hold several versions at once and only this registry says which one is served.
  # jq is checked HERE, not at the top: it is needed only to read the registry, and every caller
  # that passes --installed (the whole test suite) would otherwise fail for an unrelated reason.
  command -v jq >/dev/null 2>&1 || die "jq is required to read the runtime plugin registry"
  registry="$PLUGINS_ROOT/installed_plugins.json"
  [ -r "$registry" ] || die "cannot read the runtime plugin registry: $registry"
  # No `mapfile`: the host runs bash 3.2, where it does not exist and the array would stay empty.
  # Guarded: malformed JSON, or entries of an unexpected shape, make jq exit 5.
  paths="$(jq -r --arg id "$PLUGIN_ID" '.plugins[$id][]?.installPath // empty' "$registry" 2>/dev/null)" \
    || die "could not parse the runtime plugin registry: $registry"
  [ -n "$paths" ] || die "plugin '$PLUGIN_ID' is not installed in $registry"
  count="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || die "plugin '$PLUGIN_ID' has $count install paths; pass --installed to pick one"
  INSTALLED="$paths"
fi
[ -d "$INSTALLED" ] || die "installed plugin path does not exist: $INSTALLED"

# Agents and skills are implicit runtime entrypoints. Other executable dependencies are explicit in
# the provider-neutral desired state; omitting them is how a stale classifier continued to report
# CURRENT even though the surveyor actually executed it. Read the consumer declaration that the
# delivery-contract test separately proves byte-identical to the pinned plugin resource.
command -v jq >/dev/null 2>&1 || die "jq is required to read the provider-neutral runtime assets"
desired_state="$REPO_ROOT/.claude/plugin-consumption/agentic-engineering.desired-state.json"
[ -r "$desired_state" ] || die "cannot read the provider-neutral desired state: $desired_state"
runtime_assets="$(jq -er '
    .spec.source.requiredRuntimeAssets
    | select(type == "array" and length > 0)
    | select(all(.[];
        type == "object"
        and (.path | type == "string" and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$"))
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and .executable == true
      ))
    | select((map(.path) | unique | length) == length)
    | .[].path
  ' "$desired_state" 2>/dev/null)" \
  || die "provider-neutral requiredRuntimeAssets are missing or malformed in $desired_state"
[ -n "$runtime_assets" ] \
  || die "provider-neutral requiredRuntimeAssets are empty in $desired_state"

# ── the pinned revision's definition tree ──────────────────────────────────────
# Prefer the local submodule object database (offline, no API budget). Fall back to the forge only
# when the pinned commit is not present locally, which is the normal state of a fresh worktree.
#
# Both branches normalise to "<sha>TAB<path>". The local branch splits the leading
# "<mode> <type> <sha>" on spaces but the PATH on the tab only — reading the whole line with awk's
# default whitespace splitting truncates any path containing a space, and a truncated path is then
# dropped by the selector and invisible on BOTH sides of the comparison.
prefix="plugins/$PLUGIN_NAME/"
tree=""
sub="$REPO_ROOT/$SUBMODULE_PATH"
# --no-replace-objects on BOTH reads. `cat-file` and `ls-tree` resolve THROUGH refs/replace, so a
# replacement for the gitlink rewrites the REVIEWED side of the comparison itself: an install
# carrying the replacement bytes then matches and reports CURRENT. The Cursor branch above refuses a
# verdict for the same hazard, but it exits before this point, so every other runtime reaches these
# reads unprotected. Same rule the pin resolution above already follows.
if [ -e "$sub" ] && git -C "$sub" --no-replace-objects cat-file -e "$GITLINK^{commit}" 2>/dev/null; then
  tree="$(git -C "$sub" --no-replace-objects ls-tree -r "$GITLINK" -- "$prefix" 2>/dev/null \
            | awk -F'\t' '{split($1, m, " "); if (m[2]=="blob") print m[3] "\t" m[1] "\t" $2}')" \
    || die "could not read the pinned tree $GITLINK from $sub${RECOVERY}"
else
  command -v gh >/dev/null 2>&1 || die "commit $GITLINK is not in the local object database and gh is unavailable${RECOVERY}"
  command -v jq >/dev/null 2>&1 || die "jq is required to read the pinned tree from the forge"
  # Derived, never hard-coded: --submodule-path is a flag, so a fixed slug here would silently query
  # a different repository than the one whose gitlink was just read.
  url="$(git -C "$REPO_ROOT" config -f .gitmodules --get "submodule.$SUBMODULE_PATH.url" 2>/dev/null)" \
    || die "no .gitmodules url for '$SUBMODULE_PATH' — cannot resolve $GITLINK from the forge${RECOVERY}"
  slug="${url##*:}"; slug="${slug##*/github.com/}"; slug="${slug%.git}"
  case "$slug" in */*) ;; *) die "could not derive an owner/repo slug from '$url'" ;; esac
  raw="$(gh api "repos/$slug/git/trees/$GITLINK?recursive=1" 2>/dev/null)" \
    || die "could not read the pinned tree $GITLINK from $slug${RECOVERY}"
  # A truncated response is a PARTIAL tree. Comparing it as if complete is a fail-open: a pinned file
  # the API omitted is also absent from `reviewed`, so an install missing it reports CURRENT.
  case "$(printf '%s' "$raw" | jq -r '.truncated // false')" in
    true) die "the forge returned a TRUNCATED tree for $GITLINK — cannot verify completeness${RECOVERY}" ;;
  esac
  tree="$(printf '%s' "$raw" | jq -r '.tree[] | select(.type=="blob") | [.sha,.mode,.path] | @tsv')" \
    || die "could not parse the pinned tree $GITLINK from $slug"
fi
[ -n "$tree" ] || die "pinned revision $GITLINK yielded no tree entries"

# README, the manifest and resources/ stay outside the surface: a version bump that moves no loaded
# behaviour still does not fire. Runtime assets are an explicit allow-list, never all of scripts/.
reviewed="$(printf '%s
' "$tree" \
  | awk -F'	' -v p="$prefix" -v runtime="$runtime_assets" '
      BEGIN {
        count = split(runtime, paths, "\n")
        for (i = 1; i <= count; i++) required[paths[i]] = 1
      }
      substr($3,1,1)=="\"" { print "QUOTED" ORS; next }
      index($3,p)==1 {
        rel = substr($3, length(p) + 1)
        if (rel ~ /^agents\// || rel ~ /^skills\// || required[rel]) print $1 "	" $2 "	" rel
      }' \
  | sort -k3,3)"
quoted_record="$(printf '%s\n' "$reviewed" | awk '$0=="QUOTED"{print 1; exit}')"
[ -z "$quoted_record" ] \
  || die "the pinned tree contains a path git had to quote (tab, newline or backslash) — cannot verify it${RECOVERY}"
[ -n "$reviewed" ] || die "pinned revision $GITLINK contains no definition files under $prefix"

# A declaration absent from the pinned tree must be UNKNOWN, not silently omitted from both sides.
# Executability is part of the provider-neutral contract, so a non-executable pin is invalid even if
# the install happens to carry the same non-executable mode.
while IFS= read -r runtime_asset; do
  [ -n "$runtime_asset" ] || continue
  runtime_record="$(printf '%s\n' "$reviewed" | awk -F'	' -v r="$runtime_asset" '$3==r{print $2 "\t" $3}')"
  [ -n "$runtime_record" ] \
    || die "required runtime asset '$runtime_asset' is absent from pinned revision $GITLINK"
  runtime_mode="${runtime_record%%$'\t'*}"
  [ "$runtime_mode" = 100755 ] \
    || die "required runtime asset '$runtime_asset' is not executable at pinned revision $GITLINK"
done <<< "$runtime_assets"

# ── compare ────────────────────────────────────────────────────────────────────
drift=0
checked=0
say "pinned revision : $GITLINK"
say "installed copy  : $INSTALLED"
say ""

installed_path_has_symlink() {
  local rel_path="$1" probe="$INSTALLED" segment
  while [ -n "$rel_path" ]; do
    case "$rel_path" in
      */*) segment="${rel_path%%/*}"; rel_path="${rel_path#*/}" ;;
      *) segment="$rel_path"; rel_path="" ;;
    esac
    probe="$probe/$segment"
    [ ! -L "$probe" ] || return 0
  done
  return 1
}

while IFS=$'\t' read -r rev_sha rev_mode rel; do
  [ -n "$rel" ] || continue
  checked=$((checked + 1))
  if installed_path_has_symlink "$rel"; then
    # -f, `git hash-object` and -x all FOLLOW a symlink, so a definition replaced by a link to an
    # identical file passed every test. Check every component as well as the leaf: a scripts/
    # symlink can redirect a required asset while the final file itself is regular.
    say "DRIFT    $rel  installed through a SYMLINK where the pinned revision has a regular path"
    drift=$((drift + 1))
    continue
  fi
  if [ ! -f "$INSTALLED/$rel" ]; then
    say "MISSING  $rel  (reviewed $rev_sha — the installed copy does not have this definition at all)"
    drift=$((drift + 1))
    continue
  fi
  # --no-filters: without it a clean filter (e.g. `* text eol=lf`) normalises the content first, so
  # a CRLF copy and its LF twin hash identically and the "byte identity" promised above is not what
  # was measured.
  own_sha="$(git hash-object --no-filters "$INSTALLED/$rel" 2>/dev/null)" \
    || die "cannot hash the installed definition $INSTALLED/$rel"
  # Mode matters as much as content: a skill helper that loses its executable bit still hashes
  # identically, so a content-only comparison reports `match` while a SKILL.md invoking it fails.
  case "$rev_mode" in
    100644) want_exec=no ;;
    100755) want_exec=yes ;;
    *) die "pinned $rel has unsupported mode $rev_mode — cannot verify it" ;;
  esac
  if [ -x "$INSTALLED/$rel" ]; then have_exec=yes; else have_exec=no; fi
  if [ "$own_sha" = "$rev_sha" ] && [ "$want_exec" = "$have_exec" ]; then
    say "match    $rel"
  elif [ "$own_sha" = "$rev_sha" ]; then
    say "DRIFT    $rel  content matches but mode differs (reviewed executable=$want_exec, installed executable=$have_exec)"
    drift=$((drift + 1))
  else
    say "DRIFT    $rel  installed=${own_sha:0:12} reviewed=${rev_sha:0:12}"
    drift=$((drift + 1))
  fi
done <<< "$reviewed"

# A definition present in the install but absent from the pin is drift too: it is a role the runtime
# can still dispatch and the reviewed revision no longer describes.
#
# Enumerated WITHOUT a filename filter and classified by the shared rule above, so an installed path
# in an unexpected shape is reported rather than skipped. The listing goes through a temp file because
# a process substitution's exit status is not observable — an unreadable subtree would otherwise look
# like an empty one, hiding an extra definition and allowing CURRENT.
# Guarded: an unwritable or exhausted TMPDIR makes mktemp exit 1 under `set -e`, and 1 is the DRIFT
# verdict — an infrastructure failure would have been read as a finding about the install.
inst_list="$(mktemp)" || die "could not create a temporary file (is TMPDIR writable?)"
trap 'rm -f "$inst_list"' EXIT
: > "$inst_list"
for d in agents skills; do
  [ -d "$INSTALLED/$d" ] || continue
  # One quoted invocation per directory: joining them into a string and splitting it would break any
  # installPath containing whitespace, turning a MATCHING install into UNKNOWN.
  find "$INSTALLED/$d" \( -type f -o -type l \) >> "$inst_list" \
    || die "could not enumerate the installed definitions under $INSTALLED/$d${RECOVERY}"
done

while IFS= read -r path; do
  [ -n "$path" ] || continue
  rel="${path#"$INSTALLED"/}"
  if ! printf '%s\n' "$reviewed" | awk -F'\t' -v r="$rel" '$3==r{found=1} END{exit !found}'; then
    say "EXTRA    $rel  (installed but absent from the pinned revision)"
    drift=$((drift + 1))
  fi
done < <(sort "$inst_list")

say ""
if [ "$drift" -eq 0 ]; then
  say "CURRENT — $checked pinned loaded file(s) match the installed copy."
  # Scope the verdict explicitly. This compares the INSTALLED copy on disk; the running process
  # executes whatever it loaded at startup, and an install only becomes live on the next dispatch.
  # Left unstated, a CURRENT produced after a concurrent refresh reads as "this run is current" —
  # the fail-open direction, since the run would then follow a superseded definition believing it
  # had verified otherwise.
  say "Scope: this describes the INSTALLED copy on disk, not the definition this process booted."
  say "An install becomes live on the next dispatch, so a run whose install changed mid-flight is"
  say "still executing what it booted; only a LATER run's check establishes that the pin is live."
  exit 0
fi

# `drift` counts EXTRA files too, which are not among the `checked` pinned definitions — so phrasing
# this as "N of M differ" can print a count larger than its own denominator.
say "DRIFT — $drift finding(s) across $checked pinned loaded file(s)."
say ""
say "What to do, in this order:"
say "  1. Do NOT proceed as if the loaded definition were current. Read the reviewed definition at"
say "     $GITLINK and follow that, then report the drift in the run report."
# The control plane is per-runtime. `codex plugin` exposes add/list/marketplace/remove and no update
# command, so prescribing Claude's /plugin flow to a Codex operator names an action that cannot
# repair this lane — and could refresh the sibling Claude installation instead.
say "  2. Refresh through the runtime's own control plane. Never edit the plugin cache: it is"
say "     read-only evidence."
if [ "$RUNTIME" = codex ]; then
  say "     For Codex: \`codex plugin add\` installs the marketplace snapshot's LATEST, so the only"
  say "     safe sequence is one that never advances the snapshot. Check the snapshot's revision"
  say "     against $GITLINK first — and the revision ALONE does not establish the content, because"
  say "     a dirty file, a clean/smudge filter, or a replacement object each leave the revision"
  say "     reading correct while the bytes on disk differ. In the snapshot checkout <snapshot>,"
  say "     all four must pass before any install:"
  say "         git -C <snapshot> --no-replace-objects rev-parse HEAD   # must equal $GITLINK"
  say "         git -C <snapshot> status --porcelain                    # must print NOTHING"
  say "         and EVERY definition file must equal its pinned blob — one file proves only itself,"
  say "         so a filter or index flag altering any OTHER file survives a single-file check:"
  say "           git -C <snapshot> --no-replace-objects ls-tree -r --name-only HEAD -- <prefix>"
  say "           # for each: --no-replace-objects rev-parse HEAD:<f> must equal"
  say "           # hash-object --no-filters -- <f>"
  say "         and EVERY executable requiredRuntimeAsset must retain its pinned mode:"
  say "           git -C <snapshot> --no-replace-objects ls-tree HEAD -- <runtime-asset>"
  say "           # must start '100755 blob'; test -x <snapshot>/<runtime-asset> must succeed"
  say "       * snapshot AT the pin and all of the above clean -> reinstall WITHOUT upgrading."
  say "         \`codex plugin remove\` deletes the plugin from local config AND cache, so an 'add'"
  say "         that then fails — bad snapshot, disk error, interrupted run — leaves this lane with"
  say "         no definition to load. Do NOT rely on 'add' overwriting an existing install; the"
  say "         CLI does not document that. There is no safe local rollback of the cache: it is"
  say "         read-only evidence, so restoring a copy of it by hand is itself a violation, and a"
  say "         cache copy would not restore the deleted config entry in any case. Save the config"
  say "         entry first so registration can be rebuilt through the control plane:"
  say "           # copy the [plugins.\"$PLUGIN_ID\"] table out of $CODEX_HOME_DIR/config.toml"
  say "           codex plugin remove $PLUGIN_ID && codex plugin add $PLUGIN_ID"
  say "         If the 'add' fails, restore that config entry and re-run 'add'. If it still fails,"
  say "         this lane can neither load a definition nor repair itself: surface it to the"
  say "         maintainer on a declared channel as an outage, rather than editing the cache."
  say "       * snapshot NOT at the pin -> do NOT reinstall, and do NOT run"
  say "         'codex plugin marketplace upgrade': it moves the snapshot to the upstream tip, so a"
  say "         following 'add' installs a revision nobody here has reviewed. Reconcile the consumer"
  say "         gitlink with the revision you intend to run through the reviewed rollout instead."
else
  say "     For Claude: the /plugin marketplace update flow."
fi
say "  3. If the refresh needs an interactive session this run cannot open, surface it to the"
say "     maintainer on a declared channel rather than leaving it unreported."
exit 1
