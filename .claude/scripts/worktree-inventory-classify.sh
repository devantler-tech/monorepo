#!/usr/bin/env bash
# worktree-inventory-classify.sh — give every inventory entry, and every worktree, exactly
# one class that says what a removal would cost, from the rows the two inventory scripts
# already printed (monorepo#3072).
#
# WHY: worktree-submodule-inventory.sh says what each entry holds, and
# worktree-inventory-merged-check.sh says, commit by commit, whether GitHub or the default
# branch already has it. Neither says the one thing the issue asks for: which entries need
# no rescue, which hold work in flight, and which need a person. Reading that off by hand
# means joining three row kinds per commit, and one missed row turns "unsettled" into
# "settled". This makes the join once, and refuses input it cannot join completely.
#
# It reads two texts and nothing else: no repository, no network, no write.
#
# Usage:
#   worktree-submodule-inventory.sh <root> --tips > inventory.tsv
#   worktree-inventory-merged-check.sh <root> [--content-reference <checkout>] \
#     < inventory.tsv > check.tsv        # its exit 2 on an UNKNOWN row still leaves full output
#   worktree-inventory-classify.sh --inventory inventory.tsv < check.tsv
#
#   --inventory <file>   the inventory's complete output, taken with --tips
#   stdin                the merged check's complete output for that same inventory
#
# Output, tab-separated, one row per inventory entry, in the inventory's order:
#   CLASS <worktree> <submodule> <class> inventory=<class> settled=<n> unsettled=<n> in_flight=<n>
# then one row per worktree:
#   WORKTREE <worktree> <class> entries=<n>
# and a closing `CLASSIFIED ...` line with the totals.
#
# Classes, for an entry:
#   nothing-held       the inventory read it as `clean`: a removal destroys nothing
#   merged-in-content  it holds commits only, and every one is settled: a pull request with
#                      that head was merged into the default branch (`merged`), or one that
#                      merged there has the commit in its history (`merged-ancestor`), GitHub holds
#                      the same ref (`pushed-ref`), or the content check found it `reached`,
#                      `no-change` or `same-change`. Needs no rescue
#   tool-output        nothing but files the repository's own ignore rules cover. A removal
#                      deletes them; they are rarely authored
#   work-in-flight     at least one of its commits is the head of an open pull request
#   needs-a-person     anything else: changed, untracked or nested files (never judged
#                      here), a stash, or a commit no evidence settles. `unsettled=` counts
#                      those commits
#   unknown            the merged check printed UNKNOWN for it: nothing is claimed, whatever
#                      the inventory read
# `settled`, `unsettled` and `in_flight` count the commits looked at: HEAD of an `unpushed`
# entry, and each TIP. They are 0 for an entry whose files decided its class.
#
# A worktree gets the most demanding class among its entries, in this order: unknown,
# needs-a-person, work-in-flight, tool-output, merged-in-content, nothing-held. That row
# covers the worktree's populated submodules only. It says nothing about the worktree's own
# top-level repository, which the sweep judges separately.
#
# Every class is as old as the two texts: a session that is still running can change an
# entry after the inventory read it. Take both texts again before acting on a class.
#
# A stash is never settled, whatever any row says about it. `merged-other-base`, `closed`,
# `other-head`, `no-pr`, `not-on-github`, `not-checked`, `differs` and `no-reference` settle
# nothing.
#
# Exit codes: 0 every entry got a class other than `unknown`; 2 usage error, an `unknown`
# entry, or input that cannot be joined: either text lacks its closing line or has rows
# after it, the inventory was taken without --tips or holds an UNREADABLE row, a row is
# malformed or carries a verdict this script does not know, a row names an entry, HEAD or
# tip the inventory does not, an entry or tip that needs a verdict has none, or a row
# appears twice. On input it cannot join it prints no CLASS row at all.
set -euo pipefail

die() { printf 'worktree-inventory-classify: %s\n' "$1" >&2; exit 2; }

