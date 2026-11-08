import Foundation
import Testing

import HoldMyTrackCore

/// Where a session sends the user (apps/android/docs/SPEC.md FR-1.2, FR-1.4), and what a failed
/// check does to it.
struct SessionRouteTests {
    private let stored = StoredSession(token: "t", email: "a@b.c", isDemo: false)

    private func account(verified: Bool = true, demo: Bool = false, country: String = "DE") -> Account {
        Account(email: "a@b.c", isDemo: demo, emailVerified: verified, country: country)
    }

    @Test func aConfirmedSessionWithAnEmailAndACountryGoesHome() {
        #expect(SessionRoute.of(stored: stored, confirmed: account()) == .home)
    }

    @Test func noSessionGoesToSignInWhateverElseIsKnown() {
        #expect(SessionRoute.of(stored: nil, confirmed: nil) == .signIn)
        #expect(SessionRoute.of(stored: nil, confirmed: account()) == .signIn)
    }

    @Test func aRestoredTokenIsCheckedBeforeAnythingElseIsDecided() {
        #expect(SessionRoute.of(stored: stored, confirmed: nil) == .verify)
    }

    @Test func anUnconfirmedEmailGoesToVerifyBeforeTheFirstRun() {
        #expect(SessionRoute.of(stored: stored, confirmed: account(verified: false, country: "")) == .verifyEmail)
    }

    @Test func noCountryGoesToTheFirstRunExceptForTheDemo() {
        #expect(SessionRoute.of(stored: stored, confirmed: account(country: "")) == .onboarding)
        #expect(SessionRoute.of(stored: stored, confirmed: account(demo: true, country: "")) == .home)
    }

    @Test func onlyA401EndsTheSession() {
        #expect(SessionCheck.signsOut(.http(status: 401, code: "unauthenticated", message: nil)))
        #expect(!SessionCheck.signsOut(.http(status: 500, code: "internal", message: nil)))
        #expect(!SessionCheck.signsOut(.http(status: 403, code: "email_not_verified", message: nil)))
        #expect(!SessionCheck.signsOut(.unreachable))
        #expect(!SessionCheck.signsOut(.unreadable))
        #expect(!SessionCheck.signsOut(.outdated))
    }

    @Test func everyAccountHasItsOwnKeyAndTheDemoOneOfItsOwn() {
        #expect(AccountKey.of(email: " Ann@Example.com", isDemo: false) == "ann@example.com")
        #expect(AccountKey.of(email: "ann@example.com", isDemo: false) != AccountKey.of(email: "bob@example.com", isDemo: false))
        #expect(AccountKey.of(email: "", isDemo: true) == AccountKey.demo)
    }
}

/// Which requests get the session token.
struct ApiOriginTests {
    private let api = URL(string: "https://holdmytrack.com")!

    private func isAPI(_ url: String, base: URL? = nil) -> Bool {
        ApiOrigin.isAPI(URL(string: url)!, base: base ?? api)
    }

    @Test func theAPIsOwnRequestsAreItsOwn() {
        #expect(isAPI("https://holdmytrack.com/v1/auth/me"))
        #expect(isAPI("https://holdmytrack.com/tiles/v1/fog-vector/3/4/5.pbf"))
        #expect(isAPI("https://HOLDMYTRACK.com:443/v1/activities"))
    }

    @Test func aHostThatOnlyStartsLikeTheAPIsIsNot() {
        #expect(!isAPI("https://holdmytrack.com.evil.tld/v1/auth/me"))
        #expect(!isAPI("https://holdmytrack.com@evil.tld/v1/auth/me"))
        #expect(!isAPI("https://evil.tld/https://holdmytrack.com/v1"))
        #expect(!isAPI("https://api.maptiler.com/tiles/1/2/3.jpg"))
    }

    @Test func credentialsInTheURLAreNotTheAPIs() {
        #expect(!isAPI("https://user@holdmytrack.com/v1/auth/me"))
    }

    @Test func anotherSchemeOrPortIsNot() {
        #expect(!isAPI("http://holdmytrack.com/v1/auth/me"))
        #expect(!isAPI("https://holdmytrack.com:8443/v1/auth/me"))
    }

    @Test func aBaseWithAPathMatchesOnlyAtASegmentBoundary() {
        let base = URL(string: "http://localhost:8081/api")!
        #expect(isAPI("http://localhost:8081/api/v1/auth/me", base: base))
        #expect(isAPI("http://localhost:8081/api", base: base))
        #expect(!isAPI("http://localhost:8081/apix/v1/auth/me", base: base))
    }
}

/// The browser sign-in's PKCE and redirect (root docs/IMPLEMENTATION.md §4.9).
struct OAuthTests {
    @Test func theChallengeIsRFC7636sS256() {
        // RFC 7636, Appendix B.
        #expect(OAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func aVerifierIsFortyThreeURLSafeCharactersAndNeverRepeats() {
        let a = OAuth.newVerifier(), b = OAuth.newVerifier()
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(a != b)
    }

    @Test func theStartURLCarriesTheTimezoneAndTheChallenge() {
        let url = OAuth.startURL(.facebook, base: URL(string: "http://localhost:8081")!, timezone: "America/New_York", challenge: "abc")
        #expect(url.absoluteString == "http://localhost:8081/v1/auth/facebook/start?tz=America/New_York&app_challenge=abc")
    }

    @Test func aCodeWithASignInInFlightIsRedeemed() {
        #expect(OAuthRedirect.of(URL(string: "holdmytrack://oauth?code=abc")!, hasVerifier: true) == .exchange(code: "abc"))
    }

    @Test func anErrorIsShownAndLeavesTheSignInWaitingForItsRealRedirect() {
        #expect(OAuthRedirect.of(URL(string: "holdmytrack://oauth?error=facebook_no_email")!, hasVerifier: true) == .showError("facebook_no_email"))
        #expect(OAuthRedirect.of(URL(string: "holdmytrack://oauth")!, hasVerifier: true) == .showError(nil))
    }

    @Test func withNoSignInInFlightOrAnotherLinkARedirectIsIgnored() {
        #expect(OAuthRedirect.of(URL(string: "holdmytrack://oauth?code=abc")!, hasVerifier: false) == .ignore)
        #expect(OAuthRedirect.of(URL(string: "holdmytrack://other?code=abc")!, hasVerifier: true) == .ignore)
        #expect(OAuthRedirect.of(URL(string: "https://holdmytrack.com/oauth?code=abc")!, hasVerifier: true) == .ignore)
    }
}

struct OAuthFailureTests {
    @Test func facebooksTwoRefusalsSayWhatToDo() {
        #expect(OAuthFailure.of("facebook_no_email", provider: .facebook) == .noEmail)
        #expect(OAuthFailure.of("facebook_email_in_use", provider: .facebook) == .emailInUse)
    }

    @Test func anythingElseIsTheProvidersFailure() {
        #expect(OAuthFailure.of("google", provider: .google) == .failed(.google))
        #expect(OAuthFailure.of(nil, provider: .facebook) == .failed(.facebook))
        #expect(OAuthFailure.of("state_mismatch", provider: .google) == .failed(.google))
    }
}
