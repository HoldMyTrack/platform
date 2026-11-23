package httpapi

import "testing"

func TestDemoCopyRefusal(t *testing.T) {
	fresh := demoCopyAccount{verified: true}
	cases := []struct {
		name    string
		account demoCopyAccount
		refused bool
	}{
		{"a fresh verified account", fresh, false},
		{"the Demo Customer", demoCopyAccount{isDemo: true, verified: true}, true},
		{"unverified", demoCopyAccount{}, true},
		{"has tracks", demoCopyAccount{verified: true, tracks: 1}, true},
		{"has Private locations", demoCopyAccount{verified: true, privacyZones: 2}, true},
	}
	for _, c := range cases {
		if got := demoCopyRefusal(c.account) != nil; got != c.refused {
			t.Errorf("%s: refused = %v, want %v", c.name, got, c.refused)
		}
	}
}
