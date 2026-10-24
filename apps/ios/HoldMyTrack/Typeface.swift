import HoldMyTrackCore
import UIKit

/// The web's typefaces: Inter for text, and Fraunces or Source Serif 4 for headings by language
/// (AppLanguage.headingFamily). All three are
/// variable fonts: a weight is a point on their wght axis (DesignTokens.Weight), and the optical
/// size follows the point size, as the web's browsers set it. Sizes scale with Dynamic Type.
enum Typeface {
    /// Text: buttons, rows, fields.
    static func sans(_ size: CGFloat, weight: CGFloat = DesignTokens.Weight.regular, relativeTo style: UIFont.TextStyle = .body) -> UIFont {
        font(family: "Inter", size: size, weight: weight, style: style)
    }

    /// Headings, in the face language writes in.
    static func serif(
        _ size: CGFloat,
        weight: CGFloat = DesignTokens.Weight.semibold,
        language: String? = AppLanguage.current,
        relativeTo style: UIFont.TextStyle = .title2
    ) -> UIFont {
        font(family: AppLanguage.headingFamily(language), size: size, weight: weight, style: style)
    }

    private static func font(family: String, size: CGFloat, weight: CGFloat, style: UIFont.TextStyle) -> UIFont {
        let wght = 0x7767_6874 // "wght"
        let opsz = 0x6F70_737A // "opsz"; a font without the axis ignores it
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight, opsz: size],
        ])
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: size))
    }
}
