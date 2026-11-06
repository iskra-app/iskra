import Foundation
import Network
import Observation

/// Whether the network the device is on right now costs somebody money — mobile data, a phone's
/// hotspot, Low Data Mode. What "Wi-Fi only" in Settings → Photos & videos is asked against.
///
/// The system's own words for it (`isExpensive`, `isConstrained`) rather than "is this Wi-Fi":
/// a Mac on Ethernet is not on Wi-Fi and is not paying by the megabyte, and an iPhone tethered to
/// another iPhone is on Wi-Fi and is.
@MainActor @Observable
final class NetworkCost {
    static let shared = NetworkCost()

    private(set) var isExpensive = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in NetworkCost.shared.isExpensive = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "wtf.iskra.network-cost"))
    }
}

/// The pictures somebody tapped to fetch while automatic download was off — remembered for as
/// long as the app runs, so one scrolled out of view and back does not ask to be tapped again.
///
/// Not written anywhere. Which photos somebody chose to look at is not a thing to keep on a disk,
/// and the SDK's own encrypted cache already holds the bytes for the next time.
@MainActor @Observable
final class ManualDownloads {
    static let shared = ManualDownloads()

    private(set) var asked: Set<String> = []

    func contains(_ mediaID: String) -> Bool { asked.contains(mediaID) }
    func ask(for mediaID: String) { asked.insert(mediaID) }
}
