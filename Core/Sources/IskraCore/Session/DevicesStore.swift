import Foundation
import Observation

/// Something the Devices screen was asked to do, and it did not happen.
public enum DevicesActionFailure: String, CaseIterable, ActionFailure {
    /// The list could not be fetched.
    case load
    /// A session would not end.
    case end
    /// The password the server asked for was not the account's.
    case wrongPassword
    /// The server ends sessions on a page of its own, and did not say where it is.
    case managedElsewhere

    public var id: String { rawValue }

    public var explanation: LocalizedStringResource {
        switch self {
        case .load: CoreStrings.Devices.loadFailed
        case .end: CoreStrings.Devices.endFailed
        case .wrongPassword: CoreStrings.Devices.wrongPassword
        case .managedElsewhere: CoreStrings.Devices.managedElsewhere
        }
    }
}

/// The Devices screen: this device, the account's other sessions, and ending them — Telegram's
/// Settings → Devices. See `AccountDevices` for where the list comes from.
@MainActor
@Observable
public final class DevicesStore {
    public private(set) var devices: [AccountDevice] = []
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false

    /// The sessions being ended right now, so their rows can say so.
    public private(set) var ending: Set<String> = []

    public var failure: DevicesActionFailure?

    /// Sessions the server will end only once it has the account's password. Set when it asks;
    /// the screen puts up the question, and answers with `end(_:password:)`.
    public var awaitingPassword: [String]?

    /// The server's own page, when that is where sessions are ended — opened by the screen, which
    /// owns the browser, and cleared once it has been.
    public var pageToOpen: URL?

    private let source: AccountDevices

    public init(source: AccountDevices) {
        self.source = source
    }

    /// The session this app is running, at the top of the screen.
    public var current: AccountDevice? { devices.first(where: \.isCurrent) }

    /// Every other session, most recently seen first.
    public var others: [AccountDevice] { devices.filter { !$0.isCurrent } }

    /// Whether ending happens on the server's page rather than here — said on the screen, so that a
    /// browser opening is not a surprise.
    public var isManagedByServer: Bool { source.isManagedByServer }

    public func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            devices = try await source.list()
            hasLoaded = true
        } catch {
            // A list that never arrived is said once, and an old list stays on the screen rather
            // than being emptied — it was true a moment ago, and it is the better picture.
            if !hasLoaded { failure = .load }
        }
    }

    /// Ends these sessions. The rows go the moment the server agrees, not before — a session that
    /// vanished from the screen and then turned out to be signed in still is the worst answer.
    public func end(_ ids: [String], password: String? = nil) async {
        ending.formUnion(ids)
        defer { ending.subtract(ids) }

        do {
            try await source.end(ids, password: password)
            devices.removeAll { ids.contains($0.id) }
            // And the truth from the server, which may have ended a little more or a little less.
            await load()
        } catch let error as AccountDevicesError {
            switch error {
            case .needsPassword:
                awaitingPassword = ids
            case .wrongPassword:
                failure = .wrongPassword
            case let .managedByServer(page):
                if let page { pageToOpen = page } else { failure = .managedElsewhere }
            case .failed:
                failure = .end
            }
        } catch {
            failure = .end
        }
    }

    /// "End all other sessions" — Telegram's red button.
    public func endOthers(password: String? = nil) async {
        await end(others.map(\.id), password: password)
    }
}
