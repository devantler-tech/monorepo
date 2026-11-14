#!/usr/bin/env bash
# shellcheck disable=SC2016 # The backticks in the fixtures are literal Markdown, not expansions.
# kagent-lane-runs.test.sh — RED/GREEN coverage for kagent-lane-runs.sh (monorepo#4870) against a
# stub kubectl that serves recorded rclone folder indexes. No cluster, no kubeconfig, no network.
#
# The reader's job is to fail closed. So beside every clean read, each way the store can be unseen
# is asserted to be UNKNOWN (exit 2) and never an empty list or a verdict: a refused, unreachable,
# unavailable or missing reader; a page that is not an rclone index, or one cut off; a runs/ folder
# holding something that is not a run. The liveness verdicts are pinned against the cadence row,
# and the real AGENTS.md row is read too, so editing it into a shape the reader cannot read fails
# here rather than in a scheduled run.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
reader="$root/.claude/scripts/kagent-lane-runs.sh"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "kagent-lane-runs.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT

fails=0
asserts=0
note_fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
pass() { echo "ok   $1"; }

# The stub answers `kubectl --context prod-ctx --request-timeout=<t> get --raw <reader proxy>/<path>`
# from $FAKE/<path with / as _> (the root is `_root`), prints $FAKE/<key>.err and fails when that
# exists, prints $FAKE/<key>.partial and then fails when that exists, and fails as NotFound
# otherwise. Every request is logged. Anything outside the reader's proxy path is refused with 64,
# so a read anywhere else fails the case that made it. Every kubeconfig read is logged to
# $FAKE/config.calls, and every --context the stub is given, before it is checked, to
# $FAKE/contexts.
cat >"$tmp/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "$1" != --context ] || printf 'context=[%s]\n' "$2" >>"$FAKE/contexts"
if [ "$1" = config ]; then
  echo config >>"$FAKE/config.calls"
  [ ! -e "$FAKE/config.fail" ] || exit 1
  printf '{"contexts":[{"name":"admin-ctx","context":{"cluster":"prod","user":"admin"}},{"name":"prod-ctx","context":{"cluster":"prod","user":"oidc-user"}}]}'
  exit 0
fi
[ "$1" = --context ] && [ "$2" = prod-ctx ] || { echo "stub: unexpected context" >&2; exit 64; }
case "$3" in --request-timeout=*) ;; *) echo "stub: no request timeout" >&2; exit 64 ;; esac
[ "$4" = get ] && [ "$5" = --raw ] && [ $# -eq 6 ] || { echo "stub: not a raw get" >&2; exit 64; }
prefix=/api/v1/namespaces/agentic-engineer/services/lane-store-reader/proxy/
case "$6" in "$prefix"*) path=${6#"$prefix"} ;; *) echo "stub: outside the reader proxy" >&2; exit 64 ;; esac
printf '%s %s\n' "$3" "$path" >>"$FAKE/requests"
key=${path//\//_}
[ -n "$key" ] || key=_root
if [ -e "$FAKE/$key.err" ]; then cat "$FAKE/$key.err" >&2; exit 1; fi
if [ -e "$FAKE/$key.partial" ]; then cat "$FAKE/$key.partial"; echo 'error: unexpected EOF' >&2; exit 1; fi
[ -e "$FAKE/$key" ] || { echo 'Error from server (NotFound): the server could not find the requested resource' >&2; exit 1; }
cat "$FAKE/$key"
EOF
chmod +x "$tmp/kubectl"

# index <entry>... — an rclone `serve http` folder index, reduced from the v1.75.2 template
# (lib/http/templates/index.html) to the markup around its entries: the breadcrumb, sort and
# "Go up" links, then one row per entry with its name link and, for a folder, its zip link. An
# entry ending in / is a folder.
index() {
  local e
  printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<title>listing</title>\n</head>\n<body>\n'
  printf '\t\t<header>\n\t\t\t<h1>\n\t\t\t\t<a href="/">/</a>\n\t\t\t\t<a class="zip-root" href="?download=zip" title="Download root as .zip">\n\t\t\t\t</a>\n\t\t\t</h1>\n\t\t</header>\n'
  printf '\t\t<main>\n\t\t\t<div class="listing">\n\t\t\t\t<table aria-describedby="summary">\n\t\t\t\t\t<thead>\n\t\t\t\t\t<tr>\n\t\t\t\t\t\t<th></th>\n'
  printf '\t\t\t\t\t\t<th>\n\t\t\t\t\t\t\t<a href="?sort=name&order=asc" class="order">Name</a>\n\t\t\t\t\t\t</th>\n\t\t\t\t\t</tr>\n\t\t\t\t\t</thead>\n\t\t\t\t\t<tbody>\n'
  printf '\t\t\t\t\t<tr>\n\t\t\t\t\t\t<td></td>\n\t\t\t\t\t\t<td>\n\t\t\t\t\t\t\t<a href="..">\n\t\t\t\t\t\t\t\t<span class="goup">Go up</span>\n\t\t\t\t\t\t\t</a>\n\t\t\t\t\t\t</td>\n\t\t\t\t\t</tr>\n'
  for e in "$@"; do
    printf '\t\t\t\t\t<tr class="file">\n\t\t\t\t\t\t<td>\n\t\t\t\t\t\t</td>\n\t\t\t\t\t\t<td>\n'
    printf '\t\t\t\t\t\t\t<span class="name"><a href="%s">%s</a></span>\n' "$e" "$e"
    case "$e" in
      */) printf '\t\t\t\t\t\t\t<a class="zip" href="%s?download=zip" title="Download folder as .zip">\n\t\t\t\t\t\t\t</a>\n' "$e"
          printf '\t\t\t\t\t\t</td>\n\t\t\t\t\t\t<td data-order="-1">&mdash;</td>\n' ;;
      *) printf '\t\t\t\t\t\t</td>\n\t\t\t\t\t\t<td data-order="42"><size>42</size></td>\n' ;;
    esac
    printf '\t\t\t\t\t\t<td class="hideable"><time datetime="2026-11-09T03:00:00Z">2026-11-09T03:00:00Z</time></td>\n\t\t\t\t\t\t<td class="hideable"></td>\n\t\t\t\t\t</tr>\n'
  done
  printf '\t\t\t\t\t</tbody>\n\t\t\t\t</table>\n\t\t\t</div>\n\t\t</main>\n\t</body>\n</html>\n'
}

