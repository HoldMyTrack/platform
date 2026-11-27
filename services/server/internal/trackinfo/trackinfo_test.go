package trackinfo

import (
	"reflect"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

func ptr[T any](v T) *T { return &v }

func labels(info Info) map[string]string {
	out := map[string]string{}
	for _, l := range info.Lines {
		out[l.Label] = l.Value
	}
	return out
}

var start = time.Date(2026, 9, 27, 5, 12, 0, 0, time.UTC)

func TestOneTrack(t *testing.T) {
	l := i18n.Get("en")
	run := Track{Type: "running", StartedAt: start, Timezone: "Europe/Berlin", DurationSeconds: ptr[int32](5400), MovingSeconds: ptr[int32](4680), DistanceMeters: ptr(14300.0), ElevationGainM: ptr(212.4)}
	got := Of([]Track{run}, l, false)
	want := []Line{
		{"Type", "Running"},
		{"Start", "Sep 27, 2026, 7:12 AM"},
		{"End", "Sep 27, 2026, 8:42 AM"},
		{"Distance", "14.3 km"},
		{"Moving time", "1h 18m"},
		{"Elapsed time", "1h 30m"},
		{"Pace", "5:27 /km"},
		{"Elevation gain", "212 m"},
	}
	if !reflect.DeepEqual(got.Lines, want) {
		t.Errorf("lines\n got %v\nwant %v", got.Lines, want)
	}
	if got.Note != "Moving time leaves out stretches slower than 1.8 km/h." {
		t.Errorf("note %q", got.Note)
	}

	ride := Track{Type: "cycling", StartedAt: start, Timezone: "UTC", DurationSeconds: ptr[int32](3600), DistanceMeters: ptr(32186.88), ElevationGainM: ptr(0.1)}
	got = Of([]Track{ride}, l, true)
	m := labels(got)
	if m["Speed"] != "20.0 mph" || m["Distance"] != "20.0 mi" {
		t.Errorf("imperial ride %v", got.Lines)
	}
	if _, ok := m["Moving time"]; ok || got.Note != "" {
		t.Errorf("no moving time from the source: no line and no note, got %v %q", got.Lines, got.Note)
	}
	if _, ok := m["Elevation gain"]; ok {
		t.Errorf("a gain rounding to 0 is left out: %v", got.Lines)
	}
}

func TestPrivateTrack(t *testing.T) {
	got := Of([]Track{{Type: "hiking", StartedAt: start, Timezone: "UTC", Private: true}}, i18n.Get("en"), false)
	if len(got.Lines) != 2 || got.Lines[0].Label != "Type" || got.Lines[1].Label != "Start" {
		t.Errorf("lines %v, want Type and Start alone", got.Lines)
	}
	if got.Note == "" {
		t.Error("a Private track says why it has nothing else")
	}
}

func TestGroup(t *testing.T) {
	l := i18n.Get("en")
	tracks := []Track{
		{Type: "cycling", StartedAt: start.Add(48 * time.Hour), Timezone: "UTC", DurationSeconds: ptr[int32](3600), MovingSeconds: ptr[int32](3000), DistanceMeters: ptr(20000.0), ElevationGainM: ptr(100.0)},
		{Type: "hiking", StartedAt: start.Add(72 * time.Hour), Timezone: "UTC", Private: true},
		{Type: "walking", StartedAt: start, Timezone: "UTC", DurationSeconds: ptr[int32](1800), DistanceMeters: ptr(2000.0)},
	}
	got := Of(tracks, l, false)
	want := []Line{
		{"Tracks", "3"},
		{"First start", "Sep 27, 2026, 5:12 AM"},
		{"Last end", "Sep 30, 2026, 5:12 AM"},
		{"Distance", "22 km"},
		{"Moving time", "50m"},
		{"Elapsed time", "1h 30m"},
		{"Elevation gain", "100 m"},
	}
	if !reflect.DeepEqual(got.Lines, want) {
		t.Errorf("lines\n got %v\nwant %v", got.Lines, want)
	}
	if got.Note == "" {
		t.Error("a group with moving time has the note")
	}
}

// A group where no source gave moving time shows no Moving time line and no note.
func TestGroupWithoutMovingTime(t *testing.T) {
	l := i18n.Get("en")
	tracks := []Track{
		{Type: "walking", StartedAt: start.Add(time.Hour), Timezone: "UTC", DurationSeconds: ptr[int32](1800), DistanceMeters: ptr(2000.0)},
		{Type: "walking", StartedAt: start, Timezone: "UTC", DurationSeconds: ptr[int32](1800), DistanceMeters: ptr(2000.0)},
	}
	got := Of(tracks, l, false)
	m := labels(got)
	if _, ok := m["Moving time"]; ok || got.Note != "" {
		t.Errorf("no moving time anywhere: got %v, note %q", got.Lines, got.Note)
	}
	if m["Elapsed time"] != "1h 0m" {
		t.Errorf("elapsed: got %q", m["Elapsed time"])
	}
}

func TestRussian(t *testing.T) {
	run := Track{Type: "running", StartedAt: start, Timezone: "UTC", DurationSeconds: ptr[int32](600), MovingSeconds: ptr[int32](600), DistanceMeters: ptr(2000.0)}
	m := labels(Of([]Track{run}, i18n.Get("ru"), false))
	if m["Начало"] != "27 сент. 2026 г., 05:12" || m["Темп"] != "5:00 /км" {
		t.Errorf("ru %v", m)
	}
}
