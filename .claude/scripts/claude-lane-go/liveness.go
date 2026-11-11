package main

// liveness: did the Claude lane's dispatched runs actually RUN? The design note is
// liveness-help.txt; the comments here say how each step keeps claude-lane-liveness.sh's verdicts.

import (
	_ "embed"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
)

//go:embed liveness-help.txt
var livenessHelp string

const livenessRecovery = `
  To resolve: confirm the scheduler is dispatching the task and that dispatched runs reach the model.
  A dead dispatch still advances lastRunAt, while a stopped scheduler leaves it frozen; inspect both
  the expected slot and whether a session exists for the latest dispatch. Re-run this check once the
  newest expected dispatch has had time to settle.`

var (
	taskIDPattern   = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	taskListPattern = regexp.MustCompile(`^[A-Za-z0-9._,-]+$`)
)

type livenessOptions struct {
	store, projects, task                    string
	taskSet, quiet                           bool
	grace, skew, lookback, stall, now        int64
	graceRaw, skewRaw, lookbackRaw, stallRaw string
}

// stop is a die_unknown: its message goes to stderr, followed by the recovery note, and exit 2.
type stop struct{ msg string }

func liveness(args []string, stdout, stderr io.Writer, env environment) (code int) {
	defer func() {
		if r := recover(); r != nil {
			s, ok := r.(stop)
			if !ok {
				panic(r)
			}
			fmt.Fprintf(stderr, "claude-lane-liveness: UNKNOWN -- %s\n", s.msg)
			fmt.Fprintf(stderr, "%s\n", livenessRecovery)
			code = 2
		}
	}()
	die := func(format string, a ...any) { panic(stop{fmt.Sprintf(format, a...)}) }

	o := livenessOptions{store: env.storePath, projects: env.defaultProjects(),
		graceRaw: "900", skewRaw: "120", lookbackRaw: "72", stallRaw: "7200"}
	nowRaw := ""
	for i := 0; i < len(args); i++ {
		a := args[i]
		value := func() string {
			if i+1 >= len(args) {
				die("%s needs a value", a)
			}
			i++
			return args[i]
		}
		switch a {
		case "--help", "-h":
			fmt.Fprint(stdout, livenessHelp)
			return 0
		case "--store":
			o.store = value()
		case "--projects":
			o.projects = value()
		case "--task":
			o.task, o.taskSet = value(), true
		case "--grace-seconds":
			o.graceRaw = value()
		case "--skew-seconds":
			o.skewRaw = value()
		case "--lookback-hours":
			o.lookbackRaw = value()
		case "--stall-seconds":
			o.stallRaw = value()
		case "--now-epoch":
			nowRaw = value()
		case "--quiet":
			o.quiet = true
		default:
			die("unrecognised argument: %s", a)
		}
	}

	// Every numeric knob is validated before use, each with a floor of 1: a zero window defeats
	// the invariant it exists to hold (see liveness-help.txt and the script's history).
	knob := func(name, raw string) int64 {
		if !allDigits(raw) {
			die("%s must be a non-negative integer, got: %s", name, raw)
		}
		n, ok := parseCount(raw)
		if !ok {
			die("%s must be a decimal integer without a leading zero, got: %s", name, raw)
		}
		return n
	}
	o.grace = knob("GRACE_SECONDS", o.graceRaw)
	o.skew = knob("SKEW_SECONDS", o.skewRaw)
	o.lookback = knob("LOOKBACK_HOURS", o.lookbackRaw)
	o.stall = knob("STALL_SECONDS", o.stallRaw)
	if o.grace < 1 {
		die("--grace-seconds must be at least 1")
	}
	if o.skew < 1 {
		die("--skew-seconds must be at least 1")
	}
	if o.lookback < 1 {
		die("--lookback-hours must be at least 1")
	}
	if o.stall < 1 {
		die("--stall-seconds must be at least 1")
	}
	if nowRaw != "" {
		if !allDigits(nowRaw) {
			die("--now-epoch must be a non-negative integer, got: %s", nowRaw)
		}
		n, ok := parseCount(nowRaw)
		if !ok {
			die("--now-epoch must be a decimal integer without a leading zero, got: %s", nowRaw)
		}
		o.now = n
	} else {
		o.now = env.wallNow
	}

	// Store discovery requires EXACTLY ONE enabled store: two candidates are two plausible answers
	// about the same lane, and picking either is a guess.
	if o.store == "" {
		root := env.defaultStoreRoot()
		var selected string
		matches := 0
		for _, c := range storeCandidates(root) {
			docs, err := readDocs(c)
			if err != nil || !jqExit(docs, hasEnabledTask) {
				continue
			}
			selected = c
			matches++
		}
		if matches != 1 {
			die("expected exactly one Claude scheduled-tasks store under %s, found %d", root, matches)
		}
		o.store = selected
	}
	if !isRegularFile(o.store) {
		die("scheduled-tasks store not found: %s", o.store)
	}
	if !readable(o.store) {
		die("scheduled-tasks store is not readable: %s", o.store)
	}
	docs, err := readDocs(o.store)
	// One JSON document whose value is neither null nor false, as `jq -e .` required; a stream of
	// several documents is refused rather than judged by one of them.
	if err != nil || len(docs) != 1 || !truthy(docs[0]) {
		die("scheduled-tasks store is not valid JSON: %s", o.store)
	}
	if !isDir(o.projects) {
		die("projects root not found: %s", o.projects)
	}
	if !readable(o.projects) {
		die("projects root is not readable: %s", o.projects)
	}

	// Schema is asserted, never assumed: a renamed field would make every lookup return empty,
	// and empty reads exactly like "nothing to report".
	root, _ := docs[0].(map[string]any)
	rawTasks, isArray := root["scheduledTasks"].([]any)
	if root == nil || !isArray {
		die("unexpected store schema: .scheduledTasks is missing or not an array")
	}
	tasks := make([]map[string]any, 0, len(rawTasks))
	for _, t := range rawTasks {
		obj, _ := t.(map[string]any)
		tasks = append(tasks, obj)
	}
	for _, f := range []string{"id", "enabled", "cronExpression"} {
		for _, t := range tasks {
			if _, ok := t[f]; t == nil || !ok {
				die("unexpected store schema: a scheduled task is missing .%s", f)
			}
		}
	}
	// lastRunAt is asserted on the STORE, not on every record: an entry that has never run has
	// none, and that is its own UNKNOWN line (monorepo#4156). Missing everywhere is a rename.
	carried := false
	for _, t := range tasks {
		if _, ok := t["lastRunAt"]; ok {
			carried = true
		}
	}
	if !carried {
		die("unexpected store schema: no scheduled task carries .lastRunAt")
	}
	var enabled []string
	allStrings := true
	for _, t := range tasks {
		if isTrue(t["enabled"]) {
			s, ok := t["id"].(string)
			if !ok {
				allStrings = false
			}
			enabled = append(enabled, s)
		}
	}
	if !allStrings {
		die("unexpected store schema: an enabled task id is not a string")
	}
	for _, id := range enabled {
		if !taskIDPattern.MatchString(id) {
			die("unusable enabled task id in %s (only A-Za-z0-9._- are supported)", o.store)
		}
	}
	seen := map[string]bool{}
	for _, id := range enabled {
		if seen[id] {
			die("duplicate enabled task id in %s -- a later dispatch would be masked by an earlier record", o.store)
		}
		seen[id] = true
	}
	enabledRecord := func(id string) map[string]any {
		for _, t := range tasks {
			if t["id"] == id && isTrue(t["enabled"]) {
				return t
			}
		}
		return nil
	}

	var ids []string
	if o.taskSet {
		if o.task == "" {
			die("--task must not be empty")
		}
		if !taskListPattern.MatchString(o.task) {
			die("unusable task id: %s", o.task)
		}
		if strings.Contains(","+o.task+",", ",,") {
			die("empty task id in --task: %s", o.task)
		}
		named := strings.Split(o.task, ",")
		if len(named) > 4 {
			die("--task takes at most four ids, got %d", len(named))
		}
		listed := map[string]bool{}
		for _, id := range named {
			if listed[id] {
				die("task %s is named twice in --task", id)
			}
			// A named task is held to the same enabled filter. One the scheduler is not dispatching
			// is UNKNOWN, but named on stdout so a caller can tell "not dispatching" from "could
			// not be judged" (monorepo#4116).
			if enabledRecord(id) == nil {
				if !o.quiet {
					held := false
					for _, t := range tasks {
						if t["id"] == id {
							held = true
						}
					}
					if held {
						fmt.Fprintf(stdout, "  NOT-SCHEDULED  %s -- the scheduler holds this entry switched off\n", id)
					} else {
						fmt.Fprintf(stdout, "  NOT-SCHEDULED  %s -- the scheduler holds no entry with this id (not created yet, or removed)\n", id)
					}
				}
				die("task %s is not a single enabled task in %s", id, o.store)
			}
			listed[id] = true
			ids = append(ids, id)
		}
	} else {
		ids = append(ids, enabled...)
		sort.Strings(ids)
	}
	if len(ids) == 0 {
		die("no enabled scheduled tasks found in %s", o.store)
	}

	// Transcripts are enumerated once. Only each one's FIRST line is read to attribute it: the
	// marker always sits there, and it is the only line readable without touching run content.
	files, err := transcripts(o.projects, o.now-o.lookback*3600)
	if err != nil {
		die("could not enumerate transcripts under %s", o.projects)
	}
	if len(files) == 0 {
		die("no transcripts at all under %s in the last %dh -- cannot judge", o.projects, o.lookback)
	}
	type session struct {
		task  string
		start int64
		path  string
	}
	var index []session
	unparsable := map[string]bool{}
	for _, f := range files {
		line, err := env.readHeader(f)
		if err != nil {
			die("could not read a transcript header; cannot establish attribution")
		}
		if !strings.Contains(line, markerNeedle) {
			continue
		}
		head, err := decodeAll([]byte(line))
		if err != nil || len(head) != 1 {
			die("a task-marker candidate is not valid JSON; cannot establish attribution")
		}
		name := attributedTask(head[0], false)
		if name == "" {
			continue
		}
		start := headerStart(head[0])
		if start == "" {
			start = earliestTimestamp(f)
		}
		// ATTRIBUTABLE but unreadable: the task then answers UNKNOWN, never NOT-PRODUCING on
		// evidence that was malformed rather than absent.
		se, ok := livenessInstant(start)
		if start == "" || !ok {
			unparsable[name] = true
			continue
		}
		index = append(index, session{name, se, f})
	}
	// Transcripts exist but none is attributable: the likeliest cause is a changed marker, which
	// would otherwise report the whole fleet as not producing at once.
	if len(index) == 0 {
		die("no transcript in the last %dh is attributable to a scheduled task -- the task marker may have changed; cannot judge", o.lookback)
	}

	anyDead, anyUnknown := false, false
	var report strings.Builder
	line := func(format string, a ...any) { fmt.Fprintf(&report, format+"\n", a...) }
	for _, id := range ids {
		rec := enabledRecord(id)
		// Schedule state is kept beside the transcript state rather than returned early: a
		// conclusive transcript failure must still outrank a malformed schedule.
		scheduleState, scheduleReason := "ok", ""
		lastScheduled := jqRawOrEmpty(rec["lastScheduledFor"])
		cron := jqRawOrEmpty(rec["cronExpression"])
		lsEpoch, lsOK := livenessInstant(lastScheduled)
		var nextEpoch int64
		haveNext := false
		switch {
		case lastScheduled == "":
			scheduleState = "unknown"
			scheduleReason = "no lastScheduledFor on this task, so the schedule leg has no anchor; the transcript leg still applies"
		case lsOK && lsEpoch > o.now+o.skew:
			scheduleState = "unknown"
			scheduleReason = fmt.Sprintf("future lastScheduledFor is more than %ds ahead of the observer clock", o.skew)
		case lsOK && cron != "":
			nextEpoch, haveNext = nextSlot(cron, lsEpoch, env.loc)
		}
		if scheduleState == "ok" && !haveNext {
			shown := cron
			if shown == "" {
				shown = "<missing>"
			}
			scheduleState = "unknown"
			scheduleReason = "unsupported cron expression or lastScheduledFor does not name one of its slots: " + shown
		}

		lastRun := jqRawOrEmpty(rec["lastRunAt"])
		if lastRun == "" || lastRun == "null" {
			line("  UNKNOWN  %s -- no lastRunAt recorded, never dispatched or store incomplete", id)
			anyUnknown = true
			continue
		}
		lr, ok := livenessInstant(lastRun)
		if !ok {
			line("  UNKNOWN  %s -- unparsable lastRunAt, cannot judge", id)
			anyUnknown = true
			continue
		}
		// A dispatch older than the lookback window cannot have its session enumerated.
		if lr < o.now-o.lookback*3600 {
			line("  UNKNOWN  %s -- newest dispatch predates the %dh lookback window, cannot judge", id, o.lookback)
			anyUnknown = true
			continue
		}
		// An in-flight dispatch is not classified: it is indistinguishable from a stub.
		if lr > o.now-o.grace {
			line("  UNKNOWN  %s -- newest dispatch is still within the %ds grace window, cannot judge", id, o.grace)
			anyUnknown = true
			continue
		}

		match, bestD := "", int64(-1)
		for _, s := range index {
			if s.task != id {
				continue
			}
			d := s.start - lr
			if d < 0 {
				d = -d
			}
			if d <= o.skew && (match == "" || d < bestD) {
				match, bestD = s.path, d
			}
		}
		if match == "" {
			if unparsable[id] {
				line("  UNKNOWN  %s -- an attributable transcript could not be parsed, so the dispatch is unprovable", id)
				anyUnknown = true
				continue
			}
			line("  NOT-PRODUCING  %s -- dispatched at %s and no session started within %ds of it", id, lastRun, o.skew)
			anyDead = true
			continue
		}

		st, ok := sessionStats(match)
		if !ok {
			line("  UNKNOWN  %s -- session transcript could not be parsed, cannot judge", id)
			anyUnknown = true
			continue
		}
		fe, okF := livenessInstant(st.first)
		le, okL := livenessInstant(st.last)
		if !st.timesOK || !okF || !okL || le < fe {
			line("  UNKNOWN  %s -- unparsable session timings or turn count, cannot judge", id)
			anyUnknown = true
			continue
		}
		span := le - fe

		// A transcript timestamp beyond the observer-skew allowance is impossible overlap evidence.
		transcriptUnknown := ""
		if le > o.now+o.skew {
			transcriptUnknown = fmt.Sprintf("future session endpoint is more than %ds ahead of the observer clock", o.skew)
		}

		// per_task_limit samples cover slots while a run stays open; only integral millisecond
		// epochs within the observer-skew allowance count (monorepo#3990 for the stall leg).
		overlapUntil := le
		var stalledFor int64
		stalled := false
		if skipMS, ok := newestSkip(root, id, (o.now+o.skew)*1000); ok {
			skipEpoch := skipMS / 1000
			if skipEpoch > overlapUntil {
				overlapUntil = skipEpoch
			}
			if st.pending && skipEpoch-le > o.stall {
				stalledFor, stalled = skipEpoch-le, true
			}
		}

		// A session or skip that crosses a slot explains a suppressed dispatch there; advance past
		// every covered slot, bounded so implausible coverage is UNKNOWN, not an unbounded loop.
		overlapSlots := 0
		if transcriptUnknown == "" && scheduleState == "ok" {
			for overlapUntil >= nextEpoch {
				overlapSlots++
				if overlapSlots > 256 {
					scheduleState = "unknown"
					scheduleReason = "session spans more than 256 scheduled slots; schedule evidence is not bounded"
					break
				}
				following, ok := nextSlot(cron, nextEpoch, env.loc)
				if !ok || following <= nextEpoch {
					scheduleState = "unknown"
					scheduleReason = "could not advance the schedule beyond an overlapping run"
					break
				}
				nextEpoch = following
			}
		}
		if scheduleState == "ok" && o.now > nextEpoch+o.grace {
			scheduleState = "dead"
			scheduleReason = fmt.Sprintf("next expected slot after the observed session is overdue by more than %ds", o.grace)
		}

		// ZERO ASSISTANT TURNS IS THE WHOLE TEST; the span is reported, never required (#3287).
		switch {
		case transcriptUnknown != "":
			line("  UNKNOWN  %s -- %s", id, transcriptUnknown)
			anyUnknown = true
		case st.turns == 0:
			note := ""
			if st.cause != "none" {
				note = " (runtime error record only, cause=" + st.cause + ")"
			}
			line("  NOT-PRODUCING  %s -- dispatched at %s, session produced 0 assistant turns in %ds%s", id, lastRun, span, note)
			anyDead = true
		case stalled:
			line("  NOT-PRODUCING  %s -- dispatched at %s, session has waited %ds on a tool call that never returned while the scheduler dropped the slots behind it", id, lastRun, stalledFor)
			anyDead = true
		case scheduleState == "dead":
			line("  NOT-PRODUCING  %s -- %s", id, scheduleReason)
			anyDead = true
		case scheduleState == "unknown":
			line("  UNKNOWN  %s -- %s", id, scheduleReason)
			anyUnknown = true
		default:
			line("  OK  %s -- dispatched at %s, session produced %d assistant turn(s) over %ds, covered %d suppressed slot(s)", id, lastRun, st.turns, span, overlapSlots)
		}
	}

	if !o.quiet {
		fmt.Fprintf(stdout, "claude-lane-liveness: store=%s grace=%ss skew<=%ss lookback=%sh\n", o.store, o.graceRaw, o.skewRaw, o.lookbackRaw)
		fmt.Fprint(stdout, report.String())
	}
	// A detected dead lane OUTRANKS an unjudgeable one.
	if anyDead {
		fmt.Fprintf(stderr, "claude-lane-liveness: NOT PRODUCING -- a dispatched lane is not doing work.\n")
		fmt.Fprintf(stderr, "%s\n", livenessRecovery)
		return 1
	}
	if anyUnknown {
		fmt.Fprintf(stderr, "claude-lane-liveness: UNKNOWN -- at least one task could not be judged.\n")
		return 2
	}
	return 0
}

