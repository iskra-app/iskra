import Foundation
import MatrixRustSDK

/// What a chat's row says, read off the chat itself rather than off the SDK's summary of it.
///
/// The SDK's `latestEvent()` is a *filtered* answer, and two of the things it filters out are
/// things the list has to show. A message that was deleted is skipped — the SDK walks past the
/// redacted event to the one before it, so the row went on quoting the very words somebody had
/// taken back. And every grey line is skipped: "Аня joined", "the chat was renamed" — the row
/// showed whatever was said before them, as if they had not happened. Telegram puts both in the
/// list, and the chat it opens on agrees with the row that opened it.
///
/// The third thing is the read mark. The latest event carries no receipts — only a timeline
/// tracks them — so a message of yours read on the other side stayed "sent" in the list until you
/// opened the chat and the chat told the list (`RoomListStore.noteRead`).
///
/// All three are answered the same way: a small live timeline of the room's own, mapped by the
/// same `TimelineMapper` the conversation is drawn with, so that the last line of the row is the
/// last line of the chat — word for word, grey lines hidden in Settings → Chats left out of both.
public struct PeekLine: Sendable, Equatable {
    public let text: String
    public let kind: PreviewKind?
    /// Your own last message's progress; nil for somebody else's, and for a grey line.
    public let mark: LastMessageMark?
    public let date: Date
    /// Who said it, when it was somebody else — see `RoomSummary.lastSender`.
    public var sender: String?

    /// The last thing in the chat that the row can say — nil when it is something the mapper has
    /// no words for (a poll, an event it does not render), and then the SDK's summary is asked.
    static func last(in rows: [TimelineRow]) -> PeekLine? {
        for row in rows.reversed() {
            switch row {
            case let .message(message):
                if message.kind == .unsupported { return nil }
                let isDeleted = message.kind == .deleted
                return PeekLine(text: MessagePreview.text(for: message),
                                kind: PreviewKind(message.kind),
                                // A deleted message is not one anybody is waiting to have read.
                                mark: message.isOwn && !isDeleted ? message.delivery.map(LastMessageMark.init) : nil,
                                date: message.timestamp,
                                sender: message.isOwn ? nil : message.senderName)
            case let .event(event):
                return PeekLine(text: event.text, kind: nil, mark: nil, date: event.timestamp)
            case .dayDivider, .unreadDivider:
                continue
            }
        }
        return nil
    }
}

extension PreviewKind {
    /// The icon in front of an attachment's word in the list, for a message already flattened.
    init?(_ kind: MessageKind) {
        switch kind {
        case .image: self = .photo
        case .sticker: self = .sticker
        case .video: self = .video
        case .videoNote: self = .videoNote
        case .voice: self = .voice
        case .audio: self = .audio
        case .file: self = .file
        case .location: self = .location
        case .poll: self = .poll
        case .text, .emote, .notice, .unreadable, .deleted, .unsupported: return nil
        }
    }
}

extension LastMessageMark {
    init(_ delivery: DeliveryStatus) {
        switch delivery {
        case .sending: self = .sending
        case .sent: self = .sent
        case .read: self = .read
        case .failed: self = .failed
        }
    }
}

/// One room's live timeline, held for as long as its row is on the screen — see `PeekLine`.
///
/// A timeline per row sounds dear, and it is not, because it is a timeline per *visible* row: the
/// list asks for one when a row appears and lets the oldest go once more than `RoomListStore.peekLimit`
/// are held. Twenty items each, from the event cache on this device; no history beyond that.
@MainActor
final class RoomPeek {
    let roomID: String
    private(set) var line: PeekLine?

    /// The row has something new to say.
    var onChange: (() -> Void)?

    private let room: Room
    private let ownUserID: String
    private var timeline: Timeline?
    private var items: [TimelineItem] = []
    /// `items`, already mapped. See `TimelineMapper.Memo`.
    private let mapped = TimelineMapper.Memo()
    private var listenerHandle: TaskHandle?
    private var diffContinuation: AsyncStream<UnsafeTransfer<[TimelineDiff]>>.Continuation?
    private var diffTask: Task<Void, Never>?
    private var isStopped = false

    /// How much of the room is asked for, the once. Enough to get past a run of reactions and
    /// receipts to something with words in it.
    private static let pageSize: UInt16 = 20
    private static let sdkTimeout: Duration = .seconds(30)

    init(room: Room, ownUserID: String) {
        self.room = room
        self.roomID = room.id()
        self.ownUserID = ownUserID
    }

    func start() async {
        let configuration = TimelineConfiguration(focus: .live(hideThreadedEvents: false),
                                                  filter: .all,
                                                  internalIdPrefix: "peek",
                                                  dateDividerMode: .daily,
                                                  // The one thing the SDK's summary cannot say,
                                                  // and half the reason this exists.
                                                  trackReadReceipts: .allEvents,
                                                  reportUtds: false)
        guard let timeline = try? await withTimeout(Self.sdkTimeout, operation: { [room] in
            try await room.timelineWithConfiguration(configuration: configuration)
        }), !isStopped else { return }
        self.timeline = timeline

        // One queue, one consumer, in the order the SDK spoke — see `TimelineStore.open()`.
        let (diffs, continuation) = AsyncStream<UnsafeTransfer<[TimelineDiff]>>.makeStream()
        diffContinuation = continuation
        diffTask = Task { @MainActor [weak self] in
            for await batch in diffs {
                self?.apply(diffs: batch.value)
            }
        }

        let handle = await timeline.addListener(listener: PeekListener { batch in
            continuation.yield(UnsafeTransfer(value: batch))
        })
        guard !isStopped else {
            handle.cancel()
            return
        }
        listenerHandle = handle

        // A live timeline opens empty — see `CLAUDE.md`. One page, out of the event cache.
        _ = try? await withTimeout(Self.sdkTimeout) { try await timeline.paginateBackwards(numEvents: Self.pageSize) }
    }

    func stop() {
        isStopped = true
        listenerHandle?.cancel()
        listenerHandle = nil
        diffContinuation?.finish()
        diffContinuation = nil
        diffTask?.cancel()
        diffTask = nil
        timeline = nil
        items = []
        mapped.removeAll()
    }

    /// Settings → Chats changed which grey lines are shown; the row follows the chat.
    func refresh() {
        update()
    }

    private func apply(diffs: [TimelineDiff]) {
        guard !isStopped else { return }
        switch items.apply(diffs.map(\.asListDiff)) {
        case .applied:
            update()
        case let .desynced(what):
            // Not worth a resync of its own: the row falls back to the SDK's summary, and the next
            // time it appears it is peeked at afresh.
            Log.rooms.error("A chat-list peek is out of step with the SDK: \(what, privacy: .public)")
            items = []
            mapped.removeAll()
            line = nil
            onChange?()
        }
    }

    private func update() {
        let rows = TimelineMapper.rows(from: items, ownUserID: ownUserID,
                                       hiding: ServiceEventSettings.current(), memo: mapped)
        let next = PeekLine.last(in: rows)
        guard next != line else { return }
        line = next
        onChange?()
    }
}

private final class PeekListener: TimelineListener {
    private let onDiff: @Sendable ([TimelineDiff]) -> Void

    init(onDiff: @escaping @Sendable ([TimelineDiff]) -> Void) {
        self.onDiff = onDiff
    }

    func onUpdate(diff: [TimelineDiff]) {
        onDiff(diff)
    }
}
