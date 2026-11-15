// Package zoneinfo loads IANA time zones once per process. time.LoadLocation reads and parses the
// zone's file on every call, and a request path can need hundreds: Settings' Timezone list
// loads every zone it offers.
package zoneinfo

import (
	"sync"
	"time"
)

// loaded holds every zone Load has loaded. Only a zone that loads is kept, so it stays within
// the IANA database whatever names callers pass.
var loaded sync.Map // name → *time.Location

// Load is time.LoadLocation, remembering what it loads.
func Load(name string) (*time.Location, error) {
	if loc, ok := loaded.Load(name); ok {
		return loc.(*time.Location), nil
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return nil, err
	}
	loaded.Store(name, loc)
	return loc, nil
}

// LoadOr is Load, or fallback for a zone that doesn't load.
func LoadOr(name string, fallback *time.Location) *time.Location {
	if loc, err := Load(name); err == nil {
		return loc
	}
	return fallback
}
