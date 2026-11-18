package httpapi

// Covers docs/SPEC.md FR-13.2–FR-13.5 (Trips).

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"
)

func intPtr(v int) *int { return &v }

func TestTripsLifecycle(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	walk := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 3000, movingSeconds: intPtr(1800), durationSecs: 2000,
		startedAt: time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)})
	driveThere := d.newTrack(me, testTrack{trackType: "driving", distanceMeters: 40000, movingSeconds: intPtr(2400), durationSecs: 2600,
		startedAt: time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC)})
	// No moving time recorded: counts its elapsed time as moving, as Trends does.
	driveBack := d.newTrack(me, testTrack{trackType: "driving", distanceMeters: 41000, durationSecs: 2700,
		startedAt: time.Date(2026, 5, 1, 15, 0, 0, 0, time.UTC)})

	var created trip
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{
		"name": "  Brecksville  ", "description": "The reservation trip",
		"track_ids": []string{walk, driveThere, strings.ToUpper(walk)},
	}), http.StatusCreated, &created)
	if created.Name != "Brecksville" || created.Description == nil || *created.Description != "The reservation trip" {
		t.Errorf("created %q / %v", created.Name, created.Description)
	}
	if want := []string{driveThere, walk}; !slices.Equal(created.TrackIDs, want) {
		t.Errorf("activity_ids %v, want %v (oldest first)", created.TrackIDs, want)
	}

	var got trip
	d.decode(d.do(me, "POST", "/v2/trips/"+created.ID+"/tracks", map[string]any{
		"track_ids": []string{driveBack, walk},
	}), http.StatusOK, &got)
	if len(got.TrackIDs) != 3 {
		t.Errorf("after add: %d members, want 3", len(got.TrackIDs))
	}
	if !got.UpdatedAt.After(created.UpdatedAt) {
		t.Errorf("adding members didn't move updated_at")
	}
	wantStats := tripStats{Count: 3, DistanceMeters: 84000, MovingSeconds: 1800 + 2400 + 2700, ElapsedSeconds: 2000 + 2600 + 2700,
		ByType: []tripTypeStats{
			{TrackType: "driving", Label: "Driving", Count: 2, DistanceMeters: 81000, MovingSeconds: 5100, ElapsedSeconds: 5300},
			{TrackType: "walking", Label: "Walking", Count: 1, DistanceMeters: 3000, MovingSeconds: 1800, ElapsedSeconds: 2000},
		}}
	if !tripStatsEqual(got.Stats, wantStats) {
		t.Errorf("stats %+v, want %+v", got.Stats, wantStats)
	}

	d.decode(d.do(me, "PATCH", "/v2/trips/"+created.ID, map[string]any{"name": "Brecksville Reservation", "description": ""}), http.StatusOK, &got)
	if got.Name != "Brecksville Reservation" || got.Description != nil {
		t.Errorf("after rename: %q / %v", got.Name, got.Description)
	}

	d.decode(d.do(me, "DELETE", "/v2/trips/"+created.ID+"/tracks", map[string]any{
		"track_ids": []string{driveBack, "00000000-0000-0000-0000-000000000000"},
	}), http.StatusOK, &got)
	if want := []string{driveThere, walk}; !slices.Equal(got.TrackIDs, want) {
		t.Errorf("after remove: %v, want %v", got.TrackIDs, want)
	}

	var other trip
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Empty"}), http.StatusCreated, &other)
	var list tripsResponse
	d.decode(d.do(me, "GET", "/v2/trips", nil), http.StatusOK, &list)
	if len(list.Trips) != 2 || list.Trips[0].ID != other.ID || list.Trips[1].ID != created.ID {
		t.Fatalf("list %+v, want the two Stories newest first", list.Trips)
	}
	if list.Trips[0].TrackIDs == nil || list.Trips[0].Stats.ByType == nil {
		t.Errorf("an empty Story's lists should be [], not null")
	}
	d.decode(d.do(me, "GET", "/v2/trips/"+created.ID, nil), http.StatusOK, &got)
	if got.Name != "Brecksville Reservation" || len(got.TrackIDs) != 2 {
		t.Errorf("get: %+v", got)
	}

	d.decode(d.do(me, "DELETE", "/v2/trips/"+created.ID, nil), http.StatusNoContent, nil)
	d.decode(d.do(me, "GET", "/v2/trips/"+created.ID, nil), http.StatusNotFound, nil)
	// Deleting a Trip deletes none of its tracks.
	var n int
	if err := d.pool.QueryRow(context.Background(), `SELECT count(*) FROM tracks WHERE user_id = $1`, me.id).Scan(&n); err != nil || n != 3 {
		t.Errorf("activities after deleting the Story: %d (%v), want 3", n, err)
	}
}