// headerStart is the first line's `.timestamp` as `jq -r 'select(.timestamp) | .timestamp' | head
// -1` printed it: empty when absent, null or false.
func headerStart(doc any) string {
	v, _ := field(doc, "timestamp")
	if !truthy(v) {
		return ""
	}
	if s, ok := v.(string); ok {
		if i := strings.IndexByte(s, '\n'); i >= 0 {
			s = s[:i]
		}
		return s
	}
	return strings.SplitN(jqRaw(v), "\n", 2)[0]
}

// earliestTimestamp is the fallback over the first 40 lines: the smallest truthy `.timestamp` in
// jq's sort order, or empty when those lines do not parse or carry none that is a string.
func earliestTimestamp(path string) string {
	data, err := readFirstLines(path, 40)
	if err != nil {
		return ""
	}
	docs, err := decodeAll(data)
	if err != nil {
		return ""
	}
	var stamps []any
	for _, d := range docs {
		v, ok := field(d, "timestamp")
		if !ok {
			return ""
		}
		if truthy(v) {
			stamps = append(stamps, v)
		}
	}
	if s, ok := extremeString(stamps, false); ok {
		return strings.TrimRight(s, "\n")
	}
	if len(stamps) > 0 {
		return "unparsable"
	}
	return ""
}

