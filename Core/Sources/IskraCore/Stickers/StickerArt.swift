import Foundation

/// The stickers the app comes with — "Искорки": the pink spark with burgundy eyes, twelve moods.
///
/// Shipped as PNGs in `Resources/Stickers` (512 on a side, transparent, nothing in them but the
/// picture), drawn by hand rather than in code. The same pictures stand in the demo's packs
/// (`MockWorld`), so the demo and a real account show one set of faces.
///
/// A sticker on a server is an `mxc://` URL, and these have none until somebody needs them:
/// `StickerLibrary` uploads each once per account and remembers where, in account data. A
/// change to a picture is a change of what everybody already has — bump `version`, and every
/// account uploads the set again on the next opening of the sheet.
enum StickerArt: String, CaseIterable, Sendable {
    case hello, joy, love, curious, surprise, sleepy, sad, grumpy, loading, unlocked, bypass, connected

    /// Which set of pictures this is. Stored next to the uploaded set, and a set made by an older
    /// one is uploaded again. 1 was the faces drawn in Core Graphics.
    static let version = 2

    /// The words that stand in for the picture — the event's `body`, what VoiceOver reads.
    var emoji: String {
        switch self {
        case .hello: "👋"
        case .joy: "🎉"
        case .love: "❤️"
        case .curious: "🤔"
        case .surprise: "😮"
        case .sleepy: "😴"
        case .sad: "😢"
        case .grumpy: "😒"
        case .loading: "⏳"
        case .unlocked: "🔓"
        case .bypass: "🏃"
        case .connected: "📶"
        }
    }

    /// The side every sticker is made at. 512 is what Telegram and Element both make stickers
    /// at, so it is crisp at any size the timeline draws one.
    static let side = 512

    /// The sticker as a PNG: a shape on *nothing*. The transparency is what makes it a sticker
    /// and not a photograph. Empty only if the bundle is missing its resource, which
    /// `StickerDefaultsTests` holds against.
    func png() -> Data {
        guard let url = Bundle.module.url(forResource: "sticker-\(rawValue)", withExtension: "png",
                                          subdirectory: "Stickers")
                ?? Bundle.module.url(forResource: "sticker-\(rawValue)", withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }
}