func tripStatsEqual(a, b tripStats) bool {
	return a.Count == b.Count && a.DistanceMeters == b.DistanceMeters && a.MovingSeconds == b.MovingSeconds &&
		a.ElapsedSeconds == b.ElapsedSeconds && slices.Equal(a.ByType, b.ByType)
}

func TestTripsValidation(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	var st trip
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Trip"}), http.StatusCreated, &st)

	for _, tc := range []struct {
		name, method, path string
		body               any
	}{
		{"blank name", "POST", "/v2/trips", map[string]any{"name": "   "}},
		{"long name", "POST", "/v2/trips", map[string]any{"name": strings.Repeat("я", maxTripNameLen+1)}},
		{"long description", "POST", "/v2/trips", map[string]any{"name": "a", "description": strings.Repeat("x", maxTripDescriptionLen+1)}},
		{"malformed activity id", "POST", "/v2/trips", map[string]any{"name": "a", "track_ids": []string{"nope"}}},
		{"blank rename", "PATCH", "/v2/trips/" + st.ID, map[string]any{"name": ""}},
		{"no ids to add", "POST", "/v2/trips/" + st.ID + "/tracks", map[string]any{"track_ids": []string{}}},
		{"no ids to remove", "DELETE", "/v2/trips/" + st.ID + "/tracks", map[string]any{}},
		{"not JSON", "POST", "/v2/trips", "{"},
	} {
		if rec := d.do(me, tc.method, tc.path, tc.body); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", tc.name, rec.Code)
		}
	}
	// A name of exactly the maximum, counted in characters rather than bytes, is fine.
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": strings.Repeat("я", maxTripNameLen)}), http.StatusCreated, nil)
	if rec := d.do(account{}, "GET", "/v2/trips", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("signed out: status %d, want 401", rec.Code)
	}
}

// Another account's Trip is a 404 on every route, the same as one that doesn't exist, and
// another account's track can't be put in a Trip.
func TestTripsOwnership(t *testing.T) {
	d := newDBTest(t)
	owner, other := d.newAccount(false), d.newAccount(false)
	ownerTrack := d.newTrack(owner, testTrack{trackType: "hiking", distanceMeters: 5000, durationSecs: 3600})
	otherTrack := d.newTrack(other, testTrack{trackType: "hiking", distanceMeters: 5000, durationSecs: 3600})
	var theirs, mine trip
	d.decode(d.do(owner, "POST", "/v2/trips", map[string]any{"name": "Owner's", "track_ids": []string{ownerTrack}}), http.StatusCreated, &theirs)
	d.decode(d.do(other, "POST", "/v2/trips", map[string]any{"name": "Other's"}), http.StatusCreated, &mine)

	missing := "/v2/trips/00000000-0000-0000-0000-000000000000"
	for _, path := range []string{"/v2/trips/" + theirs.ID, missing, "/v2/trips/not-a-uuid"} {
		for _, tc := range []struct {
			method, suffix string
			body           any
		}{
			{"GET", "", nil},
			{"PATCH", "", map[string]any{"name": "Taken"}},
			{"DELETE", "", nil},
			{"POST", "/tracks", map[string]any{"track_ids": []string{otherTrack}}},
			{"DELETE", "/tracks", map[string]any{"track_ids": []string{ownerTrack}}},
		} {
			if rec := d.do(other, tc.method, path+tc.suffix, tc.body); rec.Code != http.StatusNotFound {
				t.Errorf("%s %s%s: status %d, want 404", tc.method, path, tc.suffix, rec.Code)
			}
		}
	}
	var got trip
	d.decode(d.do(owner, "GET", "/v2/trips/"+theirs.ID, nil), http.StatusOK, &got)
	if got.Name != "Owner's" || !slices.Equal(got.TrackIDs, []string{ownerTrack}) {
		t.Errorf("owner's Story changed: %+v", got)
	}

	var list tripsResponse
	d.decode(d.do(other, "GET", "/v2/trips", nil), http.StatusOK, &list)
	if len(list.Trips) != 1 || list.Trips[0].ID != mine.ID {
		t.Errorf("other's list %+v, want only their own Story", list.Trips)
	}

	// Someone else's track: all or nothing, and a 404 like a missing one.
	if rec := d.do(other, "POST", "/v2/trips/"+mine.ID+"/tracks", map[string]any{"track_ids": []string{otherTrack, ownerTrack}}); rec.Code != http.StatusNotFound {
		t.Errorf("adding someone else's activity: status %d, want 404", rec.Code)
	}
	d.decode(d.do(other, "GET", "/v2/trips/"+mine.ID, nil), http.StatusOK, &got)
	if len(got.TrackIDs) != 0 {
		t.Errorf("a rejected add left members %v", got.TrackIDs)
	}
	if rec := d.do(other, "POST", "/v2/trips", map[string]any{"name": "Sneaky", "track_ids": []string{ownerTrack}}); rec.Code != http.StatusNotFound {
		t.Errorf("creating with someone else's activity: status %d, want 404", rec.Code)
	}
	d.decode(d.do(other, "GET", "/v2/trips", nil), http.StatusOK, &list)
	if len(list.Trips) != 1 {
		t.Errorf("a rejected create left a Story behind: %+v", list.Trips)
	}
}

