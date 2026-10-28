import Foundation

/// The half-finished things, behind a switch.
///
/// A beta feature here is not a staged rollout and not an A/B test — there is nobody to roll it
/// out to. It is the app admitting that a change is big enough to be worth living with for a
/// while before it becomes the only way the app works: the old behaviour stays exactly where it
/// was, one switch away, so trying the new one costs nothing and regretting it costs nothing
/// either.
///
/// Each flag is a key in `UserDefaults`, read with `@AppStorage` wherever it matters, and named
/// here so there is one list of them. The list is also what `AppSettings.forget()` empties on
/// sign-out — an experiment somebody opted into is a preference of *theirs*, and the next person
/// to sign in on this device should get the app as it ships.
///
/// In `IskraCore` rather than in `IskraFeatures`, which is where it started, for one reason: the
/// notification extension has to read the generated-faces switch, and it links `IskraCore` and
/// nothing above it. A flag only the app can see is a flag the lock screen disobeys.
public enum BetaFeatures {
    /// Whether the conversation list is drawn as a macOS sidebar rather than as the app's own
    /// plain list — see `RoomListView`.
    public static let nativeSidebarKey = "beta.nativeSidebar"

    /// Off unless somebody turns it on.
    ///
    /// It was on by default for a while, so that the question it is being tried out for — whether
    /// the Mac's own sidebar is better than the app's list — got answered. It was: the app's list,
    /// which stands on the same page as the rest of the app (`Color.groupedPage`), where the
    /// sidebar material made the Mac app a different app from the one on the phone.
    ///
    /// Spelled out here rather than written into the two `@AppStorage` declarations that read it,
    /// because a default that disagrees with itself between the screen that sets it and the screen
    /// that obeys it is a bug nothing catches: the toggle would simply show the wrong position.
    public static let nativeSidebarByDefault = false

    /// Whether a person with no picture of their own is drawn as a generated creature rather
    /// than as their initials — see `Blobatar`, `Avatar`, and `CommunicationNotification`, which
    /// is the same question asked on a lock screen.
    public static let blobatarKey = "beta.blobatar"

    /// And it is **off**, again — it was on for a while, and the case for that is worth keeping.
    ///
    /// On, a new person met a chat list of creatures rather than of grey discs with one letter in
    /// each, because most people in most rooms have never set a picture. But it changes what every
    /// person in the app looks like, and that is a thing to ask for, not a thing to find: the
    /// creatures stay one slider away in Beta features (see `FaceMode`), for whoever goes looking.
    ///
    /// Off means off everywhere at once — the chat list, the widget, the share sheet and the lock
    /// screen all ask `drawsGeneratedFace`, and so all of them fall back to initials together.
    public static let blobatarByDefault = false

    /// Whether the creature wins even against a picture somebody actually set.
    ///
    /// Only meaningful with `blobatarKey` on, and the switch for it appears only when that one
    /// is — a preference that does nothing, shown next to the one it depends on, is a switch
    /// that teaches somebody the wrong thing about what it does.
    public static let forceBlobatarKey = "beta.blobatar.force"

    /// Off. Replacing a face somebody chose with a drawing is a thing to ask for, never a
    /// default — and it is offered at all because it is the only way to *see* the feature: most
    /// of the people worth looking at in a real account are exactly the ones who have a
    /// photograph.
    public static let forceBlobatarByDefault = false

    /// An Element Call address typed by hand, for a server that does not advertise one.
    ///
    /// Not a fallback and not a default — see `ElementCallDiscovery`, which refuses to invent one.
    /// This is the other half of that refusal: somebody running their own Element Call, or willing
    /// to use somebody else's on purpose, can say so in a sentence they wrote. The screen that
    /// offers it says plainly what it means, because the thing being typed is the address of a
    /// service that learns who is in every call.
    ///
    /// Empty by default, which is what "the server decides" looks like.
    public static let elementCallURLKey = "beta.elementCallURL"

