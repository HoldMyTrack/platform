import Foundation

/// What `GET /healthz` says about the server: reachable and on which build, or why not. The
/// project's first screen shows it until the app has screens of its own.
enum ServerStatus: Equatable, Sendable {
    case reachable(version: String)
    case refused(status: Int)
    case unreadable
    case unreachable

    /// The status for an answer with statusCode and body.
    static func from(statusCode: Int, body: Data) -> ServerStatus {
        guard statusCode == 200 else { return .refused(status: statusCode) }
        struct Healthz: Decodable {
            let status: String
            let version: String
        }
        guard let healthz = try? JSONDecoder().decode(Healthz.self, from: body), healthz.status == "ok" else {
            return .unreadable
        }
        return .reachable(version: healthz.version)
    }
}

enum ServerCheck {
    /// Asks app's API for `/healthz`, as app, in language.
    static func run(_ app: AppInfo, language: String = AppLanguage.current, session: URLSession = .shared) async -> ServerStatus {
        var request = URLRequest(url: app.apiBaseURL.appending(path: "healthz"), timeoutInterval: 10)
        request.setValue(app.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        guard let (body, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unreachable }
        return ServerStatus.from(statusCode: http.statusCode, body: body)
    }
}
