import Foundation
import IskraCore
import IskraDesign

/// Every piece of user-facing text in the app's screens.
///
/// If you are looking for a word that appears on screen, it is here. If you are
/// adding one, it goes here — not into a view. The translations live in
/// `Resources/<lang>.lproj/Localizable.strings`, which is the file to edit; this one
/// only names them.
///
/// `bundle:` is load-bearing. Inside a Swift package, `Text` and
/// `LocalizedStringResource` look in `Bundle.main` unless told otherwise, so without
/// it every string would quietly resolve to its own key and no translation would
/// ever appear.
public enum Strings {
    /// The package's own bundle, where the `.lproj` folders live.
    static let resourceBundle = Bundle.module
    static let bundle = LocalizedStringResource.BundleDescription.atURL(Bundle.module.bundleURL)

    public enum SignIn {
        public static let title = LocalizedStringResource("signIn.title", bundle: bundle)
        public static let tagline = LocalizedStringResource("signIn.tagline", bundle: bundle)

        public static let whereIsAccount = LocalizedStringResource("signIn.whereIsAccount", bundle: bundle)
        public static let whereIsAccountHelp = LocalizedStringResource("signIn.whereIsAccountHelp", bundle: bundle)
        public static let addressPlaceholder = LocalizedStringResource("signIn.addressPlaceholder", bundle: bundle)
        public static let addressLabel = LocalizedStringResource("signIn.addressLabel", bundle: bundle)
        public static let `continue` = LocalizedStringResource("signIn.continue", bundle: bundle)

        public static let readyTitle = LocalizedStringResource("signIn.readyTitle", bundle: bundle)
        public static let readyHelp = LocalizedStringResource("signIn.readyHelp", bundle: bundle)

        /// Shown only where the server says it can make accounts — OIDC advertises `prompt=create`,
        /// and a server that does not cannot register anybody through this app at all. An offer we
        /// could not keep would be worse than no offer.
        public static let createAccount = LocalizedStringResource("signIn.createAccount", bundle: bundle)
        public static let signIn = LocalizedStringResource("signIn.signIn", bundle: bundle)
        public static let username = LocalizedStringResource("signIn.username", bundle: bundle)
        public static let password = LocalizedStringResource("signIn.password", bundle: bundle)
        public static let signInWithPassword = LocalizedStringResource("signIn.signInWithPassword", bundle: bundle)

        /// The quiet way to the password fields, on a server that offers both.
        ///
        /// There used to be an "or" here, with two buttons of equal weight under it, and that was
        /// the screen handing the user a decision instead of a way in. Almost nobody arriving at a
        /// server with OAuth *wants* the password form — they want to be let in — and the ones who
        /// do need it know they need it. So there is one way in, and a sentence for the people it
        /// does not work for.
        public static let usePasswordInstead = LocalizedStringResource("signIn.usePasswordInstead", bundle: bundle)
        public static let differentAddress = LocalizedStringResource("signIn.differentAddress", bundle: bundle)

        /// Errors. Each says what happened and what to do; none names a protocol.
        public enum Problem {
            public static let notFound = LocalizedStringResource("signIn.problem.notFound", bundle: bundle)
            public static let unsupportedMethod = LocalizedStringResource("signIn.problem.unsupportedMethod", bundle: bundle)
            public static let storageUnavailable = LocalizedStringResource("signIn.problem.storageUnavailable", bundle: bundle)
            public static let unreachable = LocalizedStringResource("signIn.problem.unreachable", bundle: bundle)
            public static let ssoIncomplete = LocalizedStringResource("signIn.problem.ssoIncomplete", bundle: bundle)
            public static let badCredentials = LocalizedStringResource("signIn.problem.badCredentials", bundle: bundle)
        }
    }

    /// The state of the connection, said out loud. See `OfflineBanner`.
    public enum Connection {
        public static let offline = LocalizedStringResource("connection.offline", bundle: bundle)
    }

    public enum RoomList {
        public static let title = LocalizedStringResource("roomList.title", bundle: bundle)
        public static let searchPrompt = LocalizedStringResource("roomList.searchPrompt", bundle: bundle)
        public static let clearSearch = LocalizedStringResource("roomList.clearSearch", bundle: bundle)
        public static let loading = LocalizedStringResource("roomList.loading", bundle: bundle)
        public static let emptyTitle = LocalizedStringResource("roomList.emptyTitle", bundle: bundle)
        public static let emptyMessage = LocalizedStringResource("roomList.emptyMessage", bundle: bundle)
        public static let privateChat = LocalizedStringResource("roomList.privateChat", bundle: bundle)

        /// A room somebody has asked you into, and the two answers to it.
        ///
        /// Written to be true of anybody, for the same reason every sentence in `RoomEvent` is:
        /// Matrix does not know anyone's gender and Russian very much does. "Приглашает" is the
        /// same word whoever is doing the inviting; "пригласила" would be a coin flip on every
        /// name in every room.
        public enum Invite {
            /// The label on the row, where we know who asked.
            public static func from(_ person: String) -> LocalizedStringResource {
                LocalizedStringResource("roomList.invite.from",
                                        defaultValue: "\(person) invites you",
                                        bundle: bundle)
            }

            /// And where we do not — `RoomInfo.inviter` is genuinely optional, even for an
            /// invitation: the SDK says so, and it happens when the invite event itself is not in
            /// the store. "You have been invited" is still the whole of what the user needs.
            public static let unattributed = LocalizedStringResource("roomList.invite.unattributed", bundle: bundle)

            public static let accept = LocalizedStringResource("roomList.invite.accept", bundle: bundle)
            public static let decline = LocalizedStringResource("roomList.invite.decline", bundle: bundle)
        }

        /// The "+" in the top-left corner, and the two things it can start.
        public static let newConversation = LocalizedStringResource("roomList.newConversation", bundle: bundle)
        public static let newChat = LocalizedStringResource("roomList.newChat", bundle: bundle)
        public static let newRoom = LocalizedStringResource("roomList.newRoom", bundle: bundle)

        /// The screen behind them. Its fields are borrowed from the room-info screen — a
        /// name is a name — so only the two verbs are new, and they are two verbs rather
        /// than one because you *create* a room and you *start* a conversation with a
        /// person, and the button ought to say which of those is about to happen.
        public enum New {
            public static let create = LocalizedStringResource("roomList.new.create", bundle: bundle)
            public static let start = LocalizedStringResource("roomList.new.start", bundle: bundle)
            /// What "open chat" costs, said once, where the switch is. Encryption is not a
            /// switch of its own in this app — see `UserSession.createRoom`.
            public static let openMeansUnencrypted = LocalizedStringResource("roomList.new.openMeansUnencrypted",
                                                                             bundle: bundle)
        }

