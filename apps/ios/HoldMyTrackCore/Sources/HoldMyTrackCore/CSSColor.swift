import Foundation

/// A color the style gives as a string, as components from 0 to 1: `#rgb`, `#rrggbb`,
/// `#rrggbbaa`, `rgb()` and `rgba()`. MapLibre's iOS setters take a color, never a string, and its
/// expression parser doesn't know `to-color`, so a patched color goes through here; any other form
/// is nil, and the style reloads instead.
public struct CSSColor: Equatable, Sendable {
    public let red, green, blue, alpha: Double

    public init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let n = UInt64(hex, radix: 16) else { return nil }
            let v = hex.count == 6 ? n << 8 | 0xff : n
            self.init(Double(v >> 24 & 0xff) / 255, Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
            return
        }
        for prefix in ["rgba(", "rgb("] where s.hasPrefix(prefix) && s.hasSuffix(")") {
            let parts = s.dropFirst(prefix.count).dropLast().split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == (prefix == "rgba(" ? 4 : 3), !parts.contains(nil) else { return nil }
            let p = parts.compactMap { $0 }
            self.init(p[0] / 255, p[1] / 255, p[2] / 255, p.count == 4 ? p[3] : 1)
            return
        }
        return nil
    }

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }
}
