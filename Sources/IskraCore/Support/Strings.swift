import Foundation

/// Every piece of user-facing text that `IskraCore` produces.
///
/// Nothing below this file should contain a human-readable literal. The translations
/// themselves live in `Resources/Localizable.xcstrings`, which is the file to edit —
/// this one only names the strings.
///
/// The `bundle:` argument is not optional decoration. Inside a Swift package,
/// `LocalizedStringResource` and `Text` look in `Bundle.main` unless told otherwise,
/// which means they would silently find nothing and fall back to the key. Every
/// string here is explicitly pointed at the package's own bundle.
public enum CoreStrings {
    private static let bundle = LocalizedStringResource.BundleDescription.atURL(Bundle.module.bundleURL)

    /// How private a conversation is, in words rather than in cryptography.
    public enum Privacy {
        public static let protected = LocalizedStringResource("privacy.protected", bundle: bundle)
        public static let notProtected = LocalizedStringResource("privacy.notProtected", bundle: bundle)
        public static let unknown = LocalizedStringResource("privacy.unknown", bundle: bundle)
    }

    /// The one-line summaries under a conversation's name.
    public enum Preview {
        public static let photo = LocalizedStringResource("preview.photo", bundle: bundle)
        public static let video = LocalizedStringResource("preview.video", bundle: bundle)
        public static let videoNote = LocalizedStringResource("preview.videoNote", bundle: bundle)
        public static let voice = LocalizedStringResource("preview.voice", bundle: bundle)
        public static let audio = LocalizedStringResource("preview.audio", bundle: bundle)
        public static let file = LocalizedStringResource("preview.file", bundle: bundle)
        public static let location = LocalizedStringResource("preview.location", bundle: bundle)
        public static let sticker = LocalizedStringResource("preview.sticker", bundle: bundle)
        public static let poll = LocalizedStringResource("preview.poll", bundle: bundle)
        public static let deleted = LocalizedStringResource("preview.deleted", bundle: bundle)
        public static let unreadable = LocalizedStringResource("preview.unreadable", bundle: bundle)
    }

    public enum Room {
        /// Most Matrix DMs have no name of their own.
        public static let untitled = LocalizedStringResource("room.untitled", bundle: bundle)
    }

    /// A change to the account that did not take — see `AccountActionFailure`.
    public enum Account {
        public static let nameFailed = LocalizedStringResource("account.nameFailed", bundle: bundle)
        public static let pictureFailed = LocalizedStringResource("account.pictureFailed", bundle: bundle)
        public static let protectFailed = LocalizedStringResource("account.protectFailed", bundle: bundle)
        public static let newKeyFailed = LocalizedStringResource("account.newKeyFailed", bundle: bundle)
        /// The one failure on this screen the user can actually fix, so it says how: a
        /// recovery key is copied and pasted, and a half-copied one is by far the likeliest
        /// reason it is refused.
        public static let restoreFailed = LocalizedStringResource("account.restoreFailed", bundle: bundle)
    }

    /// A change to the room that the homeserver would not make. One sentence per act — see
    /// `RoomActionFailure` for why they are not all "something went wrong".
    public enum RoomAction {
        public static let renameFailed = LocalizedStringResource("roomAction.renameFailed", bundle: bundle)
        public static let topicFailed = LocalizedStringResource("roomAction.topicFailed", bundle: bundle)
        public static let pictureFailed = LocalizedStringResource("roomAction.pictureFailed", bundle: bundle)
        public static let visibilityFailed = LocalizedStringResource("roomAction.visibilityFailed", bundle: bundle)
        /// Also what a mistyped Matrix ID gets, and deliberately: the sentence names the
        /// shape of the thing — "@name:server" — because a typo is far and away the likeliest
        /// reason an invitation does not go through.
        public static let inviteFailed = LocalizedStringResource("roomAction.inviteFailed", bundle: bundle)
        public static let removeFailed = LocalizedStringResource("roomAction.removeFailed", bundle: bundle)
        public static let banFailed = LocalizedStringResource("roomAction.banFailed", bundle: bundle)
        public static let roleFailed = LocalizedStringResource("roomAction.roleFailed", bundle: bundle)
        public static let leaveFailed = LocalizedStringResource("roomAction.leaveFailed", bundle: bundle)
        /// The room was not created at all — which is not the same as a room created and an
        /// invitation refused, and the user is looking at an empty chat list either way.
        public static let createFailed = LocalizedStringResource("roomAction.createFailed", bundle: bundle)
        /// A mute that did not take. Worth its own sentence: the user believes the room has
        /// gone quiet, and it has not.
        public static let alertsFailed = LocalizedStringResource("roomAction.alertsFailed", bundle: bundle)

