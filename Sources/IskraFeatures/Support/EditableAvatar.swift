import SwiftUI
import IskraDesign

/// A picture that can be changed: dimmed, with a pencil on it, and a menu under a tap.
///
/// The edit screens for a profile and for a room both use it, so the two read the same way.
/// The pencil is what says the picture can be tapped at all — without it, a large face at the
/// top of a form looks like something to look at, and the menu behind it is a press nobody is
/// told about.
///
/// The menu holds no `PhotosPicker`: one declared inside a `Menu` simply never appears. "Change"
/// only asks for the picker, and the picker hangs off the root of the screen that owns it.
struct EditableAvatar: View {
    let name: String
    let url: String?
    var shape: AvatarShape = .circle
    var seed: String?

    /// Whether there is anything to remove. Without a picture "Remove" would do nothing, so it is
    /// not offered.
    let canRemove: Bool
    let onChange: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Menu {
            Button(action: onChange) {
                Label {
                    Text(Strings.Picture.change)
                } icon: {
                    Image(systemName: "photo")
                }
            }

            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Label {
                        Text(Strings.Picture.remove)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        } label: {
            Avatar(name: name, url: url, size: Theme.Size.avatarProfile, shape: shape, seed: seed)
                .overlay {
                    outline
                        .fill(.black.opacity(0.4))
                }
                .overlay {
                    Image(systemName: "pencil")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(outline)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(Strings.Picture.edit))
    }

    /// The same outline `Avatar` draws, so the shade covers the picture and nothing outside it.
    private var outline: AvatarOutline { AvatarOutline(shape: shape) }
}
