package zoneinfo

import (
	"testing"
	"time"
)

func TestLoad(t *testing.T) {
	a, err := Load("Europe/Berlin")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Load("Europe/Berlin")
	if a != b {
		t.Error("a second Load of the same zone loaded it again")
	}
	if a.String() != "Europe/Berlin" {
		t.Errorf("Load(Europe/Berlin) = %v", a)
	}
	if _, err := Load("Mars/Olympus_Mons"); err == nil {
		t.Error("Load of an unknown zone: no error")
	}
	if _, ok := loaded.Load("Mars/Olympus_Mons"); ok {
		t.Error("an unknown zone was kept")
	}
	if got := LoadOr("Mars/Olympus_Mons", time.UTC); got != time.UTC {
		t.Errorf("LoadOr of an unknown zone = %v, want the fallback", got)
	}
}

// Other spellings of a zone's path load, but aren't kept.
func TestLoadKeepsOnlyCleanNames(t *testing.T) {
	for _, name := range []string{"Europe/./Berlin", "Europe//Berlin", "Europe/Berlin/"} {
		if loc, err := Load(name); err != nil {
			t.Logf("%q doesn't load here: %v", name, err)
		} else if loc == nil {
			t.Errorf("Load(%q) = nil", name)
		}
		if _, ok := loaded.Load(name); ok {
			t.Errorf("%q was kept", name)
		}
	}
	if !cacheable("America/Argentina/Buenos_Aires") || !cacheable("UTC") || cacheable("/etc/localtime") || cacheable("Europe/../Berlin") {
		t.Error("cacheable misjudges a name")
	}
}
