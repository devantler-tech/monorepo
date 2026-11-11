package main

// dispatch-rate: how many of a Claude task's scheduled slots actually dispatched? The design note
// is dispatch-rate-help.txt; the comments here say how each step keeps claude-dispatch-rate.sh's
// readings.

import (
	_ "embed"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"
)

//go:embed dispatch-rate-help.txt
var dispatchRateHelp string

var (
	wholeSecondUTC = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)
	// The two shapes the deployment uses, whitelisted on the raw value, before anything could trim
	// a trailing newline into shape.
	supportedCron = regexp.MustCompile(`\A[0-9]{1,2} (\*|[0-9]{1,2}(,[0-9]{1,2})*) \* \* \*\z`)
)

func rateDie(format string, a ...any) { panic(stop{fmt.Sprintf(format, a...)}) }

func dispatchRate(args []string, stdout, stderr io.Writer, env environment) (code int) {
	defer func() {
		if r := recover(); r != nil {
			s, ok := r.(stop)
			if !ok {
				panic(r)
			}
			fmt.Fprintf(stderr, "claude-dispatch-rate: UNKNOWN -- %s\n", s.msg)
			code = 2
		}
	}()
	store, projects := env.storePath, env.defaultProjects()
	var task, since, until, nowRaw string
	slots := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		value := func() string {
			if i+1 >= len(args) {
				rateDie("%s needs a value", a)
			}
			i++
			return args[i]
		}
		switch a {
		case "--help", "-h":
			fmt.Fprint(stdout, dispatchRateHelp)
			return 0
		case "--task":
			task = value()
		case "--since":
			since = value()
		case "--until":
			until = value()
		case "--store":
			store = value()
		case "--projects":
			projects = value()
		case "--now-epoch":
			nowRaw = value()
		case "--slots":
			slots = true
		default:
			rateDie("unrecognised argument: %s", a)
		}
	}
	if !env.hasJQ() {
		rateDie("jq is not available")
	}
	if task == "" {
		rateDie("--task is required")
	}
	if !taskListPattern.MatchString(task) {
		rateDie("unusable task id: %s", task)
	}
	if since == "" {
		rateDie("--since is required")
	}
	now := env.wallNow
	if nowRaw != "" {
		if !allDigits(nowRaw) {
			rateDie("--now-epoch must be a non-negative integer")
		}
		n, ok := parseCount(nowRaw)
		if !ok {
			rateDie("--now-epoch must be a decimal integer without a leading zero")
		}
		now = n
	}
	// Command-line bounds are whole seconds only: a fraction would move the window, so it is
	// refused rather than rounded.
	untilShown := until
	if untilShown == "" {
		untilShown = "2000-01-01T00:00:00Z"
	}
	for _, bound := range []string{since, untilShown} {
		if !wholeSecondUTC.MatchString(bound) {
			rateDie("--since/--until must be a whole-second UTC instant (YYYY-MM-DDTHH:MM:SSZ), not a UTC instant: %s", bound)
		}
	}
	sinceE, ok := strictInstant(since)
	if !ok {
		rateDie("--since is not a UTC instant: %s", since)
	}
	untilE := now
	if until != "" {
		if untilE, ok = strictInstant(until); !ok {
			rateDie("--until is not a UTC instant: %s", until)
		}
	}
	// A window reaching past now would settle slots whose dispatch window has not closed yet.
	if untilE > now {
		rateDie("--until is later than now")
	}
	if sinceE >= untilE {
		rateDie("--since must be earlier than --until")
	}
	w := rateWindow{since: sinceE, until: untilE, now: now, store: store, projects: projects}

	if !strings.Contains(task, ",") {
		r := w.measure(task, env)
		fmt.Fprint(stdout, r.line)
		if slots {
			fmt.Fprint(stdout, r.slotLines)
		}
		return 0
	}

	// A LANE WITH MORE THAN ONE ENTRY (monorepo#4117): each entry is measured on its own schedule
	// and sessions at one pinned clock, and the sum is printed only when EVERY entry was measured.
	if strings.Contains(","+task+",", ",,") {
		rateDie("empty task id in --task: %s", task)
	}
	ids := strings.Split(task, ",")
	if len(ids) > 4 {
		rateDie("--task takes at most four ids, got %d", len(ids))
	}
	named := map[string]bool{}
	for _, id := range ids {
		if named[id] {
			rateDie("task %s is named twice in --task", id)
		}
		named[id] = true
	}
	var out strings.Builder
	crons := map[string]bool{}
	scheduled, dispatched := 0, 0
	for _, id := range ids {
		r, msg := w.tryMeasure(id, env)
		if msg != "" {
			rateDie("entry %s could not be measured, so the set has no rate: %s", id, msg)
		}
		// Two entries on one schedule start together and the overlap rule is per entry, so the
		// second adds no start to the lane; summing them would double its scheduled slots.
		if crons[r.cron] {
			rateDie("entry %s has the same schedule as another named entry (%s)", id, r.cron)
		}
		crons[r.cron] = true
		scheduled += r.scheduled
		dispatched += r.dispatched
		out.WriteString(r.line)
		if slots {
			out.WriteString(r.slotLines)
		}
	}
	if scheduled <= 0 {
		rateDie("no settled slot between --since and --until for %s", task)
	}
	dropped := scheduled - dispatched
	fmt.Fprint(stdout, out.String())
	fmt.Fprintf(stdout, "DISPATCH-RATE-SET tasks=%s window=%s..%s scheduled=%d dispatched=%d dropped=%d drop_rate=%s%%\n",
		task, isoUTC(sinceE), isoUTC(untilE), scheduled, dispatched, dropped, percent(dropped, scheduled))
	return 0
}

