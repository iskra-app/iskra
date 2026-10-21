import SwiftUI
import IskraDesign

/// Escape as "Back", on a Mac: whatever screen is on top, Escape takes it away — the conversation,
/// a pushed settings page, the info screen over a chat — the way it closes anything else on a Mac.
///
/// **One key equivalent in the window, never one per screen.** Each screen that can be left
/// registers what leaving it means on `EscapeStack`, and the root's single hidden `.cancelAction`
/// button runs the newest. It was a hidden button per screen, and on a Mac a screen covered by a
/// push is *not* taken off the window: the conversation, its info screen and the edit screen over
/// that were three `.cancelAction` buttons at once, AppKit chose between them again on every layout
/// pass, the choice invalidated the layout — and the window spun in `NSHostingView.layout()` until
/// it was force-quit. The sample showed the room and its info screen rebuilt in a loop.
///
/// **The way out is always handed in, never `@Environment(\.dismiss)`.** Half of these screens sit
/// in the sidebar column's stack, where reading `dismiss` hangs macOS 26 (see `SettingsView.onClose`
/// and CLAUDE.md) — so the screen that pushed one owns the flag that pushed it, and clearing that
/// flag is the way back. That is also why rows that push such a screen are `PushRow`s and not
/// `NavigationLink`s: a link pushes onto the stack and keeps no flag anybody could clear.
extension View {
    func escapeKey(_ action: @escaping () -> Void) -> some View {
        modifier(EscapeKey(action: action))
    }

    /// The window's one Escape — set once, at the root. See `EscapeStack`.
    func escapeKeyRoot(_ stack: EscapeStack) -> some View {
        modifier(EscapeKeyRoot(stack: stack))
    }
}

/// What Escape does: every screen on show that can be left, in the order it arrived. The newest is
/// the one on top — a push, or a chat opened after settings — and goes first.
@MainActor
final class EscapeStack {
    private var entries: [(id: UUID, action: () -> Void)] = []

    func push(_ id: UUID, _ action: @escaping () -> Void) {
        entries.removeAll { $0.id == id }
        entries.append((id, action))
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func fire() {
        entries.last?.action()
    }
}

extension EnvironmentValues {
    @Entry var escapeStack: EscapeStack?
}

private struct EscapeKey: ViewModifier {
    let action: () -> Void
    @Environment(\.escapeStack) private var stack
    @State private var id = UUID()

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onAppear { stack?.push(id, action) }
            .onDisappear { stack?.remove(id) }
        #else
        content
        #endif
    }
}

private struct EscapeKeyRoot: ViewModifier {
    let stack: EscapeStack

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .environment(\.escapeStack, stack)
            .background {
                Button("") { stack.fire() }
                    .keyboardShortcut(.cancelAction)
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
