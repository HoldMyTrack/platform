import Foundation
import Testing

@testable import HoldMyTrack

struct AppInfoTests {
    private let plist: [String: Any] = [
        "CFBundleShortVersionString": "0.1",
        "CFBundleVersion": "1400",
        "HMTCommit": "62da50b",
        "HMTAPIBaseURL": "https://holdmytrack.com",
    ]

    @Test func userAgentNamesTheBuild() throws {
        let app = try #require(AppInfo.from(plist))
        #expect(app.userAgent == "HoldMyTrack-iOS/0.1 (62da50b; 1400)")
    }

    @Test func missingBuildReadsAsOne() throws {
        var info = plist
        info["CFBundleVersion"] = nil
        info["HMTCommit"] = nil
        let app = try #require(AppInfo.from(info))
        #expect(app.build == 1)
        #expect(app.commit == "unknown")
    }

    @Test(arguments: [
        ("https://holdmytrack.com", "https://holdmytrack.com"),
        ("https://holdmytrack.com/", "https://holdmytrack.com"),
        ("http://localhost:8081//", "http://localhost:8081"),
        (" http://mac.local:8080 ", "http://mac.local:8080"),
    ])
    func apiBaseLosesItsTrailingSlash(value: String, want: String) {
        #expect(AppInfo.apiBase(value)?.absoluteString == want)
    }

    @Test(arguments: ["", "holdmytrack.com", "ftp://holdmytrack.com", "https://", "$(HMT_API_BASE_URL)"])
    func apiBaseRefusesWhatIsntAnOrigin(value: String) {
        #expect(AppInfo.apiBase(value) == nil)
    }

    @Test func noOriginNoBuild() {
        var info = plist
        info["HMTAPIBaseURL"] = nil
        #expect(AppInfo.from(info) == nil)
    }
}

struct ServerStatusTests {
    @Test func healthyServer() {
        let body = Data(#"{"status":"ok","version":"12a51b73","min_android_build":1366,"min_ios_build":0}"#.utf8)
        #expect(ServerStatus.from(statusCode: 200, body: body) == .reachable(version: "12a51b73"))
    }

    @Test func refusal() {
        #expect(ServerStatus.from(statusCode: 503, body: Data()) == .refused(status: 503))
    }

    @Test func notHealthz() {
        #expect(ServerStatus.from(statusCode: 200, body: Data("<html>".utf8)) == .unreadable)
        #expect(ServerStatus.from(statusCode: 200, body: Data(#"{"status":"down","version":"x"}"#.utf8)) == .unreadable)
    }
}
