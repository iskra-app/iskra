import SwiftUI
import WidgetKit

/// Everything Iskra puts outside itself on the home screen and the lock screen: the favourites
/// widget and the two Live Activities. Their *look* has to live in a widget extension — that is the
/// system's rule — while the app starts and moves the activities (`LiveLocationActivity`,
/// `MediaSendBackground`) and writes what the widget reads (`ChatDirectory`, `DirectoryFaces`).
///
/// Like the share extension it links `IskraCore` and `IskraDesign` and never `IskraFeatures`, and it
/// is granted the App Group and **not** the Keychain group: it reads names and pictures the app left
/// in the container and has no use for anybody's tokens.
@main
struct IskraWidgets: WidgetBundle {
    var body: some Widget {
        FavouritesWidget()
        LiveLocationActivityWidget()
        MediaSendActivityWidget()
    }
}
