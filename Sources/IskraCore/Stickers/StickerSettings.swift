import Foundation

/// Which packs the sticker sheet offers besides the account's own — Settings → Stickers.
///
/// On the device, not in the account: they are about how much this sheet shows on this screen,
/// and the packs themselves — which are the account's — are untouched by either.
public enum StickerSettings {
    /// "Искорки", the app's own pack (`StickerArt`). On unless somebody turned it off.
    public static let showsBuiltInKey = "stickers.showsBuiltIn"

    /// The open chat's own pack, offered while you are in it without subscribing to it. On unless
    /// somebody turned it off.
    public static let showsRoomPackKey = "stickers.showsRoomPack"

    /// Every key, for `AppSettings.forget`.
    public static let keys = [showsBuiltInKey, showsRoomPackKey]

    public static func showsBuiltIn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsBuiltInKey) as? Bool ?? true
    }

    public static func showsRoomPack(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsRoomPackKey) as? Bool ?? true
    }
}
