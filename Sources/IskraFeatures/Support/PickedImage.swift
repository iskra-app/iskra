import SwiftUI
import PhotosUI
import IskraCore

/// The bytes behind a photo the user picked, or nil if the library would not hand them over.
///
/// `PhotosPickerItem` is a *promise* of an image, and redeeming it fails in two ways that
/// look nothing alike in code and identical to the user: it throws, or it succeeds and
/// returns no data. Both mean the same thing — the picture did not arrive, and whatever it
/// was going to be attached to must say so — so both are one `nil` here, logged on the way
/// past.
///
/// Written once because the two screens that pick an avatar had the same fifteen lines,
/// down to the wording of the log line.
func imageData(from item: PhotosPickerItem) async -> Data? {
    do {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            Log.media.error("the photo library returned no bytes for the picture")
            return nil
        }
        return data
    } catch {
        Log.media.error("the photo library would not hand over the picture: \(Log.describe(error), privacy: .public)")
        return nil
    }
}
