import Foundation
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
        AppearanceMode.storageKey,
        QuickReaction.storageKey,
        unsavedRecoveryCode,
    ]

    /// Whether the user was shown a recovery code and chose not to save it — which is the one thing
    /// about this account's encryption that the SDK cannot tell us, because it is not a fact about
    /// the account at all. It is a fact about what somebody did on a screen, and only this side of
    /// the app was watching.
    ///
    /// It is **`unsaved`, not `saved`, and it defaults to `false`** — which reads backwards until you
    /// consider the upgrade. Phrased the other way round, every person who has been using Iskra for
    /// months and wrote their code down in January would open the new build to a banner accusing them
    /// of never having saved a code they have had all along. So the flag is only ever raised by *this
    /// app*, in the one place a code is ever shown, when the person in front of it presses "skip".
    ///
    /// Cleared on sign-out along with everything else here — and it must be, or the next person to
    /// sign in on this phone inherits a stranger's warning about a code that was never theirs.
    static let unsavedRecoveryCode = "recovery.codeUnsaved"

    static func forget() {
        let defaults = UserDefaults.standard
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
}
