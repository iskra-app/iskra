import Foundation
import MatrixRustSDK

/// Round video messages — the thing Telegram calls a "circle".
///
/// ## Why these are recognised by shape rather than by a flag
///
/// Matrix has no round-video event type, and no MSC proposes one. The obvious move
/// would be to send `m.video` with a custom field like `app.iskra.video_note: true`
/// and read it back. We deliberately do not, and the reason is worth keeping:
///
/// Setting a custom field means building the event by hand, which means calling
/// `Client.uploadMedia` and `Room.sendRaw` instead of `Timeline.sendVideo`. But
/// `uploadMedia` returns a plain `mxc://` URI — it does *not* encrypt the file. In
/// an encrypted room the SDK's `sendVideo` performs attachment encryption (AES-CTR,
/// with the key travelling inside the encrypted event); `uploadMedia` + `sendRaw`
/// would upload the user's face to the homeserver in the clear. Reimplementing
/// attachment encryption to work around that is exactly the kind of hand-rolled
/// crypto that has no place in this app.
///
/// So we send a perfectly ordinary `m.video` through the SDK, which encrypts it
/// properly, and we make it *recognisably* a video note: exactly square, and at most
/// 60 seconds. On receipt we detect those two properties.
///
/// The trade-off, stated plainly: a square clip under a minute sent by another
/// client will render as a circle here, and our circles render as ordinary square
/// videos in Element and other clients. Both are cosmetic. Neither leaks anything.
public enum VideoNote {
    /// The cap the recorder enforces and the detector trusts.
    public static let maximumDuration: TimeInterval = 60

    /// Video notes are recorded square so they can be masked to a circle without
    /// cropping surprises.
    public static let captureDimension = 480

    static func isVideoNote(_ content: VideoMessageContent) -> Bool {
        guard let info = content.info,
              let width = info.width,
              let height = info.height,
              let duration = info.duration
        else { return false }

        return width == height && width > 0 && duration <= maximumDuration
    }
}
