import Testing
import Foundation
@testable import IskraCore
@testable import IskraFeatures

/// Guards the two ways localization fails silently.
///
/// The first is a missing `bundle:` — inside a Swift package, `LocalizedStringResource`
/// looks in `Bundle.main` by default, finds nothing, and cheerfully returns the key
/// itself. The screen then reads "signIn.title" and everything still compiles.
///
/// The second is a translation that was never written: the catalog falls back to
/// English, and a Russian user sees an English sentence.
@MainActor
struct LocalizationTests {
    /// Every string the app can put on screen. Adding one to `Strings` without adding
    /// it here is fine; adding one without a translation is not, and that is what
    /// these catch.
    private static let englishAndRussian: [(LocalizedStringResource, en: String, ru: String)] = [
        (Strings.SignIn.title, en: "Welcome to Iskra", ru: "Добро пожаловать в Iskra"),
        (Strings.SignIn.whereIsAccount, en: "Where’s your account?", ru: "Где ваш аккаунт?"),
        (Strings.SignIn.continue, en: "Continue", ru: "Продолжить"),
        (Strings.RoomList.title, en: "Chats", ru: "Чаты"),
        (Strings.RoomList.searchPrompt, en: "Search messages", ru: "Поиск по сообщениям"),
        (Strings.Room.composerPlaceholder, en: "Message", ru: "Сообщение"),
        (Strings.Message.Delivery.read, en: "Read", ru: "Прочитано"),
        (Strings.Account.signOut, en: "Sign out", ru: "Выйти")
    ]

    @Test("app strings resolve in English and in Russian")
    func appStringsAreTranslated() {
        for (resource, english, russian) in Self.englishAndRussian {
            var resource = resource

            resource.locale = Locale(identifier: "en")
            #expect(String(localized: resource) == english)

            resource.locale = Locale(identifier: "ru")
            #expect(String(localized: resource) == russian)
        }
    }

    @Test("core strings resolve in English and in Russian")
    func coreStringsAreTranslated() {
        var protected = CoreStrings.Privacy.protected

        protected.locale = Locale(identifier: "en")
        #expect(String(localized: protected).contains("Only people in this chat"))

        protected.locale = Locale(identifier: "ru")
        #expect(String(localized: protected).contains("только участники чата"))
    }

    /// The failure this is really guarding against: a string that resolves to its own
    /// key because the bundle was wrong. That looks fine to the compiler and awful on
    /// screen.
    @Test("no string resolves to its own key")
    func noStringLeaksItsKey() {
        for (resource, _, _) in Self.englishAndRussian {
            let resolved = String(localized: resource)
            #expect(!resolved.contains("."), "\(resolved) looks like a key, not a sentence")
        }
    }

    /// The bundle must actually ship both languages.
    ///
    /// Note what this cannot catch: the app *bundle* also has to declare
    /// `CFBundleLocalizations` in its Info.plist. Without that the system treats the
    /// app as English-only, `Locale.current` never becomes Russian, and these
    /// translations are never reached — even though every test here passes, because
    /// the tests set the locale by hand. That declaration lives in Apps/project.yml.
    @Test("both languages ship in the bundle")
    func bothLanguagesArePresent() {
        let localizations = Set(Strings.resourceBundle.localizations)
        #expect(localizations.contains("en"))
        #expect(localizations.contains("ru"))
    }

    /// Russian has one/few/many where English has one/other. A count of 2 and a count
    /// of 5 must not read the same.
    @Test("Russian plurals decline")
    func russianPluralsDecline() {
        func unread(_ count: Int) -> String {
            var resource = Strings.RoomList.unread(count)
            resource.locale = Locale(identifier: "ru")
            return String(localized: resource)
        }

        #expect(unread(1) == "1 непрочитанное")
        #expect(unread(2) == "2 непрочитанных")
        #expect(unread(5) == "5 непрочитанных")
    }
}
