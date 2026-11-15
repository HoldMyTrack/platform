package httpapi

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// slowKeySet serves k1 once at once, then holds every later fetch until release is closed,
// telling started as each begins.
func slowKeySet(t *testing.T, key *rsa.PublicKey) (url string, started chan struct{}, release chan struct{}, fetches *atomic.Int32) {
	t.Helper()
	started, release, fetches = make(chan struct{}, 16), make(chan struct{}), &atomic.Int32{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fetches.Add(1) > 1 {
			started <- struct{}{}
			<-release
		}
		json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kid": "k1", "kty": "RSA",
			"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}}})
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	return srv.URL, started, release, fetches
}

// A token whose key is cached is checked while a fetch for an unknown kid hangs.
func TestJWKSCachedKeyDoesNotWaitOnAFetch(t *testing.T) {
	url, started, _, _ := slowKeySet(t, &newRSAKey(t).PublicKey)
	k := newJWKSKeySet(url, http.DefaultClient)
	now := time.Now()
	if _, err := k.key(context.Background(), "k1", now); err != nil {
		t.Fatal(err)
	}

	later := now.Add(jwksRefetchGap + time.Second)
	go k.key(context.Background(), "k2", later)
	<-started

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := k.key(ctx, "k1", later); err != nil {
		t.Fatalf("cached key during a hanging fetch: %v", err)
	}
}

// Callers that miss the cache together make one fetch between them.
func TestJWKSWaitersShareAFetch(t *testing.T) {
	url, started, release, fetches := slowKeySet(t, &newRSAKey(t).PublicKey)
	k := newJWKSKeySet(url, http.DefaultClient)
	now := time.Now()
	if _, err := k.key(context.Background(), "k1", now); err != nil {
		t.Fatal(err)
	}

	expired := now.Add(2 * jwksDefaultTTL)
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := k.key(context.Background(), "k1", expired)
			errs <- err
		}()
	}
	<-started
	time.Sleep(50 * time.Millisecond) // the other callers reach the wait
	close(release)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Errorf("waiter: %v", err)
		}
	}
	if got := fetches.Load(); got != 2 {
		t.Errorf("%d fetches, want 2: the first, and one for all eight waiters", got)
	}
}

// A caller waiting on another's fetch gives up with its context.
func TestJWKSWaitStopsWithTheContext(t *testing.T) {
	url, started, _, _ := slowKeySet(t, &newRSAKey(t).PublicKey)
	k := newJWKSKeySet(url, http.DefaultClient)
	now := time.Now()
	if _, err := k.key(context.Background(), "k1", now); err != nil {
		t.Fatal(err)
	}
	expired := now.Add(2 * jwksDefaultTTL)
	go k.key(context.Background(), "k1", expired)
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := k.key(ctx, "k1", expired); err != context.DeadlineExceeded {
		t.Errorf("waiting past the context: %v, want DeadlineExceeded", err)
	}
}

// A caller whose shared fetch failed fetches again rather than being refused, and one caller
// giving up doesn't fail the fetch it started for the others.
func TestJWKSWaitersSurviveTheFetchersCancel(t *testing.T) {
	url, started, release, fetches := slowKeySet(t, &newRSAKey(t).PublicKey)
	k := newJWKSKeySet(url, http.DefaultClient)
	now := time.Now()
	if _, err := k.key(context.Background(), "k1", now); err != nil {
		t.Fatal(err)
	}
	expired := now.Add(2 * jwksDefaultTTL)
	ctx, cancel := context.WithCancel(context.Background())
	first := make(chan error, 1)
	go func() {
		_, err := k.key(ctx, "k1", expired)
		first <- err
	}()
	<-started
	waiter := make(chan error, 1)
	go func() {
		_, err := k.key(context.Background(), "k1", expired)
		waiter <- err
	}()
	time.Sleep(50 * time.Millisecond) // the waiter reaches the wait
	cancel()
	close(release)
	if err := <-waiter; err != nil {
		t.Errorf("waiter after the fetcher's caller gave up: %v", err)
	}
	<-first
	if got := fetches.Load(); got != 2 {
		t.Errorf("%d fetches, want 2: the waiter used the one it waited on", got)
	}
}

// Callers that waited on a failed fetch share its failure; the next caller fetches again.
func TestJWKSWaitersShareAFailedFetch(t *testing.T) {
	key := &newRSAKey(t).PublicKey
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 2 {
			time.Sleep(100 * time.Millisecond)
			http.Error(w, "down", http.StatusBadGateway)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kid": "k1", "kty": "RSA",
			"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}}})
	}))
	t.Cleanup(srv.Close)
	k := newJWKSKeySet(srv.URL, http.DefaultClient)
	now := time.Now()
	if _, err := k.key(context.Background(), "k1", now); err != nil {
		t.Fatal(err)
	}
	expired := now.Add(2 * jwksDefaultTTL)
	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := k.key(context.Background(), "k1", expired)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err == nil {
			t.Error("a caller succeeded although the one fetch it could share failed")
		}
	}
	if got := calls.Load(); got != 2 {
		t.Errorf("%d fetches, want 2: the first, and one failed fetch for all four callers", got)
	}
	if _, err := k.key(context.Background(), "k1", expired); err != nil {
		t.Errorf("next caller after the failure: %v, want its own fetch to succeed", err)
	}
}
