package main

import (
	"strings"
	"testing"
	"time"
)

func mustZone(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("zone database has no %s: %v", name, err)
	}
	return loc
}

func utc(t *testing.T, s string) int64 {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return v.Unix()
}

// The next slot after a schedule anchor, across the daylight-saving cases the zone database has to
// answer: a skipped hour, a repeated hour and a zone whose offset is (and changes by) half an hour.
func TestNextSlotAcrossZoneChanges(t *testing.T) {
	cases := []struct {
		name, zone, cron, after, want string
	}{
		{"spring-forward gap: the nonexistent 02:30 is skipped for the configured 14:30",
			"Europe/Copenhagen", "30 2,14 * * *", "2026-03-28T13:30:00Z", "2026-03-29T12:30:00Z"},
		{"spring-forward gap: the day after the gap has its 02:30 again",
			"Europe/Copenhagen", "30 2 * * *", "2026-03-28T01:30:00Z", "2026-03-30T00:30:00Z"},
		{"fall-back repeat: the first 02:00 is the slot",
			"Europe/Copenhagen", "0 2 * * *", "2026-10-24T00:00:00Z", "2026-10-25T00:00:00Z"},
		{"fall-back repeat: the repeated 02:00 is not a second slot",
			"Europe/Copenhagen", "0 2 * * *", "2026-10-25T00:00:00Z", "2026-10-26T01:00:00Z"},
		{"fall-back repeat: the next listed hour follows the first 02:30",
			"Europe/Copenhagen", "30 2,3 * * *", "2026-10-25T00:30:00Z", "2026-10-25T02:30:00Z"},
		{"fall-back: noon is thirteen real hours after midnight",
			"Europe/Copenhagen", "0 0,12 * * *", "2026-10-24T22:00:00Z", "2026-10-25T11:00:00Z"},
		{"half-hour zone: a fixed offset of +05:30",
			"Asia/Kolkata", "20 9,21 * * *", "2026-06-01T03:50:00Z", "2026-06-01T15:50:00Z"},
		{"half-hour DST shift: the repeated 01:45 is skipped for 02:45",
			"Australia/Lord_Howe", "45 1,2 * * *", "2026-04-04T14:45:00Z", "2026-04-04T16:15:00Z"},
		{"half-hour DST start: 02:15 does not exist, 03:15 is next",
			"Australia/Lord_Howe", "15 1,2,3 * * *", "2026-10-03T14:45:00Z", "2026-10-03T16:15:00Z"},
		{"hourly: one absolute hour later",
			"Europe/Copenhagen", "0 * * * *", "2026-10-25T00:00:00Z", "2026-10-25T01:00:00Z"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := nextSlot(c.cron, utc(t, c.after), mustZone(t, c.zone))
			if !ok {
				t.Fatalf("no next slot")
			}
			if want := utc(t, c.want); got != want {
				t.Fatalf("next slot %s, want %s", isoUTC(got), c.want)
			}
		})
	}
}

func TestNextSlotRefusesWhatItCannotProve(t *testing.T) {
	cph := mustZone(t, "Europe/Copenhagen")
	cases := []struct{ name, cron, after string }{
		{"an anchor with nonzero seconds", "0 * * * *", "2026-06-01T10:00:59Z"},
		{"an anchor off the cron minute", "30 * * * *", "2026-06-01T10:00:00Z"},
		{"an anchor outside the hour list", "0 1,2 * * *", "2026-06-01T10:00:00Z"},
		{"a multi-line expression", "0 * * * *\ninvalid", "2026-06-01T10:00:00Z"},
		{"a step expression", "*/5 * * * *", "2026-06-01T10:00:00Z"},
		{"a sixth field", "0 * * * * *", "2026-06-01T10:00:00Z"},
		{"an empty hour list member", "0 1,,2 * * *", "2026-06-01T23:00:00Z"},
		{"an hour out of range after a valid one", "0 1,24 * * *", "2026-06-01T23:00:00Z"},
		{"a minute out of range", "60 * * * *", "2026-06-01T10:00:00Z"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got, ok := nextSlot(c.cron, utc(t, c.after), cph); ok {
				t.Fatalf("accepted, next slot %s", isoUTC(got))
			}
		})
	}
}

