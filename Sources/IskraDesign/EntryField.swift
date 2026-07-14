import SwiftUI

/// The way a text field looks when it is the thing the screen is asking for.
///
/// It exists because there were two of them. The sign-in screen drew its own — a plain field on a
/// quaternary fill with a `Radius.control` corner — and the recovery screen that follows it, in the
/// same centred column, in the middle of what is to the user one continuous act of getting in, used
/// `.roundedBorder`: a hairline box with square-ish corners and a different height, which is the
/// system's field from a different decade. Two screens in a row, one of them asking for an address
/// and the next for a code, and the boxes did not match.
///
/// Nobody chose that. Somebody wrote a field, somebody else needed a field and reached for the
/// stock one. So the field is named once and both screens ask for it by name — which is the same
/// argument `Theme` makes about every other number in the app.
public extension View {
    /// A field the user types the answer into: an address, a recovery code, a password.
    ///
    /// The label is carried by the placeholder or by the heading above it, never by a border — so
    /// the fill has to be strong enough to read as somewhere to type without becoming a slab that
    /// competes with the words above it. `.quaternary` is that, in both appearances, without this
    /// file naming a single colour.
    func entryField() -> some View {
        textFieldStyle(.plain)
            .padding(Theme.Spacing.normal)
            .frame(minHeight: Theme.Size.minimumTapTarget)
            .background(.quaternary,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
