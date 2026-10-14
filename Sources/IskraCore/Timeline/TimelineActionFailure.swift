import Foundation

/// Something the user asked the conversation to do, and it did not happen.
///
/// One case per act rather than one sentence for all of them, for the same reason
/// `RoomActionFailure` is: "something went wrong" tells a person nothing they can act on, and the
/// five things that can be refused here fail in five different ways and want five different
/// sentences. A reaction that did not land leaves the message perfectly sent; a message that did not
/// send is still sitting in the box.
///
/// It exists at all because `TimelineStore` was the only store in the app holding a
/// `LocalizedStringResource?` instead of one of these — the model layer handing the view a finished
/// sentence, which is precisely the wrong way round, and which cost `RoomView` seven lines of
/// hand-rolled alert reimplementing the shared modifier that every other screen uses.
public enum TimelineActionFailure: String, CaseIterable, ActionFailure {
    /// A message, a picture, a video, a voice note, a file, a place — anything that was going to
    /// the room and did not get there.
    case send

    /// A sticker that did not go. Not `send`, whose sentence promises another try: a sticker
    /// leaves outside the send queue (see `TimelineStore.send(sticker:)`), and nothing will.
    case sticker

    /// A message that would not be changed. Distinct from `send`: the original is still standing in
    /// the room, saying what it always said, which is the fact the user needs.
    case edit

    /// An emoji that did not land. The message itself is fine.
    case reaction

    /// A message that would not be taken back — the one failure here the user is likely to care
    /// about most, because they believe it is gone and it is not.
    case delete

    /// A message that would not be pinned, or would not be unpinned.
    case pin

    /// A report that did not reach the moderators. The user flagged something abusive and needs to
    /// know it did not go through, or they will assume it is being dealt with.
    case report

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .send: CoreStrings.Timeline.sendFailed
        case .sticker: CoreStrings.Timeline.stickerFailed
        case .edit: CoreStrings.Timeline.editFailed
        case .reaction: CoreStrings.Timeline.reactionFailed
        case .delete: CoreStrings.Timeline.deleteFailed
        case .pin: CoreStrings.Timeline.pinFailed
        case .report: CoreStrings.Timeline.reportFailed
        }
    }
}