# index_v176 <entry>... — the same index from rclone's v1.76.0 template, which the lane store has
# served since devantler-tech/platform#6220, reduced from a live page to the markup around its
# entries: the breadcrumb, the summary with the page's own folder and file counts, the "Go up" row,
# one row per entry (its class carries `dir` and data attributes, its name link starts with ./),
# and the placeholder row the page's filter shows.
index_v176() {
  local e dirs=0 files=0
  for e in "$@"; do case "$e" in */) dirs=$((dirs + 1)) ;; *) files=$((files + 1)) ;; esac; done
  printf '<!DOCTYPE html>\n<html>\n\t<head>\n\t\t<title>/</title>\n\t\t<meta charset="utf-8">\n\t</head>\n\t<body>\n'
  printf '\t\t<header>\n\t\t\t<div class="eyebrow">Folder path</div>\n\t\t\t<h1><a href="../">/</a>\n'
  printf '\t\t\t\t<a class="zip-root" href="?download=zip" title="Download root as .zip"><svg><use href="#zip-folder"></use></svg></a>\n\t\t\t</h1>\n\t\t</header>\n'
  printf '\t\t<main>\n\t\t\t<div class="card">\n\t\t\t\t<div id="summary">\n'
  printf '\t\t\t\t\t<button class="toggle" id="toggle-dirs" aria-pressed="true"><svg><use href="#folder"></use></svg><b id="ndirs">%s</b> directories</button>\n' "$dirs"
  printf '\t\t\t\t\t<button class="toggle" id="toggle-files" aria-pressed="true"><svg><use href="#file"></use></svg><b id="nfiles">%s</b> files</button>\n' "$files"
  printf '\t\t\t\t</div>\n\t\t\t\t<div class="listing">\n\t\t\t\t\t<table aria-describedby="summary">\n\t\t\t\t\t\t<thead>\n\t\t\t\t\t\t\t<tr>\n'
  printf '\t\t\t\t\t\t\t\t<th class="name" data-key="name"><a href="" onclick="return sortBy(this.parentNode)">Name</a></th>\n'
  printf '\t\t\t\t\t\t\t</tr>\n\t\t\t\t\t\t</thead>\n\t\t\t\t\t\t<tbody>\n'
  printf '\t\t\t\t\t\t\t<tr class="goup"><td class="name"><a href="..">Go up</a></td><td class="size">&mdash;</td><td class="time">&mdash;</td></tr>\n'
  for e in "$@"; do
    case "$e" in
      */) printf '\t\t\t\t\t\t\t<tr class="file dir" data-size="0" data-time="2026-11-09 03:00:00 +0000 UTC">\n'
          printf '\t\t\t\t\t\t\t\t<td class="name"><svg><use href="#folder"></use></svg><a href="./%s">%s</a>\n' "$e" "$e"
          printf '\t\t\t\t\t\t\t\t\t<a class="zip" href="./%s?download=zip" title="Download folder as .zip"><svg><use href="#zip-folder"></use></svg></a>\n' "$e"
          printf '\t\t\t\t\t\t\t\t</td>\n\t\t\t\t\t\t\t\t<td class="size">&mdash;</td>\n' ;;
      *) printf '\t\t\t\t\t\t\t<tr class="file" data-size="42" data-time="2026-11-09 03:00:00 +0000 UTC">\n'
         printf '\t\t\t\t\t\t\t\t<td class="name"><svg><use href="#file"></use></svg><a href="./%s">%s</a>\n' "$e" "$e"
         printf '\t\t\t\t\t\t\t\t</td>\n\t\t\t\t\t\t\t\t<td class="size"><size>42</size></td>\n' ;;
    esac
    printf '\t\t\t\t\t\t\t\t<td class="time"><time datetime="2026-11-09 03:00:00 +0000 UTC">2026-11-09 03:00:00 &#43;0000 UTC</time></td>\n\t\t\t\t\t\t\t</tr>\n'
  done
  printf '\t\t\t\t\t\t\t<tr class="empty" hidden=""><td colspan="3"></td></tr>\n'
  printf '\t\t\t\t\t\t</tbody>\n\t\t\t\t\t</table>\n\t\t\t\t</div>\n\t\t\t</div>\n\t\t</main>\n\t</body>\n</html>\n'
}
# The template a scenario's indexes come from: index (v1.75.2) or index_v176.
index_fn=index

