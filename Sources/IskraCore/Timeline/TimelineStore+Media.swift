import Foundation
import MatrixRustSDK

public extension TimelineStore {
    /// Sends a photo, as bytes rather than as a path.
    ///
    /// The picker hands back the picture in memory, and it used to be written to a file in
    /// the temporary directory purely so that the SDK could be given a path to it — a file
    /// that then had to be deleted again, because in an encrypted room it is the user's
    /// photograph sitting in the clear on disk. Two failures nobody could see lived in that
    /// round trip: the write could fail, and the file could be swept out from under an
    /// upload that had not finished reading it.
    ///
    /// `UploadSource.data` removes the round trip. The bytes cross to Rust in the call, the
    /// plaintext never touches the disk, and there is no file whose lifetime has to be
    /// guessed at.
    ///
    /// `replyingTo` threads it onto a message, exactly as text does — `UploadParameters` has
    /// carried an `inReplyTo` all along and every send in this file passed nil for it.
    func send(photo data: Data, filename: String, replyingTo replyID: String? = nil) async {
        guard let timeline = liveTimeline else {
            Log.media.error("photo dropped: the room has no live timeline")
            failure = .send
            return
        }

        let info = MediaMetadata.image(data: data, filename: filename)
        let parameters = UploadParameters(source: .data(bytes: data, filename: filename),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: replyID.flatMap { eventID(for: $0) })

        // `blurhash` is not decoration. The SDK refuses an image without one and says
        // `InvalidAttachmentData` — see `Blurhash`.
        let imageInfo = ImageInfo(height: info.height,
                                  width: info.width,
                                  mimetype: info.mimeType,
                                  size: info.size,
                                  thumbnailInfo: nil,
                                  thumbnailSource: nil,
                                  blurhash: info.blurhash,
                                  isAnimated: false)

        await upload {
            try timeline.sendImage(params: parameters, thumbnailSource: nil, imageInfo: imageInfo)
        }
    }

    /// Sends a video. A recorded video note comes through here too — it is an ordinary
    /// `m.video`, and only its shape (square, under a minute) marks it as round. See
    /// `VideoNote` for why it is not tagged with a custom field.
    func send(video url: URL, replyingTo replyID: String? = nil) async {
        guard let timeline = liveTimeline else {
            // Not a silent return. The user pressed send; if nothing is going to happen, they are
            // entitled to be told — a bare `return` here is the app appearing to swallow a message,
            // which is the exact failure this whole codebase is written against. `send(photo:)` had
            // this and the other four did not.
            Log.media.error("nothing was sent: the room has no live timeline")
            failure = .send
            return
        }

        let info = await MediaMetadata.video(at: url)

        // A clip with no audio track is a video message nobody can hear, and it is the one
        // failure the sender cannot see: the preview they just watched had sound, because it
        // was coming out of the room they are sitting in. So it is said here, once, before
        // the file leaves. It is a fact about the *file*, not about what is in it.
        if !info.hasAudio {
            Log.media.error("sending a video with no sound in it")
        }

        let parameters = UploadParameters(source: .file(filename: url.path(percentEncoded: false)),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: replyID.flatMap { eventID(for: $0) })

        // The thumbnail rides along as its own upload so a receiver has something to
        // show before the video itself arrives — and it only rides along if it is described
        // as well as uploaded. `sendVideo` takes the picture and its `ThumbnailInfo` as a
        // pair and attaches the thumbnail only when it has both; hand it the bytes with no
        // description, as this did, and it silently sends neither. The event then carries no
        // still at all, and in an encrypted room no receiver can make one — the server holds
        // ciphertext it cannot open. That is what made every circle in the timeline grey.
        let thumbnail: UploadSource? = info.thumbnail.map {
            .data(bytes: $0.data, filename: "thumbnail.jpg")
        }

        // Required, exactly as it is for a photo: `BaseVideoInfo` asks for a blurhash too, and
        // a video sent without one never leaves the device.
        let videoInfo = VideoInfo(duration: info.duration,
                                  height: info.height,
                                  width: info.width,
                                  mimetype: info.mimeType,
                                  size: info.size,
                                  thumbnailInfo: info.thumbnail.map {
                                      ThumbnailInfo(height: $0.height,
                                                    width: $0.width,
                                                    mimetype: $0.mimeType,
                                                    size: $0.size)
                                  },
                                  thumbnailSource: nil,
                                  blurhash: info.blurhash)

        await upload {
            try timeline.sendVideo(params: parameters, thumbnailSource: thumbnail, videoInfo: videoInfo)
        }
    }

