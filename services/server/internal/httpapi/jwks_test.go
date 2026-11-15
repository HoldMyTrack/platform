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

// A caller whose shared fetch failed doesn't fall back to the expired set.
func TestJWKSWaiterAfterAFailedFetchRefusesTheExpiredKey(t *testing.T) {
	url, started, release, _ := slowKeySet(t, &newRSAKey(t).PublicKey)
	k := newJWKSKeySet(url, &http.Client{Timeout: 100 * time.Millisecond})
	now := time.Now()
	if _, err := k.key(context.Background(), "k1", now); err != nil {
		t.Fatal(err)
	}
	expired := now.Add(2 * jwksDefaultTTL)
	first := make(chan error, 1)
	go func() {
		_, err := k.key(context.Background(), "k1", expired)
		first <- err
	}()
	<-started
	waiter := make(chan error, 1)
	go func() {
		_, err := k.key(context.Background(), "k1", expired)
		waiter <- err
	}()
	if err := <-first; err == nil {
		t.Fatal("fetch past the client timeout succeeded")
	}
	if err := <-waiter; err == nil {
		t.Error("waiter accepted a key from the expired set after the fetch failed")
	}
	close(release)
}