cadence_md() { # <engineer cell> [improver cell] — an AGENTS.md with the lane's cadence row
  printf '# AGENTS.md\n\n### Cadence & focus\n\n| Lane | Agentic Engineer | Agent Improver |\n|---|---|---|\n'
  printf '| **Claude** — `claude/*`, hourly at `:50` | Every hour at `:20` and `:50` | 00:00, 06:00, 12:00, 18:00 |\n'
  printf '| **kagent** — `kagent/*` | %s | %s |\n\n### Durable memory\n' "$1" "${2:-—}"
}

# scenario <name> — a store with two finished runs, the newer one complete, and a scheduled row.
scenario() {
  FAKE="$tmp/$1"
  export FAKE
  mkdir -p "$FAKE"
  "$index_fn" memory/ runs/ >"$FAKE/_root"
  "$index_fn" 2026-11-09/ 2026-11-08/ >"$FAKE/runs_"
  "$index_fn" report.md transcript.jsonl >"$FAKE/runs_2026-11-09_"
  "$index_fn" report.md transcript.jsonl >"$FAKE/runs_2026-11-08_"
  printf '# Run report 2026-11-09\nshipped one PR\n' >"$FAKE/runs_2026-11-09_report.md"
  printf '{"type":"user","message":"run"}\n{"type":"assistant","message":"done"}\n' >"$FAKE/runs_2026-11-09_transcript.jsonl"
  printf '# Run report 2026-11-08\n' >"$FAKE/runs_2026-11-08_report.md"
  cadence_md '1 run/day' >"$FAKE/AGENTS.md"
}

run() { # <reader arguments...>
  set +e
  KUBECTL="$tmp/kubectl" bash "$reader" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  out=$(cat "$tmp/out")
  err=$(cat "$tmp/err")
}
live() { run liveness --agents-md "$FAKE/AGENTS.md" --today "${TODAY:-2026-11-10}" "$@"; }

# expect <label> <rc> <stdout fragment or -> [stderr fragment]
expect() {
  asserts=$((asserts + 1))
  if [ "$rc" -ne "$2" ]; then
    note_fail "$1: rc=$rc, want $2 (stdout: $out) (stderr: $err)"
    return 0
  fi
  if [ "$3" != - ] && ! grep -qF -- "$3" <<<"$out"; then
    note_fail "$1: stdout lacks '$3' (stdout: $out) (stderr: $err)"
    return 0
  fi
  if [ -n "${4:-}" ] && ! grep -qF -- "$4" <<<"$err"; then
    note_fail "$1: stderr lacks '$4' (stderr: $err)"
    return 0
  fi
  pass "$1"
}
# no_stdout <label> — a fail-closed path must print nothing a caller could read as a list or a file.
no_stdout() {
  asserts=$((asserts + 1))
  if [ -n "$out" ]; then note_fail "$1: stdout should be empty, got: $out"; else pass "$1"; fi
}
absent() { # <label> <text> — neither stream carries the text
  asserts=$((asserts + 1))
  if grep -qF -- "$2" <<<"$out$err"; then note_fail "$1: output carries '$2'"; else pass "$1"; fi
}
requests() { cat "$FAKE/requests" 2>/dev/null || true; }

