import IskraCore
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
    /// What a generated stand-in face is computed from — a Matrix user ID, or a room ID. Nil
    /// where one would make no sense, which is a space. See `Avatar`.
    var seed: String?
    /// Whether the line underneath is the kind of thing somebody opened this screen to copy.
    /// A Matrix ID is; "12 participants" is not, and a count that highlights under a long press
    /// is a small piece of nonsense.
    var isSubtitleSelectable = false
    /// A group's faces, drawn as the same cluster the chat list shows. Empty for a person, and for
    /// the settings screen, where the header is the user's own.
    var faces: [RoomFace] = []

    var body: some View {
        VStack(spacing: Theme.Spacing.normal) {
            RoomAvatar(name: name, url: avatarURL, size: Theme.Size.avatarProfile, shape: shape,
                       seed: seed, faces: faces)

            VStack(spacing: Theme.Spacing.tight) {
                // A size up from the `.title2` a heading in a form would get, because this is not
                // a heading over the screen — it is the name of whoever the screen is about, and
                // the only words on it that have to be read from across a room.
                Text(name)
                    .font(.title.weight(.semibold))
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
        // Nothing above it. The portrait is pulled up level with the back chevron and the pencil
        // (see `profileScreen()`), and any padding here would push it back down again — the gap
        // it would leave is exactly the gap the screen is trying not to have.
        .padding(.bottom, Theme.Spacing.roomy)
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

    /// A screen whose subject is the portrait at the top of it: no title, and the form pulled up
    /// until the top of the picture is level with the top of the buttons either side of it.
    ///
    /// The title goes because it would be saying the name twice. "Settings" over a photograph of
    /// you with your name under it is a label on a thing that has already introduced itself, and
    /// it costs the portrait the one position on the screen that is worth having.
    ///
    /// What is left in the bar is two round buttons with nothing between them, and the picture
    /// rising into that gap — which is the arrangement every messenger has settled on, because the
    /// eye reads the face first and the chrome second.
    ///
    /// The lift is a negative inset rather than an ignored safe area on purpose: the form still
    /// owns its safe areas, so the picture is laid out under the navigation bar instead of being
    /// clipped by an edge the layout no longer knows about. On macOS none of this applies — the
    /// title bar is the window's, not the screen's.
    func profileScreen() -> some View {
        modifier(ProfileScreen())
    }
}

/// The chrome of a portrait screen, and the one piece of it that changes as the screen moves.
///
/// On 26 a scroll view draws a progressive blur along any edge that runs under glass, so that
/// content passing beneath a toolbar softens instead of colliding with it. It is the right effect
/// almost everywhere — and the wrong one at rest here, where the thing directly under the top edge
/// is the portrait: it washed out the top third of the picture and left a horizontal seam across
/// somebody's face, on a screen where nothing was scrolling and there was nothing to soften.
///
/// So the effect is not removed, it is *earned*. Above the fold there is nothing under the bar but
/// the face, and the bar is bare glass buttons over the page. Once the picture has scrolled out of
/// the way there is a list running under the bar, which is exactly what the effect is for, and it
/// comes back — with the bar's own background, which is refused for the same stretch and for the
/// same reason.
///
/// The threshold is the height of the picture, which is the distance it takes to leave: the screen
/// is lifted so the top of the portrait starts level with the top of the bar, so after scrolling
/// its own height it is gone. Not the height of the whole header — waiting for the name and the
/// address to go too would leave the list sliding under naked glass for another eighty points,
/// which is the effect arriving late rather than not arriving at all.
private struct ProfileScreen: ViewModifier {
    /// Whether the portrait has left. Animated, because the effect appearing is a change in the
    /// weather at the top of the screen and a hard cut reads as a flicker.
    @State private var isPastPortrait = false

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle(Text(verbatim: ""))
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(isPastPortrait ? .automatic : .hidden, for: .navigationBar)
            .scrollEdgeEffectHidden(!isPastPortrait, for: .top)
            // The grouped form's own opening gap, which sits between the bar and the first row
            // and would put the portrait back below the buttons.
            .contentMargins(.top, 0, for: .scrollContent)
            .padding(.top, -Theme.Size.navigationBar)
            // How far the content has actually travelled, rather than where it happens to sit:
            // `contentOffset` alone counts the insets the form was given, and those change under
            // a keyboard.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, travelled in
                let past = travelled > Theme.Size.avatarProfile
                guard past != isPastPortrait else { return }
                withAnimation(.easeInOut(duration: Theme.Timing.chrome)) { isPastPortrait = past }
            }
        #else
        content.navigationTitle(Text(verbatim: ""))
        #endif
    }
}
