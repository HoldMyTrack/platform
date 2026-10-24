import Testing
import UIKit

@testable import HoldMyTrack

struct TypefaceTests {
    @Test(arguments: [("ru", "Source Serif 4"), ("ru-RU", "Source Serif 4"), ("en", "Fraunces"), (nil as String?, "Fraunces")])
    func headingsFollowTheLanguage(language: String?, family: String) {
        #expect(Typeface.serifFamily(language: language) == family)
    }

    /// The bundled fonts are registered: a face that failed to load falls back to the system's.
    @Test func bundledFacesLoad() {
        #expect(Typeface.sans(13).familyName == "Inter")
        #expect(Typeface.serif(20, language: "en").familyName == "Fraunces")
        #expect(Typeface.serif(20, language: "ru").familyName == "Source Serif 4")
    }
}

struct PaletteTests {
    /// The two themes resolve to tokens.css's two values: --fm-accent is #b07e2e light, #d6a553 dark.
    @Test func accentFollowsTheTheme() {
        let accent = UIColor(resource: .accent)
        #expect(hex(accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) == "B07E2E")
        #expect(hex(accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))) == "D6A553")
    }

    private func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

struct AppLanguageTests {
    @Test(arguments: [(["ru"], "ru"), (["ru-RU", "en"], "ru"), (["en"], "en"), (["en", "ru"], "en"), (["de"], "en"), ([], "en")])
    func resolvesToASupportedLanguage(preferred: [String], want: String) {
        #expect(AppLanguage.resolve(preferred) == want)
    }
}
