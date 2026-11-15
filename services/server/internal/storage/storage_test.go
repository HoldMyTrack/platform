package storage

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/storage/storagetest"
)

// A listing that fails is an error, so a purge never takes a prefix as emptied and deletes the
// rows that point at objects it never removed; once listing works, the same call removes them.
func TestRemoveByPrefixReportsAFailedListing(t *testing.T) {
	mem := storagetest.New()
	var failListing atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		listing := r.Method == http.MethodGet && r.URL.Path == "/test/" && !r.URL.Query().Has("location")
		if failListing.Load() && listing {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusForbidden)
			io.WriteString(w, `<Error><Code>AccessDenied</Code><Message>listing refused</Message></Error>`)
			return
		}
		mem.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	store, err := New(srv.URL, "test", "test", "test")
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := store.Put(ctx, "raw/u1/a.gpx", strings.NewReader("track"), 5); err != nil {
		t.Fatal(err)
	}

	failListing.Store(true)
	if err := store.RemoveByPrefix(ctx, "raw/u1/"); err == nil {
		t.Fatal("a failed listing reported success")
	}
	failListing.Store(false)
	if err := store.RemoveByPrefix(ctx, "raw/u1/"); err != nil {
		t.Fatalf("listing works again: %v", err)
	}
	// minio's Get is lazy: a missing object errors on the first read.
	rc, err := store.Get(ctx, "raw/u1/a.gpx")
	if err == nil {
		_, err = io.ReadAll(rc)
		rc.Close()
	}
	if err == nil {
		t.Fatal("the object is still there")
	}
}
