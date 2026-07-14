import SwiftUI

/// Light, dark, or whatever the system is doing.
///
/// The system's own setting is the default and is meant to stay the common case: a phone that goes
/// dark at sunset takes every app with it, and an app that refuses is an app that glares at you in
/// bed. What this is for is the person for whom that is exactly wrong — who keeps the phone light
/// and wants their messages dark, or the other way round — and for whom "change it for everything"
/// is not an answer.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let `default` = AppearanceMode.system

    /// One key, written by the appearance screen and read at the root of the app, the same way the
    /// accent travels — see `AccentTheme.storageKey`.
    public static let storageKey = "appearance.mode"

    public var id: String { rawValue }

    /// What `preferredColorScheme` wants: a scheme, or `nil` for "do not have an opinion", which
    /// is what following the system actually *is*. Nil is the whole reason this is not a `Bool`.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
