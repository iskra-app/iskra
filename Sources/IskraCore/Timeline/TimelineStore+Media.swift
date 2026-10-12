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
    ///
    /// What goes is what the settings say: compressed, and with where it was taken, when and on
    /// what taken out — see `MediaSettings` and `MediaPreparation`. A photo the settings want
    /// stripped and that cannot be is not sent at all.
    func send(photo original: Data, filename originalName: String, replyingTo replyID: String? = nil) async {
        guard let timeline = liveTimeline else {
            Log.media.error("photo dropped: the room has no live timeline")
            failure = .send
            return
        }

        // Off the main thread: a twelve-megapixel HEIC drawn again is a few hundred milliseconds,
        // and they are not the room's to spend.
        let settings = MediaSettings.current()
        let prepared = await Task.detached(priority: .userInitiated) {
            MediaPreparation.photo(original, filename: originalName, settings: settings)
        }.value
        guard let prepared else {
            Log.media.error("photo refused: its metadata could not be removed")
            failure = .send
            return
        }
        let data = prepared.data
        let filename = prepared.filename

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

        upload {
            try timeline.sendImage(params: parameters, thumbnailSource: nil, imageInfo: imageInfo)
        }
    }

    /// Sends a video. A recorded video note comes through here too — it is an ordinary
    /// `m.video`, and only its shape (square, under a minute) marks it as round. See
    /// `VideoNote` for why it is not tagged with a custom field.
    ///
    /// What goes is what the settings say — compressed, and with the location, the camera and the
    /// dates taken out; see `MediaSettings` and `MediaPreparation`. A video note ignores them: it
    /// is always stripped, and it was compressed when it was recorded (`MediaSettings.videoNote`).
    /// Any copy made here is plaintext on disk and lives exactly as long as this call — which is
    /// safe only because the SDK is handed the *bytes*, not the path (see `owned`): it reads a
    /// path later, from its queue, by which time the copy is gone.
    func send(video original: URL, asVideoNote: Bool = false, replyingTo replyID: String? = nil) async {
        guard let timeline = liveTimeline else {
            // Not a silent return. The user pressed send; if nothing is going to happen, they are
            // entitled to be told — a bare `return` here is the app appearing to swallow a message,
            // which is the exact failure this whole codebase is written against. `send(photo:)` had
            // this and the other four did not.
            Log.media.error("nothing was sent: the room has no live timeline")
            failure = .send
            return
        }

        let prepared: MediaPreparation.Video
        do {
            prepared = try await MediaPreparation.video(original,
                                                        settings: asVideoNote ? .videoNote : .current())
        } catch {
            Log.media.error("video refused: its metadata could not be removed: \(Log.describe(error), privacy: .public)")
            failure = .send
            return
        }
        defer { prepared.discard() }
        let url = prepared.url

        let info = await MediaMetadata.video(at: url)

        // A clip with no audio track is a video message nobody can hear, and it is the one
        // failure the sender cannot see: the preview they just watched had sound, because it
        // was coming out of the room they are sitting in. So it is said here, once, before
        // the file leaves. It is a fact about the *file*, not about what is in it.
        if !info.hasAudio {
            Log.media.error("sending a video with no sound in it")
        }

        guard let source = try? Self.owned(url) else {
            Log.media.error("nothing was sent: the file could not be read")
            failure = .send
            return
        }
        let parameters = UploadParameters(source: source,
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

        upload {
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

        guard let source = try? Self.owned(url) else {
            Log.media.error("nothing was sent: the file could not be read")
            failure = .send
            return
        }
        let parameters = UploadParameters(source: source,
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: replyID.flatMap { eventID(for: $0) })

        upload {
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

        guard let source = try? Self.owned(url) else {
            Log.media.error("nothing was sent: the file could not be read")
            failure = .send
            return
        }
        let parameters = UploadParameters(source: source,
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: replyID.flatMap { eventID(for: $0) })

        let audioInfo = AudioInfo(duration: duration,
                                  size: MediaMetadata.fileSize(of: url),
                                  mimetype: MediaMetadata.mimeType(of: url) ?? "audio/ogg")

        upload {
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

    /// The file, as bytes the SDK owns from this moment — not as a path it will read later.
    ///
    /// `.file(filename:)` looked like the SDK taking the file, and was the SDK taking *the name
    /// of* the file: `sendFile` and its siblings return at once and read the path afterwards, in a
    /// task of the send queue's. Every caller deletes the file the moment the send returns — the
    /// stripped copy of a video, the Share outbox's copy, a picked file's security scope — so by
    /// the time the queue looked, there was nothing there, no local echo was ever made, and the
    /// video or the file simply did not exist. `DemoBackendTests` sends a file, deletes it at once,
    /// and waits for it to arrive, which is what it now does.
    ///
    /// Mapped rather than read where the system allows, so a large file is not copied once more
    /// on its way into the SDK than it has to be.
    private static func owned(_ url: URL) throws -> UploadSource {
        .data(bytes: try Data(contentsOf: url, options: .mappedIfSafe), filename: url.lastPathComponent)
    }

    /// Every send goes through here, and what it does *not* do is the whole of it: it does not wait
    /// for the attachment to reach the server.
    ///
    /// `sendImage` and its four siblings are not `async`. They put the attachment in the room's send
    /// queue — the same encrypted, on-disk queue a typed message goes into — and hand back a handle.
    /// `join()` on that handle means "wait until it has actually been sent", and waiting on it is
    /// what this used to do. That turned an offline photograph into a *failure*: the queue had taken
    /// it and would have sent it the moment the network came back, but we stood over the queue until
    /// it gave up, and then told the user their picture had not gone.
    ///
    /// So the two things are told apart now, because they were never the same thing:
    ///
    /// - `start()` throwing is the SDK **refusing** the attachment — a file it cannot read, an image
    ///   with no blurhash, something too large. Nothing is queued, nothing will happen later, and the
    ///   user has to be told. That is still a failure.
    /// - Everything after that belongs to the queue, and the queue reports on itself. A send that
    ///   fails arrives at `handle(sendQueueUpdate:)` and the message wears the "Not sent" badge, with
    ///   "Send again" and "Delete" on it. A send that is merely *waiting for a network* is not a
    ///   failure at all, and no longer pretends to be one.
    ///
    /// What is logged is the *error*, never the attachment: a `RoomError` says "the file was
    /// too large" or "the server said no", and none of it is the picture.
    private func upload(_ start: () throws -> SendAttachmentJoinHandle) {
        do {
            _ = try start()
        } catch {
            Log.media.error("attachment refused: \(Log.describe(error), privacy: .public)")
            failure = .send
        }
    }
}
