package httpapi

import (
	"errors"
	"net/http"
	"reflect"
	"testing"
)

func TestVerifyPage(t *testing.T) {
	for name, tc := range map[string]struct {
		token   string
		link    verifyLink
		confirm bool
		form    authForm
		status  int
	}{
		"no token":           {"", verifyLink{}, false, authForm{ErrorKey: "error.verify_link_invalid"}, http.StatusBadRequest},
		"dead link":          {"t", verifyLink{}, false, authForm{ErrorKey: "error.verify_link_invalid"}, http.StatusBadRequest},
		"dead link, error":   {"t", verifyLink{Error: "other_facebook"}, false, authForm{ErrorKey: "error.verify_link_invalid"}, http.StatusBadRequest},
		"elsewhere":          {"t", verifyLink{Live: true}, false, authForm{Token: "t", Confirm: true}, http.StatusOK},
		"own browser":        {"t", verifyLink{Live: true, Own: true}, true, authForm{}, 0},
		"own browser, error": {"t", verifyLink{Live: true, Own: true, Error: "facebook"}, true, authForm{}, 0},
		"other Facebook":     {"t", verifyLink{Live: true, Error: "other_facebook"}, false, authForm{Token: "t", Facebook: true, ErrorKey: "error.verify_other_facebook"}, http.StatusForbidden},
		"Facebook failed":    {"t", verifyLink{Live: true, Error: "facebook"}, false, authForm{Token: "t", Facebook: true, ErrorKey: "signin.facebook_failed"}, http.StatusForbidden},
		"unknown error":      {"t", verifyLink{Live: true, Error: "x"}, false, authForm{Token: "t", Confirm: true}, http.StatusOK},
	} {
		confirm, form, status := verifyPage(tc.token, tc.link, true)
		if confirm != tc.confirm || !reflect.DeepEqual(form, tc.form) || status != tc.status {
			t.Errorf("%s: (%v, %+v, %d), want (%v, %+v, %d)", name, confirm, form, status, tc.confirm, tc.form, tc.status)
		}
	}
}

func TestVerifyFailureForm(t *testing.T) {
	for name, tc := range map[string]struct {
		err  error
		want authForm
	}{
		"needs Facebook": {errVerifyNeedsFacebook, authForm{Token: "t", Facebook: true}},
		"refused":        {accountFailure(http.StatusBadRequest, "error.verify_link_invalid"), authForm{}},
		"internal":       {errors.New("connection reset"), authForm{Token: "t", Confirm: true}},
	} {
		if got := verifyFailureForm("t", tc.err, true); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: %+v, want %+v", name, got, tc.want)
		}
	}
}
