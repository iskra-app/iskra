import Foundation
import MatrixRustSDK

public extension TimelineStore {
    /// Sends a photo.
    func send(photo url: URL) async {
        guard let timeline = liveTimeline else { return }

        let info = MediaMetadata.image(at: url)
        let parameters = UploadParameters(source: .file(filename: url.path(percentEncoded: false)),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: nil)

        let imageInfo = ImageInfo(height: info.height,
                                  width: info.width,
                                  mimetype: info.mimeType,
                                  size: info.size,
                                  thumbnailInfo: nil,
                                  thumbnailSource: nil,
                                  blurhash: nil,
                                  isAnimated: false)

        await upload {
            try timeline.sendImage(params: parameters, thumbnailSource: nil, imageInfo: imageInfo)
        }
    }

    /// Sends a video. A recorded video note comes through here too — it is an ordinary
    /// `m.video`, and only its shape (square, under a minute) marks it as round. See
    /// `VideoNote` for why it is not tagged with a custom field.
    func send(video url: URL) async {
        guard let timeline = liveTimeline else { return }

        let info = await MediaMetadata.video(at: url)

        let parameters = UploadParameters(source: .file(filename: url.path(percentEncoded: false)),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: nil)

        let videoInfo = VideoInfo(duration: info.duration,
                                  height: info.height,
                                  width: info.width,
                                  mimetype: info.mimeType,
                                  size: info.size,
                                  thumbnailInfo: nil,
                                  thumbnailSource: nil,
                                  blurhash: nil)

        // The thumbnail rides along as its own upload so a receiver has something to
        // show before the video itself arrives.
        let thumbnail: UploadSource? = info.thumbnail.map { .data(bytes: $0, filename: "thumbnail.jpg") }

        await upload {
            try timeline.sendVideo(params: parameters, thumbnailSource: thumbnail, videoInfo: videoInfo)
        }
    }

    /// Sends any other file.
    func send(file url: URL) async {
        guard let timeline = liveTimeline else { return }

        let parameters = UploadParameters(source: .file(filename: url.path(percentEncoded: false)),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: nil)

        await upload {
            try timeline.sendFile(params: parameters, fileInfo: MediaMetadata.file(at: url))
        }
    }

    /// Sends a spoken message.
    ///
    /// `waveform` is the shape drawn in the bubble; it is computed at record time and
    /// travels with the event so both sides see the same picture rather than each
    /// guessing at one. Samples are 0...1 here and scaled to the wire's 0...1024.
    func send(voice url: URL, duration: TimeInterval, waveform: [Float]) async {
        guard let timeline = liveTimeline else { return }

        let parameters = UploadParameters(source: .file(filename: url.path(percentEncoded: false)),
                                          caption: nil,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: nil)

        let audioInfo = AudioInfo(duration: duration,
                                  size: MediaMetadata.fileSize(of: url),
                                  mimetype: MediaMetadata.mimeType(of: url) ?? "audio/ogg")

        await upload {
            try timeline.sendVoiceMessage(params: parameters,
                                          audioInfo: audioInfo,
                                          waveform: waveform.map { $0 * 1024 })
        }
    }

    // MARK: - Private

    /// Every send goes through here so that one failure message serves them all, and
    /// so the upload is awaited rather than abandoned when the view goes away.
    private func upload(_ start: () throws -> SendAttachmentJoinHandle) async {
        do {
            let handle = try start()
            try await handle.join()
        } catch {
            sendFailure = CoreStrings.Timeline.sendFailed
        }
    }
}