// A demo account reads its Trips but every write is refused, as for every other write.
func TestTripsDemoReadOnly(t *testing.T) {
	d := newDBTest(t)
	demo := d.newAccount(true)
	track := d.newTrack(demo, testTrack{trackType: "walking", distanceMeters: 1000, durationSecs: 600})
	var tripID string
	if err := d.pool.QueryRow(context.Background(),
		`INSERT INTO trips (user_id, name) VALUES ($1, 'Seeded') RETURNING id`, demo.id).Scan(&tripID); err != nil {
		t.Fatal(err)
	}
	if _, err := d.pool.Exec(context.Background(),
		`INSERT INTO trip_tracks (trip_id, track_id) VALUES ($1, $2)`, tripID, track); err != nil {
		t.Fatal(err)
	}

	var list tripsResponse
	d.decode(d.do(demo, "GET", "/v2/trips", nil), http.StatusOK, &list)
	if len(list.Trips) != 1 || list.Trips[0].Stats.Count != 1 {
		t.Errorf("demo list %+v", list.Trips)
	}
	d.decode(d.do(demo, "GET", "/v2/trips/"+tripID, nil), http.StatusOK, nil)

	ids := map[string]any{"track_ids": []string{track}}
	for _, tc := range []struct {
		method, path string
		body         any
	}{
		{"POST", "/v2/trips", map[string]any{"name": "Mine"}},
		{"PATCH", "/v2/trips/" + tripID, map[string]any{"name": "Renamed"}},
		{"DELETE", "/v2/trips/" + tripID, nil},
		{"POST", "/v2/trips/" + tripID + "/tracks", ids},
		{"DELETE", "/v2/trips/" + tripID + "/tracks", ids},
	} {
		var body struct{ Error string }
		d.decode(d.do(demo, tc.method, tc.path, tc.body), http.StatusForbidden, &body)
		if body.Error != "demo_read_only" {
			t.Errorf("%s %s: error %q, want demo_read_only", tc.method, tc.path, body.Error)
		}
	}
	var got trip
	d.decode(d.do(demo, "GET", "/v2/trips/"+tripID, nil), http.StatusOK, &got)
	if got.Name != "Seeded" || !slices.Equal(got.TrackIDs, []string{track}) {
		t.Errorf("demo Story changed: %+v", got)
	}
	d.decode(d.do(demo, "GET", "/v2/trips", nil), http.StatusOK, &list)
	if len(list.Trips) != 1 {
		t.Errorf("demo has %d Stories, want 1", len(list.Trips))
	}
}

