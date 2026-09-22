#if os(iOS)
import SwiftUI
import UIKit

/// The icon on the home screen, and the seven others it can be.
///
/// iPhone and iPad only, and that is not a decision taken here. `setAlternateIconName` is
/// UIKit's; AppKit has no equivalent, and a Mac app's icon is the one inside its bundle —
/// `NSApplication.applicationIconImage` changes what the Dock draws while the app is running and
/// nothing about the app in Finder. So the whole file is behind the platform check and the
/// settings row that leads to it is too, rather than a screen on the Mac that explains it cannot
/// do anything.
///
/// Most of them are the same spark on a different ground — chrome so it is metal in the dark,
/// garnet and pine for the deep ends, black-and-white for the one that is quiet on a home screen
/// full of colour, Rio for the one that is not quiet at all. Two are not: `retro` cuts the spark
/// out of a disc, and `letters` drops the spark altogether for the name set in type. That is why
/// the tiles on the picker are pictures now and no longer a shape drawn from two colours — see
/// `preview`.
///
/// The raw value is the icon's name in the bundle, which is what `setAlternateIconName` takes
/// and what `alternateIconName` gives back — so the enum converts in both directions with no
/// table to keep in step. The one the app ships with has no alternate name at all: `nil` is how
/// UIKit says "the original", and `spark` is the name for it here.
enum HomeIcon: String, CaseIterable, Identifiable, Sendable {
    case spark = "iskra"
    case chrome = "iskra-chrome"
    case garnet = "iskra-garnet"
    case pine = "iskra-pine"
    case rio = "iskra-rio-de-janeiro"
    case blackWhite = "iskra-black-white"
    case retro = "iskra-retro"
    case letters = "iskra-letters"

    var id: String { rawValue }

    /// What UIKit calls it: `nil` for the icon in the bundle, the name for the rest.
    var alternateName: String? { self == .spark ? nil : rawValue }

    /// The other way round, for reading back what is currently in force.
    init(alternateName: String?) {
        self = alternateName.flatMap(HomeIcon.init(rawValue:)) ?? .spark
    }

    /// The picture on the tile: the icon itself, exported at 1024 from its own Icon Composer
    /// document and shipped in `IskraFeatures/Resources` at 240 points square.
    ///
    /// It is a second copy of the artwork and there is no way round that. A compiled `.icon`
    /// cannot be got back out of the bundle as a picture — `UIImage(named:)` returns nothing for
    /// the alternates and throws for the primary — so Apple's own guidance is that a picker
    /// ships its own previews, which is exactly what these are.
    ///
    /// The tiles used to be *drawn* instead, from the one vector every icon shared, which was
    /// honest while every icon was the same spark on a different ground. It stopped being
    /// honest: `retro` is the spark knocked out of a disc and `letters` has no spark in it at
    /// all, so a drawn tile would have shown two icons that do not exist. A picture cannot
    /// disagree with the icon it is a picture of.
    ///
    /// The export already carries the rounded corner and a transparent outside, so the tile
    /// neither masks it nor puts a shape behind it.
    var preview: Image { Image("icon-\(rawValue)", bundle: .module) }

    /// Whether that picture is actually in the bundle. Only the probe asks — a missing preview
    /// is an empty tile and writes nothing to any log.
    var hasPreview: Bool { UIImage(named: "icon-\(rawValue)", in: .module, with: nil) != nil }

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
    /// taps it, and a preview missing from the resources leaves a blank tile on the very screen
    /// where the choosing happens. Neither writes anything to any log. So the probe asks the
    /// installed app what it actually has: whether the system will allow the change at all,
    /// which icon is in force, whether each of the eight is registered, and whether each has a
    /// picture to show.
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

            if !icon.hasPreview {
                lines.append("     ⚠️ icon-\(icon.rawValue).png is missing — its tile will be blank.")
                lines.append("        Re-export it from icons/\(icon.rawValue).icon; see HomeIcon.preview.")
            }
        }

        return lines
    }
}
#endif
