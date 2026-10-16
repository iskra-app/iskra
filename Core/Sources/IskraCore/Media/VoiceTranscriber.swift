import Foundation
import Speech
import Synchronization

/// A voice message, as words — on this device, and nowhere else.
///
/// `requiresOnDeviceRecognition` is the whole of the design. Without it the Speech framework is
/// free to send the recording to Apple to be recognised, and a voice message in an encrypted room
/// is exactly as private as the words typed beside it: the room's encryption would end at the
/// moment somebody pressed "transcribe". So recognition is on the device or it does not happen,
/// and when the device has no model for the language, that is what the person is told.
///
/// Which language: the device's, and then the person's other preferred ones, the first that has a
/// model here. Matrix does not say what language a voice message is in, and guessing from the room
/// would be guessing.
///
/// The words are kept in memory for as long as the app runs (`cached`) — pressing again on a
/// message already transcribed is instant — and never written anywhere: a transcript is the content
/// of a message, and this app keeps message content in one place, the SDK's encrypted store.
@MainActor
public final class VoiceTranscriber {
    public static let shared = VoiceTranscriber()

    public enum Failure: Error, Equatable {
        /// The person said no to speech recognition, or a profile does not allow it.
        case notAllowed
        /// No language the person reads has an on-device model on this device.
        case unavailable
        /// The recording had nothing in it the recogniser could make into words.
        case nothingHeard
        /// The file would not load, or recognition failed for its own reasons.
        case failed
    }

    private var transcripts: [String: String] = [:]

    public func cached(_ attachment: Attachment) -> String? {
        transcripts[attachment.mediaID]
    }

    public func transcribe(_ attachment: Attachment, using loader: MediaLoader) async throws(Failure) -> String {
        if let known = transcripts[attachment.mediaID] { return known }

        guard await Self.authorize() else { throw .notAllowed }
        guard let recognizer = Self.recognizer() else { throw .unavailable }

        let file: MediaFile
        do {
            file = try await loader.file(for: attachment)
        } catch {
            throw .failed
        }

        let text = try await Self.recognize(file.url, with: recognizer)
        withExtendedLifetime(file) {}
        transcripts[attachment.mediaID] = text
        return text
    }

    /// The first of the person's languages with an on-device model.
    nonisolated private static func recognizer() -> SFSpeechRecognizer? {
        let candidates = [Locale.current] + Locale.preferredLanguages.map(Locale.init(identifier:))
        for locale in candidates {
            if let recognizer = SFSpeechRecognizer(locale: locale),
               recognizer.supportsOnDeviceRecognition,
               recognizer.isAvailable {
                return recognizer
            }
        }
        return nil
    }

    /// `nonisolated`, and that is the fix for a crash: TCC answers on a queue of its own, and a
    /// closure written inside this `@MainActor` type inherits the main actor — Swift checks that on
    /// the way in and traps (`dispatch_assert_queue`) the moment the person answers the question.
    nonisolated private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    /// `nonisolated` for the same reason as `authorize`: the result handler runs on the
    /// recogniser's queue.
    nonisolated private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws(Failure) -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let result: Result<String, Failure> = await withCheckedContinuation { continuation in
            // The handler is called more than once — partial results, then the final one or an
            // error — and the continuation may be resumed once.
            let answered = Mutex(false)
            /// True for the one call that gets to resume.
            let claim: @Sendable () -> Bool = {
                answered.withLock { done in
                    defer { done = true }
                    return !done
                }
            }
            recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result, result.isFinal {
                    guard claim() else { return }
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text.isEmpty ? .failure(.nothingHeard) : .success(text))
                } else if let error {
                    guard claim() else { return }
                    // "No speech detected" is an error to the framework and an answer to the person.
                    let nsError = error as NSError
                    let nothing = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                    if !nothing {
                        Log.media.error("transcription failed: \(Log.describe(error), privacy: .public)")
                    }
                    continuation.resume(returning: .failure(nothing ? .nothingHeard : .failed))
                }
            }
        }
        return try result.get()
    }
}
