import Foundation

/// Something the user asked for that did not happen, in a sentence they can act on.
///
/// The three enums that conform — `RoomActionFailure`, `AccountActionFailure`,
/// `RoomCreationFailure` — arrived at the same shape independently, which is the sign that
/// the shape is the real thing: one case per act, a sentence per case, `Identifiable` so an
/// alert can be driven off it. Naming it lets the alert that shows them be written once
/// (`View.failureAlert`) instead of copied into every screen that can refuse something.
///
/// It deliberately says nothing about *presentation*. A failure knows what went wrong; the
/// modifier in `IskraFeatures` knows what an apology looks like.
public protocol ActionFailure: Identifiable, Sendable {
    var explanation: LocalizedStringResource { get }
}
