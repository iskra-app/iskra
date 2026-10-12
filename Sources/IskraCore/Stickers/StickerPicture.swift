import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture the person chose to send that goes as a sticker rather than as a photo: a WebP.
///
/// WebP is what stickers *are* everywhere people trade them — Telegram's packs, WhatsApp's, the
/// files saved out of either — and almost nothing else on an iPhone or a Mac is one: the camera
/// writes HEIC, screenshots are PNG. So a WebP is taken at its word, the way Telegram takes it,
/// and sent without a bubble round it, at its own size, with its transparency intact — instead of
/// being redrawn as a PNG photograph with a white square where the see-through part was.
///
/// How it goes depends on the room, and the difference is not cosmetic:
///
/// - **unencrypted**: as an `m.sticker` — uploaded with `Client.uploadMedia` and pointed at, as a
///   sticker from a pack is. Every client draws it as a sticker, and anybody can keep it.
/// - **encrypted**: as an ordinary, *encrypted* `m.image` that says it is `image/webp`, which this
///   app draws as a sticker (`isSticker(mimeType:)`). `uploadMedia` does not encrypt, so an
///   `m.sticker` here would hand the picture to the homeserver in the clear — the same reason
///   video notes are not tagged (`VideoNote`). Other clients show a picture, which is the
///   honest cost of keeping it sealed.
///
/// The compression settings do not apply — a sticker is already small, and a sticker squeezed
/// into a JPEG is a sticker on a black square. Stripping always does, as it does for a video note:
/// the bytes go untouched only if `MetadataStripper.isClean` says there is nothing in them but the
/// picture, and otherwise they are redrawn — as a PNG, because ImageIO cannot write WebP — and if
/// even that is not clean the sticker is not sent.
struct StickerPicture: Sendable, Equatable {
    let data: Data
    let mimeType: String
    let width: Int?
    let height: Int?
    let isAnimated: Bool

    /// The name it is uploaded under. Only its extension matters to anyone: it is how
    /// `MediaMetadata` and the SDK learn the type.
    var filename: String {
        "sticker.\(UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png")"
    }

    static let webPMimeType = "image/webp"

    /// Whether an image with this type is drawn as a sticker — the receiving half of the rule
    /// above, and the one place it is written down.
    static func isSticker(mimeType: String?) -> Bool {
        mimeType?.lowercased() == webPMimeType
    }

    /// What became of a picture offered as a sticker.
    enum Preparation: Sendable, Equatable {
        /// Not a WebP: it is a photo, and goes the way photos go.
        case notASticker
        /// A WebP whose metadata could not be taken out. Refused, never sent as it is.
        case refused
        case ready(StickerPicture)
    }

    /// Recognised by what is *in* the bytes, not by a filename: the photo picker and the
    /// clipboard hand over names that say nothing, or say the wrong thing.
    static func prepare(_ data: Data) -> Preparation {
        guard isWebP(data) else { return .notASticker }

        if MetadataStripper.isClean(photo: data) {
            return describe(data, mimeType: webPMimeType).map(Preparation.ready) ?? .refused
        }
        guard let stripped = MetadataStripper.photo(data, filename: "sticker.webp") else { return .refused }
        let mimeType = MediaMetadata.mimeType(ofFilename: stripped.filename) ?? "image/png"
        return describe(stripped.data, mimeType: mimeType).map(Preparation.ready) ?? .refused
    }

    static func isWebP(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return false }
        return type == UTType.webP.identifier
    }

    private static func describe(_ data: Data, mimeType: String) -> StickerPicture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return StickerPicture(data: data,
                              mimeType: mimeType,
                              width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                              height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                              isAnimated: CGImageSourceGetCount(source) > 1)
    }
}
