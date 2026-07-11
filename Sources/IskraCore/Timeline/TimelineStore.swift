import Foundation
import Observation
import MatrixRustSDK

/// One room's conversation: the messages, and the ability to add to them.
///
/// Like the room list, the SDK streams this as diffs. Unlike the room list, the
/// items include local echoes — messages we have sent but the server has not yet
/// acknowledged — which is what lets a message appear instantly and then quietly
/// gain a "sent" tick.
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var rows: [TimelineRow] = []
    public private(set) var isPaginating = false
    /// False once we have reached the beginning of the conversation.
    public private(set) var canLoadMore = true

    /// Set when sending fails in a way the user should know about.
    public var sendFailure: LocalizedStringResource?

    public let roomID: String
    public private(set) var privacy: PrivacyStatus = .unknown
    public private(set) var roomName: String = ""

    private let room: Room
    private var timeline: Timeline?

    /// The SDK timeline, for the media-sending extension in `TimelineStore+Media`.
    /// Nil until `start()` has run.
    var liveTimeline: Timeline? { timeline }
    private var listenerHandle: TaskHandle?
    private var items: [TimelineItem] = []

    init(room: Room) {
        self.room = room
        self.roomID = room.id()
    }

    public func start() async throws {
        guard timeline == nil else { return }

        if let info = try? await room.roomInfo() {
            privacy = PrivacyStatus(info.encryptionState)
            roomName = info.displayName ?? info.heroes.first?.displayName ?? String(core: CoreStrings.Room.untitled)
        }

        let timeline = try await room.timeline()
        self.timeline = timeline

        let listener = ItemsListener { [weak self] diffs in
            let transfer = UnsafeTransfer(value: diffs)
            Task { @MainActor [weak self] in
                self?.apply(diffs: transfer.value)
            }
        }

        listenerHandle = await timeline.addListener(listener: listener)
    }

    public func stop() {
        listenerHandle?.cancel()
        listenerHandle = nil
    }

    // MARK: - Sending

    /// Sends a plain text message. Markdown is honoured, because people type `*this*`
    /// and expect it to work.
    public func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let timeline else { return }

        do {
            // Not logged, not stored anywhere but the SDK's encrypted send queue.
            _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: trimmed))
        } catch {
            sendFailure = CoreStrings.Timeline.sendFailed
        }
    }

    /// Tells the server the user has seen the conversation, which is what clears the
    /// badge here and shows a read tick on the sender's side.
    public func markAsRead() async {
        try? await room.markAsRead(receiptType: .read)
    }

    /// Loads older messages. Called when the user scrolls to the top.
    public func loadMore() async {
        guard let timeline, !isPaginating, canLoadMore else { return }

        isPaginating = true
        defer { isPaginating = false }

        // `paginateBackwards` returns true once it has hit the start of the room.
        if let reachedStart = try? await timeline.paginateBackwards(numEvents: 25) {
            canLoadMore = !reachedStart
        }
    }

    // MARK: - Diff handling

    private func apply(diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case let .append(values):
                items.append(contentsOf: values)
            case .clear:
                items.removeAll()
            case let .pushFront(value):
                items.insert(value, at: 0)
            case let .pushBack(value):
                items.append(value)
            case .popFront:
                if !items.isEmpty { items.removeFirst() }
            case .popBack:
                if !items.isEmpty { items.removeLast() }
            case let .insert(index, value):
                items.insert(value, at: min(Int(index), items.count))
            case let .set(index, value):
                let i = Int(index)
                if items.indices.contains(i) { items[i] = value }
            case let .remove(index):
                let i = Int(index)
                if items.indices.contains(i) { items.remove(at: i) }
            case let .truncate(length):
                let n = Int(length)
                if n < items.count { items.removeSubrange(n...) }
            case let .reset(values):
                items = values
            }
        }

        rows = TimelineMapper.rows(from: items)
    }
}

private final class ItemsListener: TimelineListener {
    private let onDiff: @Sendable ([TimelineDiff]) -> Void

    init(onDiff: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.onDiff = onDiff
    }

    func onUpdate(diff: [TimelineDiff]) {
        onDiff(diff)
    }
}