echo "kagent-lane-runs.sh"
bash -n "$reader" || note_fail "the reader does not parse"
[ -x "$reader" ] || note_fail "the reader is not executable"

# ── usage ─────────────────────────────────────────────────────────────────────
scenario usage
run; expect "no mode is a usage error" 2 - "a mode is required"
run fetch; expect "an unknown mode is a usage error" 2 - "unknown mode"
run list --bogus 's3cr3t-value'; expect "an unknown argument is a usage error" 2 - "unknown argument"
absent "an unknown argument's value is never echoed" 's3cr3t-value'
run report; expect "report needs a run date" 2 - "needs a run date"
run report ../../etc; expect "a run date that is not a date is refused" 2 - "real date"
run transcript 2026-02-30; expect "an impossible calendar date is refused" 2 - "real date"
run liveness --max-age-days 0; expect "a zero age window is refused" 2 - "at least 1"
run liveness --today 2026-13-01; expect "an impossible --today is refused" 2 - "real date"
asserts=$((asserts + 1))
if [ -z "$(requests)" ]; then pass "no usage error reads the store"; else note_fail "a usage error read the store: $(requests)"; fi
run --help; expect "help prints the usage" 0 "USAGE"

# ── list ──────────────────────────────────────────────────────────────────────
scenario list-healthy
run list
expect "list prints the run dates" 0 "2026-11-08"
asserts=$((asserts + 1))
if [ "$out" = "$(printf '2026-11-08\n2026-11-09')" ]; then pass "list prints every run once, oldest first"
else note_fail "list order or content: $out"; fi
asserts=$((asserts + 1))
if [ "$(requests)" = "$(printf -- '--request-timeout=30s \n--request-timeout=30s runs/')" ]; then
  pass "list reads only the root and runs/ indexes, each with a request timeout"
else note_fail "list requests: $(requests)"; fi

scenario list-context
run list --context prod-ctx
expect "an explicit --context is used as given" 0 "2026-11-09"
touch "$FAKE/config.fail"
run list --context prod-ctx
expect "an explicit --context does not need the kubeconfig" 0 "2026-11-09"
run list
expect "no resolvable prod context is UNKNOWN" 2 - "(store-no-prod-context)"
no_stdout "no resolvable prod context prints no list"

scenario list-no-runs-folder
index memory/ >"$FAKE/_root"
run list
expect "a root index without runs/ is an empty list" 0 - "holds no run yet"
no_stdout "a root index without runs/ prints no date"

scenario list-empty-runs
index >"$FAKE/runs_"
run list
expect "an empty runs/ index is an empty list" 0 - "holds no run yet"
no_stdout "an empty runs/ index prints no date"

# Each kubectl failure class, with an address in kubectl's text that must never be printed.
for case_ in \
  "refused|Error from server (Forbidden): services \"lane-store-reader\" is forbidden: User \"oidc:x\" cannot get resource \"services/proxy\" at https://192.0.2.10:6443" \
  "unreachable|Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout" \
  "unavailable|Error from server (ServiceUnavailable): no endpoints available for service \"lane-store-reader\" (192.0.2.10)" \
  "not-found|Error from server (NotFound): the server could not find the requested resource (192.0.2.10)" \
  "unauthenticated|error: You must be logged in to the server (Unauthorized) 192.0.2.10" \
  "failed|error: something new happened at 192.0.2.10"; do
  class=${case_%%|*}
  scenario "list-root-$class"
  printf '%s\n' "${case_#*|}" >"$FAKE/_root.err"
  run list
  expect "a $class root read is UNKNOWN" 2 - "(store-$class)"
  no_stdout "a $class root read prints no list"
  absent "a $class root read never prints kubectl's address" "192.0.2.10"
done

scenario list-runs-refused
printf 'Error from server (Forbidden): forbidden\n' >"$FAKE/runs_.err"
run list
expect "a refused runs/ read is UNKNOWN" 2 - "(runs-refused)"
no_stdout "a refused runs/ read prints no list"

scenario list-missing-service
rm "$FAKE/_root"
run list
expect "a missing reader service is UNKNOWN, not an empty store" 2 - "(store-not-found)"

