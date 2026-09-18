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

    /// And it is on unless somebody turns it off.
    ///
    /// A beta feature nobody has seen is a beta feature nobody has an opinion about: off by
    /// default, this one would have lived its whole life behind a switch on a screen most people
    /// never open, and the thing it is being tried out *for* — whether the Mac's own sidebar is
    /// better than the app's list — would never have been answered. So the Mac opens with it on,
    /// and the switch is the way back rather than the way in.
    ///
    /// Spelled out here rather than written into the two `@AppStorage` declarations that read it,
    /// because a default that disagrees with itself between the screen that sets it and the screen
    /// that obeys it is a bug nothing catches: the toggle would simply show the wrong position.
    static let nativeSidebarByDefault = true

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