        /// The room would not open at all, so there is nothing on the screen to have refused
        /// anything. The only failure here that is not about an act the user performed.
        public static let loadFailed = LocalizedStringResource("roomAction.loadFailed", bundle: bundle)

        /// The invitation would not be taken up. Names the likeliest reason, because it is one the
        /// user can do nothing about but *ought to know*: an invitation can be withdrawn, and a
        /// room can be gone by the time you answer it.
        public static let acceptInviteFailed = LocalizedStringResource("roomAction.acceptInviteFailed", bundle: bundle)
        /// And one that would not be declined. The user believes they are rid of it; they are not.
        public static let declineInviteFailed = LocalizedStringResource("roomAction.declineInviteFailed", bundle: bundle)
    }

    /// The strip above a message that is answering another one.
    public enum Reply {
        /// The original is on its way. The SDK resolves a reply's target lazily, and for a
        /// message far up the conversation there is a moment where it has the ID and nothing
        /// else.
        public static let loading = LocalizedStringResource("reply.loading", bundle: bundle)
        /// And where it never found it — a message from before this device joined, or one the
        /// server no longer has.
        public static let unavailable = LocalizedStringResource("reply.unavailable", bundle: bundle)
    }

    /// The grey lines across the conversation: people arriving and leaving, the room being
    /// renamed. See `RoomEventKind`.
    ///
    /// Every one of them is written to be true of anybody, because Matrix does not know
    /// anyone's gender and Russian very much does. "Аня вошла" would be a coin flip on every
    /// name in every room, so the sentences are built to avoid the question: "Аня теперь в
    /// чате", not "Аня вошёл(ла)". The English reads a little more plainly than it otherwise
    /// might; that is the price, and it is a small one.
    public enum RoomEvent {
        public static func joined(_ people: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.joined", defaultValue: "\(people) joined", bundle: bundle)
        }

        public static func left(_ people: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.left", defaultValue: "\(people) left", bundle: bundle)
        }

        public static func invited(_ people: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.invited", defaultValue: "Invited: \(people)", bundle: bundle)
        }

        public static func removed(_ people: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.removed", defaultValue: "Removed: \(people)", bundle: bundle)
        }

        public static func banned(_ people: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.banned", defaultValue: "Blocked: \(people)", bundle: bundle)
        }

        public static func renamedThemselves(from: String, to: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.renamedThemselves",
                                    defaultValue: "\(from) is now known as \(to)",
                                    bundle: bundle)
        }

