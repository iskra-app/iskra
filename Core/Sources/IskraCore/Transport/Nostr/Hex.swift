import Foundation

/// Hex, because everything in nostr is written in it: keys, event ids, signatures.
///
/// Lowercase on the way out, and strict on the way in — an odd number of digits or a stray
/// character is `nil` rather than a best effort. What arrives here is usually something a person
/// pasted into a settings field, and a key read as half a key is a bridge that is never reached,
/// with nothing on screen to say why.
enum Hex {
    static func string(_ bytes: some Sequence<UInt8>) -> String {
        var out = ""
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    static func data(_ string: String) -> Data? {
        let characters = Array(string.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = value(of: characters[index]), let low = value(of: characters[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static let digits = Array("0123456789abcdef")

    private static func value(of character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
