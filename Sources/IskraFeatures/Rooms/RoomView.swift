import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// One conversation: the messages, and the box you type into.
public struct RoomView: View {
    @State private var timeline: TimelineStore
    @State private var draft = ""
    @State private var isRecordingVideoNote = false

    public init(timeline: TimelineStore) {
        _timeline = State(initialValue: timeline)
    }

    public var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if timeline.canLoadMore {
                        ProgressView()
                            .padding()
                            .task { await timeline.loadMore() }
                    }

                    ForEach(timeline.rows) { row in
                        switch row {
                        case let .dayDivider(divider):
                            DayDividerView(date: divider.date)
                        case let .message(message):
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.normal)
                // The composer floats over the timeline on glass, so the last message
                // must be able to scroll clear of it.
                .padding(.bottom, Theme.Spacing.generous)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: timeline.rows.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.smooth) { scroll.scrollTo(last, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .navigationTitle(timeline.roomName)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                PrivacyBadge(privacy: timeline.privacy)
            }
        }
        .task {
            try? await timeline.start()
            await timeline.markAsRead()
        }
        .onDisappear { timeline.stop() }
        .alert(Text(Strings.Room.sendFailedTitle),
               isPresented: .init(get: { timeline.sendFailure != nil },
                                  set: { if !$0 { timeline.sendFailure = nil } })) {
            Button(String(app: Strings.Room.ok), role: .cancel) { timeline.sendFailure = nil }
        } message: {
            if let failure = timeline.sendFailure { Text(failure) }
        }
    }

    private var composer: some View {
        MessageComposer(draft: $draft,
                        onSend: send,
                        onRecordVideoNote: { isRecordingVideoNote = true },
                        onPickedMedia: { item in Task { await sendPicked(item) } },
                        onPickedFile: { url in Task { await sendPickedFile(url) } })
            .sheet(isPresented: $isRecordingVideoNote) {
                VideoNoteComposer { url in
                    await timeline.send(video: url)
                }
                .presentationDetents([.large])
            }
    }

    /// The picker hands back bytes, not a path, and the SDK wants a file. Writing to a
    /// temporary file is the bridge — and it is deleted the moment the upload is done,
    /// because in an encrypted room that file is plaintext sitting on disk.
    private func sendPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mp4" : "jpg")
        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).\(ext)")

        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        if isVideo {
            await timeline.send(video: url)
        } else {
            await timeline.send(photo: url)
        }
    }

    private func sendPickedFile(_ url: URL) async {
        // A file the user picked lives outside our sandbox until we say otherwise.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        await timeline.send(file: url)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await timeline.send(text: text) }
    }
}

/// The lock in the title bar. Tapping it explains itself in plain words.
private struct PrivacyBadge: View {
    let privacy: PrivacyStatus
    @State private var explaining = false

    var body: some View {
        Button {
            explaining = true
        } label: {
            Image(systemName: privacy.iconName)
                .font(.footnote)
                .foregroundStyle(privacy == .protected ? Color.secondary : Color.orange)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(privacy.explanation))
        .popover(isPresented: $explaining) {
            Text(privacy.explanation)
                .font(.callout)
                .padding()
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct DayDividerView: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.Spacing.roomy)
            .frame(maxWidth: .infinity)
    }
}
