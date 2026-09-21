#if os(iOS)
import SwiftUI
import UIKit

/// The icon on the home screen, and the five others it can be.
///
/// iPhone and iPad only, and that is not a decision taken here. `setAlternateIconName` is
/// UIKit's; AppKit has no equivalent, and a Mac app's icon is the one inside its bundle —
/// `NSApplication.applicationIconImage` changes what the Dock draws while the app is running and
/// nothing about the app in Finder. So the whole file is behind the platform check and the
/// settings row that leads to it is too, rather than a screen on the Mac that explains it cannot
/// do anything.
///
/// Every one of them is the same spark. What changes is the ground it sits on and what colour it
/// catches: coal so the spark is the only light in it, frost for the cold end of it, garnet and
/// pine for the deep ends, paper for the one that is quiet on a home screen full of colour. A set
/// of icons that were six different drawings would be six different apps.
///
/// The raw value is the icon's name in the bundle, which is what `setAlternateIconName` takes
/// and what `alternateIconName` gives back — so the enum converts in both directions with no
/// table to keep in step. The one the app ships with has no alternate name at all: `nil` is how
/// UIKit says "the original", and `spark` is the name for it here.
enum HomeIcon: String, CaseIterable, Identifiable, Sendable {
    case spark = "iskra"
    case coal = "iskra-coal"
    case frost = "iskra-frost"
    case garnet = "iskra-garnet"
    case pine = "iskra-pine"
    case paper = "iskra-paper"

    var id: String { rawValue }

    /// What UIKit calls it: `nil` for the icon in the bundle, the name for the rest.
    var alternateName: String? { self == .spark ? nil : rawValue }

    /// The other way round, for reading back what is currently in force.
    init(alternateName: String?) {
        self = alternateName.flatMap(HomeIcon.init(rawValue:)) ?? .spark
    }

    /// The ground the spark sits on.
    ///
    /// The same colour the icon's own `icon.json` names, written here a second time because the
    /// tile on the settings screen is drawn rather than loaded — see `SparkShape` for why it has
    /// to be. Two numbers per icon, and the icon would have to be redrawn for them to drift; the
    /// *shape*, which is the part that has actually changed twice, is not copied at all.
    var ground: Color {
        switch self {
        case .spark: Color(red: 0.656, green: 0.600, blue: 0.178)
        case .coal: Color(red: 0.110, green: 0.110, blue: 0.125)
        case .frost: Color(red: 0.380, green: 0.620, blue: 0.860)
        case .garnet: Color(red: 0.440, green: 0.070, blue: 0.160)
        case .pine: Color(red: 0.070, green: 0.260, blue: 0.200)
        case .paper: Color(red: 0.940, green: 0.920, blue: 0.870)
        }
    }

    /// What the spark catches on that ground: the colour the glyph is filled with, and the same
    /// one this icon's copy of the SVG carries.
    var spark: Color {
        switch self {
        case .spark, .coal: Color(red: 0.988, green: 0.976, blue: 0.118)
        case .frost: Color(red: 0.918, green: 0.965, blue: 1.000)
        case .garnet: Color(red: 1.000, green: 0.761, blue: 0.796)
        case .pine: Color(red: 0.651, green: 0.941, blue: 0.776)
        case .paper: Color(red: 0.090, green: 0.090, blue: 0.102)
        }
    }

    /// Whether the system has this icon registered under this name.
    ///
    /// Read out of the app's own `Info.plist`, where `actool` writes what it was told to build —
    /// `CFBundlePrimaryIcon` for the one the app launches with, `CFBundleAlternateIcons` for the
    /// rest. It is the one thing about this feature that can be wrong without being visible: an
    /// icon left out of `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` compiles, ships, and is
    /// refused at the moment somebody taps it. See `HomeIcons.report`.
    var isRegistered: Bool {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any] else {
            return false
        }

        guard let alternateName else {
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
            return primary?["CFBundleIconName"] as? String == rawValue
        }

        let alternates = icons["CFBundleAlternateIcons"] as? [String: Any]
        return alternates?[alternateName] != nil
    }
}

/// Changing it, and reading back what it is.
///
/// A tiny thing to wrap, and it is wrapped for one reason: `setAlternateIconName` can fail — it
/// refuses outright on a device where alternate icons are switched off, and the screen has to be
/// able to say so rather than leave a tapped tile looking chosen when nothing happened.
@MainActor
public enum HomeIcons {
    /// Whether this device will allow it at all. False under some management profiles, and the
    /// screen is not drawn at all when it is.
    static var areSupported: Bool { UIApplication.shared.supportsAlternateIcons }

    static var current: HomeIcon { HomeIcon(alternateName: UIApplication.shared.alternateIconName) }

    /// Setting it shows a system alert — "You have changed the icon for Iskra" — which is iOS's
    /// and cannot be turned off. It is worth knowing about rather than being surprised by: the
    /// screen's footer says it is coming, so the alert reads as confirmation rather than as
    /// something having gone wrong.
    static func set(_ icon: HomeIcon) async throws {
        guard icon != current else { return }
        try await UIApplication.shared.setAlternateIconName(icon.alternateName)
    }

    /// What `Iskra --probe-icons` prints — see `IconProbe`.
    ///
    /// It answers the one question about this feature that no test can. Two build settings have
    /// to be right for an alternate icon to work, they are right in different ways, and both fail
    /// quietly: an icon missing from `ALTERNATE_APPICON_NAMES` is refused at the moment somebody
    /// taps it, and a spark vector missing from the resources leaves six blank tiles on the very
    /// screen where the choosing happens. Neither writes anything to any log. So the probe asks
    /// the installed app what it actually has: whether the system will allow the change at all,
    /// which icon is in force, whether each of the six is registered, and whether the tiles have
    /// anything to draw.
    ///
    /// Public, and the only part of this file that is: the app shell is deliberately thin, so the
    /// probe there prints what this returns rather than working any of it out itself.
    public static func report() -> [String] {
        var lines = ["Iskra icon check"]
        lines.append("  alternates allowed: \(areSupported ? "yes" : "no — this device forbids them")")
        lines.append("  in force: \(current.rawValue)")

        for icon in HomeIcon.allCases {
            if icon.isRegistered {
                lines.append("  ✅ \(icon.rawValue) — registered")
            } else {
                lines.append("  ❌ \(icon.rawValue) — the system does not know this name")
                lines.append("     It is missing from ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES,")
                lines.append("     or its .icon is not in the target's sources. See Apps/project.yml.")
            }
        }

        // And whether the tiles have anything to draw. The vector is a symlink into the icon
        // document, which is exactly the kind of thing a packaging change breaks silently.
        if SparkShape.isDrawable {
            lines.append("  ✅ spark.svg — parsed, the tiles will draw")
        } else {
            lines.append("  ❌ spark.svg — missing or unparseable, the tiles will be flat colour")
        }

        return lines
    }
}
#endif
