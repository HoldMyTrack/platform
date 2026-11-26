import Foundation

/// Files another app opened in HoldMyTrack, listed on Upload until its Upload sends them or
/// Cancel drops them (apps/docs/SPEC.md FR-3.6): nothing is sent unasked.
public struct SharedFiles: Equatable, Sendable {
    public private(set) var urls: [URL] = []

    public init() {}

    /// Adds urls after those listed, each file once.
    public mutating func add(_ more: [URL]) {
        for url in more where !urls.contains(url) { urls.append(url) }
    }

    /// The names to list, in order.
    public var names: [String] { urls.map(\.lastPathComponent) }

    /// Empties the list, returning what it held, for Upload to send.
    public mutating func take() -> [URL] {
        defer { urls = [] }
        return urls
    }
}
