import HoldMyTrackCore
import ImageIO
import UIKit

/// Photo images from the API, with the session: thumbnails fetched once and kept, since the
/// markers are rebuilt on every regrouping, and a photo's images never change under their path
/// (root docs/SPEC.md FR-16.3).
@MainActor
final class PhotoImages {
    private let api: APIClient
    private let thumbs = NSCache<NSString, UIImage>()
    private var waiting: [String: [(UIImage?) -> Void]] = [:]

    init(api: APIClient) {
        self.api = api
        // About 8 MB: a 320-pixel thumbnail is 400 KB at most, so tens of a trip's at once.
        thumbs.totalCostLimit = 8 * 1024 * 1024
    }

    /// The thumbnail at path if it's here.
    func cached(_ path: String) -> UIImage? { thumbs.object(forKey: path as NSString) }

    /// The thumbnail at path: at once when it's here, else once fetched; nil when it can't be.
    func thumb(_ path: String, _ done: @escaping (UIImage?) -> Void) {
        if let image = cached(path) {
            done(image)
            return
        }
        if waiting[path] != nil {
            waiting[path]?.append(done)
            return
        }
        waiting[path] = [done]
        Task {
            let image = try? await image(path, maxPixels: nil)
            if let image { thumbs.setObject(image, forKey: path as NSString, cost: image.cost) }
            for callback in waiting.removeValue(forKey: path) ?? [] { callback(image) }
        }
    }

    /// The image at path, decoded no larger than maxPixels on its long side when given.
    func image(_ path: String, maxPixels: Int?) async throws -> UIImage {
        let data = try await api.data(path: path)
        guard let image = Self.decode(data, maxPixels: maxPixels) else { throw APIError.unreadable }
        return image
    }

    private nonisolated static func decode(_ data: Data, maxPixels: Int?) -> UIImage? {
        guard let maxPixels else { return UIImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

private extension UIImage {
    /// Roughly the bytes it holds decoded.
    var cost: Int { Int(size.width * scale * size.height * scale * 4) }
}