type stats struct {
	turns       int
	first, last string
	timesOK     bool
	cause       string
	pending     bool
}

// sessionStats reads the matched transcript whole, for scalars only: real assistant turns, the
// first and last timestamp, the newest runtime-synthesised error's class (a fixed vocabulary), and
// whether the session's last turn is a tool call with no result. It never reads message text.
func sessionStats(path string) (stats, bool) {
	docs, err := readDocs(path)
	if err != nil {
		return stats{}, false
	}
	var assistant, synthetic int
	var lastSynthetic map[string]any
	var stamps []any
	var end map[string]any
	for _, d := range docs {
		r, ok := d.(map[string]any)
		if !ok {
			continue
		}
		if truthy(r["timestamp"]) {
			stamps = append(stamps, r["timestamp"])
		}
		switch r["type"] {
		case "assistant":
			assistant++
			// A record the RUNTIME synthesised is not a turn (monorepo#3412).
			model, _ := field(r["message"], "model")
			if isTrue(r["isApiErrorMessage"]) || model == "<synthetic>" {
				synthetic++
				lastSynthetic = r
			}
			end = r
		case "user":
			end = r
		}
	}
	st := stats{turns: assistant - synthetic, cause: "none"}
	if lastSynthetic != nil {
		switch lastSynthetic["error"] {
		case "rate_limit", "billing_error":
			st.cause = "quota/billing"
		case "authentication_failed":
			st.cause = "credentials/auth"
		default:
			st.cause = "unknown"
		}
	}
	first, okF := extremeString(stamps, false)
	last, okL := extremeString(stamps, true)
	st.first, st.last = first, last
	st.timesOK = okF && okL && !strings.ContainsAny(first+last, "\t\n")
	if end != nil && end["type"] == "assistant" {
		content, _ := field(end["message"], "content")
		if blocks, ok := content.([]any); ok {
			for _, b := range blocks {
				if bo, ok := b.(map[string]any); ok && bo["type"] == "tool_use" {
					st.pending = true
				}
			}
		}
	}
	return st, true
}

// newestSkip is the newest per_task_limit sample for the task: an integral, non-negative
// millisecond epoch no later than cutoffMS. Anything else proves nothing and is ignored.
func newestSkip(root map[string]any, id string, cutoffMS int64) (int64, bool) {
	skips, ok := root["recordedSkips"].(map[string]any)
	if !ok {
		return 0, false
	}
	var best int64
	found := false
	for _, s := range iterate(skips[id]) {
		obj, ok := s.(map[string]any)
		if !ok || obj["reason"] != "per_task_limit" {
			continue
		}
		at, ok := nonNegativeInteger(obj["at"])
		if !ok || at > cutoffMS {
			continue
		}
		if !found || at > best {
			best, found = at, true
		}
	}
	return best, found
}
