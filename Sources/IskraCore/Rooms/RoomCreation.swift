import Foundation
import MatrixRustSDK

/// A room that was not created. Two ways it can go wrong, and they are different acts for
/// the person who tried: one of them they can fix by retyping an address.
public enum RoomCreationFailure: String, CaseIterable, ActionFailure, Error {
    /// The Matrix ID of somebody to invite is not a Matrix ID.
    case badAddress
    /// The homeserver refused, or never answered.
    case refused

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .badAddress: CoreStrings.RoomAction.inviteFailed
        case .refused: CoreStrings.RoomAction.createFailed
        }
    }
}

public extension UserSession {
    /// Starts a conversation with one person.
    ///
    /// `trustedPrivateChat`, not `privateChat`: the preset that gives the invitee the same
    /// power level as the creator. In a room of two people, an owner and a guest is a
    /// distinction with no meaning — either of them may rename it, and neither can throw
    /// the other out, which is what a conversation between equals actually is.
    ///
    /// Encrypted, always. A one-to-one chat is the case where this matters most and the
    /// case nobody would think to turn it on for.
    func createDirectChat(with userID: String) async throws(RoomCreationFailure) -> String {
        guard RoomDetailsStore.isMatrixID(userID) else { throw .badAddress }

        return try await create(CreateRoomParameters(name: nil,
                                                     topic: nil,
                                                     isEncrypted: true,
                                                     isDirect: true,
                                                     visibility: .private,
                                                     preset: .trustedPrivateChat,
                                                     invite: [userID]))
    }

    /// Creates a room.
    ///
    /// Whether it is encrypted follows from whether it is public, and it is not a switch of
    /// its own. An encrypted public room is a room strangers can walk into and then read
    /// nothing in — the keys were shared before they arrived — so it looks broken to
    /// everyone who joins it. A public room is a noticeboard and is unencrypted; everything
    /// else is a conversation and is encrypted. That is one decision the user makes, in the
    /// words they already understand, instead of two they have to reconcile.
    func createRoom(named name: String,
                    topic: String?,
                    isPublic: Bool,
                    inviting invitees: [String] = []) async throws(RoomCreationFailure) -> String {
        guard invitees.allSatisfy(RoomDetailsStore.isMatrixID) else { throw .badAddress }

        let trimmedTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await create(CreateRoomParameters(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     topic: (trimmedTopic?.isEmpty ?? true) ? nil : trimmedTopic,
                                                     isEncrypted: !isPublic,
                                                     isDirect: false,
                                                     visibility: isPublic ? .public : .private,
                                                     preset: isPublic ? .publicChat : .privateChat,
                                                     invite: invitees.isEmpty ? nil : invitees))
    }

    /// Creates the room and waits for it to be a room this device can open.
    ///
    /// `awaitRoomRemoteEcho` is the whole reason this is not a race. `createRoom` returns as
    /// soon as the *server* has the room, which is several steps before the SDK's own store
    /// does — and the caller's next act is to put that room on screen. Without the wait, the
    /// screen opens on a room the client has never heard of and shows the "no chat selected"
    /// placeholder for as long as sync takes, which reads exactly like a room that failed to
    /// be created.
    ///
    /// Bounded, like every other call the user is made to wait on: a homeserver that accepts
    /// the room and then goes quiet must not leave a spinner turning forever.
    private func create(_ parameters: CreateRoomParameters) async throws(RoomCreationFailure) -> String {
        do {
            let client = self.client
            let roomID = try await withTimeout(Self.creationTimeout) {
                try await client.createRoom(request: parameters)
            }

            _ = try? await withTimeout(Self.echoTimeout) {
                try await client.awaitRoomRemoteEcho(roomId: roomID)
            }

            return roomID
        } catch {
            Log.rooms.error("the room was not created: \(Log.describe(error), privacy: .public)")
            throw .refused
        }
    }

    /// Creating a room is several round trips on the server's side, so it gets longer than a
    /// message does. The echo gets less: by then the room exists, and if the local store is
    /// slow to hear about it the screen can survive opening a moment later — which is why
    /// that one is a `try?` and this one is not.
    private static var creationTimeout: Duration { .seconds(30) }
    private static var echoTimeout: Duration { .seconds(10) }
}
