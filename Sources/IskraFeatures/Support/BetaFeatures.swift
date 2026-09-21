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

    /// Whether a person with no picture of their own is drawn as a generated creature rather
    /// than as their initials — see `Blobatar`, and `Avatar`, which is the only place that reads
    /// this.
    static let blobatarKey = "beta.blobatar"

    /// And it is off until somebody asks for it.
    ///
    /// The opposite of `nativeSidebarByDefault`, and for the opposite reason: a sidebar is a
    /// layout somebody can judge in a second and undo in a second, while this changes what every
    /// person in the app *looks like*. Turning that on for somebody who did not ask would replace
    /// a hundred familiar circles at once, which is not a thing to do on their behalf.
    static let blobatarByDefault = false

    /// Whether there is anything in here to show on this platform.
    ///
    /// True everywhere now, and it was not always: the first experiment here was about a sidebar
    /// that does not exist on iPhone, so the screen had nothing on it and the row that led there
    /// was hidden. Generated faces are on every platform, so the screen always has something —
    /// but the question stays, because it is the right one to ask and the answer is free to go
    /// back to being false.
    static var hasAnything: Bool { true }
}
