import Foundation

/// What `GET /healthz` says about the server: reachable and on which build, or why not. The
/// project's first screen shows it until the app has screens of its own.
public enum ServerStatus: Equatable, Sendable {
    case reachable(version: String)
    case refused(status: Int)
    case unreadable
    case unreachable

    /// The status for an answer with statusCode and body.
    public static func from(statusCode: Int, body: Data) -> ServerStatus {
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

public enum ServerCheck {
    /// The `/healthz` request to app's API, as app, in language.
    public static func request(_ app: AppInfo, language: String) -> URLRequest {
        var request = URLRequest(url: app.apiBaseURL.appending(path: "healthz"), timeoutInterval: 10)
        request.setValue(app.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// Asks app's API for `/healthz`, as app, in language.
    public static func run(_ app: AppInfo, language: String, session: URLSession = .shared) async -> ServerStatus {
        guard let (body, response) = try? await session.data(for: request(app, language: language)),
              let http = response as? HTTPURLResponse
        else { return .unreachable }
        return ServerStatus.from(statusCode: http.statusCode, body: body)
    }
}
