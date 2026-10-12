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
/// the container is cut down to the chunks the picture is made of (`pictureOnly`), that is held to
/// `MetadataStripper.isClean`, and anything that still fails it is redrawn — as a PNG, because ImageIO cannot write WebP — and if
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

        // Two checks and not one, because the second alone is not enough: `isClean` sees only what
        // ImageIO chooses to surface, and an `EXIF` or `XMP ` chunk it does not surface would pass
        // it and go out byte for byte. So the container is cut down to the picture first.
        if let picture = pictureOnly(data), MetadataStripper.isClean(photo: picture) {
            return describe(picture, mimeType: webPMimeType).map(Preparation.ready) ?? .refused
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

    /// The chunks a WebP's picture is made of. Everything else — `EXIF`, `XMP `, and anything
    /// nobody has thought of yet — is left behind: an allow-list, as `MetadataStripper`'s is.
    /// The colour profile stays, as it does for every other photo.
    private static let pictureChunks: Set<String> = ["VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF", "ICCP"]

    /// The WebP with only `pictureChunks` in it, and its header saying no more than it carries.
    /// Nil for a file that is not well-formed RIFF — refused, not sent as it came.
    static func pictureOnly(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WEBP".utf8) else { return nil }

        func size(at offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }

        var kept = [UInt8]()
        var offset = 12
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { return nil }
            let name = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let length = size(at: offset + 4)
            let end = offset + 8 + length + (length & 1)
            guard length >= 0, offset + 8 + length <= bytes.count else { return nil }
            if pictureChunks.contains(name) {
                var chunk = Array(bytes[offset..<min(end, bytes.count)])
                if length & 1 == 1, chunk.count < 8 + length + 1 { chunk.append(0) }
                // VP8X's flags announce EXIF (0x08) and XMP (0x04); neither is there any more.
                if name == "VP8X", length >= 1 { chunk[8] &= ~UInt8(0x0C) }
                kept += chunk
            }
            offset = end
        }

        let riffSize = UInt32(4 + kept.count)
        var output = Array("RIFF".utf8)
        output += withUnsafeBytes(of: riffSize.littleEndian, Array.init)
        output += Array("WEBP".utf8)
        output += kept
        return Data(output)
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
