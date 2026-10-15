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
    /// The account's own pack, "Мои стикеры", in the sheet.
    public static let showsMineKey = "stickers.showsMine"

    public static let keys = [showsBuiltInKey, showsRoomPackKey, showsMineKey]

    public static func showsBuiltIn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsBuiltInKey) as? Bool ?? true
    }

    public static func showsRoomPack(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsRoomPackKey) as? Bool ?? true
    }

    public static func showsMine(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsMineKey) as? Bool ?? true
    }

    /// Whether the sheet would show anything at all. With every source turned off the button that
    /// opens it is not drawn — a button onto an empty sheet is a button that does nothing.
    public static func showsAnything(_ defaults: UserDefaults = .standard) -> Bool {
        showsBuiltIn(defaults) || showsRoomPack(defaults) || showsMine(defaults)
    }
}
