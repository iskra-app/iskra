import OSLog

/// The app's own log, which is a different thing from the SDK's (`SDKLogging`).
///
/// It exists for one reason: a signed build on a phone has no debugger attached, so an
/// error that is caught, turned into a sentence and shown to the user leaves nothing
/// behind. The sentence is what the user needs; this is what the next hour of debugging
/// needs.
///
/// Nothing here may carry message content, a token, a filename the user chose, or an
/// OAuth callback — the same rule the SDK's log level is capped for. Errors and states,
/// which is what `.public` is safe to mark. If a value cannot be shown to a stranger
/// reading the device console, it does not go in the log.
public enum Log {
    private static let subsystem = "moscow.swag.iskra"

    /// Sending pictures, video, files and voice: the one path whose failures come back from
    /// a server as a shrug. Public because the screen is where the picker lives, and the
    /// picker is where half of these failures happen.
    public static let media = Logger(subsystem: subsystem, category: "media")

    /// Changing a room: its name, its picture, who is in it and what they may do. Every one
    /// of these is a request the homeserver is entitled to refuse on grounds it does not
    /// explain, and the user is told only that it was refused — this is where the refusal
    /// itself is kept.
    public static let rooms = Logger(subsystem: subsystem, category: "rooms")
}