scenario list-not-an-index
printf '{"kind":"Status","status":"Failure","message":"no"}\n' >"$FAKE/_root"
run list
expect "a root page that is not an rclone index is UNKNOWN" 2 - "(store-index-unparseable)"
no_stdout "a root page that is not an index prints no list"

scenario list-truncated
index 2026-11-09/ 2026-11-08/ | awk '/<\/tbody>/ { exit } { print }' >"$FAKE/runs_"
run list
expect "a runs/ index cut off before its end is UNKNOWN" 2 - "(runs-index-unparseable)"
no_stdout "a cut-off runs/ index prints no partial list"

scenario list-row-without-link
index 2026-11-09/ | awk '{ print } /<tbody>/ { print "<tr class=\"file\"><td>renamed markup</td></tr>" }' >"$FAKE/runs_"
run list
expect "an entry row without a name link is UNKNOWN" 2 - "(runs-index-unparseable)"

scenario list-stray-entry
index 2026-11-09/ notes.txt latest/ >"$FAKE/runs_"
run list
expect "runs/ holding entries that are not run folders is UNKNOWN" 2 - "(runs-index-holds-2-entries-that-are-not-run-folders)"
no_stdout "a runs/ index with stray entries prints no partial list"

scenario list-bad-date
index 2026-11-09/ 2026-02-30/ >"$FAKE/runs_"
run list
expect "an impossible run date folder is UNKNOWN" 2 - "not-run-folders"

scenario list-date-as-file
index 2026-11-09 >"$FAKE/runs_"
run list
expect "a run date that is a file, not a folder, is UNKNOWN" 2 - "not-run-folders"

# ── rclone v1.76 index ────────────────────────────────────────────────────────
# devantler-tech/platform#6220 moved the store to rclone v1.76.0, whose template renamed both markers
# the earlier reader counted. Both counts fell to 0, matched, and the live store, holding three runs,
# read as holding none.
index_fn=index_v176
scenario v176-list
run list
expect "a v1.76 index lists the run dates" 0 "2026-11-08"
asserts=$((asserts + 1))
if [ "$out" = "$(printf '2026-11-08\n2026-11-09')" ]; then pass "a v1.76 index lists every run once, without its ./ prefix"
else note_fail "v1.76 list order or content: $out"; fi

scenario v176-files
run report 2026-11-09
expect "a v1.76 run folder serves its report" 0 "shipped one PR"
live
expect "a v1.76 store reads as PRODUCING" 0 "KAGENT-LANE=PRODUCING newest=2026-11-09 age_days=1 transcript=present"

scenario v176-empty-runs
index_v176 >"$FAKE/runs_"
run list
expect "an empty v1.76 runs/ index is an empty list" 0 - "holds no run yet"
no_stdout "an empty v1.76 runs/ index prints no date"

# Without the page's own counts, only the row rule can catch rows the reader does not know.
scenario v176-unknown-rows
index_v176 2026-11-09/ 2026-11-08/ | grep -v -e 'id="ndirs"' -e 'id="nfiles"' |
  sed 's/<tr class="file dir"/<tr class="entry dir"/' >"$FAKE/runs_"
run list
expect "entry rows of a shape the reader does not know are UNKNOWN, never an empty list" 2 - "(runs-index-unparseable)"
no_stdout "rows of an unknown shape print no list"

scenario v176-unknown-root-rows
index_v176 memory/ runs/ | grep -v -e 'id="ndirs"' -e 'id="nfiles"' |
  sed 's/<tr class="file dir"/<tr class="entry dir"/' >"$FAKE/_root"
run list
expect "a root index of rows the reader does not know is UNKNOWN, never a store with no run" 2 - "(store-index-unparseable)"
absent "a root index of unknown rows is not reported as empty" "holds no run yet"

scenario v176-count-mismatch
index_v176 2026-11-09/ 2026-11-08/ | sed 's|<b id="ndirs">2</b>|<b id="ndirs">3</b>|' >"$FAKE/runs_"
run list
expect "entries that do not add up to the page's own counts are UNKNOWN" 2 - "(runs-index-unparseable)"

scenario v176-one-count
index_v176 2026-11-09/ 2026-11-08/ | grep -v 'id="nfiles"' >"$FAKE/runs_"
run list
expect "a page stating only one of its two counts is UNKNOWN" 2 - "(runs-index-unparseable)"

