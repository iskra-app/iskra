#if os(iOS)
import UIKit
#endif

/// The tenth of a second every scroll view in the app spends deciding whether a finger is a
/// scroll, before anything underneath it is told the finger is there at all.
///
/// `UIScrollView.delaysContentTouches` is on by default and costs about 150 ms. It is invisible
/// almost everywhere — a button pressed in a settings list simply highlights a moment late — and
/// it is not invisible on the one gesture in this app that is timed: the press that lifts a
/// message into its menu. That press is 170 ms (`Theme.Timing.menuLift`), and the clock does not
/// start until the touch is delivered, so the number the app believes it is asking for and the
/// wait a thumb actually feels are two different numbers. Shortening `menuLift` alone barely
/// moved it, which is exactly the symptom of a delay that lives somewhere else.
///
/// So the delay is turned off, and the press becomes the whole of the wait.
///
/// The trade is real and worth stating: with touches delivered immediately, a finger that comes
/// down on a message and rests there for a moment before flicking is a finger that has held a
/// message for 170 ms, and the menu opens. A scroll begun with any movement at all is unaffected
/// — the scroll view still cancels the touch it handed on, and the long press still gives up if
/// the finger travels — so what this costs is the deliberate press-and-pause, and what it buys is
/// every ordinary press arriving when it was asked for.
///
/// Set through the appearance proxy because SwiftUI exposes no scroll view to ask. That makes it
/// every scroll view in the app rather than only the conversation, which is the right answer
/// anyway: nothing here wants its taps held back.
///
/// On the main actor because the appearance proxy is, and because the one caller — the root
/// view's initialiser — is already there. A root view is built more than once in the life of an
/// app, so the work is done once and the flag remembers.
@MainActor
enum ScrollTouches {
    private static var isStopped = false

    /// Called from `IskraRootView.init`.
    static func stopDelaying() {
        guard !isStopped else { return }
        isStopped = true

        #if os(iOS)
        UIScrollView.appearance().delaysContentTouches = false
        #endif
    }
}
