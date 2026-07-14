import SwiftUI
import IskraDesign

/// The search field that floats at the bottom of the room list.
///
/// Its own view for exactly the reason the composer is: a control that only ever
/// appears behind a signed-in session is an expensive thing to look at, and one that
/// stands alone is a cheap one. It renders with no Matrix behind it — see
/// `SearchFieldLayoutTests`.
///
/// It is glass because it is a navigation-layer control hovering over scrolling
/// content. The conversations underneath it are content, and stay opaque.
struct RoomSearchField: View {
    @Binding var text: String

    @FocusState private var isFocused: Bool

    private var isSearching: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(String(app: Strings.RoomList.searchPrompt), text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)

            if isSearching {
                Button {
                    text = ""
                    isFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        // The glyph is the size it looks; the *target* is the size a thumb is.
                        // Apple asks for 44pt and this was about seventeen — a cross drawn at the
                        // end of a field, which is exactly the control people jab at without
                        // looking. Growing the picture would make the field look cluttered, so the
                        // hit region grows instead and the picture stays where it was.
                        .frame(width: Theme.Size.minimumTapTarget,
                               height: Theme.Size.minimumTapTarget)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Strings.RoomList.clearSearch))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .frame(height: Theme.Size.searchField)
        .navigationGlass(in: .capsule)
        .padding(.horizontal, Theme.Spacing.normal)
        .padding(.bottom, Theme.Spacing.close)
        .animation(.smooth(duration: 0.2), value: isSearching)
    }
}
