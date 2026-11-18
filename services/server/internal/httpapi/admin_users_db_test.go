package httpapi

import (
	"context"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

// An account's row totals its own tracks only, found by id or on the newest page.
func TestAdminUserRows(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	l := i18n.Get("en")
	rider, other := d.newAccount(false), d.newAccount(false)
	d.newTrack(rider, testTrack{trackType: "walk", distanceMeters: 1000})
	d.newTrack(rider, testTrack{trackType: "walk", distanceMeters: 2500})
	d.newTrack(other, testTrack{trackType: "walk", distanceMeters: 9000})

	u, found, err := d.srv.adminUser(ctx, l, rider.id, false)
	if err != nil || !found {
		t.Fatalf("adminUser: %v, found %v", err, found)
	}
	if u.ID != rider.id || u.TrackCount != 2 || u.Distance != "3.5 km" {
		t.Errorf("adminUser = %s with %d activities, %s; want %s with 2, 3.5 km", u.ID, u.TrackCount, u.Distance, rider.id)
	}
	if _, found, err := d.srv.adminUser(ctx, l, "00000000-0000-4000-8000-000000000000", false); err != nil || found {
		t.Errorf("adminUser of no account: found %v, %v", found, err)
	}

	view, err := d.srv.adminUsersPage(ctx, l, 1, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(view.Users) == 0 || len(view.Users) > adminUsersPerPage || view.Range == "" || view.PrevHref != "" {
		t.Fatalf("page 1: %d accounts, range %q, prev %q", len(view.Users), view.Range, view.PrevHref)
	}
	seen := map[string]bool{}
	for _, u := range view.Users {
		seen[u.ID] = true
	}
	if !seen[rider.id] || !seen[other.id] {
		t.Error("page 1 leaves out the newest accounts")
	}
	if view, err := d.srv.adminUsersPage(ctx, l, 1_000_000, false); err != nil || len(view.Users) != 0 || view.Range != "No accounts on this page" || view.PrevHref != "/admin/users" {
		t.Errorf("page past the end: %d accounts, range %q, prev %q, %v", len(view.Users), view.Range, view.PrevHref, err)
	}
}
