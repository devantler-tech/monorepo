package main

// Cron evaluation for the two shapes the deployment uses: `M * * * *` (hourly at one minute) and
// `M H1,H2,... * * *` (a list of local hours at one minute). Slots are local wall-clock times in the
// host zone. Every conversion between an instant and a wall clock goes through the time package,
// which reads the zone database, so a daylight-saving change (a skipped hour, a repeated hour, a
// half-hour shift) is the zone database's answer and never offset arithmetic done here.

import (
	"strings"
	"time"
)

// cronFields splits on the blanks and tabs `read` splits on.
func cronFields(cron string) []string {
	return strings.FieldsFunc(cron, func(r rune) bool { return r == ' ' || r == '\t' })
}

type schedule struct {
	minute int
	hourly bool
	hours  map[int]bool
}

func (s schedule) matches(t time.Time) bool {
	return t.Second() == 0 && t.Minute() == s.minute && (s.hourly || s.hours[t.Hour()])
}

// parseLivenessCron accepts what claude-lane-liveness.sh's evaluator accepted: one physical line,
// exactly five fields, `*` for day, month and weekday, a minute up to 59, and `*` or a comma list
// of hours up to 23 with no empty member.
func parseLivenessCron(cron string) (schedule, bool) {
	if strings.ContainsAny(cron, "\n\r") {
		return schedule{}, false
	}
	f := cronFields(cron)
	if len(f) != 5 || f[2] != "*" || f[3] != "*" || f[4] != "*" {
		return schedule{}, false
	}
	m, ok := cronNumber(f[0])
	if !ok || m > 59 {
		return schedule{}, false
	}
	s := schedule{minute: m}
	if f[1] == "*" {
		s.hourly = true
		return s, true
	}
	hours, ok := hourList(f[1])
	if !ok {
		return schedule{}, false
	}
	s.hours = hours
	return s, true
}

func hourList(spec string) (map[int]bool, bool) {
	if spec == "" || strings.HasPrefix(spec, ",") || strings.HasSuffix(spec, ",") || strings.Contains(spec, ",,") {
		return nil, false
	}
	hours := map[int]bool{}
	for _, h := range strings.Split(spec, ",") {
		n, ok := cronNumber(h)
		if !ok || n > 23 {
			return nil, false
		}
		hours[n] = true
	}
	return hours, true
}

// wallClockAfter reports whether a's local date and time of day, read as a wall clock, is later
// than b's. During a fallback the repeated hour reads the same on the wall twice; the schedule
// fires on the first of them, so the repeat is not a later slot.
func wallClockAfter(a, b time.Time) bool {
	ay, am, ad := a.Date()
	by, bm, bd := b.Date()
	ka := [...]int{ay, int(am), ad, a.Hour(), a.Minute()}
	kb := [...]int{by, int(bm), bd, b.Hour(), b.Minute()}
	for i := range ka {
		if ka[i] != kb[i] {
			return ka[i] > kb[i]
		}
	}
	return false
}

// nextSlotSearchMinutes bounds the search for the next slot. A listed hour inside a skipped
// spring-forward hour does not exist that day, so its next occurrence can be almost two days out.
const nextSlotSearchMinutes = 50 * 60

// nextSlot returns the first slot strictly after `after`, which must itself be a slot of the
// schedule (the store's lastScheduledFor). It reports false when `after` is not a slot or no slot
// follows within the search bound.
func nextSlot(cron string, after int64, loc *time.Location) (int64, bool) {
	s, ok := parseLivenessCron(cron)
	if !ok {
		return 0, false
	}
	at := time.Unix(after, 0).In(loc)
	if !s.matches(at) {
		return 0, false
	}
	if s.hourly {
		return after + 3600, true
	}
	for i := int64(1); i <= nextSlotSearchMinutes; i++ {
		c := time.Unix(after+i*60, 0).In(loc)
		if s.matches(c) && wallClockAfter(c, at) {
			return after + i*60, true
		}
	}
	return 0, false
}
