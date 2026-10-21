import SwiftUI
import IskraDesign

/// Escape as "Back", on a Mac: whatever screen is on top, Escape takes it away — the conversation,
/// a pushed settings page, the info screen over a chat — the way it closes anything else on a Mac.
///
/// A key equivalent rather than `onExitCommand`, because the latter only reaches a view that holds
/// focus, and the focus is usually in a field that keeps Escape for itself (see `RoomView`).
///
/// **The way out is always handed in, never `@Environment(\.dismiss)`.** Half of these screens sit
/// in the sidebar column's stack, where reading `dismiss` hangs macOS 26 (see `SettingsView.onClose`
/// and CLAUDE.md) — so the screen that pushed one owns the flag that pushed it, and clearing that
/// flag is the way back. That is also why rows that push such a screen are `PushRow`s and not
/// `NavigationLink`s: a link pushes onto the stack and keeps no flag anybody could clear.
///
/// Only the screen on top answers: a screen covered by a push is taken off the window, its key
/// equivalent with it. What can be on screen twice is the sidebar and the conversation beside it,
/// and there the conversation goes first — see `escapeYieldsToChat`.
extension View {
    func escapeKey(_ action: @escaping () -> Void) -> some View {
        modifier(EscapeKey(action: action))
    }
}

extension EnvironmentValues {
    /// Set on the sidebar while a conversation is open beside it: the sidebar's screens leave
    /// Escape to the conversation, so the first Escape closes the chat and the next one the page
    /// in the sidebar, rather than two shortcuts fighting over one key.
    @Entry var escapeYieldsToChat = false
}

private struct EscapeKey: ViewModifier {
    let action: () -> Void
    @Environment(\.escapeYieldsToChat) private var yields

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background {
                Button("", action: action)
                    .keyboardShortcut(.cancelAction)
                    .disabled(yields)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        #else
        content
        #endif
    }
}

extension View {
    /// A Mac sheet that is mostly a list: a `List` asks for no size of its own, and a sheet is as
    /// small as its content lets it be — so without this it opens with nothing between its title
    /// and its buttons. Nothing on iPhone or iPad, where a sheet has the screen's size.
    func listSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: Theme.Size.listSheetWidth, minHeight: Theme.Size.listSheetHeight)
        #else
        self
        #endif
    }
}

/// A row that pushes a screen, drawn as a `NavigationLink` row is — the words, and a chevron at the
/// end — but a button underneath, so that the screen it opens is pushed by a flag its owner holds
/// and can clear. See `escapeKey`.
struct PushRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(PushRowStyle())
    }
}

private struct PushRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            configuration.label
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
