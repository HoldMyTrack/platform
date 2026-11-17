package httpapi

import (
	"net/http"
	"net/url"
)

// The sign-up page, for a browser and for the native apps. An app opens it in a browser tab
// with ?app_challenge=, the S256 challenge of a verifier only the app holds, as it does for
// Google and Facebook (oauth.go), so its sign-ups pass the page's Turnstile check. A sign-up
// from the app then hands the app a one-time code at appRedirectURI and sets no cookie in the
// tab. The tab's own browser session plays no part: a browser signed in to the site still gets
// the form, and a demo there is not upgraded.

// signupAction is what a request for /signup does.
type signupAction int

const (
	signupShow signupAction = iota
	// signupHome sends a browser signed in to a real account where its account belongs.
	signupHome
	// signupBadChallenge refuses an app_challenge that isn't a PKCE value.
	signupBadChallenge
)

// signupPageAction decides what /signup does for an app's challenge (empty for a browser) and
// whether the browser is signed in to a real account.
func signupPageAction(appChallenge string, signedInReal bool) signupAction {
	if appChallenge != "" {
		if !validPKCEValue(appChallenge) {
			return signupBadChallenge
		}
		return signupShow
	}
	if signedInReal {
		return signupHome
	}
	return signupShow
}

// signupProviders are the sign-in services the sign-up page can offer.
type signupProviders struct{ google, facebook, apple bool }

// signupForm is the page's form. An app's page offers no Google, Facebook or Apple button,
// since their links would sign in this tab instead of the app, which has its own buttons, and
// no link to sign in or back to the map, nor the site's header and footer, which would also
// stay in the tab.
func signupForm(appChallenge string, upgrading bool, providers signupProviders, turnstileSiteKey string) authForm {
	if appChallenge != "" {
		return authForm{AppChallenge: appChallenge, InApp: true, TurnstileSiteKey: turnstileSiteKey}
	}
	return authForm{Google: providers.google, Facebook: providers.facebook, Apple: providers.apple, Upgrading: upgrading, TurnstileSiteKey: turnstileSiteKey}
}

func (s *Server) signupProviders() signupProviders {
	return signupProviders{google: s.google.enabled(), facebook: s.facebook.enabled(), apple: s.apple.enabled()}
}

// GET /signup. A demo session is allowed here — it's how a demo becomes a real account.
func (s *Server) handleSignUpPage(w http.ResponseWriter, r *http.Request) {
	appChallenge := r.URL.Query().Get("app_challenge")
	acct, ok := s.pageAccount(w, r)
	if !ok {
		return
	}
	switch signupPageAction(appChallenge, acct != nil && !acct.info.isDemo) {
	case signupBadChallenge:
		http.Error(w, "invalid app_challenge", http.StatusBadRequest)
		return
	case signupHome:
		http.Redirect(w, r, acct.home(), http.StatusSeeOther)
		return
	}
	// noindex: /signin is the one sign-in-or-up page search results should show (it links here).
	s.renderAuth(w, r, acct, http.StatusOK, "signup", "signup.title", true, signupForm(appChallenge, acct != nil, s.signupProviders(), s.turnstile.siteKey))
}

// POST /signup. timezone comes from a hidden field the page's one-line script fills from the
// browser; without it the account starts on UTC, as the JSON endpoint's would.
func (s *Server) handleSignUpForm(w http.ResponseWriter, r *http.Request) {
	email := r.PostFormValue("email")
	appChallenge := r.PostFormValue("app_challenge")
	if signupPageAction(appChallenge, false) == signupBadChallenge {
		http.Error(w, "invalid app_challenge", http.StatusBadRequest)
		return
	}
	acct, ok := s.pageAccount(w, r)
	if !ok {
		return
	}
	userID, err := s.createAccountLimited(r, email, r.PostFormValue("password"), r.PostFormValue("timezone"), pageLang(acct, r), s.checkTurnstile)
	if err != nil {
		form := signupForm(appChallenge, acct != nil && acct.info.isDemo, s.signupProviders(), s.turnstile.siteKey)
		form.Email = email
		s.renderAuthError(w, r, acct, "sign up", "signup", "signup.title", true, form, err)
		return
	}
	if appChallenge == "" {
		s.signIn(w, r, userID)
		return
	}
	code, err := s.createHandoff(r.Context(), userID, appChallenge)
	if err != nil {
		// The account exists: trying again would find the address taken, so the page says to
		// sign in with it in the app.
		s.log.Error("app signup handoff failed", "err", err)
		s.renderAuth(w, r, acct, http.StatusInternalServerError, "signup", "signup.title", true, authForm{InApp: true, Created: true, ErrorKey: "error.signup_created_sign_in"})
		return
	}
	http.Redirect(w, r, appRedirectURI+"?"+url.Values{"code": {code}}.Encode(), http.StatusSeeOther)
}
