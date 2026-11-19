import HoldMyTrackCore
import MapLibre
import UIKit

/// Draws the export's picture with MapLibre's snapshotter from the style the live map was composed
/// from (ExportStyle), never a crop of the live map (apps/ios/docs/IMPLEMENTATION.md §3.5): the
/// window's size in points at the live zoom and heading, at the scale that makes it the image's
/// pixels, so labels and lines keep their on-screen proportions, only sharper.
@MainActor
final class ExportRenderer {
    private var snapshotter: MLNMapSnapshotter?
    private var styleFile: URL?
    private var timeout: Task<Void, Never>?

    /// The picture, or why it couldn't be made; never called after cancel.
    func render(style: JSONValue, center: CLLocationCoordinate2D, zoom: Double, heading: Double, window: CGSize, pixelWidth: Int, pixelHeight: Int,
                done: @escaping (Result<UIImage, Error>) -> Void) {
        cancel()
        // The snapshotter loads a style by URL only.
        let file = FileManager.default.temporaryDirectory.appending(path: "export-style-\(UUID().uuidString).json")
        do {
            try style.data.write(to: file)
        } catch {
            done(.failure(error))
            return
        }
        styleFile = file
        let camera = MLNMapCamera(lookingAtCenter: center, altitude: 0, pitch: 0, heading: heading)
        let options = MLNMapSnapshotOptions(styleURL: file, camera: camera, size: window)
        options.zoomLevel = zoom
        options.scale = CGFloat(pixelWidth) / window.width
        options.showsLogo = false
        options.showsAttribution = false
        let snapshotter = MLNMapSnapshotter(options: options)
        self.snapshotter = snapshotter
        let finish: @MainActor (Result<UIImage, Error>) -> Void = { [weak self] result in
            guard let self, self.snapshotter === snapshotter else { return }
            self.cancel()
            done(result)
        }
        // Generous: every tile comes from nothing, and a bigger image takes longer to draw.
        let seconds = 30 + Double(pixelWidth * pixelHeight) / 1_000_000 * 15
        timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            finish(.failure(ExportError.timedOut))
        }
        // Called on the main queue.
        snapshotter.start { snapshot, error in
            let image = snapshot?.image
            let failure = error
            MainActor.assumeIsolated {
                if let image { finish(.success(image)) } else { finish(.failure(failure ?? ExportError.noImage)) }
            }
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        snapshotter?.cancel()
        snapshotter = nil
        if let styleFile { try? FileManager.default.removeItem(at: styleFile) }
        styleFile = nil
    }
}

enum ExportError: Error {
    case timedOut, noImage
}

/// The image made from the map's picture, at its own pixel size: the picture, the photo markers
/// the screen shows, the stats card where the window previewed it, then the credit and the mark
/// (root docs/SPEC.md FR-4.7), the web's `exportMap.ts` at the same proportions.
enum ExportImage {
    struct Marker {
        let placement: PhotoMarkerPlacement
        let thumbnail: UIImage?
    }

    /// unit is the image's pixels per point of the window, which the markers' look is scaled by.
    static func compose(picture: UIImage, width: Int, height: Int, markers: [Marker], card: UIImage?, credit: String, dark: Bool, unit: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            picture.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            for m in markers {
                PhotoMarkerPainter.draw(at: CGPoint(x: m.placement.x, y: m.placement.y), diameter: m.placement.diameter / unit,
                                        count: m.placement.ids.count, image: m.thumbnail, active: m.placement.active, small: m.placement.small,
                                        unit: unit, shadow: true)
            }
            if let card, let cg = card.cgImage {
                let at = ExportStats.placement(width: width, height: height, cardWidth: cg.width, cardHeight: cg.height)
                card.draw(in: CGRect(x: at.x.rounded(), y: at.y.rounded(), width: Double(cg.width), height: Double(cg.height)))
            }
            drawMarks(width: width, height: height, credit: credit, dark: dark)
        }
    }

    /// The credit on the right over a dark plate, an ODbL requirement on any image the map is in,
    /// and the logo and wordmark on the left, with no plate, at partial opacity.
    private static func drawMarks(width: Int, height: Int, credit: String, dark: Bool) {
        let (fontSize, margin) = ImageMarks.stripMetrics(width: width, height: height)
        let font = Typeface.unscaled("Inter", fontSize, weight: DesignTokens.Weight.regular)
        let text = NSAttributedString(string: credit, attributes: [.font: font, .foregroundColor: UIColor.white])
        let padX = fontSize * 0.5, padY = fontSize * 0.3
        let ascent = font.ascender * 0.8, descent = -font.descender * 0.8
        let baselineX = Double(width) - margin, baselineY = Double(height) - margin
        let textWidth = text.size().width
        UIColor(white: 0, alpha: 140.0 / 255).setFill()
        UIRectFill(CGRect(x: baselineX - textWidth - padX * 2, y: baselineY - ascent - padY, width: textWidth + padX * 2, height: ascent + descent + padY * 2))
        text.draw(at: CGPoint(x: baselineX - padX - textWidth, y: baselineY - font.ascender))
        let bottom = baselineY + descent + padY

        let markSize = fontSize * ImageMarks.watermarkFontScale
        let logoHeight = markSize * ImageMarks.watermarkLogoScale
        let alpha = ImageMarks.watermarkAlpha
        let midY = bottom - max(logoHeight, markSize) / 2
        var x = margin
        let logo = UIImage(resource: dark ? .exportLogoOnDark : .exportLogoOnLight)
        let logoWidth = logo.size.width / logo.size.height * logoHeight
        logo.draw(in: CGRect(x: x, y: midY - logoHeight / 2, width: logoWidth, height: logoHeight), blendMode: .normal, alpha: alpha)
        x += logoWidth + markSize * 0.35
        // The header's colors; "Track" in its amber, lightened on a dark map so it still reads.
        let light = dark ? UIColor(red: 0xe6 / 255.0, green: 0xeb / 255.0, blue: 0xe8 / 255.0, alpha: alpha)
            : UIColor(red: 0x4a / 255.0, green: 0x57 / 255.0, blue: 0x50 / 255.0, alpha: alpha)
        let amber = dark ? UIColor(red: 0xe0 / 255.0, green: 0xa8 / 255.0, blue: 0x4a / 255.0, alpha: alpha)
            : UIColor(red: 0x9a / 255.0, green: 0x6b / 255.0, blue: 0x1e / 255.0, alpha: alpha)
        let word = NSMutableAttributedString(string: "HoldMy", attributes: [.font: Typeface.unscaled("Fraunces", markSize, weight: DesignTokens.Weight.regular), .foregroundColor: light])
        word.append(NSAttributedString(string: "Track", attributes: [.font: Typeface.unscaled("Fraunces", markSize, weight: DesignTokens.Weight.heavy), .foregroundColor: amber]))
        let serif = Typeface.unscaled("Fraunces", markSize, weight: DesignTokens.Weight.regular)
        // Centred on midY as Android's baseline: half the ascent over it, half the descent under.
        let baseline = midY + (serif.ascender + serif.descender) / 2
        word.draw(at: CGPoint(x: x, y: baseline - serif.ascender))
    }
}