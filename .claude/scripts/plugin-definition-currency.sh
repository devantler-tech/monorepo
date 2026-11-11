#!/usr/bin/env bash
# plugin-definition-currency.sh — is the definition the runtime LOADED the one the consumer PINNED?
#
# Compatibility entrypoint for the Go implementation in plugin-definition-currency-go/
# (monorepo#2851). The flags, the output lines and the exit codes are unchanged; `--help` prints the
# full usage and design note (plugin-definition-currency-go/help.txt). Every repository read still
# goes through `git` on PATH, the forge read through `gh` and the Codex state query through `codex`.
#
# READ-ONLY. It never edits, and never needs write access to, the runtime's plugin install.
#
# Exit 0  CURRENT — every pinned loaded file matched, or the declared git-ref source matched
#      1  DRIFT — at least one differs, is missing, or is unexpected
#      2  UNKNOWN — could not determine, including a Go program that could not be built
# Only 0 and 1 are verdicts; a caller must not read anything else as "current".
#
# The bounded build and the private executable belong to go_helper_run, which reports an
# incomplete run as UNKNOWN; this entrypoint itself keeps no temporary file and installs no trap.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)" || exit 2
# shellcheck source=go-helper-build.sh
. "$HERE/go-helper-build.sh" || exit 2
go_helper_run "$HERE/plugin-definition-currency-go" . "$@"
