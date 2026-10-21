import Foundation

/// The app's language, when it is not the system's — Settings → Language on a Mac.
///
/// On iPhone and iPad the language is chosen where iOS wants it chosen, in the app's page of the
/// system Settings, and `chosen` stays nil. A Mac gets a list of its own, applied at once rather
/// than on the next launch, and that is what everything here is for:
///
/// - `Text` resolves a `LocalizedStringResource` with the environment's locale, so the root sets
///   `\.locale` to `locale` and every string on screen follows.
/// - A string resolved in code, `String(localized:)`, takes its language from the resource's own
///   `locale`, which is `Locale.current` — fixed for the life of the process. So nothing resolves
///   a resource that way directly: `resolve` puts `locale` on it first (`String(app:)` in the
///   features is the same thing). This is the same mechanism `LocalizationTests` reads every
///   language through.
/// - What the system draws itself — its own alerts, menus, the share sheet — reads
///   `AppleLanguages`, once, at launch. So the choice is also written there, and those catch up on
///   the next launch; nothing else has to wait for one.
public enum AppLanguage {
    /// In `UserDefaults.standard`: the app's own preference, never the App Group's — the
    /// notification extension speaks the system's language, as it always has.
    public static let key = "app.language"

    /// Every language the app is complete in, as `CFBundleLocalizations` lists them.
    public static let supported = ["ru", "en", "de", "es", "fr", "ja", "zh-Hans"]

    /// The language picked in the app, or nil for the system's.
    public static var chosen: String? {
        get {
            UserDefaults.standard.string(forKey: key).flatMap { supported.contains($0) ? $0 : nil }
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue, supported.contains(newValue) {
                defaults.set(newValue, forKey: key)
                defaults.set([newValue], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    /// The locale strings are resolved in: the chosen language with the system's region — so a
    /// Russian interface on an English Mac in Germany still writes dates the German way — or, with
    /// nothing chosen, the system's own.
    public static var locale: Locale {
        guard let language = chosen ?? systemLanguageIfOverridden else { return .current }
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }

    /// The system's language, read past this app's own `AppleLanguages` — needed only in the
    /// launch in which somebody switched back to "As in the system": `Locale.current` still
    /// speaks the language they just switched away from until the app is started again. Nil when
    /// there is nothing to read past.
    private static var systemLanguageIfOverridden: String? {
        #if os(macOS)
        guard Locale.current.language.languageCode != nil,
              let global = CFPreferencesCopyValue("AppleLanguages" as CFString,
                                                  kCFPreferencesAnyApplication,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost) as? [String] else { return nil }
        return Bundle.preferredLocalizations(from: supported, forPreferences: global).first
        #else
        return nil
        #endif
    }

    /// A string in the app's language — see the type's comment for why not `String(localized:)`.
    public static func resolve(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// A language's name in that language — "Русский", "English", "日本語" — so that each is
    /// found by somebody who reads only it.
    public static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
