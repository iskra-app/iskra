import Foundation
import IskraCore

/// Everything a row can ask the conversation to do, in one parcel.
///
/// Nine closures, and none of them is a decision the row is allowed to make: a row draws a
/// message and reports what the finger did. Only `RoomView` holds the store that owns the
/// room, so reacting, deleting, pinning, replying and the rest are all handed upward — see
/// the note on each one below.
///
/// They travel together rather than one by one, and that is what this type is for. Two things
/// draw a message now — the bubble and the compact line — and a row that carried nine separate
/// parameters would have to be kept in step with its twin by hand, every time one of them
/// gained a tenth. A parcel is passed on without being read, so a handler added here reaches
/// both rows and the menu without either of them being touched.
///
/// It also buys back a compiler. `RoomView` builds these closures inline, and with nine of
/// them written out at the call site the type checker gave up on the whole body — "unable to
/// type-check this expression in reasonable time" — because every closure it has to infer
/// multiplies through the view tree around it. One value it can name is one thing to infer.
///
/// Every closure defaults to doing nothing, so a preview or a test can name only the one it
/// cares about.
struct MessageHandlers {
    /// Starts the room's send queue again, for the one message shape that can ask for it:
    /// a failure the SDK called recoverable.
    var onRetry: () -> Void = {}

    /// Sends it past a verification that no longer holds, having been told — see
    /// `TimelineStore.sendAnyway`. Offered only where `SendFailure.canSendAnyway`.
    var onSendAnyway: () -> Void = {}

    /// Adds an emoji, or takes it back if it is already ours. One callback for both,
    /// because a reaction is a toggle — see `TimelineStore.toggleReaction`.
    var onToggleReaction: (String) -> Void = { _ in }

    /// Takes the message back for everyone. Only ever offered where `Message.canDelete`.
    var onDelete: () -> Void = {}

    /// Throws away a message that never left the device. A different act from `onDelete`,
    /// which redacts an event the room has already seen — see `TimelineStore.discard`.
    var onDiscard: () -> Void = {}

    /// Starts an answer to this message. The composer, not the row, is where the answer is
    /// actually written — so this only says which message the user chose.
    var onReply: () -> Void = {}

    /// Goes back and changes what was written. Only the user's own words — see `Message.canEdit`.
    var onEdit: () -> Void = {}

    /// Pins the message to the top of the room, or takes it off again. One callback, because
    /// the user is pressing one item whose word depends on where the message already is.
    var onTogglePin: () -> Void = {}

    /// Goes to the message this one is answering. Pressed on the quote; only `RoomView` can
    /// actually scroll the conversation, so it is reported upward.
    var onOpenReply: (String) -> Void = { _ in }

    /// Reports this message to the moderators, carrying the user's reason. Only `RoomView`
    /// holds the store that can send it, so the reason is handed upward.
    var onReport: (String) -> Void = { _ in }

    /// Answers a poll with the whole new choice, or closes one this account started.
    var onVote: ([String]) -> Void = { _ in }
    var onEndPoll: () -> Void = {}

    /// Whether the room lets this account delete other people's messages — see
    /// `TimelineStore.canDeleteOthers`. A fact rather than a closure, but it travels with the acts
    /// it unlocks, to both rows and the menu alike.
    var canDeleteOthers = false

    /// Who reacted, named — for the "N reactions" line in a group's menu. Nil in a personal chat,
    /// and nil means the line is not offered. See `ReactorsSheet`.
    var loadReactors: (() async -> [Reactor])?
}