    /// Sends any other file.
    func send(file url: URL, replyingTo replyID: String? = nil) async {
        guard let timeline = liveTimeline else {
            // Not a silent return. The user pressed send; if nothing is going to happen, they are
            // entitled to be told — a bare `return` here is the app appearing to swallow a message,
            // which is the exact failure this whole codebase is written against. `send(photo:)` had
            // this and the other four did not.
            Log.media.error("nothing was sent: the room has no live timeline")
            failure = .send
            return
        }

        let parameters = UploadParameters(source: .file(filename: url.path(percentEncoded: false)),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: replyID.flatMap { eventID(for: $0) })

        await upload {
            try timeline.sendFile(params: parameters, fileInfo: MediaMetadata.file(at: url))
        }
    }

    /// Sends a spoken message.
    ///
    /// `waveform` is the shape drawn in the bubble; it is computed at record time and
    /// travels with the event so both sides see the same picture rather than each
    /// guessing at one. Samples are 0...1 here and scaled to the wire's range on the way out —
    /// see `TimelineMapper.waveformScale`, which is the same number the way back in.
    func send(voice url: URL, duration: TimeInterval, waveform: [Float], replyingTo replyID: String? = nil) async {
        guard let timeline = liveTimeline else {
            // Not a silent return. The user pressed send; if nothing is going to happen, they are
            // entitled to be told — a bare `return` here is the app appearing to swallow a message,
            // which is the exact failure this whole codebase is written against. `send(photo:)` had
            // this and the other four did not.
            Log.media.error("nothing was sent: the room has no live timeline")
            failure = .send
            return
        }

        let parameters = UploadParameters(source: .file(filename: url.path(percentEncoded: false)),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: replyID.flatMap { eventID(for: $0) })

        let audioInfo = AudioInfo(duration: duration,
                                  size: MediaMetadata.fileSize(of: url),
                                  mimetype: MediaMetadata.mimeType(of: url) ?? "audio/ogg")

        await upload {
            try timeline.sendVoiceMessage(params: parameters,
                                          audioInfo: audioInfo,
                                          waveform: waveform.map { $0 * Float(TimelineMapper.waveformScale) })
        }
    }

    /// Sends a place.
    ///
    /// Not an attachment at all — there is no file, nothing is uploaded, and the whole message is
    /// two numbers. It lives here because this is where "the things you send that are not words"
    /// are, and because it takes the same `replyingTo`.
    ///
    /// `body` is what a client that does not understand locations will show instead, and it is
    /// the reason it is a sentence rather than a `geo:` URI: somebody reading this in a client
    /// from 2019 should see "Location: 55.755800, 37.617300", which they can paste into a map,
    /// and not a URI scheme.
    ///
    /// `assetType: .pin` says the message is *a place*, not *where the sender is*. Matrix has a
    /// `.sender` type for the latter, and this app does not send it: it would be a claim about
    /// the user's own position, made on their behalf, that they cannot see on the screen they
    /// pressed send on. If they want to say "I am here" they drop the pin on themselves, which
    /// is the same event without the claim.
    func send(location: Location, replyingTo replyID: String? = nil) async {
        guard let timeline = liveTimeline else {
            // Not a silent return. The user pressed send; if nothing is going to happen, they are
            // entitled to be told — a bare `return` here is the app appearing to swallow a message,
            // which is the exact failure this whole codebase is written against. `send(photo:)` had
            // this and the other four did not.
            Log.media.error("nothing was sent: the room has no live timeline")
            failure = .send
            return
        }

        let body = String(core: CoreStrings.Timeline.locationBody(location.latitude, location.longitude))

        do {
            try await timeline.sendLocation(body: body,
                                            geoUri: location.geoURI,
                                            description: location.name,
                                            zoomLevel: Self.locationZoom,
                                            assetType: .pin,
                                            repliedToEventId: replyID.flatMap { eventID(for: $0) })
        } catch {
            failure = .send
        }
    }

    /// How far in the receiver's map should open. Street level: close enough to see which
    /// building, far enough to see which street it is on.
    private static let locationZoom: UInt8 = 15

    // MARK: - Private

    /// Every send goes through here so that one failure message serves them all, and
    /// so the upload is awaited rather than abandoned when the view goes away.
    ///
    /// The user is told one sentence; the log is told which of the many things behind that
    /// sentence actually happened. Without this the only witness to a refused upload was a
    /// phone saying "the server would not take it" — which is where the sentence ends and
    /// the debugging has to begin, with nothing to begin from.
    ///
    /// What is logged is the *error*, never the attachment: a `RoomError` says "the file was
    /// too large" or "the server said no", and none of it is the picture.
    private func upload(_ start: () throws -> SendAttachmentJoinHandle) async {
        do {
            let handle = try start()
            try await handle.join()
        } catch {
            Log.media.error("attachment refused: \(Log.describe(error), privacy: .public)")
            failure = .send
        }
    }
}
