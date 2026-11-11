#!/usr/bin/env bash
# pipefail-grep-guard.sh — reject piping a writer into a grep that exits early.
#
# Compatibility entrypoint for the Go implementation in pipefail-grep-guard-go/ (monorepo#2797),
# which decides quoting, comments, heredocs and command boundaries with a real shell parser. The
# command line and the exit codes are unchanged; `--help` prints the usage.
#
# USAGE
#   pipefail-grep-guard.sh [path ...]
#       With no paths, scans every tracked shell script in the repository.
#
# EXIT CODES
#   0  no offending pipeline found
#   1  at least one offending pipeline found (each is printed), or a script the parser cannot
#      read — reported by name, because a file it cannot read is a file it cannot show clean
#   2  usage, or the repository/file could not be read — including a Go program that could not
#      be built, which must never read as a finding or as clean
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)" || exit 2
# shellcheck source=go-helper-build.sh
. "$HERE/go-helper-build.sh" || exit 2
go_helper_run "$HERE/pipefail-grep-guard-go" . "$@"
