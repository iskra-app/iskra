import Foundation

/// "A chat has been asked for" — said across processes, the moment it is written down.
///
/// A widget's face runs `OpenChatIntent`, which writes the chat into the shared defaults and has the
/// system bring the app forward. Two things then race: the app coming to the front, which is when it
/// used to look for a request (`handleIntents` on `.active`), and the intent writing one. Whenever
/// the app won, it found nothing, opened on whatever it was showing, and the tap seemed to have
/// missed — most of the time, on a phone. So the write is *announced*, through Darwin notifications,
/// which reach every process of the app group's owner, and the app looks again when it hears it,
/// whichever side was first.
///
/// Darwin notifications carry nothing but their name — which is the point: the request itself stays
/// in the App Group, where `ChatDirectory.takePendingOpenRequest` reads and clears it once.
public enum OpenRequestSignal {
    private static var name: CFString { "wtf.iskra.openRequested" as CFString }

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name), nil, nil, true)
    }

    /// Every announcement from now until the stream is dropped.
    public static func announcements() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = Box(continuation: continuation)
            let observer = Unmanaged.passRetained(box).toOpaque()
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), observer,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
                },
                name, nil, .deliverImmediately)
            let address = UInt(bitPattern: observer)
            continuation.onTermination = { _ in
                guard let observer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer,
                                                   CFNotificationName(name), nil)
                Unmanaged<Box>.fromOpaque(observer).release()
            }
        }
    }

    private final class Box: Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }
}