USAGE="usage: worktree-inventory-classify.sh --inventory <file> < merged-check-output"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo pipefail$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
esac
[ $# -eq 2 ] && [ "$1" = --inventory ] || die "$USAGE"
INVENTORY=$2
[ -f "$INVENTORY" ] && [ -r "$INVENTORY" ] || die "not a readable file: $INVENTORY"

OUT=$(mktemp) || die "cannot create a temporary file"
classify_finished=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -f "$OUT"
  if [ "$classify_finished" != 1 ] && [ "$status" = 0 ]; then status=2; fi
  exit "$status"
}
trap on_exit EXIT

# Both texts go through one awk run, each row tagged with its source, so a file name can
# never be read as an awk assignment and a row can never be attributed to the wrong text.
rc=0
{
  sed 's/^/I	/' < "$INVENTORY" || exit 1
  sed 's/^/C	/' || exit 1
} | LC_ALL=C awk -F'\t' '
  function fail(msg) { printf "worktree-inventory-classify: %s\n", msg > "/dev/stderr"; failed = 1; exit 3 }
  function sha_ok(s) { return length(s) == 40 && s !~ /[^0-9a-f]/ }
  function num_ok(s) { return s != "" && s !~ /[^0-9]/ }
  # val — the value of the field that must be exactly `<name>=...` at position i.
  function val(i, name,    p) {
    p = name "="
    if (substr($i, 1, length(p)) != p) fail("line " NR ": expected " p " in field " (i - 1) " of a " $2 " row")
    return substr($i, length(p) + 1)
  }
  function name_ok(s) { return s != "" }
  # judge — count one commit as in flight, settled or unsettled.
  function judge(key, verdict, kind, content) {
    if (verdict == "open") { flight[key]++; return }
    if (kind == "stash" || verdict == "stash") { unsettled[key]++; return }
    if (verdict == "merged" || verdict == "merged-ancestor" || verdict == "pushed-ref") { settled[key]++; return }
    if (content == "reached" || content == "no-change" || content == "same-change") { settled[key]++; return }
    unsettled[key]++
  }
  BEGIN {
    split("clean ignored modified untracked nested unpushed local-only", a, " ")
    for (i in a) inv_class[a[i]] = 1
    split("merged merged-ancestor merged-other-base open closed other-head no-pr not-on-github not-checked", a, " ")
    for (i in a) { head_verdict[a[i]] = 1; tip_verdict[a[i]] = 1 }
    tip_verdict["stash"] = 1; tip_verdict["pushed-ref"] = 1
    split("reached no-change same-change differs no-reference", a, " ")
    for (i in a) content_verdict[a[i]] = 1
    split("branch stash ref reflog", a, " ")
    for (i in a) tip_kind[a[i]] = 1
    rank["nothing-held"] = 1; rank["merged-in-content"] = 2; rank["tool-output"] = 3
    rank["work-in-flight"] = 4; rank["needs-a-person"] = 5; rank["unknown"] = 6
  }

  $1 == "I" {
    if (inv_closed) fail("the inventory has rows after its CHECKED line")
    if ($2 == "SKIP") next
    if ($2 == "UNREADABLE") fail("the inventory holds an UNREADABLE row: it is incomplete")
    if ($2 == "CHECKED") {
      inv_closed = 1; has_tips = 0; inv_entries = ""; below = 0
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^tips=/) has_tips = 1
        if ($i ~ /^entries=/) inv_entries = substr($i, 9)
        if ($i ~ /^below_min_idle=/) below = substr($i, 16)
      }
      if (!has_tips) fail("the inventory was taken without --tips: commits away from HEAD are not named")
      if (!num_ok(inv_entries) || !num_ok(below)) fail("the inventory CHECKED line is malformed")
      next
    }
    if ($2 == "ENTRY") {
      if (NF != 13) fail("line " NR ": an ENTRY row has " (NF - 1) " fields, not 12")
      key = $3 SUBSEP $4
      if (!name_ok($3) || !name_ok($4)) fail("line " NR ": an ENTRY row names no worktree or submodule")
      if (key in e_class) fail("the inventory lists " $3 " " $4 " twice")
      if (!($5 in inv_class)) fail("line " NR ": unknown inventory class " $5)
      val(6, "idle_days")
      e_head[key] = val(7, "head"); e_unpushed[key] = val(8, "unpushed"); e_local[key] = val(9, "local_only")
      val(10, "modified"); val(11, "untracked"); val(12, "nested"); val(13, "ignored")
      if (!sha_ok(e_head[key]) || !num_ok(e_unpushed[key]) || !num_ok(e_local[key])) fail("line " NR ": malformed ENTRY row")
      e_class[key] = $5; order[++n] = key; e_wt[key] = $3; e_sub[key] = $4
      next
    }
    if ($2 == "TIP") {
      if (NF != 8) fail("line " NR ": a TIP row has " (NF - 1) " fields, not 7")
      key = $3 SUBSEP $4
      if (!(key in e_class)) fail("line " NR ": a TIP row names an entry the inventory has not listed")
      t = val(5, "tip"); k = val(6, "kind"); val(7, "ref"); val(8, "commits")
      if (!sha_ok(t) || !(k in tip_kind)) fail("line " NR ": malformed TIP row")
      if ((key, t) in t_kind) fail("the inventory lists tip " t " twice for " $3 " " $4)
      t_kind[key, t] = k; tips[key] = tips[key] " " t; t_count[key]++
      next
    }
    fail("line " NR ": unknown inventory row " $2)
  }

  $1 == "C" {
    if (!inv_closed) fail("the inventory has no CHECKED line: it is incomplete")
    if (chk_closed) fail("the merged check has rows after its CHECKED line")
    if ($2 == "NOTE") next
    if ($2 == "CHECKED") { chk_closed = 1; next }
    key = $3 SUBSEP $4
    if ($2 == "MERGE-CHECK" || $2 == "TIP-CHECK" || $2 == "CONTENT-CHECK" || $2 == "UNKNOWN") {
      if (NF < 5) fail("merged-check line " NR ": a " $2 " row is too short")
      if (!(key in e_class)) fail("a " $2 " row names " $3 " " $4 ", which the inventory does not list")
    }
    if ($2 == "UNKNOWN") { unk[key] = 1; next }
    if (e_class[key] != "unpushed" && e_class[key] != "local-only")
      if ($2 == "MERGE-CHECK" || $2 == "TIP-CHECK" || $2 == "CONTENT-CHECK")
        fail("a " $2 " row names " $3 " " $4 ", which the inventory reads as " e_class[key])
    if ($2 == "MERGE-CHECK") {
      if (NF != 9) fail("a MERGE-CHECK row has " (NF - 1) " fields, not 8")
      if (key in mc) fail("the merged check answers twice for " $3 " " $4)
      if (!($5 in head_verdict)) fail("unknown MERGE-CHECK verdict " $5)
      if (val(6, "head") != e_head[key]) fail("the MERGE-CHECK row for " $3 " " $4 " names another HEAD than the inventory")
      mc[key] = $5
      next
    }
    if ($2 == "TIP-CHECK") {
      if (NF != 11) fail("a TIP-CHECK row has " (NF - 1) " fields, not 10")
      if (!($5 in tip_verdict)) fail("unknown TIP-CHECK verdict " $5)
      t = val(6, "tip")
      if (!((key, t) in t_kind)) fail("a TIP-CHECK row names tip " t ", which the inventory does not list for " $3 " " $4)
      if (val(7, "kind") != t_kind[key, t]) fail("the TIP-CHECK row for tip " t " names another kind than the inventory")
      if ((key, t) in tc) fail("the merged check answers twice for tip " t " of " $3 " " $4)
      tc[key, t] = $5
      next
    }
    if ($2 == "CONTENT-CHECK") {
      if (!($5 in content_verdict)) fail("unknown CONTENT-CHECK verdict " $5)
      t = val(6, "commit")
      if (!sha_ok(t)) fail("malformed CONTENT-CHECK row")
      if (t != e_head[key] && !((key, t) in t_kind)) fail("a CONTENT-CHECK row names commit " t ", which is neither HEAD nor a tip of " $3 " " $4)
      if ((key, t) in cc) fail("the merged check compares commit " t " of " $3 " " $4 " twice")
      cc[key, t] = $5
      next
    }
    fail("unknown merged-check row " $2)
  }

  { fail("line " NR ": a row from neither text") }

  END {
    if (failed) exit 3
    if (!inv_closed) fail("the inventory has no CHECKED line: it is incomplete")
    if (!chk_closed) fail("the merged check has no CHECKED line: it is incomplete")
    if (n != inv_entries + 0) fail("the inventory lists " n " entries and its CHECKED line says " inv_entries)
    for (i = 1; i <= n; i++) {
      key = order[i]; c = e_class[key]
      settled[key] += 0; unsettled[key] += 0; flight[key] += 0
      if (key in unk) cls = "unknown"
      else if (c == "clean") cls = "nothing-held"
      else if (c == "ignored") cls = "tool-output"
      else if (c == "modified" || c == "untracked" || c == "nested") cls = "needs-a-person"
      else {
        if (!(key in mc)) fail("the merged check has no row for " e_wt[key] " " e_sub[key])
        if (c == "local-only" && mc[key] != "not-checked") fail("the merged check judged the pushed HEAD of " e_wt[key] " " e_sub[key])
        if (c == "unpushed") judge(key, mc[key], "", cc[key, e_head[key]])
        if (e_local[key] + 0 > e_unpushed[key] + 0 && t_count[key] + 0 == 0)
          fail("the inventory names no tip for " e_wt[key] " " e_sub[key] ", which holds commits away from HEAD")
        m = split(tips[key], tl, " ")
        for (j = 1; j <= m; j++) {
          if (!((key, tl[j]) in tc)) fail("the merged check has no row for tip " tl[j] " of " e_wt[key] " " e_sub[key])
          judge(key, tc[key, tl[j]], t_kind[key, tl[j]], cc[key, tl[j]])
        }
        if (settled[key] + unsettled[key] + flight[key] == 0) fail("no commit was judged for " e_wt[key] " " e_sub[key])
        if (flight[key] > 0) cls = "work-in-flight"
        else if (unsettled[key] > 0) cls = "needs-a-person"
        else cls = "merged-in-content"
      }
      e_out[key] = cls; total[cls]++
      w = e_wt[key]
      if (!(w in w_class)) { w_order[++wn] = w; w_class[w] = cls }
      else if (rank[cls] > rank[w_class[w]]) w_class[w] = cls
      w_entries[w]++
    }
    for (i = 1; i <= n; i++) {
      key = order[i]
      printf "CLASS\t%s\t%s\t%s\tinventory=%s\tsettled=%d\tunsettled=%d\tin_flight=%d\n", e_wt[key], e_sub[key], e_out[key], e_class[key], settled[key], unsettled[key], flight[key]
    }
    for (i = 1; i <= wn; i++) {
      w = w_order[i]; w_total[w_class[w]]++
      printf "WORKTREE\t%s\t%s\tentries=%d\n", w, w_class[w], w_entries[w]
    }
    printf "CLASSIFIED\tentries=%d\tnothing_held=%d\tmerged_in_content=%d\ttool_output=%d\twork_in_flight=%d\tneeds_a_person=%d\tunknown=%d", n, total["nothing-held"], total["merged-in-content"], total["tool-output"], total["work-in-flight"], total["needs-a-person"], total["unknown"]
    printf "\tworktrees=%d\twt_nothing_held=%d\twt_merged_in_content=%d\twt_tool_output=%d\twt_work_in_flight=%d\twt_needs_a_person=%d\twt_unknown=%d\tbelow_min_idle=%d\n", wn, w_total["nothing-held"], w_total["merged-in-content"], w_total["tool-output"], w_total["work-in-flight"], w_total["needs-a-person"], w_total["unknown"], below
    if (total["unknown"] > 0) exit 4
  }
' > "$OUT" || rc=$?

case "$rc" in
  0|4) ;;
  *) classify_finished=1; exit 2 ;;
esac
# A complete answer ends with its closing line; anything else is a cut-short run.
[ "$(tail -n 1 "$OUT" | cut -f1)" = CLASSIFIED ] || die "the classification did not finish"
cat "$OUT"
classify_finished=1
[ "$rc" = 0 ] || exit 2
