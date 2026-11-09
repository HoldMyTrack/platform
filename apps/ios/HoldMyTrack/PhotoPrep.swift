import HoldMyTrackCore
import ImageIO
import UniformTypeIdentifiers

/// Getting a picked photo ready for upload (root docs/SPEC.md FR-16.1, ADR-0024), Android's
/// PhotoPrep: read what its EXIF says about when and where it was taken (PhotoExifFields), then
/// redraw it upright at most maxSide pixels on its long side, plus a thumbSide thumbnail. Redrawing
/// keeps the pixels alone, so no EXIF field, the position included, reaches the server inside the
/// file; the time and position go as plain upload fields.
///
/// JPEG where Android writes WebP: ImageIO decodes WebP but can't write it, and the server takes
/// either. ImageIO decodes HEIC too, so the camera's own format needs nothing extra.
enum PhotoPrep {
    static let maxSide = 2048
    static let thumbSide = 320
    /// The server's limit on the file (services/server/api/paths/photos.yaml); a photo still over
    /// it at the lowest quality is refused there.
    private static let maxBytes = 3 * 1024 * 1024
    private static let qualities = [0.85, 0.75, 0.6]

    struct Unreadable: Error {}

    /// Decodes and re-encodes, so off the main thread.
    static func prepare(_ url: URL) throws -> PreparedPhoto {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { throw Unreadable() }
        let exif = readExif(source)
        guard let image = redraw(source, maxSide), let thumb = redraw(source, thumbSide),
              let file = encode(image, fitting: maxBytes), let thumbData = encode(thumb, fitting: 256 * 1024) else { throw Unreadable() }
        return PreparedPhoto(file: file, thumb: thumbData, exif: exif)
    }

    /// The picture upright and at most side pixels on its long side, decoded at that size, so a
    /// 48-megapixel photo is never held whole.
    private static func redraw(_ source: CGImageSource, _ side: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG, at the best quality that fits in limit, with no metadata.
    private static func encode(_ image: CGImage, fitting limit: Int) -> Data? {
        var last: Data?
        for quality in qualities {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            last = data as Data
            if data.length <= limit { break }
        }
        return last
    }

    private static func readExif(_ source: CGImageSource) -> PhotoExif {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        // ImageIO gives the GPS position unsigned, with its hemisphere apart.
        let lat = (gps[kCGImagePropertyGPSLatitude] as? Double).map { gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" ? -$0 : $0 }
        let lon = (gps[kCGImagePropertyGPSLongitude] as? Double).map { gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" ? -$0 : $0 }
        return PhotoExifFields.resolve(
            dateTimeOriginal: exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            dateTime: tiff[kCGImagePropertyTIFFDateTime] as? String,
            offsetTimeOriginal: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
            lat: lat, lon: lon,
            gpsDate: gps[kCGImagePropertyGPSDateStamp] as? String,
            gpsTime: gps[kCGImagePropertyGPSTimeStamp] as? String
        )
    }
}
