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
///   the next launch; nothing else has to wait for one. Going back to "As in the system" is the
///   one choice that waits for a relaunch entirely.
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
    /// nothing chosen, the system's own. Built once per choice, not on every call: it is read for
    /// every string the screen resolves.
    public static var locale: Locale {
        guard let chosen else { return .current }
        if let cached = cachedLocale, cached.language == chosen { return cached.locale }
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: chosen)
        let locale = Locale(components: components)
        cachedLocale = (chosen, locale)
        return locale
    }

    nonisolated(unsafe) private static var cachedLocale: (language: String, locale: Locale)?

    /// The language this process started in — what `AppleLanguages` said at launch, and so what
    /// `String(localized:)` already speaks without being told.
    private static let launchLanguage = Bundle.main.preferredLocalizations.first

    /// A string in the app's language — see the type's comment for why not `String(localized:)`.
    ///
    /// The locale goes on the resource **only** when it has to: when somebody has picked a
    /// language other than the one the app started in, and only until the next launch, which
    /// starts in it. A resource with a locale of its own is looked up the slow way — Foundation
    /// reads and parses the whole `.strings` file again for every single string — and with it on
    /// every resource, each row of a conversation spent seconds on its labels, and a Mac window
    /// over a long chat stopped answering altogether.
    public static func resolve(_ resource: LocalizedStringResource) -> String {
        guard let chosen, chosen != launchLanguage else { return String(localized: resource) }
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
