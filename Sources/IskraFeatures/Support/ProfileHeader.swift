import SwiftUI
import IskraDesign

/// The top of a profile: a large round picture, the name under it, and one quiet line under
/// that saying which account or how many people this is.
///
/// The same three things in the same arrangement for a person and for a room, because they are
/// the same question — *who is this* — and answering it two different ways on two screens is how
/// an app starts to look assembled rather than designed.
///
/// Nothing here is editable, and that is the change this header made. Both screens used to put a
/// text field where the name is and hang a menu off the picture, so the profile was permanently
/// half in edit mode: a name you could delete by leaning on the screen, and a picture that opened
/// a menu when you only wanted a closer look. The pencil in the corner moved both of those to a
/// screen you have to mean to open — see `ProfileEditView` and `RoomEditView`.
struct ProfileHeader: View {
    let name: String
    /// The `mxc://` URL, or nil — `Avatar` draws the initials either way.
    let avatarURL: String?
    /// A Matrix ID under a person, a count of people under a room. Nil when there is nothing
    /// worth saying: an empty line under the name leaves the name looking as though it lost
    /// something.
    var subtitle: String?
    var shape: AvatarShape = .circle
    /// Whether the line underneath is the kind of thing somebody opened this screen to copy.
    /// A Matrix ID is; "12 participants" is not, and a count that highlights under a long press
    /// is a small piece of nonsense.
    var isSubtitleSelectable = false

    var body: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Avatar(name: name, url: avatarURL, size: Theme.Size.avatarProfile, shape: shape)

            VStack(spacing: Theme.Spacing.tight) {
                Text(name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let subtitle {
                    let line = Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    // Two branches rather than a ternary: `.enabled` and `.disabled` are two
                    // different types, and `TextSelectability` is a protocol with an associated
                    // type, so there is no expression that picks between them.
                    if isSubtitleSelectable {
                        line.textSelection(.enabled)
                    } else {
                        line.textSelection(.disabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.roomy)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// How the header sits in the `Form` above everything else: centred on the page itself,
    /// with no card drawn round it and no separators either side.
    ///
    /// A grouped `Form` wraps every row in an inset card, and a portrait in a card is a row —
    /// the eye reads it as the first item of a list rather than as the subject of the screen.
    /// Clearing the background is what lifts it out of the list without taking it out of the
    /// form, which still owns the scrolling and the safe areas.
    func profileHeaderRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}
