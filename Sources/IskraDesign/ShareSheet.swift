import SwiftUI

/// The chats to send something to, as Telegram's share sheet draws them: a grid of faces, four to a
/// row, the name under each, and a tick on the face of every one chosen.
///
/// A grid and not a list because a share sheet is picked from by *face* — the people you write to
/// most are the ones you recognise at a glance — and because choosing several at once is the
/// ordinary thing to do with it, which a list of rows that send on a tap cannot offer.
///
/// In `IskraDesign` because two processes draw it: the app, forwarding a message, and the Share
/// extension, which links this target and `IskraCore` and nothing else. Neither the words nor the
/// faces are its business — the caller hands both in — so it stays free of Matrix and of strings.
public struct ShareTargetGrid<Item: Identifiable, Face: View>: View {
    let items: [Item]
    let title: (Item) -> String
    let selection: Set<Item.ID>
    let onToggle: (Item) -> Void
    let face: (Item) -> Face

    public init(items: [Item],
                title: @escaping (Item) -> String,
                selection: Set<Item.ID>,
                onToggle: @escaping (Item) -> Void,
                @ViewBuilder face: @escaping (Item) -> Face) {
        self.items = items
        self.title = title
        self.selection = selection
        self.onToggle = onToggle
        self.face = face
    }

    @Environment(\.accent) private var accent

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.close, alignment: .top),
                                count: 4)

    public var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.roomy) {
            ForEach(items) { item in
                let isChosen = selection.contains(item.id)

                Button {
                    onToggle(item)
                } label: {
                    VStack(spacing: Theme.Spacing.tight) {
                        face(item)
                            .frame(width: Theme.Size.shareFace, height: Theme.Size.shareFace)
                            // Telegram's ring: the face draws in a little and the accent comes round it.
                            .scaleEffect(isChosen ? 0.86 : 1)
                            .background {
                                Circle()
                                    .strokeBorder(accent.color, lineWidth: 2.5)
                                    .opacity(isChosen ? 1 : 0)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if isChosen {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, accent.color)
                                        .background(Circle().fill(.background).padding(2))
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }

                        Text(title(item))
                            .font(.caption)
                            .foregroundStyle(isChosen ? accent.color : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: isChosen)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection.count)
    }
}

/// The foot of the share sheet once something is chosen: a line for a comment, and the send button
/// carrying how many chats it will go to — Telegram's. Glass, because it floats over the grid as the
/// composer floats over a conversation.
public struct ShareSendBar: View {
    @Binding var comment: String
    let placeholder: String
    let sendLabel: String
    let count: Int
    let isSending: Bool
    let onSend: () -> Void

    public init(comment: Binding<String>, placeholder: String, sendLabel: String,
                count: Int, isSending: Bool, onSend: @escaping () -> Void) {
        _comment = comment
        self.placeholder = placeholder
        self.sendLabel = sendLabel
        self.count = count
        self.isSending = isSending
        self.onSend = onSend
    }

    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            TextField(placeholder, text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.normal)
                .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))

            Button(action: onSend) {
                HStack(spacing: Theme.Spacing.tight) {
                    if isSending {
                        ProgressView().tint(accent.foreground(in: colorScheme))
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    if count > 1 {
                        Text(verbatim: "\(count)")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(accent.foreground(in: colorScheme))
                .padding(.horizontal, Theme.Spacing.roomy)
                .frame(minWidth: Theme.Size.minimumTapTarget, minHeight: Theme.Size.minimumTapTarget)
                .primaryActionGlass(tint: accent.color)
                .accessibilityLabel(Text(verbatim: sendLabel))
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .animation(.smooth(duration: Theme.Timing.chrome), value: count)
        }
        .padding(.horizontal, Theme.Spacing.normal)
        .padding(.vertical, Theme.Spacing.close)
    }
}
