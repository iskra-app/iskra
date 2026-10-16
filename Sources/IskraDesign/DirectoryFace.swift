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

    /// - Parameter pixelSize: the largest side to decode to. The file is already small, but it was
    ///   written by another process from bytes a server chose, and an extension has little memory.
    public init(file: URL?, seed: String, pixelSize: Int = 192) {
        self.picture = Self.picture(at: file, pixelSize: pixelSize)
        self.seed = seed
    }

    public var body: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                BlobatarView(seed: seed, backdrop: .circle)
            }
        }
        .clipShape(.circle)
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
