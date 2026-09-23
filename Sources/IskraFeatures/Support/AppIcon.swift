import SwiftUI
import IskraDesign

/// The app's own icon, fetched from the bundle rather than kept as a second copy in a
/// resource of its own.
///
/// There is exactly one icon in this project — `iskra-spark.icon`, an Icon Composer document — and
/// it is compiled by `actool` into the app bundle. Adding a PNG beside it so that a screen
/// could show a picture of the app would be a second icon to keep in step with the first, and
/// the first one changes.
///
/// Getting it back out is two different questions on the two platforms:
///
/// - On macOS the window server already has it, and `applicationIconImage` is the answer.
/// - On iOS there is no such call. The way in is `CFBundleIcons`, which `actool` writes into
///   `Info.plist`: the last entry of `CFBundleIconFiles` is the largest variant, and it is a
///   name `UIImage(named:)` can resolve. `CFBundleIconName` is tried after it because a build
///   configured by name alone still has that key, and `"AppIcon"` last because that is what an
///   asset catalog is called everywhere but here.
///
/// All three can miss — under `swift test` and in a SwiftUI preview there is no app bundle at
/// all — so this returns an optional and `AppIconView` draws a spark instead. A screen about
/// the app is not worth a crash, and a hole where the icon should be is worse than a stand-in.
enum AppIcon {
    /// The icon as Icon Composer exported it (`icons/pngs`), scaled to 384 and shipped as
    /// `about-iskra.png` — which is what the About screen shows.
    ///
    /// Asked for first, and the bundle's compiled icon only after it, because the two are not the
    /// same picture: on iOS the only one that can be got back out of the bundle is the legacy
    /// 60-point square, an older rendering with no layers in it, and on macOS it is the icon
    /// already inset in the Mac's own margin. Loaded from its file URL and never by name — a
    /// SwiftPM resource directory has no asset catalog, so a lookup by name draws nothing. See
    /// `HomeIcon.previewURL`, which is the same rule.
    @MainActor
    static var artwork: Image? {
        guard let url = Bundle.module.url(forResource: "about-iskra", withExtension: "png") else { return nil }
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }

    #if os(macOS)
    @MainActor
    static var image: Image? {
        Image(nsImage: NSApplication.shared.applicationIconImage)
    }
    #else
    @MainActor
    static var image: Image? {
        for name in candidateNames {
            if let icon = UIImage(named: name) {
                return Image(uiImage: icon)
            }
        }
        return nil
    }

    /// Largest first is deliberate: `CFBundleIconFiles` is ordered smallest to largest, and a
    /// 20-point icon stretched to sixty is a blur.
    private static var candidateNames: [String] {
        var names: [String] = []
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        if let files = primary?["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files.reversed())
        }
        if let name = primary?["CFBundleIconName"] as? String {
            names.append(name)
        }
        names.append("AppIcon")
        return names
    }
    #endif
}

/// The icon at a given size, with the corners the system gives it.
///
/// The rounding is drawn here rather than trusted to the file, because neither platform hands
/// over a rounded picture: macOS returns the icon with its own margin already in it and iOS
/// returns a bare square. A continuous corner at a quarter of the side is the shape iOS uses,
/// and on macOS it falls just outside the artwork, where it costs nothing.
struct AppIconView: View {
    var size: CGFloat

    @Environment(\.accent) private var accent

    var body: some View {
        if let artwork = AppIcon.artwork {
            // The Icon Composer export, which carries its own corner and transparent outside —
            // so it is drawn as it is, and not clipped again to a corner that is not quite its own.
            artwork
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            bundleIcon
        }
    }

    private var bundleIcon: some View {
        Group {
            if let icon = AppIcon.image {
                icon
                    .resizable()
                    .interpolation(.high)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        .accessibilityHidden(true)
    }

    /// What is shown where there is no bundle to ask — a preview, or a test. A spark, because
    /// that is what the name means.
    private var placeholder: some View {
        accent.color.overlay {
            Image(systemName: "sparkles")
                .font(.system(size: size / 2))
                .foregroundStyle(accent.foreground)
        }
    }
}
