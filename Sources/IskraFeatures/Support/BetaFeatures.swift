import Foundation

/// The half-finished things, behind a switch.
///
/// A beta feature here is not a staged rollout and not an A/B test — there is nobody to roll it
/// out to. It is the app admitting that a change is big enough to be worth living with for a
/// while before it becomes the only way the app works: the old behaviour stays exactly where it
/// was, one switch away, so trying the new one costs nothing and regretting it costs nothing
/// either.
///
/// Each flag is a key in `UserDefaults`, read with `@AppStorage` wherever it matters, and named
/// here so there is one list of them. The list is also what `AppSettings.forget()` empties on
/// sign-out — an experiment somebody opted into is a preference of *theirs*, and the next person
/// to sign in on this device should get the app as it ships.
enum BetaFeatures {
    /// Whether the conversation list is drawn as a macOS sidebar rather than as the app's own
    /// plain list — see `RoomListView`.
    static let nativeSidebarKey = "beta.nativeSidebar"

    /// Whether there is anything in here to show on this platform.
    ///
    /// False on iOS, where the one experiment is about a sidebar that does not exist: the split
    /// view collapses to a stack on iPhone, and on iPad the sidebar is already the system's. A
    /// settings row leading to a screen with nothing on it is worse than no row at all — so the
    /// row is asked this question, not `#if os(macOS)` spelled out at each of the three places
    /// that care.
    static var hasAnything: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
