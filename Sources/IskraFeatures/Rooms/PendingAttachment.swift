import Foundation
import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import IskraCore
import IskraDesign

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A photo or a video waiting in the composer to be sent — pasted, dropped on the room, or chosen
/// in the photo picker.
///
/// Waiting, and not sent the moment it arrives. It used to be, for the picker: a tap on a photo in
/// the grid *was* the send, with no look at what was about to go and no chance to say anything
/// about it. A paste makes the case more sharply still: it is one keystroke, and the clipboard is
/// full of things people forgot they copied. A screenshot from this morning going straight into a
/// group chat because a hand slipped onto ⌘V is the kind of mistake nobody can take back — so
/// everything lands in the composer, with a cross on it, and leaves with the send button like the
/// words beside it.
///
/// Bytes, never a file, while it waits. The same reasoning as `TimelineStore.send(photo:)`: in an
/// encrypted room a copy on disk is the user's picture sitting in the clear. A video is written out
/// only for the moment `AVAsset` needs a URL — once to draw its still here, once more at send in
/// `RoomView` — and taken away again each time.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let filename: String
    let isVideo: Bool

    /// What the tile in the composer draws — the photo, or a video's first frame — made once, small,
    /// when the item arrives.
    ///
    /// Not the bytes decoded at draw time, which is what the tile first did and what it must not:
    /// the composer is redrawn on every keystroke, and a photo from the camera is twelve megapixels
    /// of HEIC. That was a full decode of every waiting photo per letter typed beside it.
    let preview: CGImage?

    /// The longest side of `preview`: the tile's, three times over, for a screen at 3x.
    private static var previewSide: CGFloat { Theme.Size.attachmentTile * 3 }

    /// The formats that go as they are. Everything else an image can arrive as — TIFF above all,
    /// which is what a Mac puts on the clipboard for anything copied out of an app — is written
    /// out again as PNG: a TIFF is enormous, and half the clients on the other end draw nothing
    /// for one.
    static let sendable: [UTType] = [.jpeg, .png, .gif, .heic, .heif, .webP]

    /// A photo, if these bytes are one, in the form it will go.
    ///
    /// Nil for bytes that do not decode as an image — a drop that claimed to be one and was not.
    /// Nothing is sent for those, and the caller says so.
    init?(data: Data, type: UTType?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        // What the bytes say they are beats what the pasteboard said: a drop often names a
        // supertype, and only the file itself knows whether it is a PNG.
        let actual = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) ?? type
        self.isVideo = false
        self.preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.previewSide,
        ] as CFDictionary)

        if let actual, Self.sendable.contains(where: { actual.conforms(to: $0) }) {
            self.data = data
            self.filename = "\(UUID().uuidString).\(actual.preferredFilenameExtension ?? "jpg")"
            return
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = Self.encode(image, as: .png) else { return nil }
        self.data = png
        self.filename = "\(UUID().uuidString).png"
    }

    private init(video data: Data, filename: String, still: CGImage?) {
        self.data = data
        self.filename = filename
        self.isVideo = true
        self.preview = still
    }

    /// A video, with its first frame drawn for the composer.
    ///
    /// A video whose frame will not draw is still a video — its tile is grey with a play glyph on
    /// it — so a missing still is no reason to refuse it.
    static func video(data: Data, type: UTType?) async -> PendingAttachment {
        let filename = "\(UUID().uuidString).\(type?.preferredFilenameExtension ?? "mp4")"
        return PendingAttachment(video: data, filename: filename, still: await still(of: data, named: filename))
    }

    private static func still(of data: Data, named filename: String) async -> CGImage? {
        let url = URL.temporaryDirectory.appending(component: filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.media.error("a video's still could not be drawn: \(Log.describe(error), privacy: .public)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewSide, height: previewSide)
        return try? await generator.image(at: .zero).image
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - From the photo picker

extension PendingAttachment {
    /// A photo or video the picker handed back, or nil if it would not hand over its bytes.
    ///
    /// `PhotosPickerItem` is a promise of a picture, and redeeming it fails two ways — it throws,
    /// or it succeeds with no data — that mean the same thing to the user. Both are one nil here,
    /// logged on the way past; the caller turns it into words on screen.
    static func load(from item: PhotosPickerItem) async -> PendingAttachment? {
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            Log.media.error("the photo library would not hand over the item: \(Log.describe(error), privacy: .public)")
            return nil
        }
        guard let data else {
            Log.media.error("the photo library returned no bytes for the picked item")
            return nil
        }

        if let movie = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) }) {
            return await video(data: data, type: movie)
        }
        return PendingAttachment(data: data, type: item.supportedContentTypes.first)
    }
}

/// What a drop hands over, carried into the task that reads it.
///
/// `NSItemProvider` is not `Sendable`, and here it is only ever asked for its data — each load is a
/// request the provider answers on a queue of its own, which is what it is built for. The box says
/// that to the compiler; the drop closure cannot say it itself, because it is not allowed to wait.
struct DroppedItems: @unchecked Sendable {
    let providers: [NSItemProvider]
}

// MARK: - Reading them in

extension PendingAttachment {
    /// What a drop or a paste is offered as. Supertypes and not a list of formats: a provider for a
    /// PNG file dragged out of Finder registers `public.png`, a clip registers `com.apple.quicktime-movie`,
    /// and both conform.
    static let acceptedTypes: [UTType] = [.image, .movie]