scenario v176-second-link
index_v176 2026-11-09/ | sed 's|<a href="./2026-11-09/">2026-11-09/</a>|&<a href="./2026-11-07/">x</a>|' >"$FAKE/runs_"
run list
expect "an entry row with two name links is UNKNOWN" 2 - "(runs-index-unparseable)"

scenario v176-goup-elsewhere
index_v176 2026-11-09/ | sed 's|<a href="..">Go up</a>|<a href="../memory/">Go up</a>|' >"$FAKE/runs_"
run list
expect "a Go up row that links anywhere but .. is UNKNOWN" 2 - "(runs-index-unparseable)"
index_fn=index

# ── report / transcript ───────────────────────────────────────────────────────
scenario files
run report 2026-11-09
expect "report prints the run's report" 0 "shipped one PR"
asserts=$((asserts + 1))
if [ "$out" = "$(cat "$FAKE/runs_2026-11-09_report.md")" ]; then pass "report prints the file unchanged"
else note_fail "report content changed: $out"; fi
run transcript 2026-11-09
expect "transcript prints the run's transcript" 0 '{"type":"assistant","message":"done"}'
asserts=$((asserts + 1))
if grep -qxF -- '--request-timeout=300s runs/2026-11-09/transcript.jsonl' <<<"$(requests)"; then
  pass "a transcript read has the longer timeout a large file needs"
else note_fail "transcript request: $(requests)"; fi
run report 2026-11-07
expect "a missing run's report is UNKNOWN" 2 - "runs/2026-11-07/report.md could not be read (not-found)"
no_stdout "a missing run's report prints nothing"
printf '{"type":"user","message":"cut' >"$FAKE/runs_2026-11-08_transcript.jsonl.partial"
run transcript 2026-11-08
expect "a transcript read that fails part way is UNKNOWN" 2 - "(failed)"
no_stdout "a transcript read that fails part way prints none of it"

# ── cadence ───────────────────────────────────────────────────────────────────
scenario cadence
run cadence --agents-md "$FAKE/AGENTS.md"
expect "a scheduled row reads as one entry a day" 0 "engineer=1/day state=scheduled improver=none"
cadence_md '1 run/day; suspended' >"$FAKE/AGENTS.md"
run cadence --agents-md "$FAKE/AGENTS.md"
expect "a suspended row reads as one entry a day, suspended" 0 "engineer=1/day state=suspended improver=none"
run cadence
expect "the real AGENTS.md row is readable" 0 "engineer=1/day state="
asserts=$((asserts + 1))
if grep -qxE 'engineer=1/day state=(scheduled|suspended) improver=none' <<<"$out"; then
  pass "the real AGENTS.md row reads as one entry a day and no improver entry"
else note_fail "the real AGENTS.md row reads as: $out"; fi
for bad in '2 runs/day' 'Every hour at `:10`' '1 run/day; paused' '1 capped run/day; suspended' ''; do
  cadence_md "$bad" >"$FAKE/AGENTS.md"
  run cadence --agents-md "$FAKE/AGENTS.md"
  expect "an engineer cell of '$bad' is unreadable" 2 - "missing or unreadable"
  no_stdout "an unreadable engineer cell '$bad' prints no cadence"
done
cadence_md '1 run/day' '06:00' >"$FAKE/AGENTS.md"
run cadence --agents-md "$FAKE/AGENTS.md"
expect "an improver schedule on the kagent row is unreadable" 2 - "missing or unreadable"
# Two rows, both inside the cadence section and none outside it, so only the one-row rule can
# refuse this fixture. The insert lands just before the next heading, which ends the section.
cadence_md '1 run/day' >"$FAKE/AGENTS.md"
awk '/^### Durable memory/ { print "| **kagent** — `kagent/*` | 1 run/day; suspended | — |" } { print }' \
  "$FAKE/AGENTS.md" >"$FAKE/AGENTS.twice.md"