func percent(dropped, scheduled int) string {
	return fmt.Sprintf("%.1f", 100*float64(dropped)/float64(scheduled))
}

type rateWindow struct {
	since, until, now int64
	store, projects   string
}

type rateResult struct {
	line, slotLines, cron string
	scheduled, dispatched int
}

func (w rateWindow) tryMeasure(task string, env environment) (r rateResult, msg string) {
	defer func() {
		if p := recover(); p != nil {
			s, ok := p.(stop)
			if !ok {
				panic(p)
			}
			msg = s.msg
		}
	}()
	return w.measure(task, env), ""
}

// measure is one entry's reading. Every way it cannot read a rate is a stop, never a partial rate.
func (w rateWindow) measure(task string, env environment) rateResult {
	store := w.store
	if store == "" {
		// EXACTLY one enabled store. A candidate that is not readable JSON with a scheduledTasks
		// array could be the current store, so it is UNKNOWN rather than skipped.
		root := env.defaultStoreRoot()
		matches := 0
		for _, c := range storeCandidates(root) {
			docs, err := readDocs(c)
			if err != nil || !jqExit(docs, func(d any) (bool, error) {
				obj, ok := d.(map[string]any)
				_, isArray := obj["scheduledTasks"].([]any)
				return ok && isArray, nil
			}) {
				rateDie("candidate store is not readable JSON with a scheduledTasks array: %s", c)
			}
			if !jqExit(docs, hasEnabledTask) {
				continue
			}
			store = c
			matches++
		}
		if matches != 1 {
			rateDie("expected exactly one Claude scheduled-tasks store under %s, found %d", root, matches)
		}
	}
	if !readable(store) {
		rateDie("scheduled-tasks store is not readable: %s", store)
	}
	if !isDir(w.projects) {
		rateDie("projects root not found: %s", w.projects)
	}

	docs, err := readDocs(store)
	if err != nil {
		rateDie("scheduled-tasks store is not valid JSON: %s", store)
	}
	var rec map[string]any
	single := len(docs) == 1
	for _, d := range docs {
		n, first, err := enabledMatches(d, task)
		if err != nil {
			rateDie("scheduled-tasks store is not valid JSON: %s", store)
		}
		single = single && n == 1
		rec = first
	}
	if !single {
		rateDie("task %s is not a single enabled task in %s", task, store)
	}
	cron, _ := rec["cronExpression"].(string)
	if !supportedCron.MatchString(cron) {
		rateDie("task %s has no cronExpression in a supported shape (M * * * * or M H1,H2 * * *)", task)
	}
	// The store keeps no schedule history: before the task existed there is nothing to judge.
	created, ok := nonNegativeInteger(rec["createdAt"])
	if !ok {
		rateDie("task %s has no numeric createdAt, so the window cannot be bounded", task)
	}
	// Compared in milliseconds: truncating createdAt would admit a slot a fraction before it.
	if w.since*1000 < created {
		rateDie("--since predates task %s's creation at %s", task, isoUTC(created/1000))
	}
	fields := strings.Split(cron, " ")
	minute, _ := cronNumber(fields[0])
	if minute > 59 {
		rateDie("unsupported cron minute: %s", cron)
	}
	var hours map[int]bool
	if fields[1] != "*" {
		if hours, ok = hourList(fields[1]); !ok {
			rateDie("unsupported cron hour list: %s", cron)
		}
	}
	slotList, endBound, msg := rateSlots(minute, hours, w.since, w.until, env.loc)
	if msg != "" {
		if msg == errNoSuccessor {
			msg += cron
		}
		rateDie("%s", msg)
	}

	// Attributable sessions for this task that started in the window. A transcript's mtime is at
	// or after its start, so the mtime cutoff never drops an in-window session.
	files, err := transcripts(w.projects, w.since)
	if err != nil {
		rateDie("could not enumerate transcripts under %s", w.projects)
	}
	attributed := 0
	var starts []int64
	for _, f := range files {
		line, err := env.readHeader(f)
		if err != nil {
			rateDie("could not read a transcript header")
		}
		if !strings.Contains(line, markerNeedle) {
			continue
		}
		// Exactly ONE object: two objects on one line would each yield a task name.
		head, err := decodeAll([]byte(line))
		if err != nil || len(head) != 1 {
			rateDie("a task-marker transcript header is not valid JSON: %s", f)
		}
		if _, ok := head[0].(map[string]any); !ok {
			rateDie("a task-marker transcript header is not valid JSON: %s", f)
		}
		name := attributedTask(head[0], true)
		if name != "" {
			attributed++
		}
		if name != task {
			continue
		}
		ts, _ := field(head[0], "timestamp")
		se, ok := strictInstant(jqRawOrEmpty(ts))
		if !ok {
			rateDie("a %s transcript has no readable start timestamp: %s", task, f)
		}
		if se > w.now+120 {
			rateDie("a %s transcript starts after now: %s", task, f)
		}
		starts = append(starts, se)
	}
	// No attributable transcript for ANY task means the root or its layout is wrong.
	if attributed == 0 {
		rateDie("no transcript under %s in the window is attributable to any scheduled task", w.projects)
	}

	// A slot is DISPATCHED when a session starts in [slot, next slot), and SETTLED only once its
	// successor is at or before --until.
	r := rateResult{cron: cron}
	var lines strings.Builder
	bounds := append(append([]int64{}, slotList...), endBound)
	for i := 1; i < len(bounds); i++ {
		prev, s := bounds[i-1], bounds[i]
		if s > w.until {
			continue
		}
		r.scheduled++
		state := "dropped"
		for _, st := range starts {
			if st >= prev && st < s {
				state = "dispatched"
				r.dispatched++
				break
			}
		}
		fmt.Fprintf(&lines, "%s %s\n", isoUTC(prev), state)
	}
	if r.scheduled == 0 {
		rateDie("no settled slot between --since and --until for %s", cron)
	}
	dropped := r.scheduled - r.dispatched
	r.line = fmt.Sprintf("DISPATCH-RATE task=%s cron=\"%s\" cron_source=current window=%s..%s scheduled=%d dispatched=%d dropped=%d drop_rate=%s%%\n",
		task, cron, isoUTC(w.since), isoUTC(w.until), r.scheduled, r.dispatched, dropped, percent(dropped, r.scheduled))
	r.slotLines = lines.String()
	return r
}

