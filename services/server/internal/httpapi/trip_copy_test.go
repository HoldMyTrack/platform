package httpapi

// Covers docs/SPEC.md FR-13.8 (the copy).

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/export"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/parse"
	"github.com/HoldMyTrack/platform/services/server/internal/tripcopy"
)

// recorded ingests a walk for owner the way an upload does, from a GPX file in the store: 61
// points a minute apart heading east along latitude 50 from lon, so a Private location can clip
// either end.
func (d *dbTest) recorded(s3 *memS3, owner account, name string, start time.Time, lon float64) string {
	d.t.Helper()
	ctx := context.Background()
	points := make([]parse.Point, 61)
	for i := range points {
		points[i] = parse.Point{Lat: 50, Lon: lon + float64(i)*0.001, Time: start.Add(time.Duration(i) * time.Minute)}
	}
	var gpx bytes.Buffer
	if err := export.WriteGPX(&gpx, "walking", points); err != nil {
		d.t.Fatal(err)
	}
	key := fmt.Sprintf("raw/%s/%s.gpx", owner.id, name)
	s3.Put(key, gpx.Bytes())
	res, err := ingest.Process(ctx, d.pool, d.srv.store, ingest.Job{
		UserID: owner.id, Source: "upload", SourceDetail: name + ".gpx", ExternalID: name, RawPayloadKey: key,
	})
	if err != nil {
		d.t.Fatalf("ingest %s: %v", name, err)
	}
	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET name = $2, description = 'Day out' WHERE id = $1`, res.TrackID, name); err != nil {
		d.t.Fatal(err)
	}
	return res.TrackID
}

func (d *dbTest) privateLocation(owner account, lon, lat float64, radiusM int) {
	d.t.Helper()
	if _, err := d.pool.Exec(context.Background(), `
		INSERT INTO privacy_zones (user_id, center, radius_m, name) VALUES ($1, ST_MakePoint($2, $3)::geography, $4, 'Home')`,
		owner.id, lon, lat, radiusM); err != nil {
		d.t.Fatal(err)
	}
}

// sendAndAccept sends the Trip from from to to, accepts it as to and runs the copy job.
func (d *dbTest) sendAndAccept(from, to account, tripID string) {
	d.t.Helper()
	d.decode(d.do(from, "POST", "/v2/trips/"+tripID+"/send", map[string]any{"email": d.address(to)}), http.StatusNoContent, nil)
	sends := d.inbox(to)
	if len(sends) != 1 {
		d.t.Fatalf("inbox %+v, want the one copy", sends)
	}
	d.decode(d.do(to, "POST", "/v2/trip-sends/"+sends[0].ID+"/accept", nil), http.StatusAccepted, nil)
	if err := tripcopy.Process(context.Background(), d.pool, d.srv.store, tripcopy.Job{TripID: tripID, RecipientID: to.id}); err != nil {
		d.t.Fatalf("copy: %v", err)
	}
}

// tripsOf lists the account's Trips, newest first.
func (d *dbTest) tripsOf(as account) []trip {
	d.t.Helper()
	var res tripsResponse
	d.decode(d.do(as, "GET", "/v2/trips", nil), http.StatusOK, &res)
	return res.Trips
}

// copied is one of the recipient's tracks as the copy made it.
type copied struct {
	id, name, origin string
	startLon, endLon float64
}

func (d *dbTest) copiedTrack(id string) copied {
	d.t.Helper()
	var c copied
	if err := d.pool.QueryRow(context.Background(), `
		SELECT id, COALESCE(name, ''), COALESCE(origin_id::text, ''), ST_X(ST_StartPoint(trajectory)), ST_X(ST_EndPoint(trajectory))
		FROM tracks WHERE id = $1`, id).Scan(&c.id, &c.name, &c.origin, &c.startLon, &c.endLon); err != nil {
		d.t.Fatal(err)
	}
	return c
}

func TestTripCopy(t *testing.T) {
	s3 := newMemS3()
	d := newDBTestWithS3(t, s3)
	ctx := context.Background()
	dad, kid := d.newAccount(false), d.newAccount(false)
	day := time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC)

	// Dad's home is at the walk's start, the kid's at its end: the copy is clipped by both.
	d.privateLocation(dad, 10, 50, 150)
	d.privateLocation(kid, 10.06, 50, 150)
	walk := d.recorded(s3, dad, "Ridge", day, 10)
	var p photoJSON
	d.decode(d.uploadPhoto(dad, testJPEG(t, 40, 30), testJPEG(t, 8, 6), map[string]string{"track_id": walk, "route_at": day.Add(30 * time.Minute).Format(time.RFC3339)}), http.StatusCreated, &p)
	trip := d.newTrip(dad, "Alps", walk)

	d.sendAndAccept(dad, kid, trip)
	trips := d.tripsOf(kid)
	if len(trips) != 1 || trips[0].Name != "Alps" || len(trips[0].TrackIDs) != 1 {
		t.Fatalf("kid's trips %+v, want Alps with one track", trips)
	}
	if from := trips[0].From; from == nil || *from != d.address(dad) {
		t.Errorf("from %v, want Dad's address (he has no name set)", from)
	}
	if own := d.tripsOf(dad); own[0].From != nil {
		t.Errorf("Dad's own Trip says it's from %q", *own[0].From)
	}
	got := d.copiedTrack(trips[0].TrackIDs[0])
	if got.name != "Ridge" || got.origin != walk {
		t.Errorf("copy %+v, want Ridge from %s", got, walk)
	}
	if got.startLon < 10.002 || got.endLon > 10.058 {
		t.Errorf("copy runs %v → %v, want both homes clipped off", got.startLon, got.endLon)
	}
	var list photosResponse
	d.decode(d.do(kid, "GET", "/v2/photos?track="+got.id, nil), http.StatusOK, &list)
	if len(list.Photos) != 1 {
		t.Fatalf("copy's photos %+v, want the one", list.Photos)
	}
	var keys int
	d.pool.QueryRow(ctx, `SELECT count(DISTINCT image_key) FROM track_photos WHERE id IN ($1, $2)`, p.ID, list.Photos[0].ID).Scan(&keys)
	if keys != 1 {
		t.Errorf("copied photo has its own files, want the original's")
	}

	// Sent again with a second walk: only the new one arrives, into the same Trip.
	second := d.recorded(s3, dad, "Lake", day.Add(24*time.Hour), 11)
	d.decode(d.do(dad, "POST", "/v2/trips/"+trip+"/tracks", map[string]any{"track_ids": []string{second}}), http.StatusOK, nil)
	d.sendAndAccept(dad, kid, trip)
	trips = d.tripsOf(kid)
	if len(trips) != 1 || len(trips[0].TrackIDs) != 2 {
		t.Fatalf("after the second send: %+v, want one Trip with two tracks", trips)
	}

	// A copy the kid deleted doesn't come back.
	d.decode(d.do(kid, "DELETE", "/v2/tracks/"+got.id, nil), http.StatusNoContent, nil)
	d.sendAndAccept(dad, kid, trip)
	if trips = d.tripsOf(kid); len(trips[0].TrackIDs) != 1 {
		t.Errorf("after deleting a copy and a third send: %d tracks, want 1", len(trips[0].TrackIDs))
	}
	// Its photo files stayed with Dad's row.
	if !s3.Has(photoKey(dad.id, p.ID)) {
		t.Errorf("deleting the copy removed the original's photo")
	}

	// Sent back to Dad: everything in it is his own, so no Trip is made.
	d.sendAndAccept(kid, dad, trips[0].ID)
	if mine := d.tripsOf(dad); len(mine) != 1 {
		t.Errorf("Dad's trips after the kid sent theirs back: %d, want 1", len(mine))
	}

	// The kid deletes their Trip; the next send makes a new one with only what's new.
	d.decode(d.do(kid, "DELETE", "/v2/trips/"+trips[0].ID, nil), http.StatusNoContent, nil)
	third := d.recorded(s3, dad, "Summit", day.Add(48*time.Hour), 12)
	d.decode(d.do(dad, "POST", "/v2/trips/"+trip+"/tracks", map[string]any{"track_ids": []string{third}}), http.StatusOK, nil)
	d.sendAndAccept(dad, kid, trip)
	trips = d.tripsOf(kid)
	if len(trips) != 1 || len(trips[0].TrackIDs) != 1 || d.copiedTrack(trips[0].TrackIDs[0]).origin != third {
		t.Fatalf("after deleting the Trip: %+v, want a new one with only Summit", trips)
	}

	// Dad's edits and deletes don't reach the kid's copies.
	d.decode(d.do(dad, "DELETE", "/v2/tracks/"+third, nil), http.StatusNoContent, nil)
	if trips = d.tripsOf(kid); len(trips[0].TrackIDs) != 1 {
		t.Errorf("Dad's delete reached the kid's copy")
	}
}

// A track hidden by the sender's Private location stays behind, and nothing the recipient
// reads lands near that location: its circle's bbox is the sender's alone.
func TestTripCopyLeavesHiddenTracksBehind(t *testing.T) {
	s3 := newMemS3()
	d := newDBTestWithS3(t, s3)
	ctx := context.Background()
	dad, kid := d.newAccount(false), d.newAccount(false)
	day := time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC)
	walk := d.recorded(s3, dad, "Ridge", day, 10)
	d.privateLocation(dad, 20, 50, 500)
	var home string
	if err := d.pool.QueryRow(ctx, `SELECT id FROM privacy_zones WHERE user_id = $1`, dad.id).Scan(&home); err != nil {
		t.Fatal(err)
	}
	hidden := d.newTrack(dad, testTrack{trackType: "walking", startedAt: day})
	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET hidden_by = $2, raw_payload_key = 'raw/hidden.gpx' WHERE id = $1`, hidden, home); err != nil {
		t.Fatal(err)
	}
	if row := d.track(dad, hidden); row.BBox == nil {
		t.Fatalf("the sender's hidden row has no bbox: %+v", row)
	}
	trip := d.newTrip(dad, "Alps", walk, hidden)

	d.sendAndAccept(dad, kid, trip)
	trips := d.tripsOf(kid)
	if len(trips) != 1 || len(trips[0].TrackIDs) != 1 || d.copiedTrack(trips[0].TrackIDs[0]).origin != walk {
		t.Fatalf("kid's trips %+v, want Alps with Ridge alone", trips)
	}
	for _, row := range d.listTracks(kid) {
		if row.BBox == nil || row.BBox[2] > 15 {
			t.Errorf("kid's row %+v reaches past the walk, toward Dad's home", row)
		}
	}
	var resp areaResponse
	d.decode(d.do(kid, "GET", "/v2/tracks/area?bbox=19.9,49.9,20.1,50.1", nil), http.StatusOK, &resp)
	if len(resp.Tracks) != 0 {
		t.Errorf("kid's view of Dad's home lists %+v", resp.Tracks)
	}
}

