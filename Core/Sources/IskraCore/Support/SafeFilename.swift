import Foundation

/// A name somebody else chose, made safe to put on the disk.
///
/// Two places took one as given and paid for it. The Share extension used the name the *sharing
/// app* suggested, and the app later resolved it with `appending(path:)` — which understands
/// `..` — and deleted the folder it landed in: `../../x` was the App Group's root, every account's
/// store with it. And on the Mac, a received file is opened from a copy named the way its
/// **sender** named it: `../../Library/Preferences/…` was a file the other side of a chat got to
/// overwrite with one click.
///
/// What is kept is the last path component, without the characters a path is made of and without
/// the two names that mean "here" and "up". What the name is *for* survives — the extension, the
/// words someone recognises it by.
public enum SafeFilename {
    public static func make(_ raw: String, fallback: String) -> String {
        let last = (raw as NSString).lastPathComponent
        let cleaned = String(last.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) {
                return "-"
            }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading dots go: they are how `.` and `..` are spelled, and a hidden file is not
        // something another app or another person gets to leave for us.
        let visible = String(cleaned.drop(while: { $0 == "." }))
        return visible.isEmpty ? fallback : visible
    }

    /// Whether this is already a name `make` would leave alone.
    public static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && make(name, fallback: "") == name
    }
}
