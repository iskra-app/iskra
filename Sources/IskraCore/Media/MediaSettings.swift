import Foundation

/// How hard a photo or a video is squeezed before it is sent.
///
/// Three steps and not a slider: what a person is choosing between is "the chat loads fast on a
/// bad network", "fine for anything you would look at on a phone" and "nearly the original", and
/// each step is a pair of numbers — one for pictures, one for video — that only make sense
/// together. A slider would be a thousand positions nobody could tell apart.
public enum MediaCompression: String, CaseIterable, Identifiable, Sendable {
    case strong
    case balanced
    case light

    public var id: String { rawValue }

    /// The longest side a photo is sent at, in pixels. Never enlarged: a photo already smaller
    /// than this keeps its size.
    public var maxPhotoSide: Int {
        switch self {
        case .strong: 1280
        case .balanced: 2048
        case .light: 4096
        }
    }

    /// JPEG quality for a compressed photo.
    var photoQuality: Double {
        switch self {
        case .strong: 0.6
        case .balanced: 0.75
        case .light: 0.85
        }
    }

    /// The box a compressed video is fitted into, as its long side and its short side — so a
    /// portrait clip gets the same number of pixels as a landscape one. Never enlarged.
    ///
    /// Every step is H.264 and AAC in an MP4, because that is what plays in every Matrix client
    /// there is, on the web included. HEVC would be smaller, and a grey rectangle in half of them.
    var videoBox: (long: Int, short: Int) {
        switch self {
        case .strong: (960, 540)
        case .balanced: (1280, 720)
        case .light: (1920, 1080)
        }
    }

    /// Bits per second of picture. A ceiling, not a target: a clip that already spends less keeps
    /// its own rate, because re-encoding it at more would only make it bigger.
    ///
    /// Explicit, and the reason `VideoTranscoder` exists at all: the export presets have no rate
    /// setting, and one whose size a clip already fits *passes the clip through untouched* — an
    /// 8 Mbit/s screen recording at 1280 x 808 came out of the 720p preset at 8 Mbit/s.
    var videoBitRate: Int {
        switch self {
        case .strong: 1_200_000
        case .balanced: 2_500_000
        case .light: 5_000_000
        }
    }

    var audioBitRate: Int {
        switch self {
        case .strong: 64_000
        case .balanced: 96_000
        case .light: 128_000
        }
    }

    /// Frames per second, at most. Sixty only at the lightest step: everywhere else half of them
    /// are bits nobody watching a chat can see.
    var maxFrameRate: Int {
        switch self {
        case .strong, .balanced: 30
        case .light: 60
        }
    }
}

/// What happens to a photo or a video on its way out: whether it loses its metadata, and whether
/// — and how hard — it is compressed.
///
/// Read at the moment of sending, from `UserDefaults.standard`, where the settings screen writes it
/// through `@AppStorage` with the same keys and the same defaults spelled out here — a default that
/// disagrees with itself between the switch and the code that obeys it is a switch drawn in the
/// wrong position. Everything that sends media runs in the app's process (the Share extension only
/// leaves things in the outbox), so `.standard` is the right store.
///
/// A video note does not ask: see `videoNote`.
public struct MediaSettings: Sendable, Equatable {
    public var stripsMetadata: Bool
    public var compresses: Bool
    public var compression: MediaCompression

    public init(stripsMetadata: Bool, compresses: Bool, compression: MediaCompression) {
        self.stripsMetadata = stripsMetadata
        self.compresses = compresses
        self.compression = compression
    }

    public static let stripsMetadataKey = "media.stripsMetadata"
    public static let compressesKey = "media.compresses"
    public static let compressionKey = "media.compression"

    /// On. Where a photo was taken is not something anybody decides to send by sending a photo.
    public static let stripsMetadataByDefault = true

    /// On, at the middle step: the full twelve megapixels of a phone photo are several megabytes
    /// that nobody looking at it on a phone can see, paid for by the sender's upload and every
    /// receiver's download.
    public static let compressesByDefault = true
    public static let compressionByDefault = MediaCompression.balanced

    /// What the settings screen says right now.
    public static func current(_ defaults: UserDefaults = .standard) -> MediaSettings {
        MediaSettings(
            stripsMetadata: defaults.object(forKey: stripsMetadataKey) as? Bool ?? stripsMetadataByDefault,
            compresses: defaults.object(forKey: compressesKey) as? Bool ?? compressesByDefault,
            compression: defaults.string(forKey: compressionKey).flatMap(MediaCompression.init) ?? compressionByDefault
        )
    }

    /// A video note, whatever the settings say: always without metadata, and never compressed
    /// *here* — because it already has been. `SquareVideoExporter` re-encodes every note to a
    /// 480-point square at the rate `VideoNote` works out for it, and squeezing that a second time
    /// would only cost quality. A note is a face in a circle; nobody chooses to send it big.
    public static let videoNote = MediaSettings(stripsMetadata: true, compresses: false,
                                                compression: compressionByDefault)

    /// Every key, for `AppSettings.forget`.
    public static let keys = [stripsMetadataKey, compressesKey, compressionKey]
}