        /// Pluralised. Russian needs one/few/many, which is why these go through the
        /// catalog's plural rules rather than through string interpolation.
        public static func unread(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("roomList.unread", defaultValue: "\(count) unread", bundle: bundle)
        }

        public static func mentions(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("roomList.mentions", defaultValue: "\(count) mentioning you", bundle: bundle)
        }
    }

    public enum Room {
        /// The button that appears when a message arrives while you are reading further up.
        ///
        /// It exists because the conversation no longer drags you to the bottom against your will
        /// — so something has to say that there is a bottom to go to. One without the other would
        /// be worse than either: the old behaviour at least told you a message had come.
        public static let jumpToNewest = LocalizedStringResource("room.jumpToNewest", bundle: bundle)

        /// The round button in the corner that takes you to the bottom of a room you have read a
        /// long way up. Read aloud only — the arrow in it is the whole of what it says on screen.
        public static let scrollToBottom = LocalizedStringResource("room.scrollToBottom", bundle: bundle)

        /// The way into a conversation that is too short to scroll and yet has more behind it.
        ///
        /// Older messages are asked for by scrolling to the top, and a room showing two messages
        /// cannot be scrolled at all — so when the opening fetch comes up short, this is the only
        /// thing left that can ask. See `TimelineStore.needsMoreHistory`.
        public static let loadEarlier = LocalizedStringResource("room.loadEarlier", bundle: bundle)

        /// What stands in `loadEarlier`'s place when the older messages could not be fetched — see
        /// `TimelineStore.historyIsStranded`. It has to explain rather than offer: the button next
        /// to it would fail, and a reader who presses a button twice and sees nothing concludes the
        /// app has lost the conversation.
        public static let earlierUnavailable = LocalizedStringResource("room.earlierUnavailable", bundle: bundle)

        /// Somebody is writing. In a one-to-one chat their name is already the title of the screen,
        /// so this does not repeat it.
        public static let typing = LocalizedStringResource("room.typing", bundle: bundle)

        /// And in a room, where it is worth knowing *who*. Gender-neutral in Russian for the same
        /// reason every sentence in `CoreStrings.RoomEvent` is — "печатает" is the same word
        /// whoever is doing it, and Matrix does not know anybody's gender.
        public static func typingBy(_ people: String) -> LocalizedStringResource {
            LocalizedStringResource("room.typingBy",
                                    defaultValue: "\(people) is typing…",
                                    bundle: bundle)
        }

        public static let composerPlaceholder = LocalizedStringResource("room.composerPlaceholder", bundle: bundle)
        public static let send = LocalizedStringResource("room.send", bundle: bundle)
        public static let attach = LocalizedStringResource("room.attach", bundle: bundle)
        public static let attachPhoto = LocalizedStringResource("room.attachPhoto", bundle: bundle)
        public static let attachFile = LocalizedStringResource("room.attachFile", bundle: bundle)
        public static let sendFailedTitle = LocalizedStringResource("room.sendFailedTitle", bundle: bundle)

        /// The picture was chosen and then could not be read — which is a failure *before*
        /// anything was sent, and must not be reported as the server refusing it.
        public static let attachmentUnreadable = LocalizedStringResource("room.attachmentUnreadable", bundle: bundle)
        public static let noRoomSelectedTitle = LocalizedStringResource("room.noRoomSelectedTitle", bundle: bundle)
        public static let noRoomSelectedMessage = LocalizedStringResource("room.noRoomSelectedMessage", bundle: bundle)

        /// A conversation with nothing in it, and one that would not open. Two different
        /// blank screens, and only one of them is a problem — see `RoomView.placeholder`.
        public static let emptyTitle = LocalizedStringResource("room.emptyTitle", bundle: bundle)
        public static let emptyMessage = LocalizedStringResource("room.emptyMessage", bundle: bundle)
        public static let loadFailedTitle = LocalizedStringResource("room.loadFailedTitle", bundle: bundle)
        public static let loadFailedMessage = LocalizedStringResource("room.loadFailedMessage", bundle: bundle)
        public static let tryAgain = LocalizedStringResource("room.tryAgain", bundle: bundle)

        /// The strip that appears above the composer when you are answering somebody, or going
        /// back to change something you wrote. Two different jobs, so two different words —
        /// they look alike and they are not the same act, and a strip that said the same thing
        /// for both would leave the user unsure which one they had started.
        public static let replyingTo = LocalizedStringResource("room.replyingTo", bundle: bundle)
        public static let editingMessage = LocalizedStringResource("room.editingMessage", bundle: bundle)
        /// Backs out of either one. The draft survives — it is the *reply* that is cancelled,
        /// not what you had begun to type.
        public static let stopReplying = LocalizedStringResource("room.stopReplying", bundle: bundle)

        /// The pinned messages: the strip at the top of the room, and the screen behind it.
        public static let pinned = LocalizedStringResource("room.pinned", bundle: bundle)
        public static let pinnedTitle = LocalizedStringResource("room.pinnedTitle", bundle: bundle)
        public static let pinnedEmpty = LocalizedStringResource("room.pinnedEmpty", bundle: bundle)
        public static let unpin = LocalizedStringResource("room.unpin", bundle: bundle)

        /// The header above a conversation, and the screen behind it.
        public static let openDetails = LocalizedStringResource("room.openDetails", bundle: bundle)
        public static let detailsTitle = LocalizedStringResource("room.detailsTitle", bundle: bundle)
        /// The room's topic — what the room is for, written by whoever runs it.
        public static let about = LocalizedStringResource("room.about", bundle: bundle)
        public static let administrator = LocalizedStringResource("room.administrator", bundle: bundle)
        public static let moderator = LocalizedStringResource("room.moderator", bundle: bundle)

        /// Running the room. Every one of these appears only for somebody the room's own
        /// power levels allow to use it — see `RoomPermissions`, and the reason the ones
        /// that do not apply are *absent* rather than greyed out.
        public enum Manage {
            /// The name and the description, as fields rather than as labels. What the
            /// reader sees is what they can change, in place, with no "Edit" mode in front
            /// of it — a room's name is one line of text, and a whole screen state to change
            /// one line of text is a screen too many.
            public static let namePlaceholder = LocalizedStringResource("room.manage.namePlaceholder", bundle: bundle)
            public static let topicPlaceholder = LocalizedStringResource("room.manage.topicPlaceholder", bundle: bundle)