    /// Whether anything a drag is carrying is a photo or a video. Asked before the drop is accepted,
    /// so that a paragraph of text dragged over the room is not greeted with "let go to attach".
    static func canLoad(from providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.mediaType != nil }
    }

    /// Every photo and video among `providers`, in order, and how many of them could not be read.
    ///
    /// The count matters to the caller and not only to the log: a drop of three photos where one
    /// came out unreadable must say so, or it looks like the app lost one on the way.
    static func load(from providers: [NSItemProvider]) async -> (items: [PendingAttachment], unreadable: Int) {
        var items: [PendingAttachment] = []
        var unreadable = 0
        for provider in providers {
            guard let type = provider.mediaType else { continue }
            guard let data = await provider.data(as: type),
                  let item = await make(data: data, type: type) else {
                unreadable += 1
                continue
            }
            items.append(item)
        }
        if unreadable > 0 {
            Log.media.error("\(unreadable, privacy: .public) dropped or pasted item(s) could not be read")
        }
        return (items, unreadable)
    }

    /// A photo or a video, whichever `type` says, or nil for bytes that are neither.
    static func make(data: Data, type: UTType?) async -> PendingAttachment? {
        if let type, type.conforms(to: .movie) {
            return await video(data: data, type: type)
        }
        return PendingAttachment(data: data, type: type)
    }
}

private extension NSItemProvider {
    /// The most specific photo or video format this provider can hand over, if it can hand over one.
    var mediaType: UTType? {
        registeredContentTypes.first { type in PendingAttachment.acceptedTypes.contains { type.conforms(to: $0) } }
    }

    func data(as type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let error {
                    Log.media.error("a dropped item would not load: \(Log.describe(error), privacy: .public)")
                }
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - The clipboard

/// What is on the clipboard, as far as attaching a photo or a video is concerned.
///
/// Asked *without reading it*. Both systems now tell the user when an app reads the clipboard, and
/// asking what kind of thing is on it is not reading it — which is what lets the "+" offer "Paste"
/// only when there is something to paste, without a prompt every time it opens.
enum MediaPasteboard {
    static var hasMedia: Bool {
        #if os(macOS)
        let board = NSPasteboard.general
        return hasMediaFile(board) || mediaType(of: board.types ?? []) != nil
        #else
        let board = UIPasteboard.general
        return board.hasImages || board.types.contains { UTType($0)?.conforms(to: .movie) == true }
        #endif
    }

    /// The photos and videos on the clipboard, and how many of the things on it that claimed to be
    /// one could not be read.
    static func items() async -> (items: [PendingAttachment], unreadable: Int) {
        #if os(macOS)
        return await macItems(from: .general)
        #else
        return await PendingAttachment.load(from: UIPasteboard.general.itemProviders)
        #endif
    }

    private static func isMedia(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return PendingAttachment.acceptedTypes.contains { type.conforms(to: $0) }
    }

    #if os(macOS)
    /// Whether ⌘V in this room means "attach", or should be left to the text field.
    ///
    /// Copying a *file* in Finder puts three things on the clipboard: the file's URL, its icon as a
    /// TIFF, and its name as text. So "is there text" cannot be the whole test, or a copied photo
    /// would paste its own filename — and "is there an image" cannot either, or it would attach the
    /// icon. A photo or video file wins outright. Otherwise a picture wins only when there is no
    /// text beside it: copying cells out of Numbers carries a picture of the cells as well, and
    /// whoever pasted that meant the words.
    static var pasteMeansAttach: Bool {
        let board = NSPasteboard.general
        if hasMediaFile(board) { return true }
        let types = board.types ?? []
        return mediaType(of: types) != nil && !types.contains(.string)
    }

    private static var mediaFiles: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true,
         .urlReadingContentsConformToTypes: PendingAttachment.acceptedTypes.map(\.identifier)]
    }

    private static func hasMediaFile(_ board: NSPasteboard) -> Bool {
        board.canReadObject(forClasses: [NSURL.self], options: mediaFiles)
    }

    private static func mediaType(of types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        types.first { isMedia(UTType($0.rawValue)) }
    }

    private static func macItems(from board: NSPasteboard) async -> (items: [PendingAttachment], unreadable: Int) {
        var sources: [(data: Data?, type: UTType?)] = []

        let urls = board.readObjects(forClasses: [NSURL.self], options: mediaFiles) as? [URL] ?? []
        if !urls.isEmpty {
            sources = urls.map { url in
                (try? Data(contentsOf: url), UTType(filenameExtension: url.pathExtension))
            }
        } else {
            for item in board.pasteboardItems ?? [] {
                guard let type = mediaType(of: item.types) else { continue }
                sources.append((item.data(forType: type), UTType(type.rawValue)))
            }
        }

        var items: [PendingAttachment] = []
        var unreadable = 0
        for source in sources {
            if let data = source.data, let item = await PendingAttachment.make(data: data, type: source.type) {
                items.append(item)
            } else {
                unreadable += 1
            }
        }
        if unreadable > 0 {
            Log.media.error("\(unreadable, privacy: .public) pasted item(s) could not be read")
        }
        return (items, unreadable)
    }
    #endif
}