// Deleting a track takes it out of every Trip holding it; the Trips stay, even once
// empty.
func TestTrackDeleteLeavesTrips(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	first := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 1000, durationSecs: 600})
	second := d.newTrack(me, testTrack{trackType: "cycling", distanceMeters: 9000, durationSecs: 1800,
		startedAt: time.Date(2026, 5, 2, 10, 0, 0, 0, time.UTC)})
	var both, onlyFirst trip
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Both", "track_ids": []string{first, second}}), http.StatusCreated, &both)
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Only first", "track_ids": []string{first}}), http.StatusCreated, &onlyFirst)

	d.decode(d.do(me, "DELETE", "/v2/tracks/"+first, nil), http.StatusNoContent, nil)

	var got trip
	d.decode(d.do(me, "GET", "/v2/trips/"+both.ID, nil), http.StatusOK, &got)
	if !slices.Equal(got.TrackIDs, []string{second}) || got.Stats.Count != 1 || got.Stats.DistanceMeters != 9000 {
		t.Errorf("Story with both after deleting one: %+v", got)
	}
	d.decode(d.do(me, "GET", "/v2/trips/"+onlyFirst.ID, nil), http.StatusOK, &got)
	if len(got.TrackIDs) != 0 || got.Stats.Count != 0 || len(got.Stats.ByType) != 0 || got.Name != "Only first" {
		t.Errorf("Story left empty: %+v", got)
	}
}

// Each row of the track list names the Trips it's in, newest first — the Tracks
// panel's Trip badge — and a track in none has an empty list, not null.
func TestTrackListNamesTrips(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	inTwo := d.newTrack(me, testTrack{trackType: "walking", durationSecs: 60})
	inNone := d.newTrack(me, testTrack{trackType: "walking", durationSecs: 60,
		startedAt: time.Date(2026, 5, 2, 10, 0, 0, 0, time.UTC)})
	var older, newer trip
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Older", "track_ids": []string{inTwo}}), http.StatusCreated, &older)
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Newer", "track_ids": []string{inTwo}}), http.StatusCreated, &newer)

	var resp tracksResponse
	d.decode(d.do(me, "GET", "/v2/tracks", nil), http.StatusOK, &resp)
	got := map[string][]tripRef{}
	for _, a := range resp.Tracks {
		got[a.ID] = a.Trips
	}
	if want := []tripRef{{newer.ID, "Newer"}, {older.ID, "Older"}}; !slices.Equal(got[inTwo], want) {
		t.Errorf("stories of the activity in two: %v, want %v", got[inTwo], want)
	}
	if s, ok := got[inNone]; !ok || s == nil || len(s) != 0 {
		t.Errorf("stories of the activity in none: %v (present %v), want []", s, ok)
	}

	// PATCH answers with the same row.
	var row trackRow
	d.decode(d.do(me, "PATCH", "/v2/tracks/"+inTwo, map[string]any{"track_type": "hiking"}), http.StatusOK, &row)
	if len(row.Trips) != 2 {
		t.Errorf("PATCH row stories: %v", row.Trips)
	}
}

