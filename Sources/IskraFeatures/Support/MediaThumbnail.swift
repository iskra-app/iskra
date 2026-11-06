import SwiftUI
import IskraCore
import IskraDesign

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The `MediaLoader` for the signed-in user, so that a bubble deep in the timeline can
/// fetch its own picture without every view above it having to pass one down.
private struct MediaLoaderKey: EnvironmentKey {
    static let defaultValue: MediaLoader? = nil
}

public extension EnvironmentValues {
    var mediaLoader: MediaLoader? {
        get { self[MediaLoaderKey.self] }
        set { self[MediaLoaderKey.self] = newValue }
    }

    /// How wide the conversation is. Put here by `RoomView` and read by the one thing that
    /// needs to know: a video note, which grows to fill it while it plays.
    ///
    /// It is measured on the scroll view and handed *down*, and that direction is the whole
    /// point. A message row cannot measure itself for this — it did, and the app locked up.
    /// The row's width is decided by what is in it, and what is in it was being sized from
    /// the row's width: SwiftUI wrote the measurement into state, the state changed the
    /// content, the content changed the measurement, and the view graph re-entered its own
    /// update forever. The main thread never came back, so the timeline froze, and the
    /// download the user was waiting on could not finish either — its continuation was
    /// queued behind a render loop that never ended. The container's width depends on
    /// nothing inside it, and so it can be asked.
    var timelineWidth: CGFloat {
        get { self[TimelineWidthKey.self] }
        set { self[TimelineWidthKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// How tall the conversation is with the keyboard *down* — what a picture's height limit is
    /// a fraction of. Zero where nobody measured, and a picture then asks its container.
    ///
    /// Not the scroll view's height as it stands: the keyboard takes half of that away, and every
    /// photograph on the screen shrank the moment somebody started to type.
    @Entry var timelineHeight: CGFloat = 0
}

private struct TimelineWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension Image {
    /// Bytes to an `Image`, on either platform.
    init?(mediaData data: Data) {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #endif
    }
}

/// A picture in the timeline, fetched only when it scrolls into view.
///
/// Always a *thumbnail*, never the full file: scrolling past a hundred photos should
/// not download a hundred photos. The full-size version is fetched when the user taps.
///
/// In an encrypted room the SDK decrypts as it downloads, so what arrives here is
/// plaintext. It is never written to disk by us — the SDK's own encrypted store is the only
/// cache of the bytes; what is kept is the decoded picture, in memory (`decoded`).
struct MediaThumbnail: View {
    let attachment: Attachment
    /// Longest edge to ask the server for.
    var size: Int = 600

    /// Handed back the moment it arrives, for a caller that needs to draw this same picture a
    /// second way rather than fetch it a second time.
    ///
    /// `PictureBubble` is the one that needs it: the bubble's fill is the photograph itself,
    /// blurred. Asking the loader for it again — even at 64pt, even with the SDK's cache on —
    /// is a second request and a second decode, because the cache is keyed by size and a
    /// different size is a different entry. The picture is already in hand; this passes it over.
    var onLoad: (Image) -> Void = { _ in }

    /// Whether this one waits for Settings → Photos & videos → Auto-download. Only the pictures in
    /// a conversation do; a grid somebody opened to look at pictures has already been asked.
    var obeysAutoDownload = false

    @Environment(\.mediaLoader) private var loader

    @AppStorage(MediaSettings.autoDownloadKey) private var autoDownload = MediaSettings.autoDownloadByDefault

    @State private var image: Image?
    @State private var failed = false

    /// Whether the bytes may be fetched now. Read through two observable singletons, so a tap on
    /// one bubble, or walking out of Wi-Fi, is noticed by every bubble on screen.
    private var mayFetch: Bool {
        !obeysAutoDownload
            || ManualDownloads.shared.contains(attachment.mediaID)
            || autoDownload.allows(onExpensiveNetwork: NetworkCost.shared.isExpensive)
    }

    /// The sender's blur, drawn — what stands in for the picture until it is here.
    ///
    /// Decoded once per hash, not once per redraw: a grid of a hundred tiles waiting for their
    /// pictures redraws all of them every time one arrives.
    private var blur: Image? {
        guard let hash = attachment.blurhash else { return nil }
        if let cached = Self.blurs.object(forKey: hash as NSString) { return Image(decorative: cached.image, scale: 1) }
        guard let image = Blurhash.decode(hash) else { return nil }
        Self.blurs.setObject(DecodedBlur(image: image), forKey: hash as NSString)
        return Image(decorative: image, scale: 1)
    }

    private final class DecodedBlur {
        let image: CGImage
        init(image: CGImage) { self.image = image }
    }

    nonisolated(unsafe) private static let blurs: NSCache<NSString, DecodedBlur> = {
        let cache = NSCache<NSString, DecodedBlur>()
        cache.countLimit = 500
        return cache
    }()

    /// Pictures already decoded, by media and size, in memory only — never on disk; the SDK's
    /// encrypted store is still the only cache of the bytes.
    ///
    /// A row the list rebuilds — a window resized, a long scroll back — is a fresh view with empty
    /// state, and it asked the SDK again and showed the placeholder until the answer came: every
    /// picture on screen flickered through "loading" during a resize. Kept here, a rebuilt row has
    /// its picture on the first frame.
    @MainActor private static let decoded: NSCache<NSString, DecodedPicture> = {
        let cache = NSCache<NSString, DecodedPicture>()
        cache.countLimit = 300
        return cache
    }()

    private final class DecodedPicture {
        let image: Image
        init(image: Image) { self.image = image }
    }

    private var cacheKey: NSString { "\(attachment.mediaID)|\(size)" as NSString }

    /// The picture in state, or the one decoded for an earlier copy of this row.
    private var shown: Image? {
        image ?? Self.decoded.object(forKey: cacheKey)?.image
    }

    var body: some View {
        Group {
            if let image = shown {
                image
                    .resizable()
                    .scaledToFill()
            } else if failed {
                placeholder(systemImage: "photo.badge.exclamationmark")
            } else if !mayFetch {
                waiting
            } else {
                placeholder(systemImage: nil)
            }
        }
        // Keyed on the bytes *and* on being allowed to fetch them, so the tap that allows it is
        // also what starts it. The media ID, not the filename: every sticker is called "sticker".
        .task(id: "\(attachment.mediaID)|\(mayFetch)") {
            guard image == nil else { return }
            if let cached = Self.decoded.object(forKey: cacheKey)?.image {
                image = cached
                onLoad(cached)
                return
            }
            guard mayFetch, let loader else { return }
            do {
                let data = try await loader.thumbnail(for: attachment, size: size)
                image = Image(mediaData: data)
                failed = (image == nil)
                if let image {
                    Self.decoded.setObject(DecodedPicture(image: image), forKey: cacheKey)
                    onLoad(image)
                }
            } catch {
                // A thumbnail that will not load is not worth an alert. The bubble
                // stays, with a quiet marker, and the message is still readable.
                failed = true
            }
        }
    }

    /// Automatic download is off for this network: the blur, and a button that fetches it. The
    /// button and not the whole picture, because a tap on the picture opens the viewer — which is
    /// a request for the full file, and fetches it.
    private var waiting: some View {
        ZStack {
            backdrop
            Button {
                ManualDownloads.shared.ask(for: attachment.mediaID)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.Size.composerControl, height: Theme.Size.composerControl)
                    .background(.black.opacity(Theme.Backdrop.plate), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Media.download))
        }
    }

    /// The blur when the sender sent one, grey when they did not.
    @ViewBuilder
    private var backdrop: some View {
        if let blur {
            blur
                .resizable()
                .scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    @ViewBuilder
    private func placeholder(systemImage: String?) -> some View {
        ZStack {
            backdrop
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }
}
