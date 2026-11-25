import Foundation

/// The file name a download is saved under, from its Content-Disposition header
/// (testdata/client-rules/attachment-name.json).
public enum AttachmentName {
    public static let fallback = "tracks.gpx"

    /// The file name in a Content-Disposition header: `filename*` (RFC 5987,
    /// `charset'language'value`) before `filename`, quoted or not.
    public static func of(_ header: String?) -> String {
        let header = header ?? ""
        if let star = firstMatch(#"filename\*=(?:([^';]*)'[^';]*')?([^;]+)"#, in: header) {
            let charset = star[1]
            if charset == nil || charset?.lowercased() == "utf-8",
               let value = star[2], let decoded = percentDecode(value.trimmingCharacters(in: .whitespaces)) {
                return decoded
            }
        }
        if let plain = firstMatch(#"(?:^|;)\s*filename="?([^";]+)"?"#, in: header), let name = plain[1] {
            return name
        }
        return fallback
    }

    /// The capture groups of pattern's first match in text, ignoring case; a group that took no
    /// part is nil.
    private static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    /// s with its %XX escapes decoded as UTF-8, or nil when an escape or the UTF-8 is broken.
    /// A `+` stays a `+`, and a sign is not a hex digit.
    private static func percentDecode(_ s: String) -> String? {
        var bytes: [UInt8] = []
        let scalars = Array(s.utf8)
        var i = 0
        while i < scalars.count {
            if scalars[i] == UInt8(ascii: "%") {
                guard i + 2 < scalars.count, let high = hex(scalars[i + 1]), let low = hex(scalars[i + 2]) else { return nil }
                bytes.append(high << 4 | low)
                i += 3
            } else {
                bytes.append(scalars[i])
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
