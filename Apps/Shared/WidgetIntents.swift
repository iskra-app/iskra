import AppIntents
import IskraCore

// The widget's two intents. Compiled into the app *and* the widget extension, for the same reason as
// `ChatEntity`: the system matches an intent across the two bundles by its type, and it is the app's
// copy that `perform` runs in.

/// What a favourites widget is set up with: the chats to show, in order. Nothing chosen means the
/// pinned chats and then the top of the list — see `WidgetChats.fill`.
struct SelectChatsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Choose Chats" }

    @Parameter(title: "Chats") var chats: [ChatEntity]?

    init() {}
}

#if os(iOS)
/// "Stop" on the live location activity. It is drawn in the widget extension and runs here, in the
/// app — which is awake for as long as a share is, and is the only process with a session to stop
/// it with. Ending the share is what ends the activity (`LiveLocationActivity`).
struct StopLiveLocationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Sharing Location" }
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LiveLocationSharer.stopEverywhere()
        return .result()
    }
}
#endif