// The demo seed's Trips (seedDemoTrips): created by name, then held to the manifest on
// every re-run — its description and exactly its tracks — with the tile version bumped only
// when a Trip's tracks actually changed.
func TestSeedDemoTrips(t *testing.T) {
	d := newDBTest(t)
	acct := d.newAccount(false)
	ctx := context.Background()
	a := d.newTrack(acct, testTrack{trackType: "driving", durationSecs: 60})
	b := d.newTrack(acct, testTrack{trackType: "walking", durationSecs: 60})
	// c a week later: its Trip, second in the manifest, was made later and is listed first.
	c := d.newTrack(acct, testTrack{trackType: "cycling", durationSecs: 60, startedAt: time.Date(2026, 5, 8, 10, 0, 0, 0, time.UTC)})
	ids := map[string]string{"a.gpx": a, "b.gpx": b, "c.gpx": c}
	manifest := []demoManifestTrip{
		{Name: "Trip", Description: "Weekend", Tracks: []string{"a.gpx", "b.gpx"}},
		{Name: "Trail", Tracks: []string{"c.gpx"}},
	}
	version := func() int64 {
		var v int64
		if err := d.pool.QueryRow(ctx, `SELECT map_version FROM users WHERE id = $1`, acct.id).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	trips := func() map[string]trip {
		var list tripsResponse
		d.decode(d.do(acct, "GET", "/v2/trips", nil), http.StatusOK, &list)
		out := map[string]trip{}
		for _, s := range list.Trips {
			out[s.Name] = s
		}
		return out
	}

	v0 := version()
	if err := seedDemoTrips(ctx, d.pool, acct.id, manifest, ids); err != nil {
		t.Fatal(err)
	}
	got := trips()
	if len(got) != 2 || len(got["Trip"].TrackIDs) != 2 || *got["Trip"].Description != "Weekend" ||
		got["Trail"].Description != nil || !slices.Equal(got["Trail"].TrackIDs, []string{c}) {
		t.Fatalf("first seed: %+v", got)
	}
	if version() == v0 {
		t.Errorf("creating Stories with activities didn't bump the tile version")
	}
	// Each dated the day after its last track ended, so listed in the order visited.
	var list tripsResponse
	d.decode(d.do(acct, "GET", "/v2/trips", nil), http.StatusOK, &list)
	if len(list.Trips) != 2 || list.Trips[0].Name != "Trail" ||
		!list.Trips[0].CreatedAt.Equal(time.Date(2026, 5, 9, 10, 1, 0, 0, time.UTC)) ||
		!list.Trips[1].CreatedAt.Equal(time.Date(2026, 5, 2, 10, 1, 0, 0, time.UTC)) {
		t.Errorf("stories not dated by their visits: %+v", list.Trips)
	}

	// A re-run over an unchanged account changes nothing, and bumps nothing.
	v1 := version()
	if err := seedDemoTrips(ctx, d.pool, acct.id, manifest, ids); err != nil {
		t.Fatal(err)
	}
	if again := trips(); len(again) != 2 || again["Trip"].ID != got["Trip"].ID || version() != v1 {
		t.Errorf("re-run: %+v, version %d → %d", again, v1, version())
	}

	// Drift — an extra track, a lost one, another description — is put back.
	d.decode(d.do(acct, "POST", "/v2/trips/"+got["Trip"].ID+"/tracks", map[string]any{"track_ids": []string{c}}), http.StatusOK, nil)
	d.decode(d.do(acct, "DELETE", "/v2/trips/"+got["Trip"].ID+"/tracks", map[string]any{"track_ids": []string{a}}), http.StatusOK, nil)
	d.decode(d.do(acct, "PATCH", "/v2/trips/"+got["Trip"].ID, map[string]any{"name": "Trip", "description": "Edited"}), http.StatusOK, nil)
	if err := seedDemoTrips(ctx, d.pool, acct.id, manifest, ids); err != nil {
		t.Fatal(err)
	}
	fixed := trips()["Trip"]
	held := slices.Clone(fixed.TrackIDs)
	slices.Sort(held)
	want := []string{a, b}
	slices.Sort(want)
	if !slices.Equal(held, want) || *fixed.Description != "Weekend" {
		t.Errorf("drift not fixed: %+v", fixed)
	}

	// The Trip that opens first is dated a day after every other, so it lists first, on every run.
	manifest[0].OpensFirst = true
	for range 2 {
		if err := seedDemoTrips(ctx, d.pool, acct.id, manifest, ids); err != nil {
			t.Fatal(err)
		}
		d.decode(d.do(acct, "GET", "/v2/trips", nil), http.StatusOK, &list)
		if len(list.Trips) != 2 || list.Trips[0].Name != "Trip" ||
			!list.Trips[0].CreatedAt.Equal(time.Date(2026, 5, 10, 10, 1, 0, 0, time.UTC)) {
			t.Errorf("opening first: %+v", list.Trips)
		}
	}
	// Already the newest by its own tracks, it keeps that date: never before its own trip.
	manifest[0].OpensFirst, manifest[1].OpensFirst = false, true
	if err := seedDemoTrips(ctx, d.pool, acct.id, manifest, ids); err != nil {
		t.Fatal(err)
	}
	d.decode(d.do(acct, "GET", "/v2/trips", nil), http.StatusOK, &list)
	if len(list.Trips) != 2 || list.Trips[0].Name != "Trail" ||
		!list.Trips[0].CreatedAt.Equal(time.Date(2026, 5, 9, 10, 1, 0, 0, time.UTC)) {
		t.Errorf("opening first, already newest: %+v", list.Trips)
	}
}
