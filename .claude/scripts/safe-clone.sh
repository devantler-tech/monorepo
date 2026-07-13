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
#       Clone (options restricted to a safe allowlist), force the canonical
#       credential-free origin URL, wire the gh credential helper, then run
#       the fail-closed guards. An unsafe result is DELETED before returning.
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

# list_remote_urls <dir> — emit "remote.<name>.url|pushurl<TAB><value>" lines
# to stdout for iteration (pushurl leaks through `git remote -v` exactly like
# url). Callers must never print the value field.
list_remote_urls() {
  git -C "$1" config --get-regexp '^remote\..*\.(url|pushurl)$' | sed 's/ /\t/' || true
}

# has_userinfo <url> — 0 when an http(s) URL carries userinfo (anything
# before an @ in the authority part). Scheme match is case-insensitive —
# git accepts HTTPS:// remotes and they display the same way.
has_userinfo() {
  [[ "$1" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/@]*@ ]]
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
  # One pass over key=value lines catches the classes that leak through the
  # guarded diagnostics even when stored remote URLs are clean:
  #   1. a credential in an insteadOf/pushInsteadOf rewrite KEY,
  #   2. a credential in an insteadOf/pushInsteadOf rewrite VALUE,
  #   3. any http.*.extraHeader (its practical use is auth headers, and
  #      `git config --list` would print it) — fail closed on presence.
  # Capture the listing first: with a bare pipe, a failed config read leaves
  # grep matching empty input, so the UNSAFE branch is silently skipped — an
  # unreadable config must fail closed, not open.
  local config_listing
  if ! config_listing="$("${cmd[@]}" config --list 2>/dev/null)"; then
    echo "safe-clone: UNSAFE — could not read the effective git config to verify it is credential-free; fix the config read error and retry" >&2
    return 1
  fi
  if grep -Eiq \
    -e '^url\.https?://[^/@]*@[^=]*\.(insteadof|pushinsteadof)=' \
    -e '^url\.[^=]*\.(insteadof|pushinsteadof)=https?://[^/@]*@' \
    -e '^http\.[^=]*extraheader=' \
    -e '^(http\.([^=]*\.)?proxy|remote\.[^=]*\.proxy|core\.gitproxy)=[a-z][a-z0-9+.-]*://[^/@]*@' \
    <<<"$config_listing"; then
    echo "safe-clone: UNSAFE — the effective git config carries a credential-bearing URL rewrite (insteadOf/pushInsteadOf), an http extraHeader, or a credentialed proxy (details redacted); remove it from host config, use the credential helper instead, and rotate the credential" >&2
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
# userinfo-free form in place. Keys are rewritten wholesale (unset-all, then
# re-add each stripped value) because pushurl is multi-valued and a plain
# `git config <key> <value>` aborts on multiple values.
sanitize() {
  local dir="$1" key value stripped
  local -a keys=() values=()
  while IFS=$'\t' read -r key value; do
    [[ -n "${value:-}" ]] || continue
    if has_userinfo "$value"; then
      keys+=("$key")
    fi
  done < <(list_remote_urls "$dir")

  [[ ${#keys[@]} -gt 0 ]] || return 0

  local uniq_keys
  uniq_keys="$(printf '%s\n' "${keys[@]:-}" | sort -u)"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    values=()
    while IFS= read -r value; do
      if has_userinfo "$value"; then
        # https://user:secret@host/path -> https://host/path (pure bash — the
        # secret never passes through another process's argv). Split at the
        # LAST @: RFC 3986 forbids an unescaped @ in the host, so any earlier
        # @ belongs to the userinfo (e.g. an email-address username) and must
        # be stripped with it.
        stripped="${value%%://*}://${value##*@}"
        values+=("$stripped")
      else
        values+=("$value")
      fi
    done < <(git -C "$dir" config --get-all "$key")

    git -C "$dir" config --unset-all "$key"
    for value in "${values[@]}"; do
      git -C "$dir" config --add "$key" "$value"
    done
    echo "safe-clone: sanitized ${key} (userinfo stripped)" >&2
  done <<<"$uniq_keys"
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
    # Never echo the rejected value — a caller may mistakenly pass the very
    # credential-bearing URL this helper exists to replace.
    [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "invalid repo slug (want owner/repo; value redacted)"
    [[ -e "$dest" ]] && fail "destination already exists: $dest"

    # Pass-through options are ALLOWLISTED: open-ended forwarding lets a
    # caller break the safety invariants (`-c` writes repo config the
    # pre-clone check never saw, `--origin` renames origin so the canonical
    # set-url fails, `--separate-git-dir` moves the git dir outside the
    # delete-on-failure path). Only shape/history options are permitted.
    expect_value=""
    for opt in "$@"; do
      if [[ -n "$expect_value" ]]; then
        expect_value=""
        continue
      fi
      case "$opt" in
        --depth=*|--branch=*|--filter=*|--shallow-since=*|--shallow-exclude=*) ;;
        --depth|--branch|-b|--filter|--shallow-since|--shallow-exclude) expect_value=1 ;;
        --single-branch|--no-single-branch|--sparse|--no-tags|--quiet) ;;
        *)
          fail "clone option not in the safe allowlist (value redacted); allowed: --depth --branch --single-branch --filter --sparse --no-tags --shallow-since --shallow-exclude --quiet"
          ;;
      esac
    done
    [[ -z "$expect_value" ]] || fail "clone option expects a value but none was given"

    # Refuse to clone at all in a credential-leaking environment — nothing
    # is created, so there is nothing to quarantine.
    env_guard || fail "environment guard failed — fix host git config before cloning"

    url="https://github.com/${slug}.git"

    # No env scrubbing here: plain `git clone` never reads GITHUB_TOKEN /
    # GH_TOKEN, and the `gh auth git-credential` helper NEEDS them on hosts
    # where gh is authenticated only via environment token. The guard below
    # verifies nothing token-shaped was persisted regardless.
    git -c credential.helper='!gh auth git-credential' \
      clone --quiet "$@" "$url" "$dest" ||
      fail "clone failed for ${slug}"

    # Belt-and-braces: force the canonical credential-free URL and wire the
    # helper for future authenticated fetch/push from this clone.
    git -C "$dest" remote set-url origin "$url"
    git -C "$dest" config credential.helper '!gh auth git-credential'

    # Re-run BOTH guards against the finished clone: pass-through git-clone
    # options (e.g. `-c url.<...>.insteadOf=...`) can write config into the
    # new repository that the pre-clone environment check never saw.
    if ! guard "$dest" || ! env_guard "$dest"; then
      rm -rf "$dest"
      fail "clone of ${slug} failed the credential guard; clone removed — rotate the credential before retrying"
    fi

    echo "safe-clone: ${slug} -> ${dest} (remotes credential-free)"
    ;;
esac
