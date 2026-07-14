import SwiftUI
import UniformTypeIdentifiers

/// Putting text on the pasteboard, which is two different APIs wearing the same hat.
///
/// One `#if os` in the app rather than one per screen that copies something. There were two
/// — the message menu and the recovery key — written in opposite branch order, which is how
/// these things start.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The same act for something that must not be treated the same way.
    ///
    /// `UIPasteboard.general.string = key` is what the recovery key used to go out by, and the
    /// general pasteboard is the most public place in the system: it syncs to every other device on
    /// the Apple ID through Universal Clipboard, any app can read it the moment it comes to the
    /// front, and it stays there indefinitely. `Account.swift` says, correctly, that the recovery
    /// key "is never written anywhere" — and then it was written to *that*.
    ///
    /// A recovery key is the password to the entire history of the account. It is copied because it
    /// belongs in a password manager, and it should reach one and go no further:
    ///
    /// - **`localOnly`** keeps it off the user's other devices. Handing the key to the laptop it
    ///   exists to protect the phone against is not a feature.
    /// - **`expirationDate`** takes it back out again. A key that is still on the clipboard an hour
    ///   later is a key sitting in whatever app the user opens next.
    /// - On the Mac, **`org.nspasteboard.ConcealedType`** is the convention clipboard managers
    ///   honour to mean "do not keep a history of this". It is what password managers mark their
    ///   own copies with, and it is the difference between a key that disappears and a key that
    ///   ends up in a searchable log of everything the user has ever copied.
    static func copySecret(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Not a system-defined type — a convention, and the one the clipboard managers people
        // actually run have agreed on. Marking it costs nothing and is the only thing standing
        // between a recovery key and a searchable history of it.
        NSPasteboard.general.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        #else
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true,
                      .expirationDate: Date().addingTimeInterval(secretLifetime)]
        )
        #endif
    }

    /// Long enough to reach a password manager, short enough that a key forgotten on the clipboard
    /// is not a key left there.
    private static let secretLifetime: TimeInterval = 90
}