func TestTripCopyWaitsForAPendingEdit(t *testing.T) {
	s3 := newMemS3()
	d := newDBTestWithS3(t, s3)
	ctx := context.Background()
	dad, kid := d.newAccount(false), d.newAccount(false)
	walk := d.recorded(s3, dad, "Ridge", time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC), 10)
	trip := d.newTrip(dad, "Alps", walk)
	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET edit_pending = true WHERE id = $1`, walk); err != nil {
		t.Fatal(err)
	}
	d.sendAndAccept(dad, kid, trip)
	if trips := d.tripsOf(kid); len(trips) != 0 {
		t.Errorf("copied mid-edit: %+v", trips)
	}
	var waiting int
	d.pool.QueryRow(ctx, `SELECT count(*) FROM jobs WHERE kind = 'trip_copy' AND user_id = $1 AND run_after > NOW()`, kid.id).Scan(&waiting)
	if waiting != 1 {
		t.Errorf("%d retries queued, want 1", waiting)
	}
}

func TestTripCopyOfAnEmptyTrip(t *testing.T) {
	d := newDBTestWithS3(t, newMemS3())
	dad, kid := d.newAccount(false), d.newAccount(false)
	trip := d.newTrip(dad, "Someday")
	d.sendAndAccept(dad, kid, trip)
	if trips := d.tripsOf(kid); len(trips) != 1 || trips[0].Name != "Someday" {
		t.Errorf("kid's trips %+v, want the empty Someday", trips)
	}
}