        public static func roomRenamed(_ name: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.roomRenamed",
                                    defaultValue: "The chat is now called “\(name)”",
                                    bundle: bundle)
        }

        public static let roomTopicChanged = LocalizedStringResource("roomEvent.roomTopicChanged", bundle: bundle)
        public static let roomPictureChanged = LocalizedStringResource("roomEvent.roomPictureChanged", bundle: bundle)
        public static let roomCreated = LocalizedStringResource("roomEvent.roomCreated", bundle: bundle)
        public static let encryptionEnabled = LocalizedStringResource("roomEvent.encryptionEnabled", bundle: bundle)

        /// Two people, named. Its own string because "и" sits between them in Russian and
        /// "and" in English, and neither language is entitled to assume the other's word order.
        public static func pair(_ first: String, _ second: String) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.pair", defaultValue: "\(first) and \(second)", bundle: bundle)
        }

        /// Three or more: the first person by name, and the rest as a number. Pluralised, and
        /// therefore in `Localizable.stringsdict` — Russian needs "ещё 2 участника" and "ещё 5
        /// участников", which `.strings` cannot express.
        public static func others(_ first: String, _ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("roomEvent.others",
                                    defaultValue: "\(first) and \(count) others",
                                    bundle: bundle)
        }
    }

    public enum Timeline {
        public static let sendFailed = LocalizedStringResource("timeline.sendFailed", bundle: bundle)
        /// An edit that did not go through. Its own sentence, because the user is looking at
        /// their message still saying the old thing and needs to know that is what happened —
        /// not that a *new* message failed to send.
        public static let editFailed = LocalizedStringResource("timeline.editFailed", bundle: bundle)
        /// Pinning is a change to the room's state, and a homeserver will refuse it from
        /// somebody whose power level does not allow it. The menu hides the item where we know
        /// that in advance; this is for the times we do not.
        public static let pinFailed = LocalizedStringResource("timeline.pinFailed", bundle: bundle)

        /// What a client that cannot draw a map shows instead of one. Coordinates, spelled out,
        /// because they are the one thing about a place that anybody can do something with —
        /// paste them into a map and you are there. The word in front of them is translated; the
        /// numbers are numbers.
        public static func locationBody(_ latitude: Double, _ longitude: Double) -> LocalizedStringResource {
            LocalizedStringResource("timeline.locationBody",
                                    defaultValue: "Location: \(latitude), \(longitude)",
                                    bundle: bundle)
        }
        /// A reaction that did not land. Its own sentence rather than `sendFailed`: an
        /// emoji is not a message, and telling someone their *message* failed when they
        /// tapped a thumbs-up would send them looking for a message that was never there.
        public static let reactionFailed = LocalizedStringResource("timeline.reactionFailed", bundle: bundle)
        /// Deleting is the one action here that is meant to be irreversible, so a
        /// deletion that silently did not happen is the worst possible outcome: the user
        /// believes a message is gone when everyone else can still read it.
        public static let deleteFailed = LocalizedStringResource("timeline.deleteFailed", bundle: bundle)
    }

    /// Why a message is stuck. Each one names the thing the user has to do, because these
    /// are failures only they can clear — see `SendFailure`.
    public enum SendFailure {
        public static let insecureDevices = LocalizedStringResource("sendFailure.insecureDevices", bundle: bundle)
        public static let identityChanged = LocalizedStringResource("sendFailure.identityChanged", bundle: bundle)
        public static let verificationRequired = LocalizedStringResource("sendFailure.verificationRequired", bundle: bundle)
        public static let missingMedia = LocalizedStringResource("sendFailure.missingMedia", bundle: bundle)
        public static let unsupportedFileType = LocalizedStringResource("sendFailure.unsupportedFileType", bundle: bundle)
        public static let server = LocalizedStringResource("sendFailure.server", bundle: bundle)
    }

    /// What a push says once it has been decrypted on the device — see `PushDecoder`.
    ///
    /// There is almost nothing here, and that is the point: a notification about a message
    /// says the message, and the message is the user's own words, which are never a string
    /// to translate. Only the one push that is *not* a message needs a sentence of ours.
    public enum Push {
        /// Somebody asking you into a chat. Written to be true of anybody, for the same
        /// reason every sentence in `RoomEvent` is: Matrix does not know anyone's gender and
        /// Russian very much does, so "приглашает" — which is the same word whoever is doing
        /// the inviting — and never "пригласил(а)".
        public static func invite(_ person: String) -> LocalizedStringResource {
            LocalizedStringResource("push.invite",
                                    defaultValue: "\(person) invites you to the chat",
                                    bundle: bundle)
        }
    }

    /// Shown in the user's list of signed-in devices, so it is a name, not a model
    /// identifier.
    public enum Device {
        public static let mac = LocalizedStringResource("device.mac", bundle: bundle)
        public static let iOS = LocalizedStringResource("device.iOS", bundle: bundle)
        public static let generic = LocalizedStringResource("device.generic", bundle: bundle)
    }
}

extension String {
    /// Resolves a core string for the current locale.
    init(core resource: LocalizedStringResource) {
        self.init(localized: resource)
    }
}
