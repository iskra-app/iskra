import CoreGraphics
import Foundation
import IskraCore
import IskraDesign
import SwiftUI
import WidgetKit

/// A face as the widget and the activities draw it: the chat's picture from the App Group, or the
/// creature its seed comes out as.
///
/// Not `DirectoryFace` itself, though it makes the same decision from the same file, for two reasons
/// that are both about where it is shown. The creature is handed over as pixels rather than as a
/// `Canvas` — a widget is drawn ahead of time and archived, and pixels are what survives that
/// without doubt. And on a tinted home screen every picture would otherwise be flooded with one
/// colour into a silhouette; `.desaturated` keeps it a face.
struct WidgetFace: View {
    let file: URL?
    let seed: String
    var size: CGFloat = Theme.Size.widgetFace

    var body: some View {
        Group {
            if let picture = DirectoryFace.picture(at: file, pixelSize: pixels) {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
            } else if let creature = BlobatarImage.cgImage(for: seed, size: pixels) {
                Image(decorative: creature, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFit()
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var pixels: Int { Int(size * 3) }

    /// The file a face is in, given its name in the directory or an activity's state.
    static func file(named name: String?) -> URL? {
        guard let folder = try? DirectoryFaces.folder(),
              let url = DirectoryFaces.url(of: name, in: folder),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
