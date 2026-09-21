import Foundation
import IskraCore
import IskraDesign

/// Everything the app remembers about *how it looks and behaves* rather than about who is using
/// it: the accent colour, the reaction the double-tap sends.
///
/// It lives in `UserDefaults`, reached through `@AppStorage` at the handful of places that read
/// it, and this type exists for the one operation none of those places can perform — forgetting
/// all of it at once.
///
/// **Signing out forgets it.** Not because the settings are secret; they are a colour and an
/// emoji, and nothing here is worth protecting. Because the next person to sign in on this device
/// is a *different person*, and handing them the last one's chosen colour and quick reaction is
/// the app telling them something about somebody who has left. A signed-out app should look like
/// an app nobody has used yet, which is what it looked like before anybody did.
///
/// The account's own data is not here and is not forgotten by this: the store, the keys and the
/// tokens are destroyed by `AuthenticationService.signOut`, which is where destroying things that
/// matter belongs.
enum AppSettings {
    /// Every key this app writes to `UserDefaults`, in one list — which is the point of the type.
    /// A setting added elsewhere and not added here survives a sign-out, and survives it silently:
    /// nothing fails, nothing is logged, and the new user simply inherits it.
    private static let keys = [
        AccentTheme.storageKey,
        AccentTheme.tintsInterfaceKey,
        AppearanceMode.storageKey,
        MessageLayout.storageKey,
        QuickReaction.storageKey,
        Wallpaper.storageKey,
        Wallpaper.dimmingKey,
        TunnelSettings.enabledKey,
        BetaFeatures.nativeSidebarKey,
        BetaFeatures.blobatarKey,
        BetaFeatures.forceBlobatarKey,
    ]

    @MainActor
    static func forget() {
        let defaults = UserDefaults.standard
        for key in keys {
            defaults.removeObject(forKey: key)
        }

        // And the one setting that is not a value in `UserDefaults` but a file on the disk: the
        // wallpaper somebody chose from their own photo library. Forgetting the *key* and leaving
        // the picture behind would mean the next person to sign in on this device found a stranger's
        // photograph waiting the moment they went looking at wallpapers.
        WallpaperStore.shared.forget()
    }
}