// enabledMatches is `[.scheduledTasks[]? | select(.id == $t and .enabled == true)]`: how many
// records match, the first of them, and an error where jq could not index a record.
func enabledMatches(doc any, task string) (int, map[string]any, error) {
	tasks, err := tasksOf(doc)
	if err != nil {
		return 0, nil, err
	}
	n := 0
	var first map[string]any
	for _, t := range tasks {
		id, ok := field(t, "id")
		if !ok {
			return 0, nil, errIndex
		}
		if id != task {
			continue
		}
		en, _ := field(t, "enabled")
		if isTrue(en) {
			if n == 0 {
				first, _ = t.(map[string]any)
			}
			n++
		}
	}
	return n, first, nil
}

const errNoSuccessor = "could not find the slot after --until for "

// rateSlots enumerates the schedule's slots at or after since and up to until, plus the first
// slot after until, which bounds the last settled interval. hours is nil for an hourly schedule.
//
// It walks absolute hours from the first instant whose LOCAL minute is the cron minute, reading
// each instant's local wall clock from the zone database. Every local hour boundary falls on one of
// those instants while the zone's offset moves in whole hours; a half-hour shift would drift the
// walk off the cron minute, so that is refused rather than measured. The walk starts a day early so
// that a fixed hour which already fired before since (the first half of a fallback) is remembered:
// a fixed-hour schedule fires once per wall-clock hour, so the repeated hour is one slot. An hourly
// schedule fires every absolute hour and is not deduplicated.
func rateSlots(minute int, hours map[int]bool, since, until int64, loc *time.Location) ([]int64, int64, string) {
	local := func(e int64) time.Time { return time.Unix(e, 0).In(loc) }
	matches := func(t time.Time) bool { return hours == nil || hours[t.Hour()] }
	start := since + (60-since%60)%60
	first, found := int64(0), false
	for i := int64(0); i < 60; i++ {
		if local(start+i*60).Minute() == minute {
			first, found = start+i*60, true
			break
		}
	}
	if !found {
		return nil, 0, "no local minute matched the cron minute; the timezone offset is not whole-minute"
	}
	var slots []int64
	seen := map[string]bool{}
	e := first - 25*3600
	for ; e <= until; e += 3600 {
		t := local(e)
		if t.Minute() != minute {
			return nil, 0, "the host timezone offset changed by a non-whole hour inside the window; unsupported"
		}
		if !matches(t) {
			continue
		}
		if hours != nil {
			key := t.Format("2006010215")
			if seen[key] {
				continue
			}
			seen[key] = true
		}
		if e >= since {
			slots = append(slots, e)
		}
	}
	// A fixed hour inside a skipped spring-forward hour does not exist that day, so the next real
	// occurrence can be nearly two days out: the search covers 49 hours.
	for limit := e + 49*3600; e <= limit; e += 3600 {
		t := local(e)
		if t.Minute() != minute {
			return nil, 0, "the host timezone offset changed by a non-whole hour after the window; unsupported"
		}
		if matches(t) {
			return slots, e, ""
		}
	}
	return nil, 0, errNoSuccessor
}
