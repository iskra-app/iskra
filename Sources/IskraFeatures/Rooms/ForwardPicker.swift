import SwiftUI
import IskraCore
import IskraDesign

/// Where a forwarded message goes — Telegram's share sheet: a half-height sheet of faces, four to a
/// row, any number of them chosen with a tick, a comment line and a send button at the foot that
/// says how many chats it is about to go to.
///
/// It used to be a list that sent on the first tap. That made sending to two people two trips
/// through the menu, and gave nowhere to say anything about what was being passed on. Choosing and
/// sending are separate now, as they are in Telegram; nothing goes until the button is pressed.
struct ForwardPicker: View {
    let message: Message
    let forwarding: Forwarding

    @State private var query = ""
    @State private var chosen: [String] = []
    @State private var comment = ""
    @State private var isSending = false
    @Environment(\.dismiss) private var dismiss

    private var rooms: [RoomSummary] {
        let all = forwarding.destinations
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ShareTargetGrid(items: rooms,
                                title: \.name,
                                selection: Set(chosen),
                                onToggle: toggle) { room in
                    RoomAvatar(name: room.name, url: room.avatarURL, size: Theme.Size.shareFace,
                               shape: room.isSpace ? .roundedSquare : .circle,
                               seed: room.isSpace ? nil : room.avatarSeed,
                               faces: room.faces)
                }
                .padding(.horizontal, Theme.Spacing.roomy)
                .padding(.vertical, Theme.Spacing.close)
            }
            .searchable(text: $query, prompt: Text(Strings.Message.Forward.prompt))
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom) {
                if !chosen.isEmpty {
                    ShareSendBar(comment: $comment,
                                 placeholder: String(app: Strings.Message.Forward.comment),
                                 sendLabel: String(app: Strings.Message.Forward.send),
                                 count: chosen.count,
                                 isSending: isSending,
                                 onSend: send)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: Theme.Timing.chrome), value: chosen.isEmpty)
            .navigationTitle(Text(Strings.Message.Forward.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Message.Forward.cancel)) { dismiss() }
                }
            }
        }
        // Half the screen first, as Telegram's sheet opens — most forwards go to somebody in the top
        // two rows — and the whole of it a drag away.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func toggle(_ room: RoomSummary) {
        if let index = chosen.firstIndex(of: room.id) {
            chosen.remove(at: index)
        } else {
            chosen.append(room.id)
        }
    }

    private func send() {
        guard !isSending, !chosen.isEmpty else { return }
        isSending = true
        let targets = chosen
        let words = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            for roomID in targets {
                _ = await forwarding.forward(message, to: roomID)
                if !words.isEmpty { await forwarding.comment(words, to: roomID) }
            }
            dismiss()
        }
    }
}
