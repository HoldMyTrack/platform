import Foundation
import Testing

@testable import HoldMyTrackCore

/// The site's pages in the app: their cookies, and links read into the shared webPageRoute rule
/// (whose own cases run in ClientRulesTests).
struct WebPageTests {
    private let base = URL(string: "http://localhost:8081")!

    private func route(_ link: String, _ page: SitePage = .syncHistory, onboarding: Bool = false) -> WebRoute {
        WebPageSession.route(URL(string: link)!, base: base, page: page, leaving: false, onboarding: onboarding)
    }

    @Test func aPageIsSignedInMarkedAndInTheAppsLanguage() {
        let cookies = WebPageSession.cookies(token: "t", language: "ru")
        #expect(cookies == [
            WebCookie(name: "holdmytrack_session", value: "t", httpOnly: true),
            WebCookie(name: "hmt_app", value: "ios", httpOnly: false),
            WebCookie(name: "hmt_lang", value: "ru", httpOnly: false),
        ])
        #expect(WebPageSession.cookies(token: "t", language: "de")[2].value == "en")
    }

    @Test func aLinkIsReadWithItsPortAndQuery() {
        #expect(route("http://localhost:8081/sync?page=2") == .stay)
        #expect(route("http://LOCALHOST:8081/sync") == .stay)
        #expect(route("http://localhost:8080/sync") == .outside)
        #expect(route("http://localhost:8081/?activity=a1&day=2026-10-01") == .viewOnMap(activity: "a1", day: "2026-10-01"))
        #expect(route("http://localhost:8081", .settings, onboarding: true) == .onboarded)
        #expect(route("mailto:hello@holdmytrack.com") == .outside)
        #expect(route("http://localhost:8081/signin") == .close)
    }

    @Test func onlyProfileAndSyncHistoryAreReadAgainOnReturn() {
        #expect(SitePage.allCases.filter(\.refreshOnReturn) == [.profile, .syncHistory])
    }

    @Test func aRangeHoldsBothItsEnds() {
        let range = DateRange(from: "2026-10-01", to: "2026-10-05")
        #expect(range.contains("2026-10-01") && range.contains("2026-10-05") && !range.contains("2026-10-06"))
    }
}
