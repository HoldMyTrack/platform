package httpapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// A caller whose window has passed starts a fresh one, though the stale entries are swept only
// once a window.
func TestLimiterWindowResetsBetweenSweeps(t *testing.T) {
	l := newFixedWindowLimiter(1, time.Hour)
	if !l.allow("k") || l.allow("k") {
		t.Fatal("want the first through and the second refused")
	}
	l.counts["k"].windowFrom = time.Now().Add(-2 * time.Hour) // its window has passed
	l.lastSweep = time.Now()                                  // but no sweep is due
	if !l.allow("k") {
		t.Error("an expired window still refused")
	}
}

// Parallel wrong guesses at one account's password can't get past its limit of 10, and a
// successful sign-in doesn't count against it.
func TestSignInLimitHoldsUnderParallelGuesses(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	a := d.newAccount(false)
	email, _ := d.email(a)
	hash, err := bcrypt.GenerateFromPassword([]byte("right-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.pool.Exec(ctx, `UPDATE users SET password_hash = $2 WHERE id = $1`, a.id, hash); err != nil {
		t.Fatal(err)
	}
	for i := range 5 {
		if _, err := d.srv.checkPassword(ctx, fmt.Sprintf("203.0.113.%d", i), email, "right-password"); err != nil {
			t.Fatalf("right password: %v", err)
		}
	}

	var mu sync.Mutex
	statuses := map[int]int{}
	var wg sync.WaitGroup
	for i := range 30 {
		wg.Go(func() {
			_, err := d.srv.checkPassword(ctx, fmt.Sprintf("198.51.100.%d", i), email, "wrong-password")
			var ae *accountError
			if !errors.As(err, &ae) {
				t.Errorf("guess %d: %v", i, err)
				return
			}
			mu.Lock()
			statuses[ae.status]++
			mu.Unlock()
		})
	}
	wg.Wait()
	if statuses[http.StatusUnauthorized] != 10 || statuses[http.StatusTooManyRequests] != 20 {
		t.Errorf("30 parallel guesses: %v, want 10 checked (401) and 20 refused (429)", statuses)
	}
}

// Deleting one of two activities that share an original keeps it; deleting the other removes it.
func TestActivityDeleteRemovesAnOriginalOnlyWithItsLastActivity(t *testing.T) {
	s3 := newMemS3()
	d := newDBTestWithS3(t, s3)
	ctx := context.Background()
	me := d.newAccount(false)
	first := d.ingestNorth(me, "walk.gpx", 10.0)
	var key string
	if err := d.pool.QueryRow(ctx, `SELECT raw_payload_key FROM activities WHERE id = $1`, first).Scan(&key); err != nil {
		t.Fatal(err)
	}
	// The test ran the ingest itself; a pending job naming the key would keep it.
	if _, err := d.pool.Exec(ctx, `UPDATE jobs SET state = 'done' WHERE user_id = $1`, me.id); err != nil {
		t.Fatal(err)
	}
	var second string
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO activities (user_id, source, external_id, activity_type, started_at, timezone, raw_payload_key)
		VALUES ($1, 'upload', 'copy', 'walking', NOW(), 'UTC', $2) RETURNING id`, me.id, key).Scan(&second); err != nil {
		t.Fatal(err)
	}

	if rec := d.do(me, http.MethodDelete, "/v1/activities/"+first, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete first: %d", rec.Code)
	}
	if !s3.Has(key) {
		t.Fatal("original removed while another activity still names it")
	}
	if rec := d.do(me, http.MethodDelete, "/v1/activities/"+second, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete second: %d", rec.Code)
	}
	if s3.Has(key) {
		t.Error("original kept after its last activity was deleted")
	}
}
