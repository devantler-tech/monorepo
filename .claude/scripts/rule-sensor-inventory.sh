#!/usr/bin/env bash
# rule-sensor-inventory.sh — check each guide's rule -> sensor inventory and report its prose-only
# share (monorepo#4284).
#
# WHY THIS EXISTS
#   The guides are mostly prose, and a rule that only an agent reading the prose enforces fails
#   silently. Nothing recorded which test, guard or review enforces which rule, so nobody could say
#   how much of a guide is held only by prose. An inventory beside the guide gives each normative
#   rule a stable id, its anchor in the guide and the controls that enforce it; this script keeps the
#   inventory honest against the guide and the repository, and reports the share held by prose alone.
#
# WHAT A RULE IS
#   A sentence of the guide, outside code fences, that contains "never", "always" or "must" as a word
#   (any case; not as the first part of a hyphenated compound such as "always-on"). The guide is split into units -- a paragraph, a list item, a table row or a block
#   quote -- with its line wrapping joined, and each unit into sentences at ". ", "! " or "? " followed
#   by a capital letter, a backtick, an asterisk, a bracket or an opening parenthesis. A sentence
#   belongs to the section of the nearest heading above it, named by its GitHub anchor.
#
# THE INVENTORY  .claude/guides/<guide>.sensors.tsv
#   Lines starting with "#" are comments; the first other line is the header
#     id  section  quote  kind  control  evidence
#   and every later line is one rule -> control pair, tab-separated:
#     id        a stable rule id, e.g. MP-001. Never renumber or reuse one; rows that share an id
#               are the same rule and must give the same section and quote.
#     section   the GitHub anchor of the heading the rule sits under.
#     quote     a verbatim part of the rule's sentence (line wrapping joined to single spaces). It must
#               occur in exactly one sentence of the guide, that sentence must be a rule, and it must
#               be in the named section.
#     kind      computational (a script, test or CI job) | inferential (a review lane or the local
#               review round) | runtime (a hook, guard or permission rule) | none (prose only) |
#               narrative (the sentence uses one of the words but states no rule: a description,
#               a measurement or an explanation; it is reported apart and never counted as a rule).
#     control   a repository path under .claude/ or .github/ that exists; "-" for none/narrative.
#     evidence  a literal that must occur in the control file, so a row cannot cite an unrelated
#               file; "-" for none/narrative. An id marked none or narrative has no other row.
#   Only a control that itself detects or refuses the violation counts; a contract test that only
#   pins the guide's wording keeps the prose from vanishing but enforces nothing, so it is not one.
#   Every sentence the extraction finds must be covered: it contains the quote of at least one row.
#
# FAILS CLOSED
#   No inventory, an unreadable guide, an extraction that finds no rule, or an inventory with no rows
#   exits 2, never 0: an empty extraction would otherwise satisfy every coverage check.
#
# Usage: rule-sensor-inventory.sh [--root <repo-root>] [--check | --report | --extract <guide.md>]
#   --check    (default) validate every .claude/guides/*.sensors.tsv against its guide
#   --report   validate, then print the prose-only share per guide
#   --extract  print the rules of one guide: <section> TAB <line> TAB <sentence>
# Exit codes: 0 valid · 1 an inventory is wrong (each problem printed on stderr) · 2 cannot check.
set -euo pipefail
export LC_ALL=C

mode=check
guide_arg=""
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check; shift ;;
    --report) mode=report; shift ;;
    --extract)
      [ $# -ge 2 ] || { echo "rule-sensor-inventory: --extract needs a guide path" >&2; exit 2; }
      mode=extract; guide_arg="$2"; shift 2 ;;
    --root)
      [ $# -ge 2 ] || { echo "rule-sensor-inventory: --root needs a value" >&2; exit 2; }
      root="$2"; shift 2 ;;
    -h|--help) sed -n '2,48p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: rule-sensor-inventory.sh [--root <repo-root>] [--check | --report | --extract <guide.md>]" >&2; exit 2 ;;
  esac
done

