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
///
/// With the creatures switched off in Beta features, a chat with no picture is a grey circle with
/// its initials — what the app's own chat list draws (`Avatar`).
struct WidgetFace: View {
    let file: URL?
    let seed: String
    let name: String
    var size: CGFloat = Theme.Size.widgetFace

    var body: some View {
        Group {
            if seed.isEmpty && name.isEmpty {
                // Nobody to draw: the app lock is on, and a Live Activity names no one.
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "lock.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.secondary)
                    }
            } else if let picture = DirectoryFace.picture(at: file, pixelSize: pixels) {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
            } else if !BetaFeatures.drawsGeneratedFace(hasPicture: false) {
                InitialsFace(name: name)
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
