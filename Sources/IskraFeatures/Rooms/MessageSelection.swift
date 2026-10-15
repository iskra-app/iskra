import SwiftUI
import IskraCore
import IskraDesign

/// Several messages chosen at once — Telegram's "Select": started from a message's menu with that
/// message ticked, and for as long as it lasts a tap on a message ticks it instead of doing what a
/// tap usually does. The composer gives its place to a bar that says how many are chosen and
/// offers what can be done to all of them together.
///
/// The IDs are kept in the order they were ticked only for the count; what is *done* with them
/// follows the conversation's own order (`ordered(in:)`), because a forward or a copy that came
/// out in the order of the taps would be the conversation shuffled.
struct MessageSelection: Equatable {
    private(set) var ids: Set<String>

    init(_ first: String) {
        ids = [first]
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    /// The chosen rows, as the conversation has them, top to bottom.
    func ordered(in rows: [TimelineRow]) -> [Message] {
        rows.compactMap(\.message).filter { ids.contains($0.id) }
    }

    /// What "Copy" puts on the clipboard. One message is its words, as its own menu copies them;
    /// several are a transcript — who, when, what — because a run of bare lines pasted somewhere
    /// else no longer says who said which. A picture contributes its caption, and nothing when it
    /// has none.
    static func transcript(of messages: [Message]) -> String? {
        let said = messages.compactMap { message -> (Message, String)? in
            words(of: message).map { (message, $0) }
        }
        guard !said.isEmpty else { return nil }
        if said.count == 1 { return said[0].1 }
        return said.map { message, words in
            "\(message.senderName), [\(message.timestamp.formatted(date: .numeric, time: .shortened))]\n\(words)"
        }
        .joined(separator: "\n\n")
    }

    private static func words(of message: Message) -> String? {
        switch message.kind {
        case let .text(body), let .notice(body), let .emote(body): body
        default: message.members.compactMap { $0.captioned?.caption }.first
        }
    }
}

/// The bar the composer gives its place to while messages are being chosen.
struct MessageSelectionBar: View {
    let count: Int
    let canDelete: Bool
    let canForward: Bool
    let canCopy: Bool
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onForward: () -> Void
    let onCopy: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Button(String(app: Strings.Message.Selection.cancel), action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(accent.color)

            Text(Strings.Message.Selection.count(count))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)

            HStack(spacing: Theme.Spacing.roomy) {
                action("doc.on.doc", Strings.Message.Menu.copy, enabled: canCopy, perform: onCopy)
                action("arrowshape.turn.up.right", Strings.Message.Menu.forward, enabled: canForward, perform: onForward)
                action("trash", Strings.Message.Menu.delete, enabled: canDelete, tint: .red, perform: onDelete)
            }
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.vertical, Theme.Spacing.normal)
        .frame(minHeight: Theme.Size.composerControl)
        .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .padding(.horizontal, Theme.Spacing.normal)
        .padding(.vertical, Theme.Spacing.close)
    }

    private func action(_ systemImage: String, _ title: LocalizedStringResource, enabled: Bool,
                        tint: Color? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(minWidth: Theme.Size.minimumTapTarget, minHeight: Theme.Size.minimumTapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? (tint ?? accent.color) : Color.secondary)
        .disabled(!enabled || count == 0)
        .accessibilityLabel(Text(title))
    }
}

/// The tick beside a message while messages are being chosen.
struct SelectionMark: View {
    let isOn: Bool

    @Environment(\.accent) private var accent

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isOn ? AnyShapeStyle(accent.color) : AnyShapeStyle(.secondary))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