# Print every sentence of a guide as: <section> TAB <line> TAB <normative 0|1> TAB <sentence>.
sentences() {
  awk '
    function slug(h,   s) {
      s = tolower(h)
      sub(/^#+[ \t]*/, "", s)
      gsub(/[^a-z0-9 _-]/, "", s)
      gsub(/ /, "-", s)
      return s
    }
    function emit(u, line,   rest, sentence, cut) {
      gsub(/[ \t]+/, " ", u)
      sub(/^ /, "", u); sub(/ $/, "", u)
      rest = u
      while (rest != "") {
        if (match(rest, /[.!?][)"*_`'"'"']* +[A-Z`*([]/)) {
          cut = RSTART + RLENGTH - 1
          sentence = substr(rest, 1, cut - 1)
          rest = substr(rest, cut)
        } else {
          sentence = rest
          rest = ""
        }
        sub(/ +$/, "", sentence)
        if (sentence == "") continue
        normative = (tolower(sentence) ~ /(^|[^a-z])(never|always|must)([^a-z-]|$)/) ? 1 : 0
        printf "%s\t%d\t%d\t%s\n", section, line, normative, sentence
      }
    }
    function flush() {
      if (unit != "") emit(unit, unit_line)
      unit = ""
    }
    BEGIN { section = "-"; infence = 0; unit = "" }
    /^[ \t]*(```|~~~)/ { flush(); infence = !infence; next }
    infence { next }
    /^[ \t]*$/ { flush(); next }
    /^#+[ \t]/ { flush(); section = slug($0); next }
    /^[ \t]*\|/ { flush(); unit = $0; unit_line = NR; flush(); next }
    /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ {
      flush(); unit = $0; sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", unit); unit_line = NR; next
    }
    /^[ \t]*>/ {
      line = $0; sub(/^[ \t]*>[ \t]?/, "", line)
      if (unit == "") unit_line = NR
      unit = (unit == "" ? line : unit " " line); next
    }
    { if (unit == "") unit_line = NR; unit = (unit == "" ? $0 : unit " " $0) }
    END { flush() }
  ' "$1"
}

if [ "$mode" = extract ]; then
  [ -r "$guide_arg" ] || { echo "rule-sensor-inventory: cannot read $guide_arg" >&2; exit 2; }
  out="$(sentences "$guide_arg" | awk -F'\t' '$3 == 1 { print $1 "\t" $2 "\t" $4 }')"
  [ -n "$out" ] || { echo "rule-sensor-inventory: no rule found in $guide_arg (empty extraction)" >&2; exit 2; }
  printf '%s\n' "$out"
  exit 0
fi

guides_dir="$root/.claude/guides"
[ -d "$guides_dir" ] || { echo "rule-sensor-inventory: no guides directory at $guides_dir" >&2; exit 2; }

inventories=()
for f in "$guides_dir"/*.sensors.tsv; do
  [ -e "$f" ] && inventories+=("$f")
done
[ "${#inventories[@]}" -gt 0 ] || { echo "rule-sensor-inventory: no .claude/guides/*.sensors.tsv inventory found" >&2; exit 2; }

status=0
report=""
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for inv in "${inventories[@]}"; do
  name="$(basename "$inv" .sensors.tsv)"
  guide="$guides_dir/$name.md"
  rel=".claude/guides/$name.sensors.tsv"
  [ -r "$guide" ] || { echo "rule-sensor-inventory: $rel has no readable guide .claude/guides/$name.md" >&2; status=2; continue; }
  [ -r "$inv" ] || { echo "rule-sensor-inventory: cannot read $rel" >&2; status=2; continue; }

  sentences "$guide" > "$tmp/sentences"
  if ! awk -F'\t' '$3 == 1 { found = 1 } END { exit !found }' "$tmp/sentences"; then
    echo "rule-sensor-inventory: no rule found in .claude/guides/$name.md (empty extraction)" >&2
    status=2; continue
  fi

  # Validate the rows. Each problem is one stderr line; the awk exits 1 when it printed any, 2 when the
  # inventory has no rows at all. Control files are checked by the shell loop below.
  set +e
  awk -F'\t' -v rel="$rel" -v sentfile="$tmp/sentences" -v controls="$tmp/controls" '
    function bad(msg) { printf "rule-sensor-inventory: %s: %s\n", rel, msg > "/dev/stderr"; errors++ }
    BEGIN {
      while ((getline l < sentfile) > 0) {
        n++; split(l, p, "\t"); ssec[n] = p[1]; sline[n] = p[2]; snorm[n] = p[3]
        stext[n] = substr(l, length(p[1]) + length(p[2]) + length(p[3]) + 4)
      }
      kinds["computational"]; kinds["inferential"]; kinds["runtime"]; kinds["none"]; kinds["narrative"]
      printf "" > controls
    }
    /^#/ { next }
    /^[ \t]*$/ { next }
    !header_seen {
      header_seen = 1
      if ($0 != "id\tsection\tquote\tkind\tcontrol\tevidence") bad("header must be: id section quote kind control evidence (tab-separated)")
      next
    }
    {
      rows++
      if (NF != 6) { bad("line " NR ": expected 6 tab-separated fields, found " NF); next }
      id = $1; sec = $2; q = $3; kind = $4; ctl = $5; ev = $6
      gsub(/[ ]+/, " ", q)
      if (id !~ /^[A-Z]+-[0-9]+$/) bad("line " NR ": id \"" id "\" is not of the form ABC-123")
      if (!(kind in kinds)) { bad("line " NR ": " id ": unknown kind \"" kind "\""); next }
      if (id in rquote) {
        if (rquote[id] != q || rsec[id] != sec) bad("line " NR ": " id " repeats with a different section or quote")
      } else {
        rquote[id] = q; rsec[id] = sec; order[++ids] = id
        hits = 0; where = 0
        for (i = 1; i <= n; i++) if (index(stext[i], q) > 0) { hits++; where = i }
        if (hits == 0) bad("line " NR ": " id ": quote not found in the guide (dangling anchor): " q)
        else if (hits > 1) bad("line " NR ": " id ": quote occurs in " hits " sentences; quote more of it: " q)
        else {
          if (snorm[where] != 1) bad("line " NR ": " id ": the quoted sentence (line " sline[where] ") has no never/always/must, so it is not a rule")
          if (ssec[where] != sec) bad("line " NR ": " id ": quote is in section #" ssec[where] ", not #" sec)
          covered[where] = 1
        }
      }
      if (kind == "none" || kind == "narrative") {
        if (ctl != "-" || ev != "-") bad("line " NR ": " id ": kind " kind " takes control and evidence \"-\"")
        if (id in rnone) bad("line " NR ": " id ": repeats a " kind " row")
        rnone[id] = kind
      } else {
        rctl[id] = 1
        if (ctl == "-" || ev == "-") bad("line " NR ": " id ": kind " kind " needs a control path and an evidence literal")
        else if (ctl !~ /^\.(claude|github)\// || ctl ~ /(^|\/)\.\.(\/|$)/) bad("line " NR ": " id ": control must be a path under .claude/ or .github/: " ctl)
        else printf "%d\t%s\t%s\t%s\n", NR, id, ctl, ev > controls
      }
    }
    END {
      if (rows == 0) { printf "rule-sensor-inventory: %s has no rows (empty inventory)\n", rel > "/dev/stderr"; exit 2 }
      for (id in rnone) if (id in rctl) bad(id ": marked " rnone[id] " and also given a control")
      for (i = 1; i <= n; i++)
        if (snorm[i] == 1 && !(i in covered))
          bad("rule at guide line " sline[i] " (#" ssec[i] ") is not in the inventory: " substr(stext[i], 1, 160))
      exit errors > 0 ? 1 : 0
    }
  ' "$inv"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then status=2; continue; fi
  [ "$rc" -eq 0 ] || status=1

  while IFS=$'\t' read -r line id ctl ev; do
    if [ ! -f "$root/$ctl" ]; then
      echo "rule-sensor-inventory: $rel: line $line: $id: control $ctl does not exist" >&2
      [ "$status" -eq 2 ] || status=1
    elif ! awk -v ev="$ev" 'index($0, ev) { found = 1; exit } END { exit !found }' "$root/$ctl"; then
      echo "rule-sensor-inventory: $rel: line $line: $id: control $ctl does not contain its evidence: $ev" >&2
      [ "$status" -eq 2 ] || status=1
    fi
  done < "$tmp/controls"

  report="$report$(awk -F'\t' -v name="$name" '
    /^#/ || !seen++ { next }
    NF == 6 { k[$1] = k[$1] "," $4 }
    END {
      for (id in k) {
        if (k[id] == ",narrative") { narrative++; continue }
        total++
        if (k[id] == ",none") prose++
        else {
          if (k[id] ~ /,computational/) comp++
          if (k[id] ~ /,runtime/) run++
          if (k[id] ~ /,inferential/) inf++
        }
      }
      printf "%s.md\trules=%d\tprose-only=%d (%d%%)\tcomputational=%d\truntime=%d\tinferential=%d\tnarrative=%d\n", \
        name, total, prose, total ? int(prose * 100 / total + 0.5) : 0, comp, run, inf, narrative
    }
  ' "$inv")
"
done

if [ "$status" -eq 0 ] && [ "$mode" = report ]; then
  printf '%s' "$report"
fi
exit "$status"
