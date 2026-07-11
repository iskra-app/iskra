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

    public enum Timeline {
        public static let sendFailed = LocalizedStringResource("timeline.sendFailed", bundle: bundle)
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
