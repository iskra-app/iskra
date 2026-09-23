import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The icon on the home screen, and the seven others it can be.
///
/// Changing it is iPhone and iPad only, and that is not a decision taken here. `setAlternateIconName` is
/// UIKit's; AppKit has no equivalent, and a Mac app's icon is the one inside its bundle —
/// `NSApplication.applicationIconImage` changes what the Dock draws while the app is running and
/// nothing about the app in Finder. So the whole file is behind the platform check and the
/// settings row that leads to it is too, rather than a screen on the Mac that explains it cannot
/// do anything. The *list* is not behind the check, though, and deliberately: it is eight names
/// and eight files, it holds whether or not anything can act on it, and behind the check it would
/// have been untestable — `swift test` builds for the Mac, so a check that the pictures are
/// really in the bundle could never have run. `HomeIconPreviewTests` is that check.
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
/// UIKit says "the original", and `spark` is the name for it here. Its raw value is therefore the
/// app's own id for it and not a bundle name — the compiled primary is `iskra-spark`, renamed to
/// shake loose an icon iOS had cached (see `Apps/project.yml`).
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
    ///
    /// It is loaded **from its file**, and that is not incidental. `Image("icon-x", bundle:)`
    /// resolves through an asset catalog, and a SwiftPM resource directory has no catalog in it:
    /// the name misses, SwiftUI draws nothing, and there is no error anywhere — eight blank tiles
    /// and a clean log. `UIImage(named:in:)` is no help in telling you so either, because *it*
    /// does fall back to loose files in the bundle and answers yes about a picture SwiftUI will
    /// never find. So the picture and the probe both go through `previewURL` and neither can be
    /// right while the other is wrong.
    #if os(iOS)
    var preview: Image? {
        guard let previewURL, let image = UIImage(contentsOfFile: previewURL.path) else { return nil }
        return Image(uiImage: image)
    }
    #endif

    /// Where that file is, or `nil` if it is not in the bundle at all.
    var previewURL: URL? { Bundle.module.url(forResource: "icon-\(rawValue)", withExtension: "png") }

    /// Whether the system has this icon registered under this name.
    ///
    /// Read out of the app's own `Info.plist`, where `actool` writes what it was told to build —
    /// `CFBundlePrimaryIcon` for the one the app launches with, `CFBundleAlternateIcons` for the
    /// rest. It is the one thing about this feature that can be wrong without being visible: an
    /// icon left out of `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` compiles, ships, and is
    /// refused at the moment somebody taps it. See `HomeIcons.report`.
    #if os(iOS)
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
    #endif
}

#if os(iOS)

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

    /// Which one is on the home screen.
    ///
    /// UIKit is asked first and believed whenever it names one. It is the `nil` that cannot be
    /// taken at face value: `nil` is UIKit's word for "the icon the app shipped with", and it is
    /// also what `alternateIconName` answers in the Simulator after a change that plainly
    /// worked — the home screen shows the new icon and the property says nothing about it. Read
    /// literally, that emptied the ring off the chosen tile every time the screen was left and
    /// came back to, on a device where the choice was fine.
    ///
    /// So the choice is written down here as well, and stands in when UIKit says nothing. The two
    /// cannot drift: the only thing in the app that can change the icon is `set` below, which
    /// records every change it makes — including a change *back* to the original, so a genuine
    /// `nil` still reads as `spark`.
    static var current: HomeIcon {
        if let name = UIApplication.shared.alternateIconName {
            return HomeIcon(alternateName: name)
        }

        return remembered
    }

    /// The note on its own, which is what the screen draws its ring from.
    static var remembered: HomeIcon {
        UserDefaults.standard.string(forKey: rememberedKey).flatMap(HomeIcon.init(rawValue:)) ?? .spark
    }

    /// Bring the note into line with UIKit, for the one case the note cannot cover: the app was
    /// reinstalled, or the icon was set by a build that kept no note. Called when the screen
    /// appears, and it is the *only* thing that happens then — the ring itself is already drawn.
    static func reconcile() {
        guard let name = UIApplication.shared.alternateIconName else { return }
        UserDefaults.standard.set(name, forKey: rememberedKey)
    }

    /// Where that note is kept. `.standard`, not the App Group's — this is a preference of the
    /// app's, and nothing in the extension has a home screen to care about. Not private: the
    /// screen reads the very same key through `@AppStorage`, so the ring is drawn from storage
    /// rather than from something re-read every time the screen appears.
    static let rememberedKey = "homeIcon.chosen"

    /// Setting it shows a system alert — "You have changed the icon for Iskra" — which is iOS's
    /// and cannot be turned off. It is worth knowing about rather than being surprised by: the
    /// screen's footer says it is coming, so the alert reads as confirmation rather than as
    /// something having gone wrong.
    static func set(_ icon: HomeIcon) async throws {
        guard icon != current else { return }

        do {
            try await UIApplication.shared.setAlternateIconName(icon.alternateName)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSUserCancelledError {
            // A change iOS went ahead and made, reported as a cancellation. There is no cancel
            // button anywhere in this — nobody can cancel an icon change — and it comes back
            // whenever the app is not fully active at the moment of the call. Taken at face
            // value it put the failure alert up over a home screen that had just changed
            // correctly, and left the note unwritten, so the ring went back to the first tile.
            // Measured with `--probe-icons`: the same call from an active app throws nothing.
        }

        UserDefaults.standard.set(icon.rawValue, forKey: rememberedKey)
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

            if icon.previewURL == nil {
                lines.append("     ⚠️ icon-\(icon.rawValue).png is missing — its tile will be blank.")
                lines.append("        Re-export it from icons/\(icon.rawValue).icon; see HomeIcon.preview.")
            }
        }

        return lines
    }
}
#endif