            public static let changePicture = LocalizedStringResource("room.manage.changePicture", bundle: bundle)
            public static let removePicture = LocalizedStringResource("room.manage.removePicture", bundle: bundle)

            /// Who may walk in. The switch is the plain-language half of the join rules —
            /// the protocol's other answers (knocking, restricted to a space) are not
            /// offered, because neither can be explained in a sentence a person recognises.
            public static let openToAnyone = LocalizedStringResource("room.manage.openToAnyone", bundle: bundle)
            public static let openToAnyoneHelp = LocalizedStringResource("room.manage.openToAnyoneHelp", bundle: bundle)

            public static let invite = LocalizedStringResource("room.manage.invite", bundle: bundle)
            public static let inviteTitle = LocalizedStringResource("room.manage.inviteTitle", bundle: bundle)
            public static let inviteHelp = LocalizedStringResource("room.manage.inviteHelp", bundle: bundle)
            public static let invitePlaceholder = LocalizedStringResource("room.manage.invitePlaceholder", bundle: bundle)

            public static let role = LocalizedStringResource("room.manage.role", bundle: bundle)
            /// The third rung has no badge in the list — everybody is a member — but it very
            /// much needs a word in the menu that *demotes* somebody back to being one.
            public static let member = LocalizedStringResource("room.manage.member", bundle: bundle)

            public static let remove = LocalizedStringResource("room.manage.remove", bundle: bundle)
            public static let block = LocalizedStringResource("room.manage.block", bundle: bundle)
            /// Blocking is the one act here with no way back in this interface, so it is
            /// the one that asks first, by name.
            public static func blockQuestion(_ name: String) -> LocalizedStringResource {
                LocalizedStringResource("room.manage.blockQuestion",
                                        defaultValue: "Block \(name)?",
                                        bundle: bundle)
            }
            public static let blockHelp = LocalizedStringResource("room.manage.blockHelp", bundle: bundle)

            /// How loudly the room may interrupt you — the one control on this screen that
            /// everybody gets, whatever their power level. It is a rule about your own
            /// device, and the room never hears about it.
            public static let alerts = LocalizedStringResource("room.manage.alerts", bundle: bundle)

            static func alerts(_ choice: RoomAlerts) -> LocalizedStringResource {
                switch choice {
                case .all: LocalizedStringResource("room.manage.alertsAll", bundle: bundle)
                case .mentions: LocalizedStringResource("room.manage.alertsMentions", bundle: bundle)
                case .muted: LocalizedStringResource("room.manage.alertsMuted", bundle: bundle)
                }
            }

            public static let leave = LocalizedStringResource("room.manage.leave", bundle: bundle)
            public static let leaveQuestion = LocalizedStringResource("room.manage.leaveQuestion", bundle: bundle)
            public static let leaveHelp = LocalizedStringResource("room.manage.leaveHelp", bundle: bundle)

            /// Why every control on this screen is grey. Without it a disabled form is just a broken
            /// one — see `RoomInfoView`.
            public static let offline = LocalizedStringResource("room.manage.offline", bundle: bundle)

            public static let cancel = LocalizedStringResource("room.manage.cancel", bundle: bundle)
            /// The title over any refusal from the homeserver. The sentence underneath it
            /// comes from `IskraCore`, which is where the app knows *which* act failed.
        }

        /// The day divider. Only the two days people actually name have words; everything
        /// older is a date, formatted by `Date.FormatStyle` and so already in the reader's
        /// language.
        public static let today = LocalizedStringResource("room.today", bundle: bundle)
        public static let yesterday = LocalizedStringResource("room.yesterday", bundle: bundle)

        /// Pluralised: Russian needs one/few/many where English has one/other, so "2
        /// участника" and "5 участников" cannot be the same sentence with the number
        /// swapped. Lives in `Localizable.stringsdict`, which is the only file that can
        /// express that.
        public static func participants(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("room.participants", defaultValue: "\(count) participants", bundle: bundle)
        }
    }

    public enum Message {
        public static let unreadable = LocalizedStringResource("message.unreadable", bundle: bundle)
        public static let deleted = LocalizedStringResource("message.deleted", bundle: bundle)
        public static let unsupported = LocalizedStringResource("message.unsupported", bundle: bundle)
        /// The mark beside a message whose author went back and changed it. One word, so it can
        /// sit inside the bubble beside the text without becoming a second line.
        public static let edited = LocalizedStringResource("message.edited", bundle: bundle)

        /// The long press (right-click, on a Mac) on a message.
        public enum Menu {
            public static let copy = LocalizedStringResource("message.menu.copy", bundle: bundle)
            public static let reply = LocalizedStringResource("message.menu.reply", bundle: bundle)
            public static let edit = LocalizedStringResource("message.menu.edit", bundle: bundle)
            /// One action, two words, and which one is shown says which way it goes.
            public static let pin = LocalizedStringResource("message.menu.pin", bundle: bundle)
            public static let unpin = LocalizedStringResource("message.menu.unpin", bundle: bundle)
            public static let delete = LocalizedStringResource("message.menu.delete", bundle: bundle)
            /// Deleting takes the message back for everyone and cannot be undone, so it is
            /// the one thing in this menu that asks twice.
            public static let deleteConfirmTitle = LocalizedStringResource("message.menu.deleteConfirmTitle", bundle: bundle)
            public static let deleteConfirmMessage = LocalizedStringResource("message.menu.deleteConfirmMessage", bundle: bundle)

            /// What VoiceOver says a reaction pill *will do* — which is the one thing its
            /// appearance cannot say out loud.
            public static let addReaction = LocalizedStringResource("message.menu.addReaction", bundle: bundle)
            public static let removeReaction = LocalizedStringResource("message.menu.removeReaction", bundle: bundle)

            /// What VoiceOver calls the pill itself: the emoji, and how many people left
            /// it. Pluralised, so Russian declines the people rather than the emoji.
            public static func reaction(_ key: String, _ count: Int) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.reaction",
                                        defaultValue: "\(key), \(count) people",
                                        bundle: bundle)
            }

            /// The exact moment, at the foot of the menu. The date arrives already written in
            /// the reader's language — `Date.FormatStyle` did that — so what is translated here
            /// is only the word in front of it, and where in the sentence that word goes.
            public static func sentAt(_ date: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.sentAt", defaultValue: "Sent \(date)", bundle: bundle)
            }

