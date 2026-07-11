import Foundation

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
        public static let loading = LocalizedStringResource("roomList.loading", bundle: bundle)
        public static let emptyTitle = LocalizedStringResource("roomList.emptyTitle", bundle: bundle)
        public static let emptyMessage = LocalizedStringResource("roomList.emptyMessage", bundle: bundle)
        public static let privateChat = LocalizedStringResource("roomList.privateChat", bundle: bundle)

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
        public static let ok = LocalizedStringResource("room.ok", bundle: bundle)
        public static let noRoomSelectedTitle = LocalizedStringResource("room.noRoomSelectedTitle", bundle: bundle)
        public static let noRoomSelectedMessage = LocalizedStringResource("room.noRoomSelectedMessage", bundle: bundle)
    }

    public enum Message {
        public static let unreadable = LocalizedStringResource("message.unreadable", bundle: bundle)
        public static let deleted = LocalizedStringResource("message.deleted", bundle: bundle)
        public static let unsupported = LocalizedStringResource("message.unsupported", bundle: bundle)

        public enum Delivery {
            public static let sending = LocalizedStringResource("message.delivery.sending", bundle: bundle)
            public static let sent = LocalizedStringResource("message.delivery.sent", bundle: bundle)
            public static let read = LocalizedStringResource("message.delivery.read", bundle: bundle)
            public static let failed = LocalizedStringResource("message.delivery.failed", bundle: bundle)
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

    public enum Account {
        public static let menu = LocalizedStringResource("account.menu", bundle: bundle)
        public static let signOut = LocalizedStringResource("account.signOut", bundle: bundle)
    }
}

extension String {
    /// Resolves a feature string for the current locale.
    init(app resource: LocalizedStringResource) {
        self.init(localized: resource)
    }
}