    /// The address somebody typed, if it is one at all.
    ///
    /// Held to the same rule as the server's own answer: `https`, or it does not count. A typo
    /// that leaves the scheme off should be nothing, not a call placed over plain http.
    public static func elementCallURL(in defaults: UserDefaults = .standard) -> URL? {
        guard let typed = defaults.string(forKey: elementCallURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.isEmpty,
              let url = URL(string: typed),
              url.scheme?.lowercased() == "https"
        else {
            return nil
        }
        return url
    }
    /// "View JSON" in a message's menu — the event as the server sent it, for whoever is chasing a
    /// message that draws wrong. Off by default: it is a developer's tool, and to anybody else a
    /// screen of braces.
    public static let showsEventSourceKey = "beta.showsEventSource"

    /// Every event in the conversation, the ones this app never shows included — power levels,
    /// join rules, calls, avatar changes, whatever failed to parse — each as a grey line naming its
    /// type and sender (`RoomEventKind.hidden`). Off by default for the same reason as the JSON:
    /// it is for whoever is asking "why is this room behaving like that", and to anybody else it
    /// is the audit log a conversation is not. Read with the rest of `ServiceEventSettings`.
    public static let showsAllEventsKey = "beta.showsAllEvents"

    /// Whether the app talks to the made-up server inside it instead of the real account — see
    /// `MockHomeserver`. For looking at every screen with something on it, without anybody's
    /// conversations and without a network.
    ///
    /// Off, obviously. And it touches nothing on the way in or out: the real session stays in the
    /// Keychain the whole time, and turning this off goes back to it.
    public static let mockBackendKey = "beta.mockBackend"

    /// What `Iskra --mock-backend` means: start in the demo, as though the switch were on. The
    /// switch is in settings, and settings are behind signing in — so without this, the demo
    /// could not be reached from a device that has no account on it.
    public static let mockBackendArgument = "--mock-backend"

    /// Whether there is anything in here to show on this platform.
    ///
    /// True everywhere now, and it was not always: the first experiment here was about a sidebar
    /// that does not exist on iPhone, so the screen had nothing on it and the row that led there
    /// was hidden. Generated faces are on every platform, so the screen always has something —
    /// but the question stays, because it is the right one to ask and the answer is free to go
    /// back to being false.
    public static var hasAnything: Bool { true }

    /// The two face flags live in the **App Group's** defaults, not in the app's own.
    ///
    /// Everything else here is a preference of the app's, read by the app, and `.standard` is
    /// where it belongs. These two are read by a second process: the notification extension has
    /// to know whether a sender with no picture gets a creature, and an extension's `.standard`
    /// defaults are its own and empty. Put them in the shared suite and there is one answer; keep
    /// them apart and the lock screen quietly disagrees with the chat list — which is the bug
    /// this moved for.
    ///
    /// Nil where there is no App Group at all, and then `@AppStorage` falls back to `.standard`
    /// by itself, which is the right answer for a standalone build that has no extension either.
    public static var faceStore: UserDefaults? { ChatDirectory.sharedDefaults }

    /// Whether a creature is drawn rather than whatever else would stand in.
    ///
    /// The same question `Avatar` asks on screen, asked here so the lock screen and the chat list
    /// cannot answer it differently: normally a creature only where there is no picture, and —
    /// when somebody has asked for it — over a picture they actually set, which is the only way to
    /// see this feature at all in an account where everybody has a face already.
    ///
    /// The caller still needs a seed. A creature with nothing to compute it from is not a face,
    /// and there is no such thing as a default one.
    public static func drawsGeneratedFace(hasPicture: Bool,
                                          in defaults: UserDefaults? = faceStore) -> Bool {
        let store = defaults ?? .standard
        let flag = { (key: String, fallback: Bool) in
            store.object(forKey: key) as? Bool ?? fallback
        }
        guard flag(blobatarKey, blobatarByDefault) else { return false }
        return !hasPicture || flag(forceBlobatarKey, forceBlobatarByDefault)
    }

    /// Carries a face flag somebody already set from the app's own defaults into the shared ones.
    ///
    /// Once, per key, and only when the shared suite has no opinion yet — so a switch turned off
    /// after the move is not undone by the value it used to have. Called at launch; harmless on
    /// every launch after the first.
    public static func adoptFaceFlags(from local: UserDefaults = .standard,
                                      into shared: UserDefaults? = faceStore) {
        guard let shared, shared != local else { return }
        for key in [blobatarKey, forceBlobatarKey] {
            guard shared.object(forKey: key) == nil,
                  let carried = local.object(forKey: key) as? Bool else { continue }
            shared.set(carried, forKey: key)
        }
    }

    /// Every key a beta flag is kept under, with the store it is kept in — which is what
    /// `AppSettings.forget()` walks on sign-out. A flag emptied from the wrong store survives a
    /// sign-out silently, and the next person inherits somebody else's experiment.
    public static var stores: [(key: String, store: UserDefaults?)] {
        [(nativeSidebarKey, nil), (blobatarKey, faceStore), (forceBlobatarKey, faceStore),
         (elementCallURLKey, nil),
         (mockBackendKey, nil)]
    }
}
