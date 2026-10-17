import AppIntents
import IskraCore

// Siri, Shortcuts and Spotlight, from the app itself — no separate extension, because these intents
// only need the shared chat directory the app keeps in the App Group, not a session of their own.
//
// The "which chat" a phrase or a shortcut refers to is a `ChatEntity`, resolved from that directory
// so the picker in Shortcuts fills without waking a client. Opening a chat hands the room to the app
// it launches; sending a message drops it in the outbox the app flushes when it comes up — which is
// why both open the app rather than reaching the network from here.
//
// The words here are keys, not English: an intent's title and parameters are looked up in the *app*
// bundle's `Localizable.strings`, and Siri's phrases in its `AppShortcuts.strings` — both in
// `Apps/Shared/<lang>.lproj`, not in IskraFeatures, because that is where the system looks. It is
// the one place in the app where the words are not a `Strings` lookup, and the only reason.

// `ChatEntity`, `ChatQuery` and `OpenChatIntent` are in `ChatEntity.swift`, which the widget
// extension compiles too — see there.

/// Send a message to a chat. Drops it in the outbox and opens the app, which flushes it into the
/// room's send queue — so the message leaves even though the intent itself never touched the network.
struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource { "Send Message" }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Chat") var chat: ChatEntity
    @Parameter(title: "Message") var message: String

    func perform() async throws -> some IntentResult {
        ChatDirectory.enqueue(.init(roomID: chat.roomID, text: message, accountID: chat.accountID))
        // Open the chat too, so the sender can see it land.
        ChatDirectory.requestOpen(roomID: chat.roomID, accountID: chat.accountID)
        return .result()
    }
}

/// The phrases Siri listens for, and the ready-made shortcuts.
struct IskraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenChatIntent(),
                    phrases: ["Open a chat in \(.applicationName)"],
                    shortTitle: "Open Chat",
                    systemImageName: "bubble.left")
        AppShortcut(intent: SendMessageIntent(),
                    phrases: ["Send a message with \(.applicationName)"],
                    shortTitle: "Send Message",
                    systemImageName: "paperplane")
    }
}
