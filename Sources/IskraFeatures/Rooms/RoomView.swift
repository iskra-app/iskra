import SwiftUI
import IskraCore
import IskraDesign

/// One conversation: the messages, and the box you type into.
public struct RoomView: View {
    @State private var timeline: TimelineStore
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

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
        .alert("Message not sent",
               isPresented: .init(get: { timeline.sendFailure != nil },
                                  set: { if !$0 { timeline.sendFailure = nil } })) {
            Button("OK", role: .cancel) { timeline.sendFailure = nil }
        } message: {
            Text(timeline.sendFailure ?? "")
        }
    }

    /// The composer is a navigation-layer control floating over content, which is
    /// exactly what Liquid Glass is for.
    private var composer: some View {
        GlassEffectContainer(spacing: Theme.Spacing.close) {
            HStack(spacing: Theme.Spacing.close) {
                Button {
                    // Attachments land in the next pass.
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: Theme.Size.minimumTapTarget,
                               height: Theme.Size.minimumTapTarget)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Add a photo or file")

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, Theme.Spacing.roomy)
                    .padding(.vertical, Theme.Spacing.normal)
                    .frame(minHeight: Theme.Size.minimumTapTarget)
                    .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    .onSubmit(send)

                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: Theme.Size.minimumTapTarget,
                                   height: Theme.Size.minimumTapTarget)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Send")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
        }
        .animation(.smooth(duration: 0.2), value: draft.isEmpty)
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
        .accessibilityLabel(privacy.explanation)
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
