import Foundation
import IskraCore

#if os(iOS)
import PushKit
#endif

/// The PushKit token, and the pusher it is registered as.
///
/// The mirror of `PushPermission`, for a token that is not the same token: an APNs device token
/// and a PushKit VoIP token are minted separately, name different doors at Apple, and are
/// registered as two different pushers on the account. Everything in `PushPermission` about the
/// two arriving in either order applies here unchanged — the registry answers on its own schedule,
/// and the session that wants the answer is not the object that was told.
///
/// **There is no permission to ask for.** Unlike notifications, VoIP registration prompts nobody:
/// it either works or, when `voip` is missing from `UIBackgroundModes`, it silently never produces
/// a token and reports no error anywhere. That is the single most likely reason for "calls do not
/// ring", and `--probe-voip-token` exists to say so out loud.
///
/// **The push rule goes first.** `registerVoIP` is only called once `enableCallPushes()` has had
/// its turn — see the order in `IskraRootView`. A VoIP pusher on an account with no rule to stamp
/// rings means the gateway cannot tell a call from a message, which means a VoIP push per message,
/// which is how iOS takes the privilege away.
@MainActor
public final class VoIPPermission: NSObject {
    public static let shared = VoIPPermission()

    private var token: Data?
    private var registration: PushRegistration?
    private var deviceName = ""

    #if os(iOS)
    private var registry: PKPushRegistry?
    #endif

    private override init() {}

    /// Starts PushKit. Called from the app delegate at launch, not after sign-in.
    ///
    /// Earlier than `PushPermission.request()` deliberately, and it is not the same kind of act:
    /// that one asks a person a question and should wait until the question means something, while
    /// this one asks the system for a token and asks nobody anything. A registry created late is a
    /// registry iOS has already given up on delivering to.
    public func start() {
        #if os(iOS)
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        #endif
    }

    /// Whether a token has arrived. Read by the probe, and by nothing else.
    public var hasToken: Bool { token != nil }

    /// The token as the gateway spells it, for `--probe-voip-token`. Sixty-four characters when it
    /// is intact; see `docs/PUSH-GATEWAY.md` on what other lengths mean.
    public var tokenHex: String? {
        token?.map { String(format: "%02x", $0) }.joined()
    }

    /// Somebody signed in. Registers the VoIP pusher if the token is already here.
    public func signedIn(_ session: UserSession) {
        registration = session.pushes()
        deviceName = session.displayName

        guard let token else { return }
        let registration = session.pushes()
        let name = deviceName
        Task { await registration.registerVoIP(token: token, deviceName: name) }
    }

    /// Somebody signed out. The account must stop having a VoIP pusher pointed here — a device
    /// that is sent ringing pushes it cannot report to CallKit is a device Apple stops trusting.
    public func signingOut(_ session: UserSession) async {
        guard let token else {
            registration = nil
            return
        }
        await session.pushes().unregisterVoIP(token: token)
        registration = nil
    }
}

#if os(iOS)
extension VoIPPermission: @MainActor PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry,
                             didUpdate credentials: PKPushCredentials,
                             for type: PKPushType) {
        guard type == .voIP else { return }
        token = credentials.token

        guard let registration else { return }
        let name = deviceName
        let token = credentials.token
        Task { await registration.registerVoIP(token: token, deviceName: name) }
    }

    public func pushRegistry(_ registry: PKPushRegistry,
                             didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        token = nil
    }

    /// A call. **Everything that matters about this method is in `IncomingCallCenter.ring`** —
    /// in particular that a call is reported to CallKit before this returns, on every push,
    /// whatever turns out to be behind it.
    public func pushRegistry(_ registry: PKPushRegistry,
                             didReceiveIncomingPushWith payload: PKPushPayload,
                             for type: PKPushType,
                             completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }
        // PushKit hands over a plain, non-`Sendable` closure, and the report it has to be called
        // after finishes inside CallKit's own completion handler — so it has to cross one
        // boundary. Boxed rather than restructured around, because the alternative is telling
        // PushKit we are done *before* CallKit has taken the call, which is the one ordering this
        // whole path exists to get right. Everything here runs on the main queue: the registry was
        // created with `.main` and the provider's delegate queue is the same one.
        let done = CallCompletion(completion)
        IncomingCallCenter.shared.ring(payload: payload.dictionaryPayload) { done.run() }
    }
}
#endif

/// PushKit's completion handler, carried across one isolation boundary. See the call site.
private final class CallCompletion: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    func run() {
        body()
    }
}
