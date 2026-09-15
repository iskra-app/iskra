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
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value

        guard let data, let image = Image(mediaData: data) else { return }
        photo = image
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
    }

    /// Forgets it — signing out, or choosing a different wallpaper after having used one's own.
    func forget() {
        photo = nil
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

    func body(content: Content) -> some View {
        content
            .environment(\.hasWallpaper, wallpaper.isSet)
            .background { ChatWallpaper() }
    }
}
