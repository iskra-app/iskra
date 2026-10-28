import SwiftUI
import IskraCore
import IskraDesign

/// The shield the app wears while it is locked. An opaque cover — so nothing behind it can be read
/// or screenshotted — with the one thing to do: unlock. It asks the system for Face ID, Touch ID,
/// or the device passcode the moment it appears, and again on the button, and comes down only when
/// the system says yes.
///
/// It carries no way out but authentication. A "Cancel" here would be a lock with a back door.
struct LockScreen: View {
    let appLock: AppLock

    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            // Opaque, over the whole screen: this is what actually hides the conversation behind it,
            // not just a tint.
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.generous) {
                Image(systemName: "lock.fill")
                    .font(.system(size: Theme.Size.avatarLarge))
                    .foregroundStyle(.secondary)

                Text(Strings.Lock.title)
                    .font(.headline)

                Button(String(app: Strings.Lock.unlock)) {
                    unlock()
                }
                .buttonStyle(.glassAction)
                .disabled(isAuthenticating)
            }
            .padding(Theme.Spacing.generous)
        }
        // Ask straight away — the button is the retry, not the first ask.
        .task { unlock() }
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            _ = await appLock.authenticate(reason: String(app: Strings.Lock.reason))
            isAuthenticating = false
        }
    }
}

/// What the app looks like the moment it stops being in front: a blank sheet with a closed padlock
/// on it, and no conversation behind it.
///
/// This is the picture iOS keeps of the app — the card in the app switcher, and the thumbnail it
/// shows again the next time the app is brought forward. The system takes that picture as the app
/// leaves, so whatever is on screen at that instant is what anybody scrolling the switcher gets to
/// read, and that is a whole conversation in plain sight on a phone that is, as far as the owner is
/// concerned, locked. The shield in `LockScreen` cannot help: it goes up on the way *back*, long
/// after the photograph was taken.
///
/// Only when the lock is switched on. Somebody who has not asked the app to lock itself has not
/// asked for their app switcher to be blank either, and a cover they did not ask for reads as the
/// app having crashed.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            // Opaque, like the shield and for the same reason: a blur or a tint is a picture of the
            // conversation with a filter on it, and the words survive a filter better than anyone
            // expects.
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            Image(systemName: "lock.fill")
                .font(.system(size: Theme.Size.avatarLarge))
                .foregroundStyle(.secondary)
        }
        // Nothing to read out and nothing to touch: this is a cover, not a screen.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Whether the cover should be up, given the lock's setting and where the app is in its life.
    ///
    /// `.inactive` is the whole point and not an edge case: it is the phase the app is in *while*
    /// the switcher photograph is taken — by the time `.background` arrives the picture has already
    /// been taken. Waiting for `.background` would cover an app nobody was looking at any more and
    /// leave the one moment that mattered uncovered.
    ///
    /// On a Mac the phase is not enough: a window left behind when somebody switches to another
    /// app stays on screen, readable by whoever is looking, and its scene often still says
    /// `.active`. So there the cover is also up whenever Iskra is not the app in front.
    ///
    /// A pure function so `PrivacyCoverTests` can ask it the question directly; a cover is one of
    /// those things nobody notices is broken until a screenshot proves it.
    static func isNeeded(lockEnabled: Bool, phase: ScenePhase, appIsActive: Bool = true) -> Bool {
        lockEnabled && (phase != .active || !appIsActive)
    }
}
