import HoldMyTrackCore
import Testing

struct AppLanguageTests {
    @Test(arguments: [(["ru"], "ru"), (["ru-RU", "en"], "ru"), (["en"], "en"), (["en", "ru"], "en"), (["de"], "en"), ([], "en")])
    func resolvesToASupportedLanguage(preferred: [String], want: String) {
        #expect(AppLanguage.resolve(preferred) == want)
    }

    @Test(arguments: [("ru", "Source Serif 4"), ("ru-RU", "Source Serif 4"), ("en", "Fraunces"), (nil as String?, "Fraunces")])
    func headingsFollowTheLanguage(language: String?, family: String) {
        #expect(AppLanguage.headingFamily(language) == family)
    }
}
