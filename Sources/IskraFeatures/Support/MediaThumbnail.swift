import SwiftUI
import IskraCore

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
/// plaintext. It is handed straight to the view and never written to a cache of our
/// own — the SDK's own encrypted store is the only cache.
struct MediaThumbnail: View {
    let attachment: Attachment
    /// Longest edge to ask the server for.
    var size: Int = 600

    @Environment(\.mediaLoader) private var loader

    @State private var image: Image?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else if failed {
                placeholder(systemImage: "photo.badge.exclamationmark")
            } else {
                placeholder(systemImage: nil)
            }
        }
        .task(id: attachment.filename) {
            guard image == nil, let loader else { return }
            do {
                let data = try await loader.thumbnail(for: attachment, size: size)
                image = Image(mediaData: data)
                failed = (image == nil)
            } catch {
                // A thumbnail that will not load is not worth an alert. The bubble
                // stays, with a quiet marker, and the message is still readable.
                failed = true
            }
        }
    }

    @ViewBuilder
    private func placeholder(systemImage: String?) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
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