            /// And on a message that is gone, the other moment worth knowing.
            public static func deletedAt(_ date: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.deletedAt", defaultValue: "Deleted \(date)", bundle: bundle)
            }
        }

        /// Watching what somebody sent.
        public enum Media {
            public static let close = LocalizedStringResource("message.media.close", bundle: bundle)
            public static let share = LocalizedStringResource("message.media.share", bundle: bundle)
            /// Into the photo library. Only on iOS: on a Mac the share sheet already offers
            /// every sensible destination, and a "Save" button beside it would be a second way
            /// to do the same thing.
            public static let save = LocalizedStringResource("message.media.save", bundle: bundle)
            /// The voice message, played. VoiceOver has nothing else to go on: the control is a
            /// waveform, which is a picture of a sound and not a label.
            public static let play = LocalizedStringResource("message.media.play", bundle: bundle)
            public static let pause = LocalizedStringResource("message.media.pause", bundle: bundle)
            /// A file, opened in whatever the system thinks should open it.
            public static let openFile = LocalizedStringResource("message.media.openFile", bundle: bundle)

            /// What the bubble *is*, said aloud — for the three whose whole content is a picture
            /// or a sound and which therefore have nothing a screen reader can read.
            ///
            /// These are not decoration. A photograph and a video note are opened by a tap
            /// gesture, and a tap gesture does not exist in the accessibility tree at all: without
            /// a name and an action there was no element there to press, and no way to open either
            /// of them with VoiceOver on.
            public static let photo = LocalizedStringResource("message.media.photo", bundle: bundle)
            public static let video = LocalizedStringResource("message.media.video", bundle: bundle)
            public static let videoNote = LocalizedStringResource("message.media.videoNote", bundle: bundle)

            /// The hint on both: what pressing them does.
            public static let openFullScreen = LocalizedStringResource("message.media.openFullScreen", bundle: bundle)
            /// The video would not come down. Said on the bubble, not in an alert — there is
            /// nothing to do about it but press it again.
            public static let loadFailed = LocalizedStringResource("message.media.loadFailed", bundle: bundle)
        }

        public enum Delivery {
            public static let sending = LocalizedStringResource("message.delivery.sending", bundle: bundle)
            public static let sent = LocalizedStringResource("message.delivery.sent", bundle: bundle)
            public static let read = LocalizedStringResource("message.delivery.read", bundle: bundle)
            public static let failed = LocalizedStringResource("message.delivery.failed", bundle: bundle)
            /// Offered only where trying again can actually work — see `SendFailure.canRetry`.
            public static let sendAgain = LocalizedStringResource("message.delivery.sendAgain", bundle: bundle)
            /// Throws the message out of the send queue. Its own word rather than
            /// `Menu.delete`, even though both read "Удалить": that one redacts an event the
            /// whole room has already seen, this one drops a message nobody ever received.
            /// The user sees the same word because to them it *is* the same word — but the
            /// two must be free to diverge in translation without dragging each other along.
            public static let discard = LocalizedStringResource("message.delivery.discard", bundle: bundle)
        }

        /// What VoiceOver reads instead of a bubble it cannot describe.
        public enum Spoken {
            public static let you = LocalizedStringResource("message.spoken.you", bundle: bundle)
            public static let sentPhoto = LocalizedStringResource("message.spoken.sentPhoto", bundle: bundle)
            public static let sentSticker = LocalizedStringResource("message.spoken.sentSticker", bundle: bundle)

            /// The same, for a sticker whose sender described it — which most of them do, with
            /// an emoji or a word. It is the only thing that tells two stickers apart when you
            /// cannot see either of them, so it is said rather than dropped.
            public static func sentStickerNamed(_ description: String) -> LocalizedStringResource {
                LocalizedStringResource("message.spoken.sentStickerNamed",
                                        defaultValue: "a sticker, \(description)",
                                        bundle: bundle)
            }

            public static let sentVideo = LocalizedStringResource("message.spoken.sentVideo", bundle: bundle)
            public static let sentVideoNote = LocalizedStringResource("message.spoken.sentVideoNote", bundle: bundle)
            public static let sentVoice = LocalizedStringResource("message.spoken.sentVoice", bundle: bundle)
            public static let sentAudio = LocalizedStringResource("message.spoken.sentAudio", bundle: bundle)
            public static let sentFile = LocalizedStringResource("message.spoken.sentFile", bundle: bundle)
            public static let sentLocation = LocalizedStringResource("message.spoken.sentLocation", bundle: bundle)
            public static let sentUnreadable = LocalizedStringResource("message.spoken.sentUnreadable", bundle: bundle)
            public static let deletedMessage = LocalizedStringResource("message.spoken.deletedMessage", bundle: bundle)
            public static let sentUnsupported = LocalizedStringResource("message.spoken.sentUnsupported", bundle: bundle)
        }
    }

    public enum VideoNote {
        public static let title = LocalizedStringResource("videoNote.title", bundle: bundle)
        public static let holdToRecord = LocalizedStringResource("videoNote.holdToRecord", bundle: bundle)
        public static let sending = LocalizedStringResource("videoNote.sending", bundle: bundle)
        public static let needsCamera = LocalizedStringResource("videoNote.needsCamera", bundle: bundle)
        public static let noCamera = LocalizedStringResource("videoNote.noCamera", bundle: bundle)
        public static let record = LocalizedStringResource("videoNote.record", bundle: bundle)
        /// Said under the camera while the finger is still on the button that started it. It
        /// names all three ways out of a recording in one line, because the two swipes are the
        /// kind of gesture nobody discovers by accident and the moment to say so is while they
        /// are holding the button.
        public static let releaseToSend = LocalizedStringResource("videoNote.releaseToSend", bundle: bundle)
        /// The button on the preview. Only ever shown where there is a second camera to
        /// turn to — see `VideoNoteRecorder.canFlip`.
        public static let flipCamera = LocalizedStringResource("videoNote.flipCamera", bundle: bundle)
    }

    /// The one button that records, whichever kind of message it is set to. What it says is only
    /// ever read aloud: the gesture — tap to flip, hold to record — is not one VoiceOver can
    /// perform, so it has to be a sentence and two actions instead.
    public enum Recording {
        public static let hint = LocalizedStringResource("recording.hint", bundle: bundle)
        public static let switchToVoice = LocalizedStringResource("recording.switchToVoice", bundle: bundle)
        public static let switchToVideo = LocalizedStringResource("recording.switchToVideo", bundle: bundle)
        /// On the strip, beside the clock, for both kinds of recording — as a button once the
        /// finger is off the record button, and as the target of the swipe while it is still down.
        /// One word either way; `RecordingStrip` explains why it cannot be one *button* either way.
        public static let cancel = LocalizedStringResource("recording.cancel", bundle: bundle)
        /// What the record button is called once a recording is running hands-free, and what the
        /// camera's shutter is called then too — both are showing the arrow, and both send. Read
        /// aloud only, but it has to follow the glyph rather than the mode.
        public static let send = LocalizedStringResource("recording.send", bundle: bundle)
    }

    /// Recording a spoken message. Same gestures as a round video one, and deliberately the
    /// same words for them — it is one button, set one way or the other.
    public enum Voice {
        public static let record = LocalizedStringResource("voice.record", bundle: bundle)
        public static let needsMicrophone = LocalizedStringResource("voice.needsMicrophone", bundle: bundle)
    }

    /// Sending a place.
    public enum Location {
        public static let title = LocalizedStringResource("location.title", bundle: bundle)
        public static let send = LocalizedStringResource("location.send", bundle: bundle)
        public static let cancel = LocalizedStringResource("location.cancel", bundle: bundle)
        public static let myLocation = LocalizedStringResource("location.myLocation", bundle: bundle)
        /// The third thing the "+" can attach.
        public static let attach = LocalizedStringResource("location.attach", bundle: bundle)
    }

    /// The apology every screen shares — see `View.failureAlert`, which is the only thing
    /// that says them. They were `Room.ok` and `Room.Manage.failedTitle` until the account
    /// screens started refusing things too, and a settings alert reaching into the room's
    /// vocabulary for the word "OK" was the sign they had never belonged to the room.
    public enum Problem {
        public static let title = LocalizedStringResource("problem.title", bundle: bundle)
        public static let ok = LocalizedStringResource("problem.ok", bundle: bundle)
    }

    /// Proving this device is yours, by comparing seven pictures with a device that already is.
    ///
    /// Every word here is written around one idea and never around the cryptography behind it: the
    /// user is being asked to *look at two screens and say whether they show the same thing*. They
    /// are not being asked to understand cross-signing, and a screen that mentioned it would be
    /// asking them to.
    public enum Verification {
        public static let verify = LocalizedStringResource("verification.verify", bundle: bundle)
        public static let title = LocalizedStringResource("verification.title", bundle: bundle)

        /// Why anyone should bother — shown under the button, before it is pressed.
        public static let why = LocalizedStringResource("verification.why", bundle: bundle)

        public static let waitingTitle = LocalizedStringResource("verification.waiting.title", bundle: bundle)
        public static let waitingMessage = LocalizedStringResource("verification.waiting.message", bundle: bundle)

        /// A device of this user's, signing in and asking to be trusted — the question that starts
        /// the flow from the other end. The device's own name carries the message, so this says
        /// what the two answers *mean* rather than repeating the name back.
        public static let askedMessage = LocalizedStringResource("verification.asked.message", bundle: bundle)

        /// What to call a device whose owner never named it. Not "Unknown device", which sounds
        /// like the app failed to find something out: the account knows exactly what it is, it
        /// simply has no name, and saying so is less alarming and more true.
        public static let unnamedDevice = LocalizedStringResource("verification.unnamedDevice", bundle: bundle)

        /// The two answers to it. As with `match`/`noMatch`, neither is worded as the easy one.
        public static let mine = LocalizedStringResource("verification.mine", bundle: bundle)
        public static let notMine = LocalizedStringResource("verification.notMine", bundle: bundle)

        public static let negotiatingTitle = LocalizedStringResource("verification.negotiating.title", bundle: bundle)
        public static let negotiatingMessage = LocalizedStringResource("verification.negotiating.message", bundle: bundle)

        public static let compare = LocalizedStringResource("verification.compare", bundle: bundle)

        /// The two answers. Neither is styled as the obvious one, and neither is worded as one:
        /// "yes" is the answer that grants trust, and it is the answer somebody standing in the
        /// middle of the conversation needs the user to give without looking.
        public static let match = LocalizedStringResource("verification.match", bundle: bundle)
        public static let noMatch = LocalizedStringResource("verification.noMatch", bundle: bundle)

        public static let doneTitle = LocalizedStringResource("verification.done.title", bundle: bundle)
        public static let doneMessage = LocalizedStringResource("verification.done.message", bundle: bundle)

        public static let declinedTitle = LocalizedStringResource("verification.declined.title", bundle: bundle)
        public static let declinedMessage = LocalizedStringResource("verification.declined.message", bundle: bundle)

        /// The user was asked to trust a device and said it was not theirs. Deliberately not the
        /// same words as `declined`: that one is a verification that did not happen, and this one
        /// is a report that somebody else is signing in with this account's password. It is the
        /// only place in the app that tells the user to go and do something *outside* it.
        public static let refusedTitle = LocalizedStringResource("verification.refused.title", bundle: bundle)
        public static let refusedMessage = LocalizedStringResource("verification.refused.message", bundle: bundle)

        /// The one thing a person can actually *do* about a device that is not theirs, and until now
        /// the app named it without offering it: the sentence said "somebody else knows your
        /// password, change it now" and then presented a Close button. Advice with no door next to it
        /// is advice nobody follows — they close the sheet, mean to deal with it later, and don't.
        ///
        /// The door is the server's own sessions page, which is the only place a session can be
        /// killed (see `Settings.devices` — the FFI exports no way to do it natively). It exists only
        /// where the server hands one over, so the button appears only then.
        public static let endSession = LocalizedStringResource("verification.refused.endSession", bundle: bundle)

        public static let failedTitle = LocalizedStringResource("verification.failed.title", bundle: bundle)
        public static let failedMessage = LocalizedStringResource("verification.failed.message", bundle: bundle)

        public static let close = LocalizedStringResource("verification.close", bundle: bundle)

        /// The title over an *incoming* request, where the neutral "Verification" used to sit.
        ///
        /// It is the closest thing this app has to an alert that somebody signed in, and for a long
        /// time it did not say so: a sheet headed "Verification" showing a device name reads as a
        /// chore the app is asking for, not as news about the account. The words underneath already
        /// said what had happened; the title was the one part still being coy about it.
        ///
        /// Only on the incoming side. Asking to have *this* device trusted is not news about
        /// anything, and it keeps the plain title.
        public static let signInTitle = LocalizedStringResource("verification.signIn.title", bundle: bundle)
    }

    /// The sign-out nobody here performed — the server stopped accepting this session, because
    /// somebody ended it from another device or the account was closed.
    ///
    /// It gets a sentence of its own rather than the generic apology, and the sentence names the
    /// likely cause. A person put back on the sign-in screen without explanation will conclude the
    /// app lost their account; telling them *what* happened is the difference between a moment of
    /// irritation and an evening of doubt about where their messages went.
    public enum Session {
        public static let endedTitle = LocalizedStringResource("session.ended.title", bundle: bundle)
        public static let endedMessage = LocalizedStringResource("session.ended.message", bundle: bundle)

        /// The launch that could not reach the server. The opposite of the two above, and the
        /// distinction is the whole point: nobody has been signed out, so this must not mention
        /// signing in. See `IskraRootView.Phase.offline`.
        public static let offlineTitle = LocalizedStringResource("session.offlineTitle", bundle: bundle)
        public static let offlineMessage = LocalizedStringResource("session.offlineMessage", bundle: bundle)
        public static let tryAgain = LocalizedStringResource("session.tryAgain", bundle: bundle)
    }

    public enum Account {
        /// The button in the top-right corner that opens settings — the user's avatar on
        /// iPhone, a gear in the sidebar on iPad and Mac. It is the same door either way,
        /// so it is named once.
        public static let settings = LocalizedStringResource("account.settings", bundle: bundle)
        public static let signOut = LocalizedStringResource("account.signOut", bundle: bundle)

        /// The field the name is typed into. It is the *placeholder*, so it has to read as
        /// an invitation rather than as a label — the row has no label, because the thing
        /// you are looking at is your own name.
        public static let namePlaceholder = LocalizedStringResource("account.namePlaceholder", bundle: bundle)
        public static let changePicture = LocalizedStringResource("account.changePicture", bundle: bundle)
        public static let removePicture = LocalizedStringResource("account.removePicture", bundle: bundle)
    }

    /// Getting your messages back: the screen between signing in and the conversations, and the
    /// strip in the chat list that will not let you forget about it.
    ///
    /// The whole vocabulary of this flow is one word — a *recovery code* — and it behaves like the
    /// backup code from an authenticator app, which is a thing people already understand. Nothing
    /// here says "verification", "cross-signing" or "secret storage", and nothing here should ever
    /// be made to: the person who has just signed in on a new phone does not want to learn what a
    /// megolm session is, they want to read yesterday's messages.
    public enum Recovery {
        public static let preparing = LocalizedStringResource("recovery.preparing", bundle: bundle)

        public static let creatingTitle = LocalizedStringResource("recovery.creating.title", bundle: bundle)
        public static let creatingMessage = LocalizedStringResource("recovery.creating.message", bundle: bundle)

        /// What is actually at stake, under the code, in the plainest words there are — and the tick
        /// that has to be made before the only button on that screen comes alive.
        ///
        /// These two replace "Skip". A modal with no way out is one people learn to dismiss without
        /// reading, which is why Skip existed; but the way out it offered was a *tap*, and a tap is a
        /// reflex. The tick is a claim, and it is the last honest moment to notice that you have not
        /// in fact written anything down. The warning is there so the claim is made against a full
        /// account of what it costs to be wrong.
        public static let saveWarning = LocalizedStringResource("recovery.save.warning", bundle: bundle)
        public static let saveConfirm = LocalizedStringResource("recovery.save.confirm", bundle: bundle)

        /// The question in front of every code this app destroys, and it is asked in exactly two
        /// places because there are exactly two ways to reach `resetRecoveryKey()`: the confirmation
        /// dialog in settings, and `Step.confirmNew` in the flow. There must never be a third.
        ///
        /// `keepOldCode` is the answer that used not to exist. After proving this device against
        /// another one, the app minted a replacement on the spot — but the comparison does not touch
        /// the secret storage, so the old code was never dead until the app killed it. A person who
        /// finds it in their password manager tonight can still use it, and now they are allowed to
        /// go and look.
        public static let keepOldCode = LocalizedStringResource("recovery.new.keepOld", bundle: bundle)

        /// The question the browser cannot answer.
        ///
        /// The server's approval page redirects nowhere the app is listening, so
        /// `ASWebAuthenticationSession` reports the same thing whether the user approved and closed
        /// it or closed it instead of approving. The app used to guess "approved", and guessed wrong
        /// for everybody who read what a reset costs and backed out — they got an error alert instead
        /// of the quiet nothing they had asked for. So it asks.
        public static let approveTitle = LocalizedStringResource("recovery.approve.title", bundle: bundle)
        public static let approveMessage = LocalizedStringResource("recovery.approve.message", bundle: bundle)
        /// The destructive answer, and it says what it does rather than "carry on": on the far side
        /// of this button every message the account ever received becomes permanently unreadable.
        /// It is painted red and worded as the act itself — a button labelled by its consequence is
        /// the one a person cannot press by mistake.
        public static let approveConfirm = LocalizedStringResource("recovery.approve.confirm", bundle: bundle)
        public static let approveCancel = LocalizedStringResource("recovery.approve.cancel", bundle: bundle)

        public static let newTitle = LocalizedStringResource("recovery.new.title", bundle: bundle)
        public static let newMessage = LocalizedStringResource("recovery.new.message", bundle: bundle)
        public static let newConfirm = LocalizedStringResource("recovery.new.confirm", bundle: bundle)

        public static let chooseTitle = LocalizedStringResource("recovery.choose.title", bundle: bundle)
        public static let chooseMessage = LocalizedStringResource("recovery.choose.message", bundle: bundle)
        public static let haveCode = LocalizedStringResource("recovery.choose.haveCode", bundle: bundle)
        public static let otherDevice = LocalizedStringResource("recovery.choose.otherDevice", bundle: bundle)
        public static let neither = LocalizedStringResource("recovery.choose.neither", bundle: bundle)

        public static let enterTitle = LocalizedStringResource("recovery.enter.title", bundle: bundle)
        public static let enterMessage = LocalizedStringResource("recovery.enter.message", bundle: bundle)
        public static let unlock = LocalizedStringResource("recovery.enter.unlock", bundle: bundle)
        public static let lostCode = LocalizedStringResource("recovery.enter.lost", bundle: bundle)

        public static let lostTitle = LocalizedStringResource("recovery.lost.title", bundle: bundle)
        public static let lostHasDevices = LocalizedStringResource("recovery.lost.hasDevices", bundle: bundle)

        /// The way past a screen that would otherwise be a locked room.
        ///
        /// `hasOtherDevices` is the account's answer, and the account does not know that the laptop
        /// was sold or that the other client will not open. Without this, somebody who had just said
        /// they had no other device could be shown a single button telling them to use one.
        public static let noAccessToOtherDevice = LocalizedStringResource("recovery.lost.noAccess", bundle: bundle)

        public static let aloneTitle = LocalizedStringResource("recovery.lost.alone.title", bundle: bundle)
        public static let aloneMessage = LocalizedStringResource("recovery.lost.alone.message", bundle: bundle)

        /// The sentence that keeps two different things apart, and it earns its place. Resetting an
        /// account password and getting the keys to old messages back are not the same act, and a
        /// person who believes they are will reset their password, find the messages still gone, and
        /// conclude the app is broken.
        public static let notPassword = LocalizedStringResource("recovery.lost.alone.notPassword", bundle: bundle)
        public static let startOver = LocalizedStringResource("recovery.lost.alone.start", bundle: bundle)

        public static let passwordTitle = LocalizedStringResource("recovery.password.title", bundle: bundle)
        public static let passwordMessage = LocalizedStringResource("recovery.password.message", bundle: bundle)
        public static let passwordPlaceholder = LocalizedStringResource("recovery.password.placeholder", bundle: bundle)
        public static let passwordConfirm = LocalizedStringResource("recovery.password.confirm", bundle: bundle)

        public static let bannerLocked = LocalizedStringResource("recovery.banner.locked", bundle: bundle)

        /// What the banner is *for*, said to a screen reader — which saw only the sentence and a
        /// chevron and had no way to know the strip was a button at all, let alone what pressing it
        /// would do. The sighted reader gets that from the chevron; everybody else got nothing.
        public static let bannerHint = LocalizedStringResource("recovery.banner.hint", bundle: bundle)

        /// The way out of the flow, for a screen reader. The control is an "×" and nothing else, and
        /// an unlabelled image in a button is announced as "button" — a control whose entire purpose
        /// is to be the way out, and which cannot say so.
        public static let close = LocalizedStringResource("recovery.close", bundle: bundle)
    }

    /// The state of this account's encryption, in words with no cryptography in them.
    ///
    /// Every string here is written to be read by somebody who does not know what a
    /// cross-signing key is and should not have to. The subject is never "the key" — it is
    /// "your messages", and what is at stake is whether they come back.
    public enum Encryption {
        public static let title = LocalizedStringResource("encryption.title", bundle: bundle)

        public static let on = LocalizedStringResource("encryption.on", bundle: bundle)
        public static let onHelp = LocalizedStringResource("encryption.onHelp", bundle: bundle)

        public static let off = LocalizedStringResource("encryption.off", bundle: bundle)
        public static let offHelp = LocalizedStringResource("encryption.offHelp", bundle: bundle)
        public static let protect = LocalizedStringResource("encryption.protect", bundle: bundle)

        /// Recovery is on for the account, and this device does not hold the key — so the
        /// history is *there* and unreadable. The distinction from `off` is the whole reason
        /// `HistoryProtection` has four cases.
        public static let keyNeeded = LocalizedStringResource("encryption.keyNeeded", bundle: bundle)
        public static let keyNeededHelp = LocalizedStringResource("encryption.keyNeededHelp", bundle: bundle)
        public static let keyPlaceholder = LocalizedStringResource("encryption.keyPlaceholder", bundle: bundle)
        public static let restore = LocalizedStringResource("encryption.restore", bundle: bundle)

        public static let newKey = LocalizedStringResource("encryption.newKey", bundle: bundle)
        public static let newKeyHelp = LocalizedStringResource("encryption.newKeyHelp", bundle: bundle)

        /// Shown once, when the key is made. There is no screen anywhere in the app that
        /// shows it again, and `saveKeyHelp` says so before the user taps Done.
        public static let saveKey = LocalizedStringResource("encryption.saveKey", bundle: bundle)
        public static let saveKeyHelp = LocalizedStringResource("encryption.saveKeyHelp", bundle: bundle)
        public static let copyKey = LocalizedStringResource("encryption.copyKey", bundle: bundle)
        public static let keyCopied = LocalizedStringResource("encryption.keyCopied", bundle: bundle)
        public static let saved = LocalizedStringResource("encryption.saved", bundle: bundle)

        public static let thisDevice = LocalizedStringResource("encryption.thisDevice", bundle: bundle)
        public static let deviceVerified = LocalizedStringResource("encryption.deviceVerified", bundle: bundle)
        public static let deviceUnverified = LocalizedStringResource("encryption.deviceUnverified", bundle: bundle)
        /// Why this screen lists one device and not all of them. The honest sentence — see
        /// `ROADMAP.md`, stage 6.
        /// What to say about the *other* devices, and there are two answers because there are two
        /// worlds. On a server that hands over an account page there is a "My devices" row to point
        /// at; on one that does not, there is no such row — and a footer that cited it anyway would
        /// send the reader hunting through settings for a section that is not there. Which is
        /// precisely what it did, until somebody went looking.
        public static let otherDevicesHere = LocalizedStringResource("encryption.otherDevicesHere", bundle: bundle)
        public static let otherDevices = LocalizedStringResource("encryption.otherDevices", bundle: bundle)
    }

    public enum Settings {
        public static let title = LocalizedStringResource("settings.title", bundle: bundle)

        /// Only ever shown in a sidebar, where the system pushes settings without giving
        /// it a way back. On iPhone the back button is the system's and is labelled — and
        /// localized — by the system, so this string never appears there.
        public static let back = LocalizedStringResource("settings.back", bundle: bundle)

        /// The one section here that exists as structure and nothing more. It is shown
        /// disabled, and `moreSoon` is what says why — a greyed-out row with no explanation
        /// reads as a bug rather than as a promise. It goes when stage 7 lands.
        public static let notifications = LocalizedStringResource("settings.notifications", bundle: bundle)
        public static let encryption = LocalizedStringResource("settings.encryption", bundle: bundle)

        /// The row that leads out of the app entirely, to the server's own page — because there is
        /// no native list of devices to lead to instead. The FFI does not export one, and on a
        /// server running the authentication service the endpoint that would delete a device is
        /// gone rather than merely guarded. A link to the page that *can* do it is the honest
        /// answer; a screen that listed nothing would be a dishonest one.
        public static let devices = LocalizedStringResource("settings.devices", bundle: bundle)
        public static let devicesHelp = LocalizedStringResource("settings.devicesHelp", bundle: bundle)

        public static let appearance = LocalizedStringResource("settings.appearance", bundle: bundle)
        /// Where the emoji a double tap sends is chosen — see `QuickReaction`.
        public static let reactions = LocalizedStringResource("settings.reactions", bundle: bundle)
        public static let storage = LocalizedStringResource("settings.storage", bundle: bundle)
        public static let moreSoon = LocalizedStringResource("settings.moreSoon", bundle: bundle)

        /// The app's own name, at the foot of the screen. Not the bundle's display name and
        /// not translated: it is what the app is called, in both languages, and it is here so
        /// that somebody reporting a bug can say which app they mean.
        public static let appName = LocalizedStringResource("settings.appName", bundle: bundle)

        /// And which build of it they are holding. Two numbers, because either alone is
        /// useless: the version says what the app is, the build says which of the many
        /// attempts at that version this one is.
        public static func version(_ version: String, build: String) -> LocalizedStringResource {
            LocalizedStringResource("settings.version",
                                    defaultValue: "Version \(version) (\(build))",
                                    bundle: bundle)
        }
    }

    /// What the app is keeping on the device, and the one part of it the user can throw away.
    ///
    /// Each kind is a name *and* a sentence, because the names alone do not answer the question
    /// somebody opens this screen with: which of these can I lose, and what does losing it cost?
    /// A row that says "Cache — 412 MB" and nothing else invites the wrong press.
    public enum Storage {
        public static let title = LocalizedStringResource("storage.title", bundle: bundle)
        public static let total = LocalizedStringResource("storage.total", bundle: bundle)
        public static let measuring = LocalizedStringResource("storage.measuring", bundle: bundle)

        public static let session = LocalizedStringResource("storage.session", bundle: bundle)
        public static let sessionExplained = LocalizedStringResource("storage.session.explained", bundle: bundle)
        public static let cache = LocalizedStringResource("storage.cache", bundle: bundle)
        public static let cacheExplained = LocalizedStringResource("storage.cache.explained", bundle: bundle)
        public static let search = LocalizedStringResource("storage.search", bundle: bundle)
        public static let searchExplained = LocalizedStringResource("storage.search.explained", bundle: bundle)

        public static let clear = LocalizedStringResource("storage.clear", bundle: bundle)
        public static let clearing = LocalizedStringResource("storage.clearing", bundle: bundle)
        public static let confirmTitle = LocalizedStringResource("storage.confirm.title", bundle: bundle)
        public static let confirmBody = LocalizedStringResource("storage.confirm.body", bundle: bundle)
        public static let confirmAction = LocalizedStringResource("storage.confirm.action", bundle: bundle)
        public static let cancel = LocalizedStringResource("storage.cancel", bundle: bundle)
        public static let failed = LocalizedStringResource("storage.failed", bundle: bundle)

        /// The button that clears the index and nothing else. It carries no footer: the row above
        /// already says what the index is, and the confirmation dialog says what clearing it costs,
        /// so a standing sentence under the button only repeated one of them.
        public static let clearSearch = LocalizedStringResource("storage.search.clear", bundle: bundle)
        public static let clearSearchTitle = LocalizedStringResource("storage.search.confirm.title", bundle: bundle)
        public static let clearSearchBody = LocalizedStringResource("storage.search.confirm.body", bundle: bundle)
        public static let clearSearchFailed = LocalizedStringResource("storage.search.failed", bundle: bundle)
    }

    /// Choosing what a double tap on a message leaves behind.
    public enum Reactions {
        public static let quick = LocalizedStringResource("reactions.quick", bundle: bundle)
        /// Names the *gesture*, not the setting: an emoji nobody knows how to send is a
        /// preference about nothing.
        public static let quickHelp = LocalizedStringResource("reactions.quickHelp", bundle: bundle)
    }

    /// Choosing what the app is painted in.
    public enum Appearance {
        public static let theme = LocalizedStringResource("appearance.theme", bundle: bundle)
        public static let themeHelp = LocalizedStringResource("appearance.themeHelp", bundle: bundle)

        /// Light, dark, or the system's own. A `switch` with no `default`, for the same reason
        /// the colours below have none: a fourth mode should stop the build, not ship unnamed.
        public static func mode(_ mode: AppearanceMode) -> LocalizedStringResource {
            switch mode {
            case .system: LocalizedStringResource("appearance.mode.system", bundle: bundle)
            case .light: LocalizedStringResource("appearance.mode.light", bundle: bundle)
            case .dark: LocalizedStringResource("appearance.mode.dark", bundle: bundle)
            }
        }

        public static let accent = LocalizedStringResource("appearance.accent", bundle: bundle)
        public static let accentHelp = LocalizedStringResource("appearance.accentHelp", bundle: bundle)

        /// The switch that washes the accent across the whole interface — see
        /// `AccentTheme.tintsInterfaceKey`. `tintInterfaceMono` is the footer it gets when the accent
        /// is the mono one and there is no colour to spread.
        public static let tintInterface = LocalizedStringResource("appearance.tintInterface", bundle: bundle)
        public static let tintInterfaceHelp = LocalizedStringResource("appearance.tintInterfaceHelp", bundle: bundle)
        public static let tintInterfaceMono = LocalizedStringResource("appearance.tintInterfaceMono", bundle: bundle)

        /// Three lines of a conversation that never happened, so that a colour can be judged as
        /// what it will actually be — the fill behind everything the user ever says — rather than
        /// as a circle on a settings screen. The middle one is theirs, and is the one painted.
        public static let previewAsk = LocalizedStringResource("appearance.previewAsk", bundle: bundle)
        public static let previewAnswer = LocalizedStringResource("appearance.previewAnswer", bundle: bundle)
        public static let previewReply = LocalizedStringResource("appearance.previewReply", bundle: bundle)

        /// What the whole little exchange is called, for VoiceOver, which should hear one thing
        /// and not be walked through an invented conversation on its way to the colours.
        public static let previewLabel = LocalizedStringResource("appearance.previewLabel", bundle: bundle)

        /// The name of a colour, which is the only thing a swatch can be read out as: a
        /// circle of colour has nothing for VoiceOver to say, and "button" is not an answer.
        ///
        /// A `switch` with no `default`, deliberately. An eighth colour added to
        /// `AccentTheme` should stop the build here, rather than ship as a swatch nobody
        /// can name.
        public static func color(_ theme: AccentTheme) -> LocalizedStringResource {
            switch theme {
            case .red: LocalizedStringResource("appearance.color.red", bundle: bundle)
            case .orange: LocalizedStringResource("appearance.color.orange", bundle: bundle)
            case .yellow: LocalizedStringResource("appearance.color.yellow", bundle: bundle)
            case .green: LocalizedStringResource("appearance.color.green", bundle: bundle)
            case .cyan: LocalizedStringResource("appearance.color.cyan", bundle: bundle)
            case .blue: LocalizedStringResource("appearance.color.blue", bundle: bundle)
            case .violet: LocalizedStringResource("appearance.color.violet", bundle: bundle)
            case .mono: LocalizedStringResource("appearance.color.mono", bundle: bundle)
            }
        }
    }
}

extension String {
    /// Resolves a feature string for the current locale.
    init(app resource: LocalizedStringResource) {
        self.init(localized: resource)
    }
}
