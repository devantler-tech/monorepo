#!/usr/bin/env bash
#
# safe-clone.sh — the shared safe-clone primitive for autonomous agent work
# (monorepo#2132). Guarantees a temporary clone's HTTP(S) remotes never carry
# URL userinfo (an embedded credential), so a later output-producing
# diagnostic (`git remote -v`, `GIT_TRACE`, `git config --list`) cannot leak
# a token into durable task output. Authenticated fetch/push flows through
# `gh auth git-credential` instead of the remote URL.
#
# Modes:
#   safe-clone.sh <owner>/<repo> <dest-dir> [git-clone-options...]
#       Clone with a scrubbed environment, force the canonical
#       credential-free origin URL, wire the gh credential helper, then run
#       the fail-closed guard. An unsafe result is DELETED before returning.
#   safe-clone.sh --check <dir>
#       Verify an existing clone: exit 1 with a redacted message if any
#       HTTP(S) remote URL carries userinfo, or if the effective git config
#       carries a credential-bearing insteadOf rewrite (which would leak
#       through `git remote -v` even on a clean clone). Never prints a URL
#       value or config key.
#   safe-clone.sh --sanitize <dir>
#       Strip userinfo from every HTTP(S) remote URL in place, then re-run
#       the guard. Never prints a URL value.
#
# Every failure path prints only redacted messages — no remote URL value is
# ever echoed, traced, or embedded in an error.
set -Eeuo pipefail

fail() {
  echo "safe-clone: $*" >&2
  exit 1
}

# list_remote_urls <dir> — emit "remote.<name>.url<TAB><value>" lines to
# stdout for iteration. Callers must never print the value field.
list_remote_urls() {
  git -C "$1" config --get-regexp '^remote\..*\.url$' | sed 's/ /\t/' || true
}

# has_userinfo <url> — 0 when an http(s) URL carries userinfo (anything
# before an @ in the authority part).
has_userinfo() {
  [[ "$1" =~ ^https?://[^/@]*@ ]]
}

# env_guard [dir] — fail closed when the EFFECTIVE git config (system,
# global, and — when dir is given — the clone's local scope) carries a
# `url.<...>.insteadOf` rewrite whose URL embeds credentials. Such a rewrite
# leaks the secret through every `git remote -v`/`get-url` even when the
# stored remote URL is clean (the 2026-07-12 incident mechanism), and the
# secret sits in the config KEY itself, so nothing matched here is ever
# echoed — only a redacted message.
env_guard() {
  local dir="${1:-}"
  local -a cmd=(git)
  [[ -n "$dir" ]] && cmd=(git -C "$dir")
  if "${cmd[@]}" config --list --name-only 2>/dev/null |
    grep -Eiq '^url\.https?://[^/@]*@.*\.insteadof$'; then
    echo "safe-clone: UNSAFE — a git insteadOf URL rewrite in the effective config embeds credentials (key redacted); remove it from host config, use the credential helper instead, and rotate the credential" >&2
    return 1
  fi
  return 0
}

# guard <dir> — fail-closed verification. Exits 1 (redacted) on the first
# credential-bearing remote; prints nothing sensitive.
guard() {
  local dir="$1" key value
  while IFS=$'\t' read -r key value; do
    [[ -n "${value:-}" ]] || continue
    if has_userinfo "$value"; then
      echo "safe-clone: UNSAFE — ${key} carries URL userinfo (value redacted)" >&2
      return 1
    fi
  done < <(list_remote_urls "$dir")
  return 0
}

# sanitize <dir> — rewrite every credential-bearing http(s) remote URL to its
# userinfo-free form in place.
sanitize() {
  local dir="$1" key value name stripped
  while IFS=$'\t' read -r key value; do
    [[ -n "${value:-}" ]] || continue
    if has_userinfo "$value"; then
      name="${key#remote.}"
      name="${name%.url}"
      # https://user:secret@host/path -> https://host/path (pure bash — the
      # secret never passes through another process's argv).
      stripped="${value%%://*}://${value#*@}"
      git -C "$dir" remote set-url "$name" "$stripped"
      echo "safe-clone: sanitized remote ${name} (userinfo stripped)" >&2
    fi
  done < <(list_remote_urls "$dir")
}

case "${1:-}" in
  --check)
    dir="${2:-}"
    [[ $# -eq 2 && ( -d "${dir}/.git" || -f "${dir}/.git" ) ]] ||
      fail "usage: safe-clone.sh --check <clone-dir>"
    env_guard "$dir" || fail "environment guard failed — fix host git config before running remote/trace diagnostics"
    guard "$dir" || fail "guard failed for ${dir} — sanitize or delete the clone and rotate the credential"
    echo "safe-clone: ${dir} remotes are credential-free"
    ;;
  --sanitize)
    dir="${2:-}"
    [[ $# -eq 2 && ( -d "${dir}/.git" || -f "${dir}/.git" ) ]] ||
      fail "usage: safe-clone.sh --sanitize <clone-dir>"
    sanitize "$dir"
    guard "$dir" || fail "guard still failing for ${dir} after sanitize — delete the clone and rotate the credential"
    env_guard "$dir" || fail "stored remotes are clean but the environment guard failed — fix host git config before running remote/trace diagnostics"
    echo "safe-clone: ${dir} remotes are credential-free"
    ;;
  --*)
    fail "unknown mode ${1}"
    ;;
  *)
    [[ $# -ge 2 ]] || fail "usage: safe-clone.sh <owner>/<repo> <dest-dir> [git-clone-options...]"
    slug="$1"
    dest="$2"
    shift 2
    [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "invalid repo slug (want owner/repo): $slug"
    [[ -e "$dest" ]] && fail "destination already exists: $dest"

    # Refuse to clone at all in a credential-leaking environment — nothing
    # is created, so there is nothing to quarantine.
    env_guard || fail "environment guard failed — fix host git config before cloning"

    url="https://github.com/${slug}.git"

    # Scrub inherited token env vars so no tool on this path can embed one
    # into the persisted remote; auth flows through the credential helper.
    env -u GITHUB_TOKEN -u GH_TOKEN \
      git -c credential.helper='!gh auth git-credential' \
      clone --quiet "$@" "$url" "$dest" ||
      fail "clone failed for ${slug}"

    # Belt-and-braces: force the canonical credential-free URL and wire the
    # helper for future authenticated fetch/push from this clone.
    git -C "$dest" remote set-url origin "$url"
    git -C "$dest" config credential.helper '!gh auth git-credential'

    if ! guard "$dest"; then
      rm -rf "$dest"
      fail "clone of ${slug} had a credential-bearing remote; clone removed — rotate the credential before retrying"
    fi

    echo "safe-clone: ${slug} -> ${dest} (remotes credential-free)"
    ;;
esac
