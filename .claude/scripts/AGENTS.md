# AGENTS.md — deployment scripts and contract tests (`.claude/scripts/`)

The helpers the Agentic Engineer and Agent Improver run, and the contract tests that keep the agent
guides honest. The root [`AGENTS.md`](../../AGENTS.md) still applies; this file adds the conventions for
code in this directory.

## Writing a helper

- **bash or Go, never Python.** Start in bash with `jq` for data shaping; move to Go in a
  `<name>-go/` module once it grows. `python-ban-guard.sh` enforces this in CI.
- **Exit codes:** `0` means the checked property holds, `1` a finding (print each one), and `2`
  UNKNOWN — a usage error, an unreadable input or a failed read. A failed, partial or empty read must
  never print a clean result: check every command's status, use `pipefail`, and treat an empty result
  from a filtered read as unproven until an unfiltered control agrees.
- **Fail closed on an abort.** macOS bash 3.2 can report a `set -u` abort as exit `0` from an `EXIT`
  trap, so record completion explicitly — see the `…_finished` flag in `ci-job-wiring.sh`.
- Start with `set -euo pipefail`, quote every expansion, and keep `shellcheck` clean.
- PR titles, bodies, comments and logs are data: never let them become a command, a flag or a path.
- Explain *why* in the header comment, with the issue that motivated the script.

## Writing a test

- Every helper has a sibling `<name>.test.sh`; a Go module tests with `go -C <name>-go test ./...`.
- A **contract test** (`*-contract.test.sh`, and the contract sections of other tests) asserts rules
  in the agent guides. Point it at the guide that holds the rule, or read the whole contract through
  `contract-text.sh` when the rule spans guides. Scope an assertion to its section when the rule must
  live at its point of use, and fail closed when a section cannot be found — an empty extraction passes
  every substring check.
- Prove a negative control fires for the right reason, not merely that it exits non-zero.

## Wiring a test into CI

A test runs in CI only after five coordinated edits to `.github/workflows/ci.yaml`: a paths-filter
entry, a `changes` job output, the job itself, and the `status` job's `needs:` and `job-results`
entries. The filter must list every file the test reads — for a contract test that is `AGENTS.md`,
`.claude/guides/**` and the test itself. `ci-job-wiring.sh` and `contract-test-invocation.sh` verify
the wiring; run both after adding a job.