asserts=$((asserts + 1))
twice_shape=$(awk '/^### Durable memory/ { after = 1 }
  index($0, "**kagent**") { if (after) outside++; else inside++ }
  END { printf "inside=%d outside=%d", inside, outside }' "$FAKE/AGENTS.twice.md")
if [ "$twice_shape" = "inside=2 outside=0" ]; then
  pass "the two-row fixture holds two kagent rows, both in the cadence section"
else note_fail "the two-row fixture's kagent rows: $twice_shape, want inside=2 outside=0"; fi
run cadence --agents-md "$FAKE/AGENTS.twice.md"
expect "two kagent rows in the cadence section are unreadable" 2 - "missing or unreadable"
printf '### Cadence & focus\n\n| Lane | A | B |\n|---|---|---|\n\n### Elsewhere\n| **kagent** — `kagent/*` | 1 run/day | — |\n' \
  >"$FAKE/AGENTS.md"
run cadence --agents-md "$FAKE/AGENTS.md"
expect "a kagent row outside the cadence section is not the lane's schedule" 2 - "missing or unreadable"
run cadence --agents-md "$FAKE/no-such-AGENTS.md"
expect "a missing AGENTS.md is unreadable" 2 - "missing or unreadable"

# ── liveness ──────────────────────────────────────────────────────────────────
scenario live-healthy
live
expect "a recent complete run is PRODUCING" 0 "KAGENT-LANE=PRODUCING newest=2026-11-09 age_days=1 transcript=present"
TODAY=2026-11-11 live
expect "a run two UTC dates old is still PRODUCING by default" 0 "KAGENT-LANE=PRODUCING newest=2026-11-09 age_days=2"
TODAY=2026-11-12 live
expect "a run three UTC dates old is overdue" 1 "KAGENT-LANE=NOT-PRODUCING reason=overdue newest=2026-11-09 age_days=3 max_age_days=2"
TODAY=2026-11-11 live --max-age-days 1
expect "--max-age-days narrows the window" 1 "reason=overdue newest=2026-11-09 age_days=2 max_age_days=1"
TODAY=2026-11-09 live
expect "a run from today is PRODUCING" 0 "KAGENT-LANE=PRODUCING newest=2026-11-09 age_days=0"
TODAY=2026-11-08 live
expect "a newest run dated after today is UNKNOWN, not PRODUCING" 2 "KAGENT-LANE=UNKNOWN reason=newest-run-is-dated-after-today"

scenario live-newest-judged
# The newest run, not the first listed, decides: the older run is complete, the newer one is not.
index report.md >"$FAKE/runs_2026-11-08_"
index transcript.jsonl >"$FAKE/runs_2026-11-09_"
live
expect "a newest run without a report is NOT-PRODUCING even beside a complete older one" 1 \
  "KAGENT-LANE=NOT-PRODUCING reason=no-report newest=2026-11-09 age_days=1 transcript=present"

scenario live-empty-report
: >"$FAKE/runs_2026-11-09_report.md"
live
expect "an empty report is NOT-PRODUCING" 1 "KAGENT-LANE=NOT-PRODUCING reason=empty-report newest=2026-11-09"

scenario live-no-transcript
index report.md >"$FAKE/runs_2026-11-09_"
live
expect "a run without its transcript is producing and says the transcript is missing" 0 \
  "KAGENT-LANE=PRODUCING newest=2026-11-09 age_days=1 transcript=missing"

scenario live-suspended
cadence_md '1 run/day; suspended' >"$FAKE/AGENTS.md"
live
expect "a suspended lane is NOT-SCHEDULED, not producing and not down" 2 "KAGENT-LANE=NOT-SCHEDULED"
asserts=$((asserts + 1))
if [ -z "$(requests)" ]; then pass "a suspended lane's liveness does not read the store"
else note_fail "a suspended lane's liveness read the store: $(requests)"; fi

scenario live-no-row
printf '### Cadence & focus\n' >"$FAKE/AGENTS.md"
live
expect "a missing cadence row is UNKNOWN" 2 "KAGENT-LANE=UNKNOWN reason=cadence-row-missing-or-unreadable"

scenario live-unreachable
printf 'Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout\n' >"$FAKE/_root.err"
live
expect "an unreachable store is UNKNOWN, never NOT-PRODUCING" 2 "KAGENT-LANE=UNKNOWN reason=store-unreachable"
absent "an unreachable store's verdict never prints kubectl's address" "192.0.2.10"

scenario live-unparseable
printf '<html><body>sign in</body></html>\n' >"$FAKE/_root"
live
expect "an unparseable store index is UNKNOWN" 2 "KAGENT-LANE=UNKNOWN reason=store-index-unparseable"

scenario live-no-run-yet
index memory/ >"$FAKE/_root"
live
expect "a store with no run yet is UNKNOWN, neither producing nor down" 2 "KAGENT-LANE=UNKNOWN reason=no-run-yet"

scenario live-run-folder-refused
printf 'Error from server (Forbidden): forbidden\n' >"$FAKE/runs_2026-11-09_.err"
live
expect "an unreadable run folder is UNKNOWN" 2 "KAGENT-LANE=UNKNOWN reason=run-folder-refused newest=2026-11-09"

scenario live-run-folder-unparseable
printf 'not an index\n' >"$FAKE/runs_2026-11-09_"
live
expect "an unparseable run folder index is UNKNOWN" 2 "KAGENT-LANE=UNKNOWN reason=run-folder-index-unparseable"

scenario live-report-refused
printf 'Error from server (ServiceUnavailable): no endpoints available\n' >"$FAKE/runs_2026-11-09_report.md.err"
live
expect "a listed report that cannot be read is UNKNOWN, not NOT-PRODUCING" 2 "KAGENT-LANE=UNKNOWN reason=report-unavailable newest=2026-11-09"

# ── a failed context resolution stays failed (#4909) ──────────────────────────
# Every mode stops at its first failed read, so no mode reads twice after one. This lifts the
# reader's own classify, resolve_context and store_get out of the script and reads twice. kubectl
# given an empty --context uses the kubeconfig's current context, which can be the admin one, so
# the second read must fail the same way and must never reach kubectl.
lift_reads() { # <output script> — the lifted functions and a loop that reads the root twice
  {
    printf '%s\n' 'set -Eeuo pipefail' "trap 'exit 2' ERR"
    printf 'KUBECTL=%q\nscript_dir=%q\ntmp=%q\n' "$tmp/kubectl" "$root/.claude/scripts" "$FAKE"
    printf '%s\n' 'PROXY="/api/v1/namespaces/agentic-engineer/services/lane-store-reader/proxy"' \
      'context=""' 'contexted=0' 'read_class=""'
    for fn in classify resolve_context store_get; do
      awk -v fn="$fn" '$0 == fn "() {" { on = 1 } on { print } on && $0 == "}" { exit }' "$reader"
    done
    printf '%s\n' 'for attempt in 1 2; do' \
      '  if store_get "" "$tmp/read.$attempt" 30s; then echo "read $attempt ok"; else echo "read $attempt failed: $read_class"; fi' \
      'done'
  } >"$1"
}
scenario resolve-twice
lift_reads "$FAKE/lifted.sh"
asserts=$((asserts + 1))
lifted=$(grep -cE '^(classify|resolve_context|store_get)\(\) \{$' "$FAKE/lifted.sh" || true)
if [ "$lifted" = 3 ]; then pass "the three read functions are lifted from the reader"
else note_fail "lifted $lifted of the 3 read functions; the cases below prove nothing"; fi
touch "$FAKE/config.fail"
set +e; out=$(bash "$FAKE/lifted.sh" 2>"$tmp/err"); rc=$?; set -e; err=$(cat "$tmp/err")
expect "a failed context resolution fails the first read" 0 "read 1 failed: no-prod-context"
expect "a read after a failed context resolution is still refused, as no prod context" 0 "read 2 failed: no-prod-context"
asserts=$((asserts + 1))
if [ ! -e "$FAKE/contexts" ]; then pass "no read after a failed context resolution reaches kubectl"
else note_fail "kubectl was called after a failed context resolution: $(cat "$FAKE/contexts")"; fi
rm -f "$FAKE/config.fail" "$FAKE/config.calls" "$FAKE/contexts"
set +e; out=$(bash "$FAKE/lifted.sh" 2>"$tmp/err"); rc=$?; set -e; err=$(cat "$tmp/err")
expect "a resolved context serves the first read" 0 "read 1 ok"
expect "a resolved context serves a later read" 0 "read 2 ok"
asserts=$((asserts + 1))
if [ "$(cat "$FAKE/config.calls")" = config ] && [ "$(sort -u "$FAKE/contexts")" = "context=[prod-ctx]" ]; then
  pass "the context is resolved once and every read uses the scoped one"
else note_fail "kubeconfig reads: $(wc -l <"$FAKE/config.calls"); contexts: $(sort -u "$FAKE/contexts" | tr '\n' ' ')"; fi

scenario live-no-clock
mkdir -p "$FAKE/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE/bin/date"
chmod +x "$FAKE/bin/date"
set +e
PATH="$FAKE/bin:$PATH" KUBECTL="$tmp/kubectl" bash "$reader" liveness --agents-md "$FAKE/AGENTS.md" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
expect "a clock that cannot be read is UNKNOWN, never a verdict" 2 "KAGENT-LANE=UNKNOWN reason=no-usable-clock"

if [ "$fails" -ne 0 ]; then
  echo "kagent-lane-runs.test.sh: $fails of $asserts assertions FAILED" >&2
  exit 1
fi
echo "kagent-lane-runs.test.sh: all $asserts assertions passed"
completed=1
