// Package zoneinfo loads IANA time zones once per process. time.LoadLocation reads and parses the
// zone's file on every call, and a request path can need hundreds: Settings' Timezone list
// loads every zone it offers.
package zoneinfo

import (
	"path"
	"strings"
	"sync"
	"time"
)

// loaded holds every zone Load has loaded under its own name. A name is kept only if it loads
// and is written as the zone's file path, so the cache stays within the zone files whatever
// names callers pass: time.LoadLocation also loads "Europe/./Berlin" and "Europe//Berlin",
// spellings without end, and those load uncached.
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
	if cacheable(name) {
		loaded.Store(name, loc)
	}
	return loc, nil
}

// cacheable reports whether name is written as a zone file's own path.
func cacheable(name string) bool {
	return path.Clean(name) == name && !strings.HasPrefix(name, "/")
}

// LoadOr is Load, or fallback for a zone that doesn't load.
func LoadOr(name string, fallback *time.Location) *time.Location {
	if loc, err := Load(name); err == nil {
		return loc
	}
	return fallback
}
