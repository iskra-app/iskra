import SwiftUI
import IskraCore
import IskraDesign

/// The one picture the user chose to sit behind their conversations, and where it is kept.
///
/// On this device and nowhere else. A wallpaper is not account data — it is not synced, it is not
/// backed up into the encrypted store, and it never goes near the homeserver — so it lives as a
/// plain file in the app's own Application Support directory. It is also the one thing in this app
/// deliberately kept *out* of the App Group: the notification extension has no use for it, and
/// twenty-four megabytes of budget is not the place to hold a photograph.
///
/// A singleton, which is not the app's habit and is the right shape here. Every room draws the
/// wallpaper, so a store owned per view would read the same JPEG off the disk once per conversation
/// opened and once more each time one was reopened; the picture is a single fact about the app, held
/// once, and the rooms observe it.
@MainActor
@Observable
final class WallpaperStore {
    static let shared = WallpaperStore()

    /// The picture, once it has been read. Nil before that, and nil for good if the file is not
    /// there or will not decode — in which case a conversation simply sits on the app's own page,
    /// which is what it did before anybody chose anything.
    private(set) var photo: Image?

    /// How bright the picture is on average, 0 to 1 — what the time beside a bubble takes its
    /// colour from (`onWallpaperInk()`). Measured once, when the picture is read.
    private(set) var luminance: Double?

    /// Whether the disk has already been asked. The file is read once per launch: it does not
    /// change except through `store(_:)`, which updates `photo` itself.
    private var hasLoaded = false

    private init() {}

    private var directory: URL {
        URL.applicationSupportDirectory.appending(component: "Iskra")
    }

    private var fileURL: URL {
        directory.appending(component: "wallpaper.jpg")
    }

    /// Reads the picture off the disk, once.
    ///
    /// Off the main actor for the read itself: a wallpaper can be a twelve-megapixel photograph, and
    /// decoding one on the actor that draws the conversation is a visible stall on the first room
    /// opened after launch.
    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        let url = fileURL
        let read = await Task.detached(priority: .userInitiated) { () -> (Data, Double?)? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (data, Self.measure(data))
        }.value

        guard let read, let image = Image(mediaData: read.0) else { return }
        photo = image
        luminance = read.1
    }

    /// The picture's mean relative luminance, from a thumbnail a few pixels across — which is the
    /// average the eye makes of it from arm's length, and costs nothing.
    nonisolated static func measure(_ data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 16
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = thumbnail.width, height = thumbnail.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += Wallpaper.luminance(red: Double(pixels[index]) / 255,
                                         green: Double(pixels[index + 1]) / 255,
                                         blue: Double(pixels[index + 2]) / 255)
        }
        return total / Double(width * height)
    }

    /// Keeps a picked photograph as the wallpaper.
    ///
    /// The bytes are written as they came from the library, not re-encoded. A JPEG re-encoded to be
    /// stored is a JPEG made slightly worse for no reason, and the one thing this file is for is
    /// being looked at.
    func store(_ data: Data) {
        guard let image = Image(mediaData: data) else {
            Log.media.error("the picked wallpaper could not be decoded")
            return
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Kept on screen anyway. The picture the user just chose is in memory and is already
            // their wallpaper; what failed is its surviving a relaunch, and telling them about it
            // in the middle of choosing a background would be the app making a drama of a JPEG.
            Log.media.error("the wallpaper would not be written: \(Log.describe(error), privacy: .public)")
        }

        hasLoaded = true
        photo = image
        luminance = Self.measure(data)
    }

    /// Whether this wallpaper, at this dimming, is dark enough for light words — see
    /// `Wallpaper.isDark`. A photograph not yet measured counts as dark: it is dimmed by default,
    /// and white with a halo is the safer guess over a picture nobody has looked at yet.
    func isDark(_ wallpaper: Wallpaper, dimming: Double) -> Bool {
        let luminance = wallpaper == .photo ? self.luminance : wallpaper.luminance
        guard let luminance else { return true }
        return Wallpaper.isDark(luminance: luminance, dimming: dimming)
    }

    /// Forgets it — signing out, or choosing a different wallpaper after having used one's own.
    func forget() {
        photo = nil
        luminance = nil
        hasLoaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The wallpaper behind a conversation: the setting, the picture, and the dimmer, assembled.
///
/// A view of its own rather than a modifier on the room, because the two `@AppStorage` reads belong
/// to *it*. Put on the room they would rebuild the whole conversation — every row, every bubble —
/// each time the dimming slider moved a hair on the settings screen behind it.
struct ChatWallpaper: View {
    @AppStorage(Wallpaper.storageKey) private var wallpaper: Wallpaper = .default
    @AppStorage(Wallpaper.dimmingKey) private var dimming: Double = Wallpaper.defaultDimming

    private let store = WallpaperStore.shared

    var body: some View {
        WallpaperBackdrop(wallpaper: wallpaper, photo: store.photo, dimming: dimming)
            .task { await store.load() }
    }
}

extension View {
    /// Puts the chosen wallpaper behind this screen, and tells the bubbles standing on it that they
    /// are standing on something — see `EnvironmentValues.hasWallpaper`.
    func chatWallpaper() -> some View {
        modifier(ChatWallpaperBackground())
    }
}

private struct ChatWallpaperBackground: ViewModifier {
    @AppStorage(Wallpaper.storageKey) private var wallpaper: Wallpaper = .default
    @AppStorage(Wallpaper.dimmingKey) private var dimming: Double = Wallpaper.defaultDimming

    func body(content: Content) -> some View {
        content
            .environment(\.hasWallpaper, wallpaper.isSet)
            .environment(\.wallpaperIsDark, WallpaperStore.shared.isDark(wallpaper, dimming: dimming))
            .background { ChatWallpaper() }
    }
}
