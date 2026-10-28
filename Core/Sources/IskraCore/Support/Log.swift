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
    private static let subsystem = "wtf.iskra"

    /// Sending pictures, video, files and voice: the one path whose failures come back from
    /// a server as a shrug. Public because the screen is where the picker lives, and the
    /// picker is where half of these failures happen.
    public static let media = Logger(subsystem: subsystem, category: "media")

    /// Changing a room: its name, its picture, who is in it and what they may do. Every one
    /// of these is a request the homeserver is entitled to refuse on grounds it does not
    /// explain, and the user is told only that it was refused — this is where the refusal
    /// itself is kept.
    public static let rooms = Logger(subsystem: subsystem, category: "rooms")

    /// The account itself: the name and face the user shows the world, and the state of
    /// this session's encryption. The rule above matters most here — a recovery key is a
    /// password, and the errors around one are logged without it.
    public static let session = Logger(subsystem: subsystem, category: "session")

    /// Decrypting a push, which happens in the notification extension — a different process,
    /// with no UI, no debugger and about thirty seconds to live. Nothing it does is visible
    /// anywhere else, and when it fails the only symptom the user gets is a notification that
    /// says "New message" forever. This log is the sole witness.
    ///
    /// It is also the log most in danger of breaking the rule above: the thing this code is
    /// holding *is* a decrypted message. The body never goes in — only which step failed.
    public static let push = Logger(subsystem: subsystem, category: "push")

    /// Calls: finding out whether the server can carry one, building the widget, and the driver
    /// that pumps messages between the SDK and the page the call is drawn on.
    ///
    /// The rule above bites here in its own way. A widget URL is not a secret the way a token is,
    /// but it carries the room ID and the user ID in its query, so it is written down only by
    /// `--probe-call`, never by this log. What goes here is which step refused: the server, the
    /// well-known, the driver.
    public static let calls = Logger(subsystem: subsystem, category: "calls")

    /// What may be written down about a failure.
    ///
    /// Every error in this app used to reach the log as `String(describing: error)`, and that was
    /// two different mistakes wearing one spelling.
    ///
    /// Where it was marked `.public`, it *leaks*. An `NSError` from Foundation, Photos or QuickLook
    /// carries a `userInfo` dictionary, and `NSFilePath` is very often in it — so a failure to open
    /// an attachment wrote the name of the user's file into the system log, and the user's file is
    /// called `паспорт_скан.pdf`. The SDK's own errors are no safer: `ClientError.generic` carries
    /// a message and a details string that come from the homeserver's response.
    ///
    /// Where it was *not* marked `.public`, `os.Logger` redacted the whole thing to `<private>` —
    /// which means the log that exists precisely because a signed build on a phone has no debugger
    /// attached said nothing at all on a phone.
    ///
    /// So: the kind of the failure, and nothing it is carrying. For a Swift error — which is what
    /// the SDK's are, and ours — that is the type and the case, with the payload left behind:
    /// `ClientError.generic`, not the server's sentence. For anything that is really an `NSError`,
    /// the domain and the code and *not* the `userInfo`: `NSCocoaErrorDomain #260`, which is
    /// "no such file" and gives away no file. Both are the answer to "which step failed", which is
    /// the whole reason the line was ever written.
    ///
    /// It is safe to mark `.public` at every call site, and it is meant to be — an error nobody can
    /// read is not a log entry, it is a decoration.
    public static func describe(_ error: some Error) -> String {
        let mirror = Mirror(reflecting: error)

        if mirror.displayStyle == .enum {
            // A case with a payload reflects as one child, labelled with the case name. The payload
            // itself is exactly what must not be printed, so only the label is taken.
            if let caseName = mirror.children.first?.label {
                return "\(type(of: error)).\(caseName)"
            }

            // A case with nothing in it has nothing to leak, and its own description *is* the name.
            return "\(type(of: error)).\(error)"
        }

        let asNSError = error as NSError
        return "\(asNSError.domain) #\(asNSError.code)"
    }
}
