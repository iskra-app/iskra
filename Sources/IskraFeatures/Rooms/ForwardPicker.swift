import SwiftUI
import IskraCore
import IskraDesign

/// Where a forwarded message goes: a searchable list of the conversations you are in. Tapping one
/// sends the message there and closes — no second confirmation, because the list of your own chats
/// is not a dangerous place to send to, and the message lands in that room's own send queue.
struct ForwardPicker: View {
    let message: Message
    let forwarding: Forwarding

    @State private var query = ""
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
            List(rooms) { room in
                Button {
                    send(to: room.id)
                } label: {
                    HStack(spacing: Theme.Spacing.normal) {
                        Avatar(name: room.name, url: room.avatarURL, size: Theme.Size.avatar)
                        Text(room.name)
                            .font(.body)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: Text(Strings.Message.Forward.prompt))
            .navigationTitle(Text(Strings.Message.Forward.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Message.Forward.cancel)) { dismiss() }
                }
            }
        }
    }

    private func send(to roomID: String) {
        guard !isSending else { return }
        isSending = true
        Task {
            _ = await forwarding.forward(message, to: roomID)
            dismiss()
        }
    }
}