func TestRateSlotsAcrossZoneChanges(t *testing.T) {
	cases := []struct {
		name, zone   string
		minute       int
		hours        []int
		since, until string
		want         []string
		end          string
		err          string
	}{
		{name: "spring-forward gap: the successor is the next day that has 02:30",
			zone: "Europe/Copenhagen", minute: 30, hours: []int{2},
			since: "2026-03-27T00:00:00Z", until: "2026-03-28T03:00:00Z",
			want: []string{"2026-03-27T01:30:00Z", "2026-03-28T01:30:00Z"}, end: "2026-03-30T00:30:00Z"},
		{name: "fall-back repeat: the repeated 02:30 is one slot",
			zone: "Europe/Copenhagen", minute: 30, hours: []int{2},
			since: "2026-10-24T00:00:00Z", until: "2026-10-26T12:00:00Z",
			want: []string{"2026-10-24T00:30:00Z", "2026-10-25T00:30:00Z", "2026-10-26T01:30:00Z"}, end: "2026-10-27T01:30:00Z"},
		{name: "fall-back repeat: a since between the two occurrences sees no slot that day",
			zone: "Europe/Copenhagen", minute: 30, hours: []int{2},
			since: "2026-10-25T01:00:00Z", until: "2026-10-26T12:00:00Z",
			want: []string{"2026-10-26T01:30:00Z"}, end: "2026-10-27T01:30:00Z"},
		{name: "fall-back: an hourly schedule fires every absolute hour",
			zone: "Europe/Copenhagen", minute: 30,
			since: "2026-10-25T00:00:00Z", until: "2026-10-25T02:00:00Z",
			want: []string{"2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z"}, end: "2026-10-25T02:30:00Z"},
		{name: "half-hour zone: a fixed +05:30 offset keeps the local minute",
			zone: "Asia/Kolkata", minute: 50,
			since: "2026-06-01T00:00:00Z", until: "2026-06-01T03:00:00Z",
			want: []string{"2026-06-01T00:20:00Z", "2026-06-01T01:20:00Z", "2026-06-01T02:20:00Z"}, end: "2026-06-01T03:20:00Z"},
		{name: "half-hour DST shift inside the window is refused",
			zone: "Australia/Lord_Howe", minute: 50,
			since: "2026-04-04T12:00:00Z", until: "2026-04-04T18:00:00Z",
			err: "non-whole hour inside the window"},
		{name: "half-hour DST shift just after the window is refused",
			zone: "Australia/Lord_Howe", minute: 50,
			since: "2026-04-04T10:00:00Z", until: "2026-04-04T14:55:00Z",
			err: "non-whole hour after the window"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var hours map[int]bool
			if c.hours != nil {
				hours = map[int]bool{}
				for _, h := range c.hours {
					hours[h] = true
				}
			}
			slots, end, msg := rateSlots(c.minute, hours, utc(t, c.since), utc(t, c.until), mustZone(t, c.zone))
			if c.err != "" {
				if !strings.Contains(msg, c.err) {
					t.Fatalf("error %q, want one containing %q", msg, c.err)
				}
				return
			}
			if msg != "" {
				t.Fatalf("unexpected error %q", msg)
			}
			var got []string
			for _, s := range slots {
				got = append(got, isoUTC(s))
			}
			if strings.Join(got, " ") != strings.Join(c.want, " ") {
				t.Fatalf("slots %v, want %v", got, c.want)
			}
			if isoUTC(end) != c.end {
				t.Fatalf("successor %s, want %s", isoUTC(end), c.end)
			}
		})
	}
}

func TestInstantsAreReadStrictly(t *testing.T) {
	for raw, want := range map[string]bool{
		"2026-09-01T00:00:00Z":      true,
		"2026-09-01T00:00:00.123Z":  true,
		"2026-09-01T00:00:00.x1Z":   false,
		"2026-09-01T02:00:00+02:00": false,
		"2026-02-30T00:00:00Z":      false,
		"1969-12-31T23:59:59Z":      false,
	} {
		if _, ok := strictInstant(raw); ok != want {
			t.Errorf("strictInstant(%q) = %v, want %v", raw, ok, want)
		}
	}
	// The liveness reading keeps claude-lane-liveness.sh's: everything from the first dot is
	// dropped, so an offset after a fraction is not read.
	if e, ok := livenessInstant("2026-09-01T00:00:00.000+02:00"); !ok || isoUTC(e) != "2026-09-01T00:00:00Z" {
		t.Errorf("livenessInstant with a fraction = %v %v", e, ok)
	}
	if _, ok := livenessInstant("2026-09-01T00:00:00+02:00"); ok {
		t.Errorf("livenessInstant accepted an offset without a fraction")
	}
}
