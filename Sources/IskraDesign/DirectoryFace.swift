import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// A chat's face where there is no session to fetch it — the share sheet and the widget.
///
/// Given a file, it draws the picture in it; given none, or one that will not decode, it draws the
/// creature `seed` comes out as. It knows nothing of Matrix: whoever uses it says where the file is
/// (`DirectoryFaces` in `IskraCore`) and what the seed is. The two places that show a chat's face
/// outside the app both draw it through here, so the same chat cannot look one way in the share
/// sheet and another on the home screen.
public struct DirectoryFace: View {
    private let picture: CGImage?
    private let seed: String
    private let name: String
    private let generated: Bool

    /// - Parameters:
    ///   - name: what the initials are taken from when there is no picture and no creature.
    ///   - generated: whether a chat with no picture gets the creature its seed comes out as, or
    ///     the grey circle with initials the app draws — the "faces" switch in Beta features,
    ///     which the caller reads (`BetaFeatures.drawsGeneratedFace`), so that the share sheet and
    ///     the lock screen say what the chat list says.
    ///   - pixelSize: the largest side to decode to. The file is already small, but it was written
    ///     by another process from bytes a server chose, and an extension has little memory.
    public init(file: URL?, seed: String, name: String, generated: Bool, pixelSize: Int = 192) {
        self.picture = Self.picture(at: file, pixelSize: pixelSize)
        self.seed = seed
        self.name = name
        self.generated = generated
    }

    public var body: some View {
        Group {
            if let picture {
                // Over a square rather than as one: a picture that is not square, filled, is laid
                // out larger than its circle, and the overflow takes taps meant for its neighbours.
                Color.clear
                    .overlay {
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
            } else if generated {
                BlobatarView(seed: seed, backdrop: .circle)
            } else {
                InitialsFace(name: name)
            }
        }
        .clipShape(.circle)
        .contentShape(.circle)
    }

    /// The picture in a file, decoded straight to the size it is drawn at — never the whole image
    /// first. Nil when there is no file or it is not a picture.
    public static func picture(at file: URL?, pixelSize: Int = 192) -> CGImage? {
        guard let file else { return nil }
        // A view is rebuilt on every keystroke of the share sheet's search; the faces are not.
        // The file name is the picture's address hashed, so a name never means two pictures.
        let key = "\(file.path)#\(pixelSize)" as NSString
        if let known = cache.object(forKey: key) { return known.image }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(Decoded(image: image), forKey: key)
        return image
    }

    private final class Decoded {
        let image: CGImage
        init(image: CGImage) { self.image = image }
    }

    /// `NSCache` is thread-safe, and empties itself when memory is short — which in an extension is
    /// the thing that matters.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Decoded> = {
        let cache = NSCache<NSString, Decoded>()
        cache.countLimit = 64
        return cache
    }()
}

/// The face a chat has with no picture and the creatures switched off: a grey circle with its
/// initials, as `Avatar` draws it in the app.
public struct InitialsFace: View {
    let name: String

    public init(name: String) {
        self.name = name
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Circle()
                .fill(.quaternary)
                .overlay {
                    Text(verbatim: Initials.of(name))
                        .font(.system(size: side * 0.4, weight: .medium))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// What a face with no picture says: the first letters of the first two words of a name.
public enum Initials {
    public static func of(_ name: String) -> String {
        // Only words that start with a letter or a number count. Punctuation never did any work
        // here, and now it can turn up: a chat renamed on this device is whatever the user typed,
        // so «Тарас (работа)» was coming out as "Т(" — a bracket drawn at forty points, which
        // reads as a bug rather than as a name.
        let words = name.split(separator: " ")
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
            .prefix(2)

        let letters = words.compactMap(\.first).map(String.init).joined().uppercased()
        // A name made entirely of punctuation or emoji still has to draw something, and the first
        // character of it is the best guess there is.
        return letters.isEmpty ? String(name.prefix(1)).uppercased() : letters
    }
}
