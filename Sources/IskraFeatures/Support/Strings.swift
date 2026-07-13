import Foundation
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
        public static let signIn = LocalizedStringResource("signIn.signIn", bundle: bundle)
        public static let or = LocalizedStringResource("signIn.or", bundle: bundle)
        public static let username = LocalizedStringResource("signIn.username", bundle: bundle)
        public static let password = LocalizedStringResource("signIn.password", bundle: bundle)
        public static let signInWithPassword = LocalizedStringResource("signIn.signInWithPassword", bundle: bundle)
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

    public enum RoomList {
        public static let title = LocalizedStringResource("roomList.title", bundle: bundle)
        public static let searchPrompt = LocalizedStringResource("roomList.searchPrompt", bundle: bundle)
        public static let clearSearch = LocalizedStringResource("roomList.clearSearch", bundle: bundle)
        public static let loading = LocalizedStringResource("roomList.loading", bundle: bundle)
        public static let emptyTitle = LocalizedStringResource("roomList.emptyTitle", bundle: bundle)
        public static let emptyMessage = LocalizedStringResource("roomList.emptyMessage", bundle: bundle)
        public static let privateChat = LocalizedStringResource("roomList.privateChat", bundle: bundle)

        /// The "+" in the top-left corner, and the two things it can start.
        public static let newConversation = LocalizedStringResource("roomList.newConversation", bundle: bundle)
        public static let newChat = LocalizedStringResource("roomList.newChat", bundle: bundle)
        public static let newRoom = LocalizedStringResource("roomList.newRoom", bundle: bundle)

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
        public static let composerPlaceholder = LocalizedStringResource("room.composerPlaceholder", bundle: bundle)
        public static let send = LocalizedStringResource("room.send", bundle: bundle)
        public static let attach = LocalizedStringResource("room.attach", bundle: bundle)
        public static let attachPhoto = LocalizedStringResource("room.attachPhoto", bundle: bundle)
        public static let attachFile = LocalizedStringResource("room.attachFile", bundle: bundle)
        public static let sendFailedTitle = LocalizedStringResource("room.sendFailedTitle", bundle: bundle)

        /// The picture was chosen and then could not be read — which is a failure *before*
        /// anything was sent, and must not be reported as the server refusing it.
        public static let attachmentUnreadable = LocalizedStringResource("room.attachmentUnreadable", bundle: bundle)
        public static let ok = LocalizedStringResource("room.ok", bundle: bundle)
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
            public static let sentVideo = LocalizedStringResource("message.spoken.sentVideo", bundle: bundle)
            public static let sentVideoNote = LocalizedStringResource("message.spoken.sentVideoNote", bundle: bundle)
            public static let sentVoice = LocalizedStringResource("message.spoken.sentVoice", bundle: bundle)
            public static let sentAudio = LocalizedStringResource("message.spoken.sentAudio", bundle: bundle)
            public static let sentFile = LocalizedStringResource("message.spoken.sentFile", bundle: bundle)
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
        /// The button on the preview. Only ever shown where there is a second camera to
        /// turn to — see `VideoNoteRecorder.canFlip`.
        public static let flipCamera = LocalizedStringResource("videoNote.flipCamera", bundle: bundle)
    }

    public enum Account {
        /// The button in the top-right corner that opens settings — the user's avatar on
        /// iPhone, a gear in the sidebar on iPad and Mac. It is the same door either way,
        /// so it is named once.
        public static let settings = LocalizedStringResource("account.settings", bundle: bundle)
        public static let signOut = LocalizedStringResource("account.signOut", bundle: bundle)
    }

    public enum Settings {
        public static let title = LocalizedStringResource("settings.title", bundle: bundle)

        /// Only ever shown in a sidebar, where the system pushes settings without giving
        /// it a way back. On iPhone the back button is the system's and is labelled — and
        /// localized — by the system, so this string never appears there.
        public static let back = LocalizedStringResource("settings.back", bundle: bundle)

        /// Sections that exist as structure but have nothing behind them yet. They are
        /// shown disabled, and `moreSoon` is what says why — a greyed-out row with no
        /// explanation reads as a bug rather than as a promise.
        public static let notifications = LocalizedStringResource("settings.notifications", bundle: bundle)
        public static let privacy = LocalizedStringResource("settings.privacy", bundle: bundle)
        public static let appearance = LocalizedStringResource("settings.appearance", bundle: bundle)
        /// Where the emoji a double tap sends is chosen — see `QuickReaction`.
        public static let reactions = LocalizedStringResource("settings.reactions", bundle: bundle)
        public static let moreSoon = LocalizedStringResource("settings.moreSoon", bundle: bundle)
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
        public static let accent = LocalizedStringResource("appearance.accent", bundle: bundle)
        public static let accentHelp = LocalizedStringResource("appearance.accentHelp", bundle: bundle)

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
