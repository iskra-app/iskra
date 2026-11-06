import Testing
import Foundation
@testable import IskraFeatures
import IskraCore

/// The language picked in Settings on a Mac reaches strings resolved in code at once, without a
/// relaunch — see `AppLanguage`.
@Suite("App language", .serialized)
struct AppLanguageTests {
    @Test("a chosen language is the one strings resolve in, and nil goes back to the system's")
    func chosenLanguageResolves() {
        let before = UserDefaults.standard.object(forKey: AppLanguage.key)
        let languagesBefore = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer {
            UserDefaults.standard.set(before, forKey: AppLanguage.key)
            UserDefaults.standard.set(languagesBefore, forKey: "AppleLanguages")
        }

        AppLanguage.chosen = "de"
        #expect(String(app: Strings.Settings.language) == "Sprache")
        AppLanguage.chosen = "ja"
        #expect(String(app: Strings.Settings.language) == "言語")
        AppLanguage.chosen = "xx"
        #expect(AppLanguage.chosen == nil)
    }

    @Test("every language is named in itself")
    func autonyms() {
        #expect(AppLanguage.name(of: "ru") == "Русский")
        #expect(AppLanguage.name(of: "en").hasPrefix("English"))
    }
}
