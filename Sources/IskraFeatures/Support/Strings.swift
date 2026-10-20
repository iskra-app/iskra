import Foundation
import IskraCore
import IskraDesign

/// Every piece of user-facing text in the app's screens.
///
/// If you are looking for a word that appears on screen, it is here. If you are
/// adding one, it goes here — not into a view. The translations live in
/// `Resources/<lang>.lproj/Localizable.strings`, which is the file to edit; this one
/// only names them.
///
/// `bundle:` is load-bearing. Inside a Swift package, `Text` and
/// `LocalizedStringResource` look in `Bundle.main` unless told otherwise, so without
/// it every string would quietly resolve to its own key and no translation would
/// ever appear.
public enum Strings {
    /// The package's own bundle, where the `.lproj` folders live.
    static let resourceBundle = Bundle.module
    static let bundle = LocalizedStringResource.BundleDescription.atURL(Bundle.module.bundleURL)

    /// The lock screen — the shield over the app when it is locked.
    public enum Lock {
        public static let title = LocalizedStringResource("lock.title", bundle: bundle)
        public static let unlock = LocalizedStringResource("lock.unlock", bundle: bundle)
        /// Shown by the system in the Face ID / passcode prompt, so it must read as a reason, not a
        /// label: "Unlock Iskra".
        public static let reason = LocalizedStringResource("lock.reason", bundle: bundle)
    }

    /// The first run: the slides that say what this app is, and the questions it asks once
    /// somebody is in — see `WelcomeView` and `FirstRunView`.
    public enum Onboarding {
        /// The six slides, in the order they come. One case per slide rather than six pairs of
        /// properties, so that the carousel can count them and nothing on screen has to know how
        /// many there are.
        ///
        /// Every key below is spelled out rather than built from the case, and that is not
        /// clumsiness: a key with a `\(…)` in it is not a key at all — `LocalizedStringResource`
        /// reads an interpolation as a *format placeholder*, so the lookup would go looking for
        /// "onboarding.slide.%@.title" and find nothing. Every dynamic name in this file switches
        /// over literals for the same reason.
        public enum Slide: Int, CaseIterable, Identifiable, Sendable {
            case iskra, encryption, decentralised, appleWay, freedom, anonymous

            public var id: Int { rawValue }

            public var title: LocalizedStringResource {
                switch self {
                case .iskra: LocalizedStringResource("onboarding.slide.iskra.title", bundle: bundle)
                case .encryption: LocalizedStringResource("onboarding.slide.encryption.title", bundle: bundle)
                case .decentralised: LocalizedStringResource("onboarding.slide.decentralised.title", bundle: bundle)
                case .appleWay: LocalizedStringResource("onboarding.slide.appleWay.title", bundle: bundle)
                case .freedom: LocalizedStringResource("onboarding.slide.freedom.title", bundle: bundle)
                case .anonymous: LocalizedStringResource("onboarding.slide.anonymous.title", bundle: bundle)
                }
            }

            public var body: LocalizedStringResource {
                switch self {
                case .iskra: LocalizedStringResource("onboarding.slide.iskra.body", bundle: bundle)
                case .encryption: LocalizedStringResource("onboarding.slide.encryption.body", bundle: bundle)
                case .decentralised: LocalizedStringResource("onboarding.slide.decentralised.body", bundle: bundle)
                case .appleWay: LocalizedStringResource("onboarding.slide.appleWay.body", bundle: bundle)
                case .freedom: LocalizedStringResource("onboarding.slide.freedom.body", bundle: bundle)
                case .anonymous: LocalizedStringResource("onboarding.slide.anonymous.body", bundle: bundle)
                }
            }
        }

        /// The button under the slides. It is the only one there: the slides are a pitch, not a
        /// form, and the way past them is the way in.
        public static let start = LocalizedStringResource("onboarding.start", bundle: bundle)

        /// VoiceOver's name for the row of dots, which says nothing on its own.
        public static func slidePosition(_ index: Int, of total: Int) -> LocalizedStringResource {
            LocalizedStringResource("onboarding.slidePosition",
                                    defaultValue: "Slide \(index) of \(total)",
                                    bundle: bundle)
        }

        public static let `continue` = LocalizedStringResource("onboarding.continue", bundle: bundle)

        /// The way past a question that has a perfectly good answer already. Both screens after
        /// the sign-in have one: these are preferences, not steps, and somebody who wants their
        /// conversations should not be detained by a colour.
        public static let skip = LocalizedStringResource("onboarding.skip", bundle: bundle)

        /// The hello, by name, on the way in from the sign-in.
        public static func greeting(_ name: String) -> LocalizedStringResource {
            LocalizedStringResource("onboarding.greeting", defaultValue: "Hello, \(name)!", bundle: bundle)
        }

        /// And the same hello where the account has no name to say yet — a fresh account often
        /// has none at all, and "Hello, !" is not a greeting.
        public static let greetingNameless = LocalizedStringResource("onboarding.greetingNameless", bundle: bundle)

        public static let appearanceTitle = LocalizedStringResource("onboarding.appearance.title", bundle: bundle)
        public static let appearanceBody = LocalizedStringResource("onboarding.appearance.body", bundle: bundle)

        public static let facesTitle = LocalizedStringResource("onboarding.faces.title", bundle: bundle)
        public static let facesBody = LocalizedStringResource("onboarding.faces.body", bundle: bundle)

        /// The three positions of the slider — see `FaceMode`.
        public static func faceMode(_ mode: FaceMode) -> LocalizedStringResource {
            switch mode {
            case .pictures: LocalizedStringResource("onboarding.faces.pictures", bundle: bundle)
            case .mixed: LocalizedStringResource("onboarding.faces.mixed", bundle: bundle)
            case .faces: LocalizedStringResource("onboarding.faces.faces", bundle: bundle)
            }
        }

        /// And what each of them does, in a sentence under the slider.
        public static func faceModeHelp(_ mode: FaceMode) -> LocalizedStringResource {
            switch mode {
            case .pictures: LocalizedStringResource("onboarding.faces.picturesHelp", bundle: bundle)
            case .mixed: LocalizedStringResource("onboarding.faces.mixedHelp", bundle: bundle)
            case .faces: LocalizedStringResource("onboarding.faces.facesHelp", bundle: bundle)
            }
        }

        /// The two faces under the slider: somebody who set a picture, and somebody who did not.
        /// Named, because the whole of what the slider does is treat those two people differently.
        public static let withPicture = LocalizedStringResource("onboarding.faces.withPicture", bundle: bundle)
        public static let withoutPicture = LocalizedStringResource("onboarding.faces.withoutPicture", bundle: bundle)

        /// And the names those two go by. Invented people, named in each language, because the
        /// first position of the slider draws initials — and initials are a letter of somebody's
        /// alphabet, so a Russian stand-in name would put a Cyrillic letter on an English screen.
        public static let picturedName = LocalizedStringResource("onboarding.faces.picturedName", bundle: bundle)
        public static let unpicturedName = LocalizedStringResource("onboarding.faces.unpicturedName", bundle: bundle)
    }

    public enum SignIn {
        public static let title = LocalizedStringResource("signIn.title", bundle: bundle)
        public static let tagline = LocalizedStringResource("signIn.tagline", bundle: bundle)

        public static let whereIsAccount = LocalizedStringResource("signIn.whereIsAccount", bundle: bundle)
        public static let whereIsAccountHelp = LocalizedStringResource("signIn.whereIsAccountHelp", bundle: bundle)
        public static let addressPlaceholder = LocalizedStringResource("signIn.addressPlaceholder", bundle: bundle)
        public static let addressLabel = LocalizedStringResource("signIn.addressLabel", bundle: bundle)
        public static let `continue` = LocalizedStringResource("signIn.continue", bundle: bundle)
        /// Under the empty address field: the button for people who have no address to type.
        public static let chooseServer = LocalizedStringResource("signIn.chooseServer", bundle: bundle)
        public static let next = LocalizedStringResource("signIn.next", bundle: bundle)
        /// The small grey link at the foot of the sign-in screen.
        public static let whatIsMatrix = LocalizedStringResource("signIn.whatIsMatrix", bundle: bundle)

        public static let readyTitle = LocalizedStringResource("signIn.readyTitle", bundle: bundle)
        public static let readyHelp = LocalizedStringResource("signIn.readyHelp", bundle: bundle)

        /// Shown only where the server says it can make accounts — OIDC advertises `prompt=create`,
        /// and a server that does not cannot register anybody through this app at all. An offer we
        /// could not keep would be worse than no offer.
        public static let createAccount = LocalizedStringResource("signIn.createAccount", bundle: bundle)
        public static let signIn = LocalizedStringResource("signIn.signIn", bundle: bundle)
        public static let username = LocalizedStringResource("signIn.username", bundle: bundle)
        public static let password = LocalizedStringResource("signIn.password", bundle: bundle)
        public static let signInWithPassword = LocalizedStringResource("signIn.signInWithPassword", bundle: bundle)

        /// The quiet way to the password fields, on a server that offers both.
        ///
        /// There used to be an "or" here, with two buttons of equal weight under it, and that was
        /// the screen handing the user a decision instead of a way in. Almost nobody arriving at a
        /// server with OAuth *wants* the password form — they want to be let in — and the ones who
        /// do need it know they need it. So there is one way in, and a sentence for the people it
        /// does not work for.
        public static let usePasswordInstead = LocalizedStringResource("signIn.usePasswordInstead", bundle: bundle)
        public static let differentAddress = LocalizedStringResource("signIn.differentAddress", bundle: bundle)

        /// The one line on the opening screen that says where the account will be — matrix.org
        /// unless somebody changes it — and the word that changes it.
        public static func server(_ name: String) -> LocalizedStringResource {
            LocalizedStringResource("signIn.server", defaultValue: "Server: \(name)", bundle: bundle)
        }
        public static let changeServer = LocalizedStringResource("signIn.changeServer", bundle: bundle)
        public static let serverDone = LocalizedStringResource("signIn.serverDone", bundle: bundle)

        /// The second screen, reached only on a server with nothing but a password, or after the
        /// browser was closed half way: whose sign-in it is, and the way back.
        public static func signInTo(_ name: String) -> LocalizedStringResource {
            LocalizedStringResource("signIn.signInTo", defaultValue: "Sign in to \(name)", bundle: bundle)
        }
        public static let back = LocalizedStringResource("signIn.back", bundle: bundle)
        public static let continueInBrowser = LocalizedStringResource("signIn.continueInBrowser", bundle: bundle)
        public static let browserHelp = LocalizedStringResource("signIn.browserHelp", bundle: bundle)
        public static let passwordHelp = LocalizedStringResource("signIn.passwordHelp", bundle: bundle)
        /// Under a server that could not be reached, with the bridge off: the bridge as the way round
        /// a block, and the button that switches it on and looks again.
        public static let bridgeOffer = LocalizedStringResource("signIn.bridgeOffer", bundle: bundle)
        public static let tryThroughBridge = LocalizedStringResource("signIn.tryThroughBridge", bundle: bundle)

        /// Errors. Each says what happened and what to do; none names a protocol.
        public enum Problem {
            public static let notFound = LocalizedStringResource("signIn.problem.notFound", bundle: bundle)
            public static let unsupportedMethod = LocalizedStringResource("signIn.problem.unsupportedMethod", bundle: bundle)
            public static let storageUnavailable = LocalizedStringResource("signIn.problem.storageUnavailable", bundle: bundle)
            public static let unreachable = LocalizedStringResource("signIn.problem.unreachable", bundle: bundle)
            /// The bridge is switched on and would not come up — and the app will not go direct.
            public static let bridgeUnavailable = LocalizedStringResource("signIn.problem.bridgeUnavailable", bundle: bundle)
            public static let ssoIncomplete = LocalizedStringResource("signIn.problem.ssoIncomplete", bundle: bundle)
            public static let badCredentials = LocalizedStringResource("signIn.problem.badCredentials", bundle: bundle)
            /// Signing in, from "Add account", to somebody who is already on the device.
            public static let alreadySignedIn = LocalizedStringResource("signIn.problem.alreadySignedIn", bundle: bundle)
            /// "Create an account" on a server that will not make one through an app.
            public static let noRegistration = LocalizedStringResource("signIn.problem.noRegistration", bundle: bundle)
        }
    }

    /// What the bridge said when it ended a stream, in words a person can act on. Shared by the
    /// status line, "Check the bridge" and sign-in, so the three never describe one refusal
    /// three ways.
    public enum Bridge {
        public static func refusal(_ refusal: BridgeRefusal) -> LocalizedStringResource {
            switch refusal {
            case .notAllowed: LocalizedStringResource("bridge.refusal.notAllowed", bundle: bundle)
            case .notMatrix: LocalizedStringResource("bridge.refusal.notMatrix", bundle: bundle)
            case .badPort: LocalizedStringResource("bridge.refusal.badPort", bundle: bundle)
            case .notPublic: LocalizedStringResource("bridge.refusal.notPublic", bundle: bundle)
            case .noSuchHost: LocalizedStringResource("bridge.refusal.noSuchHost", bundle: bundle)
            case .unreachable: LocalizedStringResource("bridge.refusal.unreachable", bundle: bundle)
            case .busy: LocalizedStringResource("bridge.refusal.busy", bundle: bundle)
            case .disagreement: LocalizedStringResource("bridge.refusal.disagreement", bundle: bundle)
            case .broke(let word):
                LocalizedStringResource("bridge.refusal.broke",
                                        defaultValue: "The bridge dropped the connection: \(word)",
                                        bundle: bundle)
            }
        }
    }

    /// "What is Matrix?" — for somebody who has never heard the word.
    public enum AboutMatrix {
        public static let title = LocalizedStringResource("aboutMatrix.title", bundle: bundle)
        public static let intro = LocalizedStringResource("aboutMatrix.intro", bundle: bundle)
        public static let emailTitle = LocalizedStringResource("aboutMatrix.email.title", bundle: bundle)
        public static let emailBody = LocalizedStringResource("aboutMatrix.email.body", bundle: bundle)
        public static let nobodyTitle = LocalizedStringResource("aboutMatrix.nobody.title", bundle: bundle)
        public static let nobodyBody = LocalizedStringResource("aboutMatrix.nobody.body", bundle: bundle)
        public static let privateTitle = LocalizedStringResource("aboutMatrix.private.title", bundle: bundle)
        public static let privateBody = LocalizedStringResource("aboutMatrix.private.body", bundle: bundle)
    }

    /// "Not sure which server to choose?" — the public servers, and running your own.
    /// See `PublicServer` for why these four.
    public enum Servers {
        public static let title = LocalizedStringResource("servers.title", bundle: bundle)
        public static let intro = LocalizedStringResource("servers.intro", bundle: bundle)
        public static let matrixOrg = LocalizedStringResource("servers.matrixOrg", bundle: bundle)
        public static let matrixOrgWhere = LocalizedStringResource("servers.matrixOrgWhere", bundle: bundle)
        public static let matrixOrgBlocked = LocalizedStringResource("servers.matrixOrgBlocked", bundle: bundle)
        public static let tchncs = LocalizedStringResource("servers.tchncs", bundle: bundle)
        public static let tchncsWhere = LocalizedStringResource("servers.tchncsWhere", bundle: bundle)
        public static let quassel = LocalizedStringResource("servers.quassel", bundle: bundle)
        public static let quasselWhere = LocalizedStringResource("servers.quasselWhere", bundle: bundle)
        public static let nopeChat = LocalizedStringResource("servers.nopeChat", bundle: bundle)
        public static let nopeChatWhere = LocalizedStringResource("servers.nopeChatWhere", bundle: bundle)
        public static let ownTitle = LocalizedStringResource("servers.ownTitle", bundle: bundle)
        public static let ownAbout = LocalizedStringResource("servers.ownAbout", bundle: bundle)
    }

    /// The state of the connection, said out loud. See `OfflineBanner`.
    public enum Connection {
        public static let offline = LocalizedStringResource("connection.offline", bundle: bundle)

        // The screen where traffic is routed through a bridge rather than straight at the
        // homeserver. Two of these strings are the screen's whole reason for existing.
        // `unfinishedBody` says that the switch does not yet get anyone past a block — a person
        // who believes otherwise, in a place where it matters, is worse off than one who was told
        // plainly. `seesBody` says what a bridge can read: the token, the rooms, the text of
        // unencrypted messages. That is the bargain being offered, and offering it without naming
        // it is not consent.
        public static let title = LocalizedStringResource("connection.title", bundle: bundle)
        public static let bridge = LocalizedStringResource("connection.bridge", bundle: bundle)
        public static let bridgeFooter = LocalizedStringResource("connection.bridgeFooter", bundle: bundle)

        public static let status = LocalizedStringResource("connection.status", bundle: bundle)
        public static let statusDirect = LocalizedStringResource("connection.statusDirect", bundle: bundle)
        /// The tunnel is up and the bridge has not connected anything yet: nothing is claimed.
        public static func statusConnecting(_ relays: Int) -> LocalizedStringResource {
            LocalizedStringResource("connection.statusConnecting",
                                    defaultValue: "Through the bridge, relays: \(relays). The bridge hasn’t answered yet",
                                    bundle: bundle)
        }
        /// The one place the screen says the bridge cannot see — `TunnelStatus.bridgedBlind`, true
        /// of traffic that is flowing, never of a setting.
        public static func statusBlind(_ relays: Int) -> LocalizedStringResource {
            LocalizedStringResource("connection.statusBlind",
                                    defaultValue: "Through the bridge, relays: \(relays). The bridge can’t see your messages",
                                    bundle: bundle)
        }
        public static let statusFailed = LocalizedStringResource("connection.statusFailed", bundle: bundle)
        /// A change waiting to be applied, and the button that applies it at once.
        public static let pending = LocalizedStringResource("connection.pending", bundle: bundle)
        public static let applyNow = LocalizedStringResource("connection.applyNow", bundle: bundle)

        // The bridge's address, and this device's own key. The footers carry the two facts a
        // person cannot guess: where the bridge's key is printed, and that a closed bridge has to
        // be told about this device before it will answer it at all.
        public static let address = LocalizedStringResource("connection.address", bundle: bundle)
        public static let addressPrompt = LocalizedStringResource("connection.addressPrompt", bundle: bundle)
        public static let addressFooter = LocalizedStringResource("connection.addressFooter", bundle: bundle)
        public static let addressBad = LocalizedStringResource("connection.addressBad", bundle: bundle)
        public static let addressSecret = LocalizedStringResource("connection.addressSecret", bundle: bundle)
        public static let defaultBridge = LocalizedStringResource("connection.defaultBridge", bundle: bundle)

        public static let relays = LocalizedStringResource("connection.relays", bundle: bundle)
        public static let relaysPrompt = LocalizedStringResource("connection.relaysPrompt", bundle: bundle)
        public static let relaysFooter = LocalizedStringResource("connection.relaysFooter", bundle: bundle)

        public static let myKey = LocalizedStringResource("connection.myKey", bundle: bundle)
        public static let myKeyFooter = LocalizedStringResource("connection.myKeyFooter", bundle: bundle)
        public static let copy = LocalizedStringResource("connection.copy", bundle: bundle)
        public static let copied = LocalizedStringResource("connection.copied", bundle: bundle)

        public static let check = LocalizedStringResource("connection.check", bundle: bundle)
        public static let checking = LocalizedStringResource("connection.checking", bundle: bundle)
        public static func checkOK(_ milliseconds: Int) -> LocalizedStringResource {
            LocalizedStringResource("connection.checkOK",
                                    defaultValue: "The bridge answered, the server is there — \(milliseconds) ms",
                                    bundle: bundle)
        }
        public static let checkNoRelay = LocalizedStringResource("connection.checkNoRelay", bundle: bundle)
        public static let checkSilent = LocalizedStringResource("connection.checkSilent", bundle: bundle)
        public static func checkFailed(_ reason: String) -> LocalizedStringResource {
            LocalizedStringResource("connection.checkFailed", defaultValue: "No luck: \(reason)", bundle: bundle)
        }

        public static let unfinished = LocalizedStringResource("connection.unfinished", bundle: bundle)
        public static let unfinishedBody = LocalizedStringResource("connection.unfinishedBody", bundle: bundle)

        public static let sees = LocalizedStringResource("connection.sees", bundle: bundle)
        public static let seesBody = LocalizedStringResource("connection.seesBody", bundle: bundle)
    }

    /// The notifications screen — what the account does before any one chat has an opinion.
    ///
    /// The words are careful about one thing above all: these are rules on the *server*, not
    /// preferences on this phone, so they follow the account everywhere and a chat's own setting
    /// beats them. A screen that let somebody silence their groups here and then be woken by a
    /// group they had personally set to "all messages" would be a screen that lied. See
    /// `NotificationRulesStore`.
    public enum Notifications {
        public static let title = LocalizedStringResource("notifications.title", bundle: bundle)

        public static let defaults = LocalizedStringResource("notifications.defaults", bundle: bundle)
        public static let direct = LocalizedStringResource("notifications.direct", bundle: bundle)
        public static let groups = LocalizedStringResource("notifications.groups", bundle: bundle)
        public static let defaultsFooter = LocalizedStringResource("notifications.defaultsFooter", bundle: bundle)

        public static let mentions = LocalizedStringResource("notifications.mentions", bundle: bundle)
        public static let mentionsMe = LocalizedStringResource("notifications.mentionsMe", bundle: bundle)
        public static let roomMentions = LocalizedStringResource("notifications.roomMentions", bundle: bundle)

        public static let other = LocalizedStringResource("notifications.other", bundle: bundle)
        public static let invitations = LocalizedStringResource("notifications.invitations", bundle: bundle)
        public static let calls = LocalizedStringResource("notifications.calls", bundle: bundle)
        public static let otherFooter = LocalizedStringResource("notifications.otherFooter", bundle: bundle)

        /// Whether the system is letting anything through at all, said before the rules rather
        /// than after them. Every switch below is about what the *server* sends; none of it
        /// reaches the screen if the system is holding the door shut, and a person who refused
        /// the permission once would otherwise spend a while adjusting rules that cannot fire.
        public static let system = LocalizedStringResource("notifications.system", bundle: bundle)
        public static let systemOn = LocalizedStringResource("notifications.systemOn", bundle: bundle)
        public static let systemOff = LocalizedStringResource("notifications.systemOff", bundle: bundle)
        public static let systemUnknown = LocalizedStringResource("notifications.systemUnknown", bundle: bundle)
        public static let openSystem = LocalizedStringResource("notifications.openSystem", bundle: bundle)
        public static let systemFooter = LocalizedStringResource("notifications.systemFooter", bundle: bundle)

        /// The rules could not be read. Not the same as "everything is off", and the difference
        /// is the whole of what the reader needs: nothing here has been changed, and the screen
        /// is not describing their account.
        public static let failed = LocalizedStringResource("notifications.failed", bundle: bundle)
    }

    /// Folders of chats — tabs over the list, and the screen that makes them. See `ChatFolder`.
    public enum Folders {
        public static let all = LocalizedStringResource("folders.all", bundle: bundle)
        public static let title = LocalizedStringResource("folders.title", bundle: bundle)
        public static let explanation = LocalizedStringResource("folders.explanation", bundle: bundle)
        public static let new = LocalizedStringResource("folders.new", bundle: bundle)
        public static let suggested = LocalizedStringResource("folders.suggested", bundle: bundle)
        public static let add = LocalizedStringResource("folders.add", bundle: bundle)
        public static let edit = LocalizedStringResource("folders.edit", bundle: bundle)
        public static let namePlaceholder = LocalizedStringResource("folders.namePlaceholder", bundle: bundle)
        public static let kindsHeader = LocalizedStringResource("folders.kindsHeader", bundle: bundle)
        public static func kind(_ kind: ChatFolder.Kind) -> LocalizedStringResource {
            switch kind {
            case .direct: LocalizedStringResource("folders.kind.direct", bundle: bundle)
            case .groups: LocalizedStringResource("folders.kind.groups", bundle: bundle)
            case .spaces: LocalizedStringResource("folders.kind.spaces", bundle: bundle)
            case .invitations: LocalizedStringResource("folders.kind.invitations", bundle: bundle)
            }
        }
        public static func suggestion(_ suggestion: ChatFolder.Suggestion) -> LocalizedStringResource {
            switch suggestion {
            case .personal: LocalizedStringResource("folders.kind.direct", bundle: bundle)
            case .groups: LocalizedStringResource("folders.kind.groups", bundle: bundle)
            case .unread: LocalizedStringResource("folders.suggestion.unread", bundle: bundle)
            }
        }
        public static let conditionsHeader = LocalizedStringResource("folders.conditionsHeader", bundle: bundle)
        public static let onlyUnread = LocalizedStringResource("folders.onlyUnread", bundle: bundle)
        public static let excludesMuted = LocalizedStringResource("folders.excludesMuted", bundle: bundle)
        public static let includesArchived = LocalizedStringResource("folders.includesArchived", bundle: bundle)
        public static let includedHeader = LocalizedStringResource("folders.includedHeader", bundle: bundle)
        public static let excludedHeader = LocalizedStringResource("folders.excludedHeader", bundle: bundle)
        public static let addChats = LocalizedStringResource("folders.addChats", bundle: bundle)
        public static let chooseChats = LocalizedStringResource("folders.chooseChats", bundle: bundle)
        public static let editList = LocalizedStringResource("folders.editList", bundle: bundle)
        public static let done = LocalizedStringResource("folders.done", bundle: bundle)
        public static let cancel = LocalizedStringResource("folders.cancel", bundle: bundle)
        public static let delete = LocalizedStringResource("folders.delete", bundle: bundle)
        public static func deleteQuestion(_ name: String) -> LocalizedStringResource {
            LocalizedStringResource("folders.deleteQuestion", defaultValue: "\(name)", bundle: bundle)
        }
        public static let deleteHelp = LocalizedStringResource("folders.deleteHelp", bundle: bundle)
        public static let addToFolder = LocalizedStringResource("folders.addToFolder", bundle: bundle)
        public static let membershipTitle = LocalizedStringResource("folders.membershipTitle", bundle: bundle)
        public static let membershipFooter = LocalizedStringResource("folders.membershipFooter", bundle: bundle)
        public static let emptyTitle = LocalizedStringResource("folders.emptyTitle", bundle: bundle)
        public static let emptyMessage = LocalizedStringResource("folders.emptyMessage", bundle: bundle)
    }

    public enum RoomList {
        public static let title = LocalizedStringResource("roomList.title", bundle: bundle)
        public static let searchPrompt = LocalizedStringResource("roomList.searchPrompt", bundle: bundle)
        public static let clearSearch = LocalizedStringResource("roomList.clearSearch", bundle: bundle)
        /// The title while the list is catching up, and while there is no network — see
        /// `RoomListStatus`.
        public static let updating = LocalizedStringResource("roomList.updating", bundle: bundle)
        public static let waitingForNetwork = LocalizedStringResource("roomList.waitingForNetwork", bundle: bundle)
        public static let emptyTitle = LocalizedStringResource("roomList.emptyTitle", bundle: bundle)
        public static let emptyMessage = LocalizedStringResource("roomList.emptyMessage", bundle: bundle)
        public static let privateChat = LocalizedStringResource("roomList.privateChat", bundle: bundle)
        public static let pinned = LocalizedStringResource("roomList.pinned", bundle: bundle)
        /// A chat's unsent words, in place of its last message.
        public static func draft(_ text: String) -> LocalizedStringResource {
            LocalizedStringResource("roomList.draft", defaultValue: "Draft: \(text)", bundle: bundle)
        }

        /// The headings of the native macOS sidebar, and of nowhere else.
        ///
        /// The app's own list is deliberately unsorted — it shows the conversations in the order
        /// the server puts them in, most recent first, which is the order a chat app is read in.
        /// A *sidebar* is a different thing: it is a place things are filed, every Mac app files
        /// them, and a sidebar that refused to would look broken rather than principled. So the
        /// headings exist only where the sidebar does. See `BetaFeatures.nativeSidebarKey`.
        public enum Sidebar {
            public static let invitations = LocalizedStringResource("roomList.section.invitations", bundle: bundle)
            public static let spaces = LocalizedStringResource("roomList.section.spaces", bundle: bundle)
            public static let pinned = LocalizedStringResource("roomList.section.pinned", bundle: bundle)
            public static let chats = LocalizedStringResource("roomList.section.chats", bundle: bundle)
        }

        /// A room somebody has asked you into, and the two answers to it.
        ///
        /// Written to be true of anybody, for the same reason every sentence in `RoomEvent` is:
        /// Matrix does not know anyone's gender and Russian very much does. "Приглашает" is the
        /// same word whoever is doing the inviting; "пригласила" would be a coin flip on every
        /// name in every room.
        public enum Invite {
            /// The label on the row, where we know who asked.
            public static func from(_ person: String) -> LocalizedStringResource {
                LocalizedStringResource("roomList.invite.from",
                                        defaultValue: "\(person) invites you",
                                        bundle: bundle)
            }

            /// And where we do not — `RoomInfo.inviter` is genuinely optional, even for an
            /// invitation: the SDK says so, and it happens when the invite event itself is not in
            /// the store. "You have been invited" is still the whole of what the user needs.
            public static let unattributed = LocalizedStringResource("roomList.invite.unattributed", bundle: bundle)

            public static let accept = LocalizedStringResource("roomList.invite.accept", bundle: bundle)
            public static let decline = LocalizedStringResource("roomList.invite.decline", bundle: bundle)
        }

        /// The "+" in the top-left corner, and the two things it can start.
        public static let newConversation = LocalizedStringResource("roomList.newConversation", bundle: bundle)
        public static let newChat = LocalizedStringResource("roomList.newChat", bundle: bundle)
        public static let newRoom = LocalizedStringResource("roomList.newRoom", bundle: bundle)

        /// The screen behind them. Its fields are borrowed from the room-info screen — a
        /// name is a name — so only the two verbs are new, and they are two verbs rather
        /// than one because you *create* a room and you *start* a conversation with a
        /// person, and the button ought to say which of those is about to happen.
        public enum New {
            public static let create = LocalizedStringResource("roomList.new.create", bundle: bundle)
            /// What "open chat" costs, said once, where the switch is. Encryption is not a
            /// switch of its own in this app — see `UserSession.createRoom`.
            public static let openMeansUnencrypted = LocalizedStringResource("roomList.new.openMeansUnencrypted",
                                                                             bundle: bundle)
            /// Under the "open to anyone" switch on the new-room screen: what the room will be.
            public static let willBeEncrypted = LocalizedStringResource("roomList.new.willBeEncrypted", bundle: bundle)
            public static let willNotBeEncrypted = LocalizedStringResource("roomList.new.willNotBeEncrypted", bundle: bundle)

            /// "New chat", Telegram's way: one field to find a person by, three ways into a room
            /// beneath it, then everybody there is already a conversation with.
            public static let searchPrompt = LocalizedStringResource("roomList.new.searchPrompt", bundle: bundle)
            public static let createRoom = LocalizedStringResource("roomList.new.createRoom", bundle: bundle)
            public static let publicRooms = LocalizedStringResource("roomList.new.publicRooms", bundle: bundle)
            public static let joinByAddress = LocalizedStringResource("roomList.new.joinByAddress", bundle: bundle)
            /// The two halves of a search: people already written to, and people the server knows.
            public static let yourChats = LocalizedStringResource("roomList.new.yourChats", bundle: bundle)
            public static let onServer = LocalizedStringResource("roomList.new.onServer", bundle: bundle)
            /// Under a Matrix ID typed in full that the directory did not turn up — still somebody
            /// you can write to.
            public static let writeTo = LocalizedStringResource("roomList.new.writeTo", bundle: bundle)
            public static let nobodyFound = LocalizedStringResource("roomList.new.nobodyFound", bundle: bundle)
            public static let searchFailed = LocalizedStringResource("roomList.new.searchFailed", bundle: bundle)

            /// The public room directory.
            public static let roomsPrompt = LocalizedStringResource("roomList.new.roomsPrompt", bundle: bundle)
            public static let inviteOnly = LocalizedStringResource("roomList.new.inviteOnly", bundle: bundle)
            public static let noRooms = LocalizedStringResource("roomList.new.noRooms", bundle: bundle)
            public static let directoryFailed = LocalizedStringResource("roomList.new.directoryFailed", bundle: bundle)
            public static let retry = LocalizedStringResource("roomList.new.retry", bundle: bundle)

            /// Joining a room by its address.
            public static let join = LocalizedStringResource("roomList.new.join", bundle: bundle)
            public static let addressPlaceholder = LocalizedStringResource("roomList.new.addressPlaceholder", bundle: bundle)
            public static let addressHelp = LocalizedStringResource("roomList.new.addressHelp", bundle: bundle)
        }

        /// Pluralised. Russian needs one/few/many, which is why these go through the
        /// catalog's plural rules rather than through string interpolation.
        public static func unread(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("roomList.unread", defaultValue: "\(count) unread", bundle: bundle)
        }

        /// Unread, with nothing to count — a muted chat, or one flagged unread by hand. The
        /// counted sentence would have said "0 unread" here, which is the opposite of true.
        public static let hasUnread = LocalizedStringResource("roomList.hasUnread", bundle: bundle)

        public static func mentions(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("roomList.mentions", defaultValue: "\(count) mentioning you", bundle: bundle)
        }

        /// Reactions nobody has seen yet — the heart beside a chat's badge, for VoiceOver.
        public static func reactions(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("roomList.reactions", defaultValue: "\(count) new reactions", bundle: bundle)
        }

        /// The swipe actions on a chat row, and their VoiceOver twins. Each verb has both
        /// directions where it toggles, so the label always says what the *next* press does.
        public enum Swipe {
            public static let markRead = LocalizedStringResource("roomList.swipe.markRead", bundle: bundle)
            public static let markUnread = LocalizedStringResource("roomList.swipe.markUnread", bundle: bundle)
            public static let pin = LocalizedStringResource("roomList.swipe.pin", bundle: bundle)
            public static let unpin = LocalizedStringResource("roomList.swipe.unpin", bundle: bundle)
            public static let archive = LocalizedStringResource("roomList.swipe.archive", bundle: bundle)
            public static let unarchive = LocalizedStringResource("roomList.swipe.unarchive", bundle: bundle)
            /// "Delete" to the user, `room.leave()` to Matrix — you cannot delete a shared room, only
            /// take yourself out of it. The confirmation says as much, because leaving is not undoable.
            public static let delete = LocalizedStringResource("roomList.swipe.delete", bundle: bundle)
            public static let leaveConfirmTitle = LocalizedStringResource("roomList.swipe.leaveConfirmTitle", bundle: bundle)
            public static let leaveConfirmMessage = LocalizedStringResource("roomList.swipe.leaveConfirmMessage", bundle: bundle)
            public static let leaveConfirm = LocalizedStringResource("roomList.swipe.leaveConfirm", bundle: bundle)
            public static let cancel = LocalizedStringResource("roomList.swipe.cancel", bundle: bundle)
        }

        /// The look inside a chat that a long press on its row opens — see `ChatPeek`. Worded as
        /// menu items rather than as swipe buttons: there is room here for the whole verb.
        public enum Peek {
            /// The Mac's way in, from the right-click menu, where there is no long press.
            public static let peek = LocalizedStringResource("roomList.peek.peek", bundle: bundle)
            public static let open = LocalizedStringResource("roomList.peek.open", bundle: bundle)
            public static let markRead = LocalizedStringResource("roomList.peek.markRead", bundle: bundle)
            public static let markUnread = LocalizedStringResource("roomList.peek.markUnread", bundle: bundle)
            /// Said under the name of a chat with unread messages in it, because that is the one
            /// case where somebody might hesitate to look.
            public static let staysUnread = LocalizedStringResource("roomList.peek.staysUnread", bundle: bundle)
            public static let close = LocalizedStringResource("roomList.peek.close", bundle: bundle)
        }

        /// The archive: the shelf where swept-aside chats wait, and the way back to them.
        public enum Archive {
            public static let title = LocalizedStringResource("roomList.archive.title", bundle: bundle)
            public static let emptyTitle = LocalizedStringResource("roomList.archive.emptyTitle", bundle: bundle)
            public static let emptyMessage = LocalizedStringResource("roomList.archive.emptyMessage", bundle: bundle)
        }
    }

    /// Where somebody was last seen — the line under their name in a one-to-one chat.
    ///
    /// «был(а)», not «был» — Matrix knows nothing about anyone's gender and inventing one in a
    /// sentence about them would be a strange place for this app to start guessing. The units are
    /// abbreviated («мин», «ч») because that is how the line is read at a glance, and because an
    /// abbreviation does not decline: `5 мин назад` is right where `5 минут назад` needs a plural
    /// rule and `2 минуты` to go with it. See `PresenceLabel`.
    public enum Presence {
        public static let online = LocalizedStringResource("presence.online", bundle: bundle)
        public static let justNow = LocalizedStringResource("presence.justNow", bundle: bundle)
        public static let yesterday = LocalizedStringResource("presence.yesterday", bundle: bundle)

        public static func minutesAgo(_ minutes: Int) -> LocalizedStringResource {
            LocalizedStringResource("presence.minutesAgo",
                                    defaultValue: "last seen \(minutes) min ago",
                                    bundle: bundle)
        }

        public static func hoursAgo(_ hours: Int) -> LocalizedStringResource {
            LocalizedStringResource("presence.hoursAgo",
                                    defaultValue: "last seen \(hours) hr ago",
                                    bundle: bundle)
        }

        /// A clock time, for earlier the same day.
        public static func atTime(_ time: String) -> LocalizedStringResource {
            LocalizedStringResource("presence.atTime",
                                    defaultValue: "last seen at \(time)",
                                    bundle: bundle)
        }

        /// A date, for anything older than yesterday.
        public static func at(_ date: String) -> LocalizedStringResource {
            LocalizedStringResource("presence.at",
                                    defaultValue: "last seen \(date)",
                                    bundle: bundle)
        }
    }

    /// Threads — answers kept under the message they answer. See `TimelineStore.threadRootID`.
    public enum Thread {
        public static let title = LocalizedStringResource("thread.title", bundle: bundle)
        public static let replyInThread = LocalizedStringResource("thread.replyInThread", bundle: bundle)
        public static func replies(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("thread.replies", defaultValue: "\(count) replies", bundle: bundle)
        }
    }

    public enum Room {
        /// Somebody in the room has new keys — see `IdentityChangeBanner`. Written so that no name
        /// has to be declined and nobody's gender guessed: the name stands alone before a colon.
        public enum Identity {
            public static func changedTitle(_ name: String) -> LocalizedStringResource {
                LocalizedStringResource("room.identity.changedTitle", defaultValue: "\(name): new encryption keys",
                                        bundle: bundle)
            }
            public static let changedBody = LocalizedStringResource("room.identity.changedBody", bundle: bundle)
            public static let understood = LocalizedStringResource("room.identity.understood", bundle: bundle)
            public static func violationTitle(_ name: String) -> LocalizedStringResource {
                LocalizedStringResource("room.identity.violationTitle",
                                        defaultValue: "\(name): keys no longer match the ones you verified",
                                        bundle: bundle)
            }
            public static let violationBody = LocalizedStringResource("room.identity.violationBody", bundle: bundle)
            /// Takes back a verification that no longer holds. Not "OK": it changes something.
            public static let withdraw = LocalizedStringResource("room.identity.withdraw", bundle: bundle)
            public static let failed = LocalizedStringResource("room.identity.failed", bundle: bundle)
        }

        /// The bar where the reader left off — see `UnreadDividerView`.
        public static let unreadMessages = LocalizedStringResource("room.unreadMessages", bundle: bundle)

        /// The round button in the corner that takes you to the bottom of a room you have read a
        /// long way up. Read aloud only — the arrow in it is the whole of what it says on screen.
        public static let scrollToBottom = LocalizedStringResource("room.scrollToBottom", bundle: bundle)

        /// What stands at the head of the conversation when the older messages could not be
        /// fetched — see `TimelineStore.historyIsStranded`. It has to explain rather than offer: a
        /// reader who presses a button twice and sees nothing concludes the app has lost the
        /// conversation.
        public static let earlierUnavailable = LocalizedStringResource("room.earlierUnavailable", bundle: bundle)

        /// Somebody is writing. In a one-to-one chat their name is already the title of the screen,
        /// so this does not repeat it.
        public static let typing = LocalizedStringResource("room.typing", bundle: bundle)

        /// And in a room, where it is worth knowing *who*. Gender-neutral in Russian for the same
        /// reason every sentence in `CoreStrings.RoomEvent` is — "печатает" is the same word
        /// whoever is doing it, and Matrix does not know anybody's gender.
        public static func typingBy(_ people: String) -> LocalizedStringResource {
            LocalizedStringResource("room.typingBy",
                                    defaultValue: "\(people) is typing…",
                                    bundle: bundle)
        }

        public static let composerPlaceholder = LocalizedStringResource("room.composerPlaceholder", bundle: bundle)
        /// The same field with photos waiting in it, or while a caption is being edited: the words
        /// will go under the pictures, and the field says so — see `MediaCaption`.
        public static let captionPlaceholder = LocalizedStringResource("room.captionPlaceholder", bundle: bundle)
        /// The "@" list over the composer, as VoiceOver names it.
        public static let mentionSuggestions = LocalizedStringResource("room.mentionSuggestions", bundle: bundle)
        public static let send = LocalizedStringResource("room.send", bundle: bundle)
        public static let attach = LocalizedStringResource("room.attach", bundle: bundle)

        /// Shown in place of the composer when the room's power levels do not allow posting.
        public static let readOnly = LocalizedStringResource("room.readOnly", bundle: bundle)
        public static let attachPhoto = LocalizedStringResource("room.attachPhoto", bundle: bundle)
        public static let attachFile = LocalizedStringResource("room.attachFile", bundle: bundle)

        /// Photos and videos waiting in the composer — see `PendingAttachment`.
        public static let pasteImage = LocalizedStringResource("room.pasteImage", bundle: bundle)
        public static let attachedPhoto = LocalizedStringResource("room.attachedPhoto", bundle: bundle)
        public static let attachedVideo = LocalizedStringResource("room.attachedVideo", bundle: bundle)
        public static let removeAttachment = LocalizedStringResource("room.removeAttachment", bundle: bundle)
        public static let dropToAttach = LocalizedStringResource("room.dropToAttach", bundle: bundle)
        public static let sendFailedTitle = LocalizedStringResource("room.sendFailedTitle", bundle: bundle)

        /// The picture was chosen and then could not be read — which is a failure *before*
        /// anything was sent, and must not be reported as the server refusing it.
        public static let attachmentUnreadable = LocalizedStringResource("room.attachmentUnreadable", bundle: bundle)
        public static let noRoomSelectedTitle = LocalizedStringResource("room.noRoomSelectedTitle", bundle: bundle)
        public static let noRoomSelectedMessage = LocalizedStringResource("room.noRoomSelectedMessage", bundle: bundle)

        /// A conversation with nothing in it, and one that would not open. Two different
        /// blank screens, and only one of them is a problem — see `RoomView.placeholder`.
        public static let emptyTitle = LocalizedStringResource("room.emptyTitle", bundle: bundle)
        public static let emptyMessage = LocalizedStringResource("room.emptyMessage", bundle: bundle)
        public static let loadFailedTitle = LocalizedStringResource("room.loadFailedTitle", bundle: bundle)
        public static let loadFailedMessage = LocalizedStringResource("room.loadFailedMessage", bundle: bundle)
        public static let tryAgain = LocalizedStringResource("room.tryAgain", bundle: bundle)

        /// The strip that appears above the composer when you are answering somebody, or going
        /// back to change something you wrote. Two different jobs, so two different words —
        /// they look alike and they are not the same act, and a strip that said the same thing
        /// for both would leave the user unsure which one they had started.
        public static let replyingTo = LocalizedStringResource("room.replyingTo", bundle: bundle)
        public static let editingMessage = LocalizedStringResource("room.editingMessage", bundle: bundle)
        /// Backs out of either one. The draft survives — it is the *reply* that is cancelled,
        /// not what you had begun to type.
        public static let stopReplying = LocalizedStringResource("room.stopReplying", bundle: bundle)

        /// The pinned messages: the strip at the top of the room, and the screen behind it.
        public static let pinned = LocalizedStringResource("room.pinned", bundle: bundle)
        public static let pinnedTitle = LocalizedStringResource("room.pinnedTitle", bundle: bundle)
        public static let pinnedEmpty = LocalizedStringResource("room.pinnedEmpty", bundle: bundle)
        public static let unpin = LocalizedStringResource("room.unpin", bundle: bundle)

        /// Searching inside this one conversation, as opposed to the room list's search across all
        /// of them. The button, the field, and what an empty result says.
        public static let searchInChat = LocalizedStringResource("room.searchInChat", bundle: bundle)
        public static let searchPrompt = LocalizedStringResource("room.searchPrompt", bundle: bundle)
        public static let searchClose = LocalizedStringResource("room.searchClose", bundle: bundle)
        public static let searchEmptyTitle = LocalizedStringResource("room.searchEmptyTitle", bundle: bundle)

        /// The room's shared media: a grid of pictures and videos, a list of files.
        public static let sharedMedia = LocalizedStringResource("room.sharedMedia", bundle: bundle)
        public static let sharedMediaEmptyTitle = LocalizedStringResource("room.sharedMediaEmptyTitle", bundle: bundle)
        public static let sharedMediaEmptyMessage = LocalizedStringResource("room.sharedMediaEmptyMessage", bundle: bundle)

        /// Spaces — «пространства» — the rooms grouped inside one, and the empty state of a space with
        /// nothing in it yet. The word is the plain one, never "space" the Matrix jargon.
        public static let spaceLabel = LocalizedStringResource("room.spaceLabel", bundle: bundle)
        public static let spaceEmptyTitle = LocalizedStringResource("room.spaceEmptyTitle", bundle: bundle)
        public static let spaceEmptyMessage = LocalizedStringResource("room.spaceEmptyMessage", bundle: bundle)

        /// The header above a conversation, and the screen behind it.
        public static let openDetails = LocalizedStringResource("room.openDetails", bundle: bundle)
        public static let detailsTitle = LocalizedStringResource("room.detailsTitle", bundle: bundle)
        /// The room's topic — what the room is for, written by whoever runs it.
        public static let about = LocalizedStringResource("room.about", bundle: bundle)

        /// The strip of tabs at the bottom of the info screen — what the room is made of, once you
        /// stop reading it as a conversation.
        ///
        /// Six short words, and short is the requirement rather than the style: they sit in
        /// capsules in a row, and a label that wraps turns the strip into two strips. "Кружки" is
        /// deliberately the spoken word for a round video message rather than the technical one —
        /// nobody has ever asked another person to send them a video note.
        public enum Tabs {
            public static let members = LocalizedStringResource("room.tabs.members", bundle: bundle)
            public static let media = LocalizedStringResource("room.tabs.media", bundle: bundle)
            public static let voice = LocalizedStringResource("room.tabs.voice", bundle: bundle)
            public static let videoNotes = LocalizedStringResource("room.tabs.videoNotes", bundle: bundle)
            public static let files = LocalizedStringResource("room.tabs.files", bundle: bundle)
            public static let links = LocalizedStringResource("room.tabs.links", bundle: bundle)

            /// What the switch itself is called. Never drawn — the strip is made of the six words
            /// themselves and the heading under it names the open one — but VoiceOver reads a
            /// container before its contents, and "what's in here" is a better introduction to six
            /// capsules than silence.
            public static let label = LocalizedStringResource("room.tabs.label", bundle: bundle)
        }

        /// What *you* call the person at the other end of a personal chat, as opposed to what
        /// they call themselves. Kept on this device and never sent — which is the one thing the
        /// screen has to say out loud, because a name that looks like a setting looks like a
        /// setting that syncs. See `LocalNames`.
        public enum LocalName {
            public static let header = LocalizedStringResource("room.localName.header", bundle: bundle)
            public static let help = LocalizedStringResource("room.localName.help", bundle: bundle)
            /// Names the name that comes back — "Вернуть «Anna»" — so the button says what it does.
            public static func reset(_ name: String) -> LocalizedStringResource {
                LocalizedStringResource("room.localName.reset", defaultValue: "Restore “\(name)”", bundle: bundle)
            }
        }
        public static let administrator = LocalizedStringResource("room.administrator", bundle: bundle)
        public static let moderator = LocalizedStringResource("room.moderator", bundle: bundle)

        /// Running the room. Every one of these appears only for somebody the room's own
        /// power levels allow to use it — see `RoomPermissions`, and the reason the ones
        /// that do not apply are *absent* rather than greyed out.
        /// The screen behind "Roles and permissions" on the editing screen: who runs the room, and
        /// which rung may do what.
        public enum Rules {
            public static let title = LocalizedStringResource("room.rules.title", bundle: bundle)
            public static let staffHeader = LocalizedStringResource("room.rules.staffHeader", bundle: bundle)
            public static let staffFooter = LocalizedStringResource("room.rules.staffFooter", bundle: bundle)
            public static let rulesHeader = LocalizedStringResource("room.rules.rulesHeader", bundle: bundle)
            public static let rulesFooter = LocalizedStringResource("room.rules.rulesFooter", bundle: bundle)
            public static let sendMessages = LocalizedStringResource("room.rules.sendMessages", bundle: bundle)
            public static let invite = LocalizedStringResource("room.rules.invite", bundle: bundle)
            public static let remove = LocalizedStringResource("room.rules.remove", bundle: bundle)
            public static let ban = LocalizedStringResource("room.rules.ban", bundle: bundle)
            public static let deleteOthers = LocalizedStringResource("room.rules.deleteOthers", bundle: bundle)
            public static let rename = LocalizedStringResource("room.rules.rename", bundle: bundle)
            public static let changeTopic = LocalizedStringResource("room.rules.changeTopic", bundle: bundle)
            public static let changePicture = LocalizedStringResource("room.rules.changePicture", bundle: bundle)
            /// The lowest rung that may do a thing, as a choice: plural, and "moderators" includes
            /// the administrators above them — the footer says so.
            public static let everyone = LocalizedStringResource("room.rules.everyone", bundle: bundle)
            public static let moderators = LocalizedStringResource("room.rules.moderators", bundle: bundle)
            public static let administrators = LocalizedStringResource("room.rules.administrators", bundle: bundle)
            /// Making somebody a moderator or an administrator from this screen, and the sheet that
            /// picks them.
            public static let addStaff = LocalizedStringResource("room.rules.addStaff", bundle: bundle)
            public static let appointTitle = LocalizedStringResource("room.rules.appointTitle", bundle: bundle)
            public static let nobodyToAppoint = LocalizedStringResource("room.rules.nobodyToAppoint", bundle: bundle)
            /// Taking the role away — back to an ordinary member, still in the room.
            public static let demote = LocalizedStringResource("room.rules.demote", bundle: bundle)
        }

        /// "Invite": the people picked from the contacts and the directory — see `InviteView`.
        public enum Invite {
            /// The button in the corner once somebody is ticked: "Invite (3)".
            public static func inviteCount(_ count: Int) -> LocalizedStringResource {
                LocalizedStringResource("room.invite.inviteCount",
                                        defaultValue: "Invite (\(count))",
                                        bundle: bundle)
            }
            /// Over the people ticked from a search, once the search is cleared.
            public static let chosen = LocalizedStringResource("room.invite.chosen", bundle: bundle)
            /// Under somebody who is in the room already, in place of their address.
            public static let alreadyHere = LocalizedStringResource("room.invite.alreadyHere", bundle: bundle)
            /// Under a full Matrix ID typed into the field.
            public static let byAddress = LocalizedStringResource("room.invite.byAddress", bundle: bundle)
        }

        /// Who sees the past, how the room is found, and who is kept out — the room's doors, on the
        /// edit screen. See `RoomEditView`.
        public enum Access {
            public static let historyHeader = LocalizedStringResource("room.access.historyHeader", bundle: bundle)
            public static let historyFooter = LocalizedStringResource("room.access.historyFooter", bundle: bundle)
            public static func history(_ visibility: HistoryAccess) -> LocalizedStringResource {
                switch visibility {
                case .shared: LocalizedStringResource("room.access.history.shared", bundle: bundle)
                case .invited: LocalizedStringResource("room.access.history.invited", bundle: bundle)
                case .joined: LocalizedStringResource("room.access.history.joined", bundle: bundle)
                case .worldReadable: LocalizedStringResource("room.access.history.worldReadable", bundle: bundle)
                }
            }

            public static let addressHeader = LocalizedStringResource("room.access.addressHeader", bundle: bundle)
            public static let addressPlaceholder = LocalizedStringResource("room.access.addressPlaceholder", bundle: bundle)
            public static let addressFooter = LocalizedStringResource("room.access.addressFooter", bundle: bundle)
            public static let inDirectory = LocalizedStringResource("room.access.inDirectory", bundle: bundle)
            public static func inDirectoryHelp(_ server: String) -> LocalizedStringResource {
                LocalizedStringResource("room.access.inDirectoryHelp", defaultValue: "\(server)", bundle: bundle)
            }

            /// The people the room has shut out, and the way to let them back. "Blocked", as the
            /// ban itself is called everywhere in this app.
            public static let banned = LocalizedStringResource("room.access.banned", bundle: bundle)
            public static let bannedFooter = LocalizedStringResource("room.access.bannedFooter", bundle: bundle)
            public static let unban = LocalizedStringResource("room.access.unban", bundle: bundle)
            public static func unbanQuestion(_ name: String) -> LocalizedStringResource {
                LocalizedStringResource("room.access.unbanQuestion", defaultValue: "\(name)", bundle: bundle)
            }
            public static let unbanHelp = LocalizedStringResource("room.access.unbanHelp", bundle: bundle)
        }

        public enum Manage {
            /// The name and the description, as fields rather than as labels. What the
            /// reader sees is what they can change, in place, with no "Edit" mode in front
            /// of it — a room's name is one line of text, and a whole screen state to change
            /// one line of text is a screen too many.
            public static let namePlaceholder = LocalizedStringResource("room.manage.namePlaceholder", bundle: bundle)

            /// The pencil above the chat's portrait, and the screen behind it. Shown only to
            /// somebody the room lets change something — see `RoomInfoView.canEdit`.
            public static let edit = LocalizedStringResource("room.manage.edit", bundle: bundle)
            public static let editTitle = LocalizedStringResource("room.manage.editTitle", bundle: bundle)
            /// Over the name field on that screen, where `room.about` already labels the one below it.
            public static let nameHeader = LocalizedStringResource("room.manage.nameHeader", bundle: bundle)

            /// Getting rid of a personal chat, which is the same call to the server as leaving a
            /// room and a different thing to say about it.
            ///
            /// You do not "leave" a conversation with one person — there is no group to be outside
            /// of, and nobody is told. What the button does is take the chat off this device: it
            /// goes from the list, the history goes with it, and the other person, who is not
            /// consulted, can bring an empty one back by writing again. The words have to carry
            /// that last part or the act looks more final than it is.
            public static let deleteChat = LocalizedStringResource("room.manage.deleteChat", bundle: bundle)
            public static let deleteChatQuestion = LocalizedStringResource("room.manage.deleteChatQuestion", bundle: bundle)
            public static let deleteChatHelp = LocalizedStringResource("room.manage.deleteChatHelp", bundle: bundle)
            public static let topicPlaceholder = LocalizedStringResource("room.manage.topicPlaceholder", bundle: bundle)

            /// Who may walk in. The switch is the plain-language half of the join rules —
            /// the protocol's other answers (knocking, restricted to a space) are not
            /// offered, because neither can be explained in a sentence a person recognises.
            public static let openToAnyone = LocalizedStringResource("room.manage.openToAnyone", bundle: bundle)
            public static let openToAnyoneHelp = LocalizedStringResource("room.manage.openToAnyoneHelp", bundle: bundle)

            public static let invite = LocalizedStringResource("room.manage.invite", bundle: bundle)

            public static let role = LocalizedStringResource("room.manage.role", bundle: bundle)

            /// Over the rungs on somebody's own screen.
            public static let roleHeader = LocalizedStringResource("room.manage.roleHeader", bundle: bundle)
            /// The title of the dialog a swipe opens. The person's name goes under it as the message,
            /// because a swipe can land on the wrong row and the dialog is where that is noticed.
            public static let chooseRole = LocalizedStringResource("room.manage.chooseRole", bundle: bundle)
            /// The third rung has no badge in the list — everybody is a member — but it very
            /// much needs a word in the menu that *demotes* somebody back to being one.
            public static let member = LocalizedStringResource("room.manage.member", bundle: bundle)

            /// Starting a conversation with somebody met in a room, and — where that conversation
            /// already exists — going to it instead. Two words for one button, because the button
            /// does one thing and the reader is owed which of the two it will be.
            public static let write = LocalizedStringResource("room.manage.write", bundle: bundle)
            public static let goToChat = LocalizedStringResource("room.manage.goToChat", bundle: bundle)
            public static let remove = LocalizedStringResource("room.manage.remove", bundle: bundle)
            public static let block = LocalizedStringResource("room.manage.block", bundle: bundle)
            /// Blocking is the one act here with no way back in this interface, so it is
            /// the one that asks first, by name.
            public static func blockQuestion(_ name: String) -> LocalizedStringResource {
                LocalizedStringResource("room.manage.blockQuestion",
                                        defaultValue: "Block \(name)?",
                                        bundle: bundle)
            }
            public static let blockHelp = LocalizedStringResource("room.manage.blockHelp", bundle: bundle)

            /// How loudly the room may interrupt you — the one control on this screen that
            /// everybody gets, whatever their power level. It is a rule about your own
            /// device, and the room never hears about it.
            public static let alerts = LocalizedStringResource("room.manage.alerts", bundle: bundle)

            static func alerts(_ choice: RoomAlerts) -> LocalizedStringResource {
                switch choice {
                case .all: LocalizedStringResource("room.manage.alertsAll", bundle: bundle)
                case .mentions: LocalizedStringResource("room.manage.alertsMentions", bundle: bundle)
                case .muted: LocalizedStringResource("room.manage.alertsMuted", bundle: bundle)
                }
            }

            public static let leave = LocalizedStringResource("room.manage.leave", bundle: bundle)
            public static let leaveQuestion = LocalizedStringResource("room.manage.leaveQuestion", bundle: bundle)
            public static let leaveHelp = LocalizedStringResource("room.manage.leaveHelp", bundle: bundle)

            /// Why every control on this screen is grey. Without it a disabled form is just a broken
            /// one — see `RoomInfoView`.
            public static let offline = LocalizedStringResource("room.manage.offline", bundle: bundle)

            public static let cancel = LocalizedStringResource("room.manage.cancel", bundle: bundle)
            /// The title over any refusal from the homeserver. The sentence underneath it
            /// comes from `IskraCore`, which is where the app knows *which* act failed.
        }

        /// The day divider. Only the two days people actually name have words; everything
        /// older is a date, formatted by `Date.FormatStyle` and so already in the reader's
        /// language.
        public static let today = LocalizedStringResource("room.today", bundle: bundle)
        public static let yesterday = LocalizedStringResource("room.yesterday", bundle: bundle)

        /// Pluralised: Russian needs one/few/many where English has one/other, so "2
        /// участника" and "5 участников" cannot be the same sentence with the number
        /// swapped. Lives in `Localizable.stringsdict`, which is the only file that can
        /// express that.
        public static func participants(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("room.participants", defaultValue: "\(count) participants", bundle: bundle)
        }
    }

    public enum Message {
        public static let unreadable = LocalizedStringResource("message.unreadable", bundle: bundle)
        public static let deleted = LocalizedStringResource("message.deleted", bundle: bundle)
        /// Over a forwarded message whose original sender it does not name.
        public static let forwarded = LocalizedStringResource("message.forwarded", bundle: bundle)
        /// Over a forwarded message: who wrote it in the first place.
        public static func forwardedFrom(_ name: String) -> LocalizedStringResource {
            LocalizedStringResource("message.forwardedFrom", defaultValue: "Forwarded from \(name)", bundle: bundle)
        }
        public static let unsupported = LocalizedStringResource("message.unsupported", bundle: bundle)
        /// The mark beside a message whose author went back and changed it. One word, so it can
        /// sit inside the bubble beside the text without becoming a second line.
        public static let edited = LocalizedStringResource("message.edited", bundle: bundle)

        /// The long press (right-click, on a Mac) on a message.
        /// Several messages chosen at once — the bar that takes the composer's place. See
        /// `MessageSelection`.
        /// A voice message as words — see `VoiceTranscriber`.
        public enum Transcript {
            public static let show = LocalizedStringResource("message.transcript.show", bundle: bundle)
            public static let hide = LocalizedStringResource("message.transcript.hide", bundle: bundle)
            public static let notAllowed = LocalizedStringResource("message.transcript.notAllowed", bundle: bundle)
            public static let unavailable = LocalizedStringResource("message.transcript.unavailable", bundle: bundle)
            public static let nothingHeard = LocalizedStringResource("message.transcript.nothingHeard", bundle: bundle)
            public static let failed = LocalizedStringResource("message.transcript.failed", bundle: bundle)
        }

        public enum Selection {
            public static func count(_ count: Int) -> LocalizedStringResource {
                LocalizedStringResource("message.selection.count", defaultValue: "\(count)", bundle: bundle)
            }
            public static let cancel = LocalizedStringResource("message.selection.cancel", bundle: bundle)
            public static let deleteTitle = LocalizedStringResource("message.selection.deleteTitle", bundle: bundle)
            public static let deleteMessage = LocalizedStringResource("message.selection.deleteMessage", bundle: bundle)
            public static let copied = LocalizedStringResource("message.selection.copied", bundle: bundle)
        }

        public enum Menu {
            /// "5 reactions" — the line that opens who reacted, and the title of that list.
            public static func reactors(_ count: Int) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.reactors", defaultValue: "\(count) reactions", bundle: bundle)
            }
            /// The "everybody" tab in that list, with the total.
            public static func reactorsAll(_ count: Int) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.reactorsAll", defaultValue: "All · \(count)", bundle: bundle)
            }
            public static let copy = LocalizedStringResource("message.menu.copy", bundle: bundle)
            public static let reply = LocalizedStringResource("message.menu.reply", bundle: bundle)
            public static let edit = LocalizedStringResource("message.menu.edit", bundle: bundle)
            /// One action, two words, and which one is shown says which way it goes.
            public static let pin = LocalizedStringResource("message.menu.pin", bundle: bundle)
            public static let unpin = LocalizedStringResource("message.menu.unpin", bundle: bundle)
            public static let delete = LocalizedStringResource("message.menu.delete", bundle: bundle)
            /// Deleting takes the message back for everyone and cannot be undone, so it is
            /// the one thing in this menu that asks twice.
            public static let deleteConfirmTitle = LocalizedStringResource("message.menu.deleteConfirmTitle", bundle: bundle)
            public static let deleteConfirmMessage = LocalizedStringResource("message.menu.deleteConfirmMessage", bundle: bundle)

            /// What VoiceOver says a reaction pill *will do* — which is the one thing its
            /// appearance cannot say out loud.
            public static let addReaction = LocalizedStringResource("message.menu.addReaction", bundle: bundle)
            public static let removeReaction = LocalizedStringResource("message.menu.removeReaction", bundle: bundle)
            /// The quick reaction, as a VoiceOver action — see `MessageActions.spokenActions`.
            public static func addQuick(_ emoji: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.addQuick", defaultValue: "React with \(emoji)", bundle: bundle)
            }
            public static func removeQuick(_ emoji: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.removeQuick", defaultValue: "Remove \(emoji)", bundle: bundle)
            }
            /// Opens the menu with the whole bar of emoji — the one way VoiceOver reaches the rest.
            public static let moreReactions = LocalizedStringResource("message.menu.moreReactions", bundle: bundle)

            /// Flagging somebody else's message to the moderators.
            public static let report = LocalizedStringResource("message.menu.report", bundle: bundle)

            /// Sending this message on into another room.
            public static let forward = LocalizedStringResource("message.menu.forward", bundle: bundle)
            public static let select = LocalizedStringResource("message.menu.select", bundle: bundle)

            /// Blocking the person who sent it — Matrix's ignore. Reversible from settings, so it
            /// asks once by name rather than twice.
            public static let block = LocalizedStringResource("message.menu.block", bundle: bundle)
            public static func blockConfirm(_ name: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.blockConfirm", defaultValue: "Block \(name)?", bundle: bundle)
            }
            public static let blockConfirmMessage = LocalizedStringResource("message.menu.blockConfirmMessage", bundle: bundle)

            /// What VoiceOver calls the pill itself: the emoji, and how many people left
            /// it. Pluralised, so Russian declines the people rather than the emoji.
            public static func reaction(_ key: String, _ count: Int) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.reaction",
                                        defaultValue: "\(key), \(count) people",
                                        bundle: bundle)
            }

            /// The exact moment, at the foot of the menu. The date arrives already written in
            /// the reader's language — `Date.FormatStyle` did that — so what is translated here
            /// is only the word in front of it, and where in the sentence that word goes.
            public static func sentAt(_ date: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.sentAt", defaultValue: "Sent \(date)", bundle: bundle)
            }

            /// And when somebody read it, on one of your own that has been read.
            ///
            /// Only sometimes there. A read receipt is allowed to arrive without a moment
            /// attached to it — see `Message.readAt` — and this line is not written from the
            /// clock when it does: "read" with a time on it that nobody measured is worse than
            /// the two ticks beside the bubble, which at least only claim what they know.
            public static func readAt(_ date: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.readAt", defaultValue: "Read \(date)", bundle: bundle)
            }

            /// And on a message that is gone, the other moment worth knowing.
            public static func deletedAt(_ date: String) -> LocalizedStringResource {
                LocalizedStringResource("message.menu.deletedAt", defaultValue: "Deleted \(date)", bundle: bundle)
            }

            /// What the darkened conversation behind an open menu *is*, for anybody who cannot
            /// see that it is a way out. Tapping it closes the menu; VoiceOver has no other way
            /// of being told so.
            public static let close = LocalizedStringResource("message.menu.close", bundle: bundle)
        }

        /// Watching what somebody sent.
        /// Choosing where a forwarded message goes.
        public enum Forward {
            public static let title = LocalizedStringResource("message.forward.title", bundle: bundle)
            public static let prompt = LocalizedStringResource("message.forward.prompt", bundle: bundle)
            public static let cancel = LocalizedStringResource("message.forward.cancel", bundle: bundle)
            /// The comment line and the send button at the foot of the share sheet.
            public static let comment = LocalizedStringResource("message.forward.comment", bundle: bundle)
            public static let send = LocalizedStringResource("message.forward.send", bundle: bundle)
        }

        /// A link in a message, and the question asked before it opens. The address itself is the
        /// dialog's title — the part that cannot be dressed up — so these are only the two answers.
        public enum Link {
            public static let open = LocalizedStringResource("message.link.open", bundle: bundle)
            public static let cancel = LocalizedStringResource("message.link.cancel", bundle: bundle)
        }

        /// The report form: what it is for, and how to send it. The reason is optional — a report
        /// with no words is still a report — and the copy says the moderators are who receives it,
        /// not us.
        public enum Report {
            public static let title = LocalizedStringResource("message.report.title", bundle: bundle)
            public static let explanation = LocalizedStringResource("message.report.explanation", bundle: bundle)
            public static let reasonPrompt = LocalizedStringResource("message.report.reasonPrompt", bundle: bundle)
            public static let submit = LocalizedStringResource("message.report.submit", bundle: bundle)
            public static let cancel = LocalizedStringResource("message.report.cancel", bundle: bundle)
        }

        public enum Media {
            public static let close = LocalizedStringResource("message.media.close", bundle: bundle)
            public static let share = LocalizedStringResource("message.media.share", bundle: bundle)
            /// Into the photo library. Only on iOS: on a Mac the share sheet already offers
            /// every sensible destination, and a "Save" button beside it would be a second way
            /// to do the same thing.
            public static let save = LocalizedStringResource("message.media.save", bundle: bundle)
            /// The voice message, played. VoiceOver has nothing else to go on: the control is a
            /// waveform, which is a picture of a sound and not a label.
            public static let play = LocalizedStringResource("message.media.play", bundle: bundle)
            public static let pause = LocalizedStringResource("message.media.pause", bundle: bundle)
            /// A file, opened in whatever the system thinks should open it.
            public static let openFile = LocalizedStringResource("message.media.openFile", bundle: bundle)

            /// What the bubble *is*, said aloud — for the three whose whole content is a picture
            /// or a sound and which therefore have nothing a screen reader can read.
            ///
            /// These are not decoration. A photograph and a video note are opened by a tap
            /// gesture, and a tap gesture does not exist in the accessibility tree at all: without
            /// a name and an action there was no element there to press, and no way to open either
            /// of them with VoiceOver on.
            public static let photo = LocalizedStringResource("message.media.photo", bundle: bundle)
            public static let video = LocalizedStringResource("message.media.video", bundle: bundle)
            public static let videoNote = LocalizedStringResource("message.media.videoNote", bundle: bundle)

            /// The hint on both: what pressing them does.
            public static let openFullScreen = LocalizedStringResource("message.media.openFullScreen", bundle: bundle)
            /// The video would not come down. Said on the bubble, not in an alert — there is
            /// nothing to do about it but press it again.
            public static let loadFailed = LocalizedStringResource("message.media.loadFailed", bundle: bundle)

            /// "3 of 12" — where in the room's pictures the gallery is.
            public static func counter(_ position: Int, _ total: Int) -> LocalizedStringResource {
                LocalizedStringResource("message.media.counter", defaultValue: "\(position) of \(total)", bundle: bundle)
            }
            /// A video's fifteen seconds back and forward, said aloud.
            public static let skipBack = LocalizedStringResource("message.media.skipBack", bundle: bundle)
            public static let skipForward = LocalizedStringResource("message.media.skipForward", bundle: bundle)
        }

        public enum Delivery {
            public static let sending = LocalizedStringResource("message.delivery.sending", bundle: bundle)
            public static let sent = LocalizedStringResource("message.delivery.sent", bundle: bundle)
            public static let read = LocalizedStringResource("message.delivery.read", bundle: bundle)
            public static let failed = LocalizedStringResource("message.delivery.failed", bundle: bundle)
            /// Offered only where trying again can actually work — see `SendFailure.canRetry`.
            public static let sendAgain = LocalizedStringResource("message.delivery.sendAgain", bundle: bundle)
            /// Offered where the queue stopped because a verified person no longer checks out —
            /// see `SendFailure.canSendAnyway`. A decision, and worded as one.
            public static let sendAnyway = LocalizedStringResource("message.delivery.sendAnyway", bundle: bundle)
            public static let sendAnywayFailed = LocalizedStringResource("message.delivery.sendAnywayFailed", bundle: bundle)
            /// Throws the message out of the send queue. Its own word rather than
            /// `Menu.delete`, even though both read "Удалить": that one redacts an event the
            /// whole room has already seen, this one drops a message nobody ever received.
            /// The user sees the same word because to them it *is* the same word — but the
            /// two must be free to diverge in translation without dragging each other along.
            public static let discard = LocalizedStringResource("message.delivery.discard", bundle: bundle)
            /// The cross in the ring over an attachment still going up — see `UploadRing`.
            public static let cancelUpload = LocalizedStringResource("message.delivery.cancelUpload", bundle: bundle)
        }

        /// What VoiceOver reads instead of a bubble it cannot describe.
        public enum Spoken {
            public static let you = LocalizedStringResource("message.spoken.you", bundle: bundle)
            public static let sentPhoto = LocalizedStringResource("message.spoken.sentPhoto", bundle: bundle)
            public static let sentSticker = LocalizedStringResource("message.spoken.sentSticker", bundle: bundle)

            /// The same, for a sticker whose sender described it — which most of them do, with
            /// an emoji or a word. It is the only thing that tells two stickers apart when you
            /// cannot see either of them, so it is said rather than dropped.
            public static func sentStickerNamed(_ description: String) -> LocalizedStringResource {
                LocalizedStringResource("message.spoken.sentStickerNamed",
                                        defaultValue: "a sticker, \(description)",
                                        bundle: bundle)
            }

            public static let sentVideo = LocalizedStringResource("message.spoken.sentVideo", bundle: bundle)
            public static let sentVideoNote = LocalizedStringResource("message.spoken.sentVideoNote", bundle: bundle)
            public static let sentVoice = LocalizedStringResource("message.spoken.sentVoice", bundle: bundle)
            public static let sentAudio = LocalizedStringResource("message.spoken.sentAudio", bundle: bundle)
            public static let sentFile = LocalizedStringResource("message.spoken.sentFile", bundle: bundle)
            public static let sentLocation = LocalizedStringResource("message.spoken.sentLocation", bundle: bundle)
            public static func sentPoll(_ question: String) -> LocalizedStringResource {
                LocalizedStringResource("message.spoken.sentPoll", defaultValue: "a poll, \(question)", bundle: bundle)
            }
            public static let sentUnreadable = LocalizedStringResource("message.spoken.sentUnreadable", bundle: bundle)
            public static let deletedMessage = LocalizedStringResource("message.spoken.deletedMessage", bundle: bundle)
            public static let sentUnsupported = LocalizedStringResource("message.spoken.sentUnsupported", bundle: bundle)
        }
    }

    public enum VideoNote {
        public static let title = LocalizedStringResource("videoNote.title", bundle: bundle)
        public static let holdToRecord = LocalizedStringResource("videoNote.holdToRecord", bundle: bundle)
        public static let sending = LocalizedStringResource("videoNote.sending", bundle: bundle)
        public static let needsCamera = LocalizedStringResource("videoNote.needsCamera", bundle: bundle)
        public static let noCamera = LocalizedStringResource("videoNote.noCamera", bundle: bundle)
        public static let record = LocalizedStringResource("videoNote.record", bundle: bundle)
        /// The button on the preview. Only ever shown where there is a second camera to
        /// turn to — see `VideoNoteRecorder.canFlip`.
        public static let flipCamera = LocalizedStringResource("videoNote.flipCamera", bundle: bundle)
    }

    /// The one button that records, whichever kind of message it is set to. What it says is only
    /// ever read aloud: the gesture — tap to flip, hold to record — is not one VoiceOver can
    /// perform, so it has to be a sentence and two actions instead.
    public enum Recording {
        public static let hint = LocalizedStringResource("recording.hint", bundle: bundle)
        public static let switchToVoice = LocalizedStringResource("recording.switchToVoice", bundle: bundle)
        public static let switchToVideo = LocalizedStringResource("recording.switchToVideo", bundle: bundle)
        /// On the strip, beside the clock, for both kinds of recording — as a button once the
        /// finger is off the record button, and as the target of the swipe while it is still down.
        /// One word either way; `RecordingStrip` explains why it cannot be one *button* either way.
        public static let cancel = LocalizedStringResource("recording.cancel", bundle: bundle)
        /// What the record button is called once a recording is running hands-free, and what the
        /// camera's shutter is called then too — both are showing the arrow, and both send. Read
        /// aloud only, but it has to follow the glyph rather than the mode.
        public static let send = LocalizedStringResource("recording.send", bundle: bundle)
    }

    /// Recording a spoken message. Same gestures as a round video one, and deliberately the
    /// same words for them — it is one button, set one way or the other.
    public enum Voice {
        public static let record = LocalizedStringResource("voice.record", bundle: bundle)
        public static let needsMicrophone = LocalizedStringResource("voice.needsMicrophone", bundle: bundle)
    }

    /// Sending a place.
    public enum Location {
        public static let title = LocalizedStringResource("location.title", bundle: bundle)
        public static let send = LocalizedStringResource("location.send", bundle: bundle)
        public static let cancel = LocalizedStringResource("location.cancel", bundle: bundle)
        public static let myLocation = LocalizedStringResource("location.myLocation", bundle: bundle)
        /// The third thing the "+" can attach.
        public static let attach = LocalizedStringResource("location.attach", bundle: bundle)

        /// Sharing where you are as you move — see `LiveLocationSharer`.
        public static let shareLive = LocalizedStringResource("location.shareLive", bundle: bundle)
        public static let shareLiveFor = LocalizedStringResource("location.shareLiveFor", bundle: bundle)
        public static func liveFor(minutes: Int) -> LocalizedStringResource {
            LocalizedStringResource("location.liveForMinutes", defaultValue: "\(minutes)", bundle: bundle)
        }
        public static func liveFor(hours: Int) -> LocalizedStringResource {
            LocalizedStringResource("location.liveForHours", defaultValue: "\(hours)", bundle: bundle)
        }
        public static func liveUntil(_ time: String) -> LocalizedStringResource {
            LocalizedStringResource("location.liveUntil", defaultValue: "\(time)", bundle: bundle)
        }
        public static let liveEnded = LocalizedStringResource("location.liveEnded", bundle: bundle)
        public static let liveWaiting = LocalizedStringResource("location.liveWaiting", bundle: bundle)
        public static func youAreSharing(_ time: String) -> LocalizedStringResource {
            LocalizedStringResource("location.youAreSharing", defaultValue: "\(time)", bundle: bundle)
        }
        public static let stop = LocalizedStringResource("location.stop", bundle: bundle)
    }

    /// A poll in the conversation, and the sheet that writes one.
    public enum Poll {
        /// Taking one's vote back, from the poll's menu.
        public static let retract = LocalizedStringResource("poll.retract", bundle: bundle)
        /// The small line above the question: what sort of poll it is, or that it is over.
        public static let kind = LocalizedStringResource("poll.kind", bundle: bundle)
        public static let kindAnonymous = LocalizedStringResource("poll.kindAnonymous", bundle: bundle)
        public static let ended = LocalizedStringResource("poll.ended", bundle: bundle)
        public static let multiple = LocalizedStringResource("poll.multiple", bundle: bundle)
        /// "5 votes" — counted by person, see `Poll.voters`.
        public static func voters(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("poll.voters", defaultValue: "\(count) votes", bundle: bundle)
        }
        public static let noVotes = LocalizedStringResource("poll.noVotes", bundle: bundle)
        public static let hiddenUntilEnd = LocalizedStringResource("poll.hiddenUntilEnd", bundle: bundle)
        /// VoiceOver's word for an answer this account picked.
        public static let chosen = LocalizedStringResource("poll.chosen", bundle: bundle)

        /// Closing it — the sender's item in the message menu, and the question it asks.
        public static let end = LocalizedStringResource("poll.end", bundle: bundle)
        public static let endConfirmTitle = LocalizedStringResource("poll.endConfirmTitle", bundle: bundle)
        public static let endConfirmMessage = LocalizedStringResource("poll.endConfirmMessage", bundle: bundle)

        /// The "+" item, and the sheet it opens.
        public static let attach = LocalizedStringResource("poll.attach", bundle: bundle)
        public static let newTitle = LocalizedStringResource("poll.newTitle", bundle: bundle)
        public static let question = LocalizedStringResource("poll.question", bundle: bundle)
        public static let questionPlaceholder = LocalizedStringResource("poll.questionPlaceholder", bundle: bundle)
        public static let answers = LocalizedStringResource("poll.answers", bundle: bundle)
        public static let answerPlaceholder = LocalizedStringResource("poll.answerPlaceholder", bundle: bundle)
        public static let addAnswer = LocalizedStringResource("poll.addAnswer", bundle: bundle)
        public static let removeAnswer = LocalizedStringResource("poll.removeAnswer", bundle: bundle)
        public static let settings = LocalizedStringResource("poll.settings", bundle: bundle)
        public static let allowMultiple = LocalizedStringResource("poll.allowMultiple", bundle: bundle)
        public static let anonymous = LocalizedStringResource("poll.anonymous", bundle: bundle)
        public static let anonymousFooter = LocalizedStringResource("poll.anonymousFooter", bundle: bundle)
        public static let send = LocalizedStringResource("poll.send", bundle: bundle)
        public static let cancel = LocalizedStringResource("poll.cancel", bundle: bundle)
    }

    /// The sticker sheet, the button that opens it, and adding a sticker from a conversation.
    public enum Stickers {
        public static let title = LocalizedStringResource("stickers.title", bundle: bundle)
        /// The button in the composer's field, as VoiceOver says it.
        public static let open = LocalizedStringResource("stickers.open", bundle: bundle)
        public static let close = LocalizedStringResource("stickers.close", bundle: bundle)
        public static let recent = LocalizedStringResource("stickers.recent", bundle: bundle)
        /// The account's own pack — the one a sticker is added to.
        public static let mine = LocalizedStringResource("stickers.mine", bundle: bundle)
        /// A room's pack that did not say what it is called.
        public static let roomPack = LocalizedStringResource("stickers.roomPack", bundle: bundle)
        /// The pack the app comes with — see `StickerArt`.
        public static let builtIn = LocalizedStringResource("stickers.builtIn", bundle: bundle)
        public static let emptyTitle = LocalizedStringResource("stickers.empty.title", bundle: bundle)
        /// Says how to get the first one, because the sheet itself has no way to.
        public static let emptyMessage = LocalizedStringResource("stickers.empty.message", bundle: bundle)
        public static let add = LocalizedStringResource("stickers.add", bundle: bundle)
        public static let remove = LocalizedStringResource("stickers.remove", bundle: bundle)
        /// Over a chat's pack in the sheet: keep it for every chat, not only this one.
        public static let subscribe = LocalizedStringResource("stickers.subscribe", bundle: bundle)

        /// The sticker sections of Settings → Stickers & reactions.
        public enum Settings {
            public static let sheetSection = LocalizedStringResource("stickers.settings.sheetSection", bundle: bundle)
            public static let builtIn = LocalizedStringResource("stickers.settings.builtIn", bundle: bundle)
            public static let roomPacks = LocalizedStringResource("stickers.settings.roomPacks", bundle: bundle)
            public static let mine = LocalizedStringResource("stickers.settings.mine", bundle: bundle)
            public static let roomPacksHelp = LocalizedStringResource("stickers.settings.roomPacksHelp", bundle: bundle)
            public static let subscriptionsSection = LocalizedStringResource("stickers.settings.subscriptions", bundle: bundle)
            public static let subscriptionsHelp = LocalizedStringResource("stickers.settings.subscriptionsHelp", bundle: bundle)
            public static let unsubscribe = LocalizedStringResource("stickers.settings.unsubscribe", bundle: bundle)
            public static let mineHelp = LocalizedStringResource("stickers.settings.mineHelp", bundle: bundle)
            public static let clearRecent = LocalizedStringResource("stickers.settings.clearRecent", bundle: bundle)
            public static let clearRecentHelp = LocalizedStringResource("stickers.settings.clearRecentHelp", bundle: bundle)

            /// How many stickers are in a pack. Plural, so it is in the `.stringsdict`.
            public static func count(_ count: Int) -> LocalizedStringResource {
                LocalizedStringResource("stickers.settings.count", defaultValue: "\(count) stickers", bundle: bundle)
            }
        }
    }

    /// The apology every screen shares — see `View.failureAlert`, which is the only thing
    /// that says them. They were `Room.ok` and `Room.Manage.failedTitle` until the account
    /// screens started refusing things too, and a settings alert reaching into the room's
    /// vocabulary for the word "OK" was the sign they had never belonged to the room.
    public enum Problem {
        public static let title = LocalizedStringResource("problem.title", bundle: bundle)
        public static let ok = LocalizedStringResource("problem.ok", bundle: bundle)
    }

    /// Proving this device is yours, by comparing seven pictures with a device that already is.
    ///
    /// Every word here is written around one idea and never around the cryptography behind it: the
    /// user is being asked to *look at two screens and say whether they show the same thing*. They
    /// are not being asked to understand cross-signing, and a screen that mentioned it would be
    /// asking them to.
    public enum Verification {
        public static let verify = LocalizedStringResource("verification.verify", bundle: bundle)
        public static let title = LocalizedStringResource("verification.title", bundle: bundle)

        /// Why anyone should bother — shown under the button, before it is pressed.
        public static let why = LocalizedStringResource("verification.why", bundle: bundle)

        public static let waitingTitle = LocalizedStringResource("verification.waiting.title", bundle: bundle)
        public static let waitingMessage = LocalizedStringResource("verification.waiting.message", bundle: bundle)

        /// A device of this user's, signing in and asking to be trusted — the question that starts
        /// the flow from the other end. The device's own name carries the message, so this says
        /// what the two answers *mean* rather than repeating the name back.
        public static let askedMessage = LocalizedStringResource("verification.asked.message", bundle: bundle)

        /// What to call a device whose owner never named it. Not "Unknown device", which sounds
        /// like the app failed to find something out: the account knows exactly what it is, it
        /// simply has no name, and saying so is less alarming and more true.
        public static let unnamedDevice = LocalizedStringResource("verification.unnamedDevice", bundle: bundle)

        /// The two answers to it. As with `match`/`noMatch`, neither is worded as the easy one.
        public static let mine = LocalizedStringResource("verification.mine", bundle: bundle)
        public static let notMine = LocalizedStringResource("verification.notMine", bundle: bundle)

        public static let negotiatingTitle = LocalizedStringResource("verification.negotiating.title", bundle: bundle)
        public static let negotiatingMessage = LocalizedStringResource("verification.negotiating.message", bundle: bundle)

        public static let compare = LocalizedStringResource("verification.compare", bundle: bundle)

        /// The two answers. Neither is styled as the obvious one, and neither is worded as one:
        /// "yes" is the answer that grants trust, and it is the answer somebody standing in the
        /// middle of the conversation needs the user to give without looking.
        public static let match = LocalizedStringResource("verification.match", bundle: bundle)
        public static let noMatch = LocalizedStringResource("verification.noMatch", bundle: bundle)

        public static let doneTitle = LocalizedStringResource("verification.done.title", bundle: bundle)
        public static let doneMessage = LocalizedStringResource("verification.done.message", bundle: bundle)

        public static let declinedTitle = LocalizedStringResource("verification.declined.title", bundle: bundle)
        public static let declinedMessage = LocalizedStringResource("verification.declined.message", bundle: bundle)

        /// The user was asked to trust a device and said it was not theirs. Deliberately not the
        /// same words as `declined`: that one is a verification that did not happen, and this one
        /// is a report that somebody else is signing in with this account's password. It is the
        /// only place in the app that tells the user to go and do something *outside* it.
        public static let refusedTitle = LocalizedStringResource("verification.refused.title", bundle: bundle)
        public static let refusedMessage = LocalizedStringResource("verification.refused.message", bundle: bundle)

        /// The one thing a person can actually *do* about a device that is not theirs, and until now
        /// the app named it without offering it: the sentence said "somebody else knows your
        /// password, change it now" and then presented a Close button. Advice with no door next to it
        /// is advice nobody follows — they close the sheet, mean to deal with it later, and don't.
        ///
        /// The door is the server's own sessions page, which is the only place a session can be
        /// killed (see `Settings.devices` — the FFI exports no way to do it natively). It exists only
        /// where the server hands one over, so the button appears only then.
        public static let endSession = LocalizedStringResource("verification.refused.endSession", bundle: bundle)

        public static let failedTitle = LocalizedStringResource("verification.failed.title", bundle: bundle)
        public static let failedMessage = LocalizedStringResource("verification.failed.message", bundle: bundle)

        public static let close = LocalizedStringResource("verification.close", bundle: bundle)

        /// The title over an *incoming* request, where the neutral "Verification" used to sit.
        ///
        /// It is the closest thing this app has to an alert that somebody signed in, and for a long
        /// time it did not say so: a sheet headed "Verification" showing a device name reads as a
        /// chore the app is asking for, not as news about the account. The words underneath already
        /// said what had happened; the title was the one part still being coy about it.
        ///
        /// Only on the incoming side. Asking to have *this* device trusted is not news about
        /// anything, and it keeps the plain title.
        public static let signInTitle = LocalizedStringResource("verification.signIn.title", bundle: bundle)
    }

    /// The sign-out nobody here performed — the server stopped accepting this session, because
    /// somebody ended it from another device or the account was closed.
    ///
    /// It gets a sentence of its own rather than the generic apology, and the sentence names the
    /// likely cause. A person put back on the sign-in screen without explanation will conclude the
    /// app lost their account; telling them *what* happened is the difference between a moment of
    /// irritation and an evening of doubt about where their messages went.
    public enum Session {
        public static let endedTitle = LocalizedStringResource("session.ended.title", bundle: bundle)
        public static let endedMessage = LocalizedStringResource("session.ended.message", bundle: bundle)

        /// The launch that could not reach the server. The opposite of the two above, and the
        /// distinction is the whole point: nobody has been signed out, so this must not mention
        /// signing in. See `IskraRootView.Phase.offline`.
        public static let offlineTitle = LocalizedStringResource("session.offlineTitle", bundle: bundle)
        public static let offlineMessage = LocalizedStringResource("session.offlineMessage", bundle: bundle)
        public static let tryAgain = LocalizedStringResource("session.tryAgain", bundle: bundle)

        /// The same news as `endedMessage`, about one account of several: the app has gone on to
        /// another one, and has to say whose session it was and that the rest are fine.
        public static func endedOtherMessage(_ account: String) -> LocalizedStringResource {
            LocalizedStringResource("session.endedOther.message",
                                    defaultValue: "The server stopped accepting the session for \(account).",
                                    bundle: bundle)
        }
    }

    /// More than one account on the device: the list in settings, the menu on the avatar, and
    /// adding another. See `AccountSwitcher`.
    public enum Accounts {
        public static let section = LocalizedStringResource("accounts.section", bundle: bundle)
        public static let add = LocalizedStringResource("accounts.add", bundle: bundle)
        /// Backing out of adding one, from the sign-in sheet.
        public static let cancel = LocalizedStringResource("accounts.cancel", bundle: bundle)
        /// Read out on a row of another account: what tapping it does.
        public static let switchHint = LocalizedStringResource("accounts.switchHint", bundle: bundle)
        /// Read out on the account already open.
        public static let current = LocalizedStringResource("accounts.current", bundle: bundle)

        /// The count beside a dormant account, read aloud. Written as "Unread: 3" rather than
        /// "3 unread", so that Russian needs no plural forms for a number that is shown as a digit.
        public static func unread(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("accounts.unread", defaultValue: "Unread: \(count)", bundle: bundle)
        }

        /// The sign-out button, once there is more than one account it could mean.
        public static func signOut(of account: String) -> LocalizedStringResource {
            LocalizedStringResource("accounts.signOutOf", defaultValue: "Sign out of \(account)", bundle: bundle)
        }

        /// The swipe on another account's row, and the button that confirms it.
        public static let signOutShort = LocalizedStringResource("accounts.signOut", bundle: bundle)

        /// Asked before an account that is not on screen is signed out of.
        public static func signOutTitle(of account: String) -> LocalizedStringResource {
            LocalizedStringResource("accounts.signOutTitle", defaultValue: "Sign out of \(account)?", bundle: bundle)
        }

        /// What goes with it — said before, because nothing can bring it back from here.
        public static let signOutMessage = LocalizedStringResource("accounts.signOutMessage", bundle: bundle)
    }

    public enum Account {
        /// The button in the top-right corner that opens settings — the user's avatar on
        /// iPhone, a gear in the sidebar on iPad and Mac. It is the same door either way,
        /// so it is named once.
        public static let settings = LocalizedStringResource("account.settings", bundle: bundle)
        public static let signOut = LocalizedStringResource("account.signOut", bundle: bundle)

        /// The field the name is typed into. It is the *placeholder*, so it has to read as
        /// an invitation rather than as a label — the row has no label, because the thing
        /// you are looking at is your own name.
        public static let namePlaceholder = LocalizedStringResource("account.namePlaceholder", bundle: bundle)

        /// The pencil in the corner of settings, and the screen it opens.
        ///
        /// The button has no words on it — a pencil beside a title says "change this" in every app
        /// on the phone — so `edit` is read aloud rather than drawn, and it is the whole label a
        /// blind user gets. `editTitle` names the screen it leads to, and names it as a *place*
        /// ("Your profile") rather than as an instruction: the back chevron beside it already says
        /// what leaving does, and a title that repeats the button is a screen shouting its own name.
        public static let edit = LocalizedStringResource("account.edit", bundle: bundle)
        public static let editTitle = LocalizedStringResource("account.editTitle", bundle: bundle)
        /// Over the one field on that screen. The placeholder below it invites, this one labels —
        /// they are not the same words, because a field with the same sentence twice in it looks
        /// like a mistake.
        public static let nameHeader = LocalizedStringResource("account.nameHeader", bundle: bundle)
        /// Why the field will not take anything at the moment.
        public static let editOffline = LocalizedStringResource("account.editOffline", bundle: bundle)
        /// Under the name: a new one is announced in every chat the account is in.
        public static let nameChangeNotice = LocalizedStringResource("account.nameChangeNotice", bundle: bundle)
        /// Over the Matrix ID on the same screen, and the greyed field's placeholder.
        public static let usernameHeader = LocalizedStringResource("account.usernameHeader", bundle: bundle)
        /// Under it: why the field is grey.
        public static let usernameFixed = LocalizedStringResource("account.usernameFixed", bundle: bundle)
    }

    /// The menu on a picture that can be changed — a profile's or a room's. See `EditableAvatar`.
    public enum Picture {
        /// What VoiceOver calls the picture, since its pencil has no words on it.
        public static let edit = LocalizedStringResource("picture.edit", bundle: bundle)
        public static let change = LocalizedStringResource("picture.change", bundle: bundle)
        public static let remove = LocalizedStringResource("picture.remove", bundle: bundle)
    }

    /// Getting your messages back: the screen between signing in and the conversations, and the
    /// strip in the chat list that will not let you forget about it.
    ///
    /// The whole vocabulary of this flow is one word — a *recovery code* — and it behaves like the
    /// backup code from an authenticator app, which is a thing people already understand. Nothing
    /// here says "verification", "cross-signing" or "secret storage", and nothing here should ever
    /// be made to: the person who has just signed in on a new phone does not want to learn what a
    /// megolm session is, they want to read yesterday's messages.
    public enum Recovery {
        public static let preparing = LocalizedStringResource("recovery.preparing", bundle: bundle)

        public static let creatingTitle = LocalizedStringResource("recovery.creating.title", bundle: bundle)
        public static let creatingMessage = LocalizedStringResource("recovery.creating.message", bundle: bundle)

        /// What is actually at stake, under the code, in the plainest words there are — and the tick
        /// that has to be made before the only button on that screen comes alive.
        ///
        /// These two replace "Skip". A modal with no way out is one people learn to dismiss without
        /// reading, which is why Skip existed; but the way out it offered was a *tap*, and a tap is a
        /// reflex. The tick is a claim, and it is the last honest moment to notice that you have not
        /// in fact written anything down. The warning is there so the claim is made against a full
        /// account of what it costs to be wrong.
        public static let saveWarning = LocalizedStringResource("recovery.save.warning", bundle: bundle)
        public static let saveConfirm = LocalizedStringResource("recovery.save.confirm", bundle: bundle)

        /// The question in front of every code this app destroys, and it is asked in exactly two
        /// places because there are exactly two ways to reach `resetRecoveryKey()`: the confirmation
        /// dialog in settings, and `Step.confirmNew` in the flow. There must never be a third.
        ///
        /// `keepOldCode` is the answer that used not to exist. After proving this device against
        /// another one, the app minted a replacement on the spot — but the comparison does not touch
        /// the secret storage, so the old code was never dead until the app killed it. A person who
        /// finds it in their password manager tonight can still use it, and now they are allowed to
        /// go and look.
        public static let keepOldCode = LocalizedStringResource("recovery.new.keepOld", bundle: bundle)

        /// The question the browser cannot answer.
        ///
        /// The server's approval page redirects nowhere the app is listening, so
        /// `ASWebAuthenticationSession` reports the same thing whether the user approved and closed
        /// it or closed it instead of approving. The app used to guess "approved", and guessed wrong
        /// for everybody who read what a reset costs and backed out — they got an error alert instead
        /// of the quiet nothing they had asked for. So it asks.
        public static let approveTitle = LocalizedStringResource("recovery.approve.title", bundle: bundle)
        public static let approveMessage = LocalizedStringResource("recovery.approve.message", bundle: bundle)
        /// The destructive answer, and it says what it does rather than "carry on": on the far side
        /// of this button every message the account ever received becomes permanently unreadable.
        /// It is painted red and worded as the act itself — a button labelled by its consequence is
        /// the one a person cannot press by mistake.
        public static let approveConfirm = LocalizedStringResource("recovery.approve.confirm", bundle: bundle)
        public static let approveCancel = LocalizedStringResource("recovery.approve.cancel", bundle: bundle)

        public static let newTitle = LocalizedStringResource("recovery.new.title", bundle: bundle)
        public static let newMessage = LocalizedStringResource("recovery.new.message", bundle: bundle)
        public static let newConfirm = LocalizedStringResource("recovery.new.confirm", bundle: bundle)

        public static let chooseTitle = LocalizedStringResource("recovery.choose.title", bundle: bundle)
        public static let chooseMessage = LocalizedStringResource("recovery.choose.message", bundle: bundle)
        public static let haveCode = LocalizedStringResource("recovery.choose.haveCode", bundle: bundle)
        public static let otherDevice = LocalizedStringResource("recovery.choose.otherDevice", bundle: bundle)
        public static let neither = LocalizedStringResource("recovery.choose.neither", bundle: bundle)

        public static let enterTitle = LocalizedStringResource("recovery.enter.title", bundle: bundle)
        public static let enterMessage = LocalizedStringResource("recovery.enter.message", bundle: bundle)
        public static let unlock = LocalizedStringResource("recovery.enter.unlock", bundle: bundle)
        public static let lostCode = LocalizedStringResource("recovery.enter.lost", bundle: bundle)

        public static let lostTitle = LocalizedStringResource("recovery.lost.title", bundle: bundle)
        public static let lostHasDevices = LocalizedStringResource("recovery.lost.hasDevices", bundle: bundle)

        /// The way past a screen that would otherwise be a locked room.
        ///
        /// `hasOtherDevices` is the account's answer, and the account does not know that the laptop
        /// was sold or that the other client will not open. Without this, somebody who had just said
        /// they had no other device could be shown a single button telling them to use one.
        public static let noAccessToOtherDevice = LocalizedStringResource("recovery.lost.noAccess", bundle: bundle)

        public static let aloneTitle = LocalizedStringResource("recovery.lost.alone.title", bundle: bundle)
        public static let aloneMessage = LocalizedStringResource("recovery.lost.alone.message", bundle: bundle)

        /// The sentence that keeps two different things apart, and it earns its place. Resetting an
        /// account password and getting the keys to old messages back are not the same act, and a
        /// person who believes they are will reset their password, find the messages still gone, and
        /// conclude the app is broken.
        public static let notPassword = LocalizedStringResource("recovery.lost.alone.notPassword", bundle: bundle)
        public static let startOver = LocalizedStringResource("recovery.lost.alone.start", bundle: bundle)

        public static let passwordTitle = LocalizedStringResource("recovery.password.title", bundle: bundle)
        public static let passwordMessage = LocalizedStringResource("recovery.password.message", bundle: bundle)
        public static let passwordPlaceholder = LocalizedStringResource("recovery.password.placeholder", bundle: bundle)
        public static let passwordConfirm = LocalizedStringResource("recovery.password.confirm", bundle: bundle)

        public static let bannerLocked = LocalizedStringResource("recovery.banner.locked", bundle: bundle)

        /// What the banner is *for*, said to a screen reader — which saw only the sentence and a
        /// chevron and had no way to know the strip was a button at all, let alone what pressing it
        /// would do. The sighted reader gets that from the chevron; everybody else got nothing.
        public static let bannerHint = LocalizedStringResource("recovery.banner.hint", bundle: bundle)

        /// The way out of the flow, for a screen reader. The control is an "×" and nothing else, and
        /// an unlabelled image in a button is announced as "button" — a control whose entire purpose
        /// is to be the way out, and which cannot say so.
        public static let close = LocalizedStringResource("recovery.close", bundle: bundle)
    }

    /// The state of this account's encryption, in words with no cryptography in them.
    ///
    /// Every string here is written to be read by somebody who does not know what a
    /// cross-signing key is and should not have to. The subject is never "the key" — it is
    /// "your messages", and what is at stake is whether they come back.
    public enum Encryption {
        public static let title = LocalizedStringResource("encryption.title", bundle: bundle)

        public static let on = LocalizedStringResource("encryption.on", bundle: bundle)
        public static let onHelp = LocalizedStringResource("encryption.onHelp", bundle: bundle)

        public static let off = LocalizedStringResource("encryption.off", bundle: bundle)
        public static let offHelp = LocalizedStringResource("encryption.offHelp", bundle: bundle)
        public static let protect = LocalizedStringResource("encryption.protect", bundle: bundle)

        /// Recovery is on for the account, and this device does not hold the key — so the
        /// history is *there* and unreadable. The distinction from `off` is the whole reason
        /// `HistoryProtection` has four cases.
        public static let keyNeeded = LocalizedStringResource("encryption.keyNeeded", bundle: bundle)
        public static let keyNeededHelp = LocalizedStringResource("encryption.keyNeededHelp", bundle: bundle)
        public static let keyPlaceholder = LocalizedStringResource("encryption.keyPlaceholder", bundle: bundle)
        public static let restore = LocalizedStringResource("encryption.restore", bundle: bundle)

        public static let newKey = LocalizedStringResource("encryption.newKey", bundle: bundle)
        public static let newKeyHelp = LocalizedStringResource("encryption.newKeyHelp", bundle: bundle)

        /// Shown once, when the key is made. There is no screen anywhere in the app that
        /// shows it again, and `saveKeyHelp` says so before the user taps Done.
        public static let saveKey = LocalizedStringResource("encryption.saveKey", bundle: bundle)
        public static let saveKeyHelp = LocalizedStringResource("encryption.saveKeyHelp", bundle: bundle)
        public static let copyKey = LocalizedStringResource("encryption.copyKey", bundle: bundle)
        public static let keyCopied = LocalizedStringResource("encryption.keyCopied", bundle: bundle)
        public static let saved = LocalizedStringResource("encryption.saved", bundle: bundle)

        public static let deviceUnverified = LocalizedStringResource("encryption.deviceUnverified", bundle: bundle)
    }

    /// The screen where the unfinished things are switched on — see `BetaView`.
    public enum Beta {
        /// The developers' corner of the Beta screen.
        public static let developers = LocalizedStringResource("beta.developers", bundle: bundle)
        public static let showsSource = LocalizedStringResource("beta.showsSource", bundle: bundle)
        public static let showsSourceHelp = LocalizedStringResource("beta.showsSourceHelp", bundle: bundle)
        /// The homeserver the SDK really talks to — see `UserSession.homeserverURL`.
        public static let homeserver = LocalizedStringResource("beta.homeserver", bundle: bundle)
        public static let homeserverHelp = LocalizedStringResource("beta.homeserverHelp", bundle: bundle)
        /// See `BetaFeatures.showsAllEventsKey`.
        public static let showsAllEvents = LocalizedStringResource("beta.showsAllEvents", bundle: bundle)
        public static let showsAllEventsHelp = LocalizedStringResource("beta.showsAllEventsHelp", bundle: bundle)
        public static let viewSource = LocalizedStringResource("beta.viewSource", bundle: bundle)
        public static let noSource = LocalizedStringResource("beta.noSource", bundle: bundle)
        public static let demoSignIn = LocalizedStringResource("beta.demoSignIn", bundle: bundle)
        public static let demoSignInHelp = LocalizedStringResource("beta.demoSignInHelp", bundle: bundle)
        public static func demoSignedIn(_ who: String) -> LocalizedStringResource {
            LocalizedStringResource("beta.demoSignedIn", defaultValue: "\(who)", bundle: bundle)
        }
        public static let close = LocalizedStringResource("beta.close", bundle: bundle)
        public static let title = LocalizedStringResource("beta.title", bundle: bundle)

        /// The sentence over the switches, which is the whole reason the screen is worth having:
        /// it says that nothing here is load-bearing and that changing your mind costs nothing.
        public static let intro = LocalizedStringResource("beta.intro", bundle: bundle)

        public static let nativeSidebar = LocalizedStringResource("beta.nativeSidebar", bundle: bundle)
        public static let nativeSidebarHelp = LocalizedStringResource("beta.nativeSidebarHelp", bundle: bundle)

        public static let blobatar = LocalizedStringResource("beta.blobatar", bundle: bundle)
        public static let blobatarHelp = LocalizedStringResource("beta.blobatarHelp", bundle: bundle)

        public static let blobatarForce = LocalizedStringResource("beta.blobatarForce", bundle: bundle)
        public static let blobatarForceHelp = LocalizedStringResource("beta.blobatarForceHelp", bundle: bundle)

        /// The in-process demo server — see `MockHomeserver`.
        public static let mockBackend = LocalizedStringResource("beta.mockBackend", bundle: bundle)
        public static let mockBackendHelp = LocalizedStringResource("beta.mockBackendHelp", bundle: bundle)
    }

    /// The photos-and-videos screen — see `MediaSettingsView`.
    public enum Media {
        public static let title = LocalizedStringResource("media.title", bundle: bundle)

        public static let stripMetadata = LocalizedStringResource("media.stripMetadata", bundle: bundle)

        public static let compress = LocalizedStringResource("media.compress", bundle: bundle)
        public static let compression = LocalizedStringResource("media.compression", bundle: bundle)

        public static func compressionLabel(_ level: MediaCompression) -> LocalizedStringResource {
            switch level {
            case .strong: LocalizedStringResource("media.compression.strong", bundle: bundle)
            case .balanced: LocalizedStringResource("media.compression.balanced", bundle: bundle)
            case .light: LocalizedStringResource("media.compression.light", bundle: bundle)
            }
        }

        /// The button on a picture that automatic download left alone.
        public static let download = LocalizedStringResource("media.download", bundle: bundle)
        public static let autoDownload = LocalizedStringResource("media.autoDownload", bundle: bundle)

        public static func autoDownloadLabel(_ choice: MediaAutoDownload) -> LocalizedStringResource {
            switch choice {
            case .always: LocalizedStringResource("media.autoDownload.always", bundle: bundle)
            case .wifi: LocalizedStringResource("media.autoDownload.wifi", bundle: bundle)
            case .never: LocalizedStringResource("media.autoDownload.never", bundle: bundle)
            }
        }

        public static func autoDownloadHelp(_ choice: MediaAutoDownload) -> LocalizedStringResource {
            switch choice {
            case .always: LocalizedStringResource("media.autoDownload.alwaysHelp", bundle: bundle)
            case .wifi: LocalizedStringResource("media.autoDownload.wifiHelp", bundle: bundle)
            case .never: LocalizedStringResource("media.autoDownload.neverHelp", bundle: bundle)
            }
        }
    }

    /// Settings → Security → Privacy — see `SecurityView`.
    public enum Privacy {
        public static let title = LocalizedStringResource("privacy.title", bundle: bundle)
        public static let hidePresence = LocalizedStringResource("privacy.hidePresence", bundle: bundle)
        public static let hidePresenceHelp = LocalizedStringResource("privacy.hidePresenceHelp", bundle: bundle)
        public static let hideTyping = LocalizedStringResource("privacy.hideTyping", bundle: bundle)
        public static let hideTypingHelp = LocalizedStringResource("privacy.hideTypingHelp", bundle: bundle)
    }

    /// Settings → Chats — see `ChatSettingsView`.
    public enum Chats {
        public static let title = LocalizedStringResource("chats.title", bundle: bundle)
        public static let serviceSection = LocalizedStringResource("chats.serviceSection", bundle: bundle)
        public static let hideNameChanges = LocalizedStringResource("chats.hideNameChanges", bundle: bundle)
        public static let hideMembershipChanges = LocalizedStringResource("chats.hideMembershipChanges", bundle: bundle)
        public static let serviceHelp = LocalizedStringResource("chats.serviceHelp", bundle: bundle)
        public static let keyboardSection = LocalizedStringResource("chats.keyboardSection", bundle: bundle)
        public static let commandReturn = LocalizedStringResource("chats.commandReturn", bundle: bundle)
        public static let commandReturnOnHelp = LocalizedStringResource("chats.commandReturnOnHelp", bundle: bundle)
        public static let commandReturnOffHelp = LocalizedStringResource("chats.commandReturnOffHelp", bundle: bundle)
        public static let shareSection = LocalizedStringResource("chats.shareSection", bundle: bundle)
        public static let shareAccount = LocalizedStringResource("chats.shareAccount", bundle: bundle)
        public static let shareActive = LocalizedStringResource("chats.shareActive", bundle: bundle)
        public static let shareAll = LocalizedStringResource("chats.shareAll", bundle: bundle)
        public static let shareHelp = LocalizedStringResource("chats.shareHelp", bundle: bundle)
        /// Whose chats the favourites widget shows when nothing was chosen in it.
        public static let widgetSection = LocalizedStringResource("chats.widgetSection", bundle: bundle)
        public static let widgetHelp = LocalizedStringResource("chats.widgetHelp", bundle: bundle)
        public static let namesAccount = LocalizedStringResource("chats.namesAccount", bundle: bundle)
        public static let threads = LocalizedStringResource("chats.threads", bundle: bundle)
        public static let threadsHelp = LocalizedStringResource("chats.threadsHelp", bundle: bundle)
        public static let threadsAlways = LocalizedStringResource("chats.threadsAlways", bundle: bundle)
        public static let threadsLargeRooms = LocalizedStringResource("chats.threadsLargeRooms", bundle: bundle)
        public static let threadsNever = LocalizedStringResource("chats.threadsNever", bundle: bundle)
        public static let threadsHideReplies = LocalizedStringResource("chats.threadsHideReplies", bundle: bundle)
        public static let namesAccountHelp = LocalizedStringResource("chats.namesAccountHelp", bundle: bundle)
    }

    /// A person's page — see `MemberProfileView`.
    public enum Profile {
        public static let message = LocalizedStringResource("profile.message", bundle: bundle)
        public static let share = LocalizedStringResource("profile.share", bundle: bundle)
        public static let matrixID = LocalizedStringResource("profile.matrixID", bundle: bundle)
        /// While the room's member list is still being fetched for a profile opened from the chat.
        public static let loading = LocalizedStringResource("profile.loading", bundle: bundle)
        /// The person has left the room, or was never in it.
        public static let notInRoom = LocalizedStringResource("profile.notInRoom", bundle: bundle)

        /// The tiles a personal chat adds to a person's page: finding something in the chat, and
        /// how loudly it reaches you.
        public static let search = LocalizedStringResource("profile.search", bundle: bundle)
        public static let mute = LocalizedStringResource("profile.mute", bundle: bundle)
        public static let unmute = LocalizedStringResource("profile.unmute", bundle: bundle)

        /// The account's block — Matrix's ignore — at the foot of a person's page. Not the room's
        /// ban, which is `Room.Manage.block` and only for whoever runs a group.
        public static let blockUser = LocalizedStringResource("profile.blockUser", bundle: bundle)
        public static let unblockUser = LocalizedStringResource("profile.unblockUser", bundle: bundle)

        /// What a personal chat says about a person you have blocked — on their page, and over the
        /// field where you would otherwise write to them.
        public static let blockedNotice = LocalizedStringResource("profile.blockedNotice", bundle: bundle)
    }

    /// Settings → Devices — see `DevicesView`.
    public enum Devices {
        public static let title = LocalizedStringResource("devices.title", bundle: bundle)
        public static let thisDevice = LocalizedStringResource("devices.thisDevice", bundle: bundle)
        public static let online = LocalizedStringResource("devices.online", bundle: bundle)
        public static let endOthers = LocalizedStringResource("devices.endOthers", bundle: bundle)
        public static let endOthersFooter = LocalizedStringResource("devices.endOthersFooter", bundle: bundle)
        public static let endOthersConfirm = LocalizedStringResource("devices.endOthersConfirm", bundle: bundle)
        public static let others = LocalizedStringResource("devices.others", bundle: bundle)
        public static let noOthers = LocalizedStringResource("devices.noOthers", bundle: bundle)
        public static let end = LocalizedStringResource("devices.end", bundle: bundle)
        public static let endConfirm = LocalizedStringResource("devices.endConfirm", bundle: bundle)
        public static let managedFooter = LocalizedStringResource("devices.managedFooter", bundle: bundle)
        public static let passwordTitle = LocalizedStringResource("devices.passwordTitle", bundle: bundle)
        public static let passwordMessage = LocalizedStringResource("devices.passwordMessage", bundle: bundle)
        public static let passwordField = LocalizedStringResource("devices.passwordField", bundle: bundle)
        public static let cancel = LocalizedStringResource("devices.cancel", bundle: bundle)
        public static let retry = LocalizedStringResource("devices.retry", bundle: bundle)

        /// The card for one session — see `DeviceDetailSheet`.
        public static let application = LocalizedStringResource("devices.application", bundle: bundle)
        public static let lastSeen = LocalizedStringResource("devices.lastSeen", bundle: bundle)
        public static let ipAddress = LocalizedStringResource("devices.ipAddress", bundle: bundle)
        public static let deviceID = LocalizedStringResource("devices.deviceID", bundle: bundle)
        public static let unknown = LocalizedStringResource("devices.unknown", bundle: bundle)
        public static let endSession = LocalizedStringResource("devices.endSession", bundle: bundle)
        public static let done = LocalizedStringResource("devices.done", bundle: bundle)

        /// The banner at the top of the chat list — see `NewSignInBanner`.
        public static let newSignInTitle = LocalizedStringResource("devices.newSignInTitle", bundle: bundle)
        public static func newSignInMore(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("devices.newSignInMore", defaultValue: "and \(count) more", bundle: bundle)
        }
        public static let newSignInYes = LocalizedStringResource("devices.newSignInYes", bundle: bundle)
        public static let newSignInNo = LocalizedStringResource("devices.newSignInNo", bundle: bundle)
    }

    public enum Settings {
        public static let title = LocalizedStringResource("settings.title", bundle: bundle)

        /// Only ever shown in a sidebar, where the system pushes settings without giving
        /// it a way back. On iPhone the back button is the system's and is labelled — and
        /// localized — by the system, so this string never appears there.
        public static let back = LocalizedStringResource("settings.back", bundle: bundle)

        /// The notifications screen, which for a long time was a greyed-out row promising one.
        /// See `NotificationsView`.
        public static let notifications = LocalizedStringResource("settings.notifications", bundle: bundle)

        /// See `ChatSettingsView` and `SecurityView`.
        public static let chats = LocalizedStringResource("settings.chats", bundle: bundle)

        /// What used to be called "Encryption", and was too narrow a name for what was already
        /// on it. The screen has always answered "who can get at this" rather than "is this
        /// encrypted" — which in this app is never a question, because it always is. It now also
        /// holds the devices, the Face ID lock and the bridge, which were three separate rows on
        /// the settings root asking three halves of the same question. See `SecurityView`.
        public static let security = LocalizedStringResource("settings.security", bundle: bundle)

        /// The heading *inside* that screen, over the recovery state. Still "Encryption", and
        /// deliberately: the section really is about encryption, and it is the screen around it
        /// that was misnamed.
        public static let encryption = LocalizedStringResource("settings.encryption", bundle: bundle)

        public static let appearance = LocalizedStringResource("settings.appearance", bundle: bundle)

        /// The row that leads to the emoji a double tap leaves — see `ReactionsView`. A screen of
        /// its own rather than a section of Appearance: it is what a gesture *does*, not what the
        /// app looks like, and it is the word people come looking for.
        public static let reactions = LocalizedStringResource("settings.reactions", bundle: bundle)

        /// The row that leads to the six icons — see `HomeIconPicker`. iPhone and iPad only, and
        /// the row is not drawn elsewhere, so this string is never read on a Mac.
        public static let appIcon = LocalizedStringResource("settings.appIcon", bundle: bundle)

        /// The last row, and the only one that changes nothing — see `Strings.About`.
        public static let about = LocalizedStringResource("settings.about", bundle: bundle)

        public static let storage = LocalizedStringResource("settings.storage", bundle: bundle)
        /// What happens to a photo or a video before it is sent — see `Strings.Media`.
        public static let media = LocalizedStringResource("settings.media", bundle: bundle)
        /// Where the bridge is switched on — see `Strings.Connection`.
        public static let connection = LocalizedStringResource("settings.connection", bundle: bundle)

        /// The blocked-people screen, reached from settings.
        public static let blocked = LocalizedStringResource("settings.blocked", bundle: bundle)
        public static let blockedEmptyTitle = LocalizedStringResource("settings.blockedEmptyTitle", bundle: bundle)
        public static let blockedEmptyMessage = LocalizedStringResource("settings.blockedEmptyMessage", bundle: bundle)
        public static let unblock = LocalizedStringResource("settings.unblock", bundle: bundle)

        /// The app-lock settings: the switch, the grace-period picker, and a note when the device
        /// has no lock of its own to lean on.
        public static let lock = LocalizedStringResource("settings.lock", bundle: bundle)
        public static let lockEnable = LocalizedStringResource("settings.lockEnable", bundle: bundle)
        public static let lockTimeout = LocalizedStringResource("settings.lockTimeout", bundle: bundle)
        public static let lockExplanation = LocalizedStringResource("settings.lockExplanation", bundle: bundle)
        public static let lockUnavailable = LocalizedStringResource("settings.lockUnavailable", bundle: bundle)
        public static func lockTimeoutLabel(_ timeout: AppLockTimeout) -> LocalizedStringResource {
            switch timeout {
            case .immediately: LocalizedStringResource("settings.lockTimeout.immediately", bundle: bundle)
            case .afterMinute: LocalizedStringResource("settings.lockTimeout.afterMinute", bundle: bundle)
            case .afterFiveMinutes: LocalizedStringResource("settings.lockTimeout.afterFiveMinutes", bundle: bundle)
            }
        }

        /// The app's own name, under the icon on the About screen. Not the bundle's display name
        /// and not translated: it is what the app is called, in both languages.
        public static let appName = LocalizedStringResource("settings.appName", bundle: bundle)
    }

    /// The screen behind the last row of settings: what the app is, which build of it this is,
    /// and whose code it is standing on.
    ///
    /// The licences are the part that has to be here rather than in the README. The SDK is
    /// Apache-2.0 and blobatar is MIT, and both travel with the binary — so the app itself has
    /// to say so somewhere a person holding it can read. See `LicensesView`.
    public enum About {
        public static let title = LocalizedStringResource("about.title", bundle: bundle)

        /// One sentence under the icon: what the app is.
        public static let tagline = LocalizedStringResource("about.tagline", bundle: bundle)

        /// The version people quote, `0.1.0`.
        public static let version = LocalizedStringResource("about.version", bundle: bundle)
        /// The build number, with the commit it was built from — see `AppVersion.buildWithCommit`.
        public static let build = LocalizedStringResource("about.build", bundle: bundle)
        /// Which machine, with the OS in brackets after it — the two facts a bug report is
        /// useless without, and the two nobody can answer from memory.
        public static let device = LocalizedStringResource("about.device", bundle: bundle)

        /// The app's own page. The address is shown under the label rather than hidden behind
        /// it: a link whose destination is invisible is one nobody presses.
        public static let website = LocalizedStringResource("about.website", bundle: bundle)
        /// Where the code is. Shown with its address for the same reason as `website`.
        public static let sourceCode = LocalizedStringResource("about.sourceCode", bundle: bundle)

        /// The row that leads to `LicensesView`, and that screen's title.
        public static let licences = LocalizedStringResource("about.licences", bundle: bundle)

        /// The GPL's "appropriate legal notices" (sections 0 and 5(d)): an interactive program
        /// under it has to say who holds the copyright, that it is free software under the GPL,
        /// and that there is no warranty — on a screen, not only in a file in the repository.
        public static let copyright = LocalizedStringResource("about.copyright", bundle: bundle)
        public static let freeSoftware = LocalizedStringResource("about.freeSoftware", bundle: bundle)
    }

    /// The licences screen, past the list itself — see `LicensesView`.
    public enum Licences {
        /// Over the projects Iskra is made from, below Iskra's own licence.
        public static let builtOn = LocalizedStringResource("licences.builtOn", bundle: bundle)
        /// The section 7 permission that lets the app be published in app stores at all.
        public static let storePermission = LocalizedStringResource("licences.storePermission", bundle: bundle)
        /// From the text of a licence to the project it belongs to.
        public static let projectPage = LocalizedStringResource("licences.projectPage", bundle: bundle)
    }

    /// What the app is keeping on the device, and the one part of it the user can throw away.
    ///
    /// Each kind is a name *and* a sentence, because the names alone do not answer the question
    /// somebody opens this screen with: which of these can I lose, and what does losing it cost?
    /// A row that says "Cache — 412 MB" and nothing else invites the wrong press.
    public enum Storage {
        public static let title = LocalizedStringResource("storage.title", bundle: bundle)
        public static let total = LocalizedStringResource("storage.total", bundle: bundle)
        public static let measuring = LocalizedStringResource("storage.measuring", bundle: bundle)

        public static let session = LocalizedStringResource("storage.session", bundle: bundle)
        public static let sessionExplained = LocalizedStringResource("storage.session.explained", bundle: bundle)
        public static let cache = LocalizedStringResource("storage.cache", bundle: bundle)
        public static let cacheExplained = LocalizedStringResource("storage.cache.explained", bundle: bundle)
        public static let search = LocalizedStringResource("storage.search", bundle: bundle)
        public static let searchExplained = LocalizedStringResource("storage.search.explained", bundle: bundle)

        public static let clear = LocalizedStringResource("storage.clear", bundle: bundle)
        public static let clearing = LocalizedStringResource("storage.clearing", bundle: bundle)
        public static let confirmTitle = LocalizedStringResource("storage.confirm.title", bundle: bundle)
        public static let confirmBody = LocalizedStringResource("storage.confirm.body", bundle: bundle)
        public static let confirmAction = LocalizedStringResource("storage.confirm.action", bundle: bundle)
        public static let cancel = LocalizedStringResource("storage.cancel", bundle: bundle)
        public static let failed = LocalizedStringResource("storage.failed", bundle: bundle)

        /// The button that clears the index and nothing else. It carries no footer: the row above
        /// already says what the index is, and the confirmation dialog says what clearing it costs,
        /// so a standing sentence under the button only repeated one of them.
        public static let clearSearch = LocalizedStringResource("storage.search.clear", bundle: bundle)
        public static let clearSearchTitle = LocalizedStringResource("storage.search.confirm.title", bundle: bundle)
        public static let clearSearchBody = LocalizedStringResource("storage.search.confirm.body", bundle: bundle)
        public static let clearSearchFailed = LocalizedStringResource("storage.search.failed", bundle: bundle)
    }

    /// Choosing what a double tap on a message leaves behind.
    public enum Reactions {
        public static let quick = LocalizedStringResource("reactions.quick", bundle: bundle)
        /// Names the *gesture*, not the setting: an emoji nobody knows how to send is a
        /// preference about nothing.
        public static let quickHelp = LocalizedStringResource("reactions.quickHelp", bundle: bundle)

        /// The "+" at the end of the bar of six, which opens all the rest. Said out loud only —
        /// on screen it is a plus sign, because a word there would be as wide as three emoji.
        public static let more = LocalizedStringResource("reactions.more", bundle: bundle)

        /// Closing that panel when it is a sheet on the settings screen rather than a pane
        /// hanging off a message. Over a message there is nothing to write this on — the way out
        /// is a tap anywhere else.
        public static let cancel = LocalizedStringResource("reactions.cancel", bundle: bundle)

        /// The groups the panel of every emoji is divided into — see `EmojiCatalog`. Each is a
        /// heading in the grid and the name VoiceOver gives the tab that jumps to it.
        public static let recent = LocalizedStringResource("reactions.recent", bundle: bundle)
        public static let smileys = LocalizedStringResource("reactions.smileys", bundle: bundle)
        public static let animals = LocalizedStringResource("reactions.animals", bundle: bundle)
        public static let food = LocalizedStringResource("reactions.food", bundle: bundle)
        public static let activity = LocalizedStringResource("reactions.activity", bundle: bundle)
        public static let places = LocalizedStringResource("reactions.places", bundle: bundle)
        public static let objects = LocalizedStringResource("reactions.objects", bundle: bundle)
        public static let symbols = LocalizedStringResource("reactions.symbols", bundle: bundle)
        public static let flags = LocalizedStringResource("reactions.flags", bundle: bundle)
    }

    /// Choosing which icon the app wears on the home screen — see `HomeIconPicker`.
    ///
    /// The names are the one part of this the tiles cannot say for themselves. They are things
    /// rather than colours — хром, гранат, хвоя — because "dark grey" is a description and a
    /// name is something you can ask somebody for. The rest name what the picture *is*, because
    /// that is the whole of what sets them apart: «Ретро», «Буквы», «Ч/б».
    public enum HomeIcon {

        /// When the system refuses. It does on a device where alternate icons are switched off
        /// by a management profile, and there is nothing the app can do about it beyond saying
        /// so — hence one sentence and one button.
        public static let failed = LocalizedStringResource("appIcon.failed", bundle: bundle)
        public static let failedOK = LocalizedStringResource("appIcon.failedOK", bundle: bundle)

        #if os(iOS)
        /// A `switch` with no `default`, like the appearance modes above and for the same
        /// reason: a ninth icon should stop the build rather than ship unnamed.
        ///
        /// Internal where everything around it is public, because `HomeIcon` is: the type only
        /// exists on iOS and only this module ever names one.
        static func name(_ icon: IskraFeatures.HomeIcon) -> LocalizedStringResource {
            switch icon {
            case .spark: LocalizedStringResource("appIcon.spark", bundle: bundle)
            case .chrome: LocalizedStringResource("appIcon.chrome", bundle: bundle)
            case .garnet: LocalizedStringResource("appIcon.garnet", bundle: bundle)
            case .pine: LocalizedStringResource("appIcon.pine", bundle: bundle)
            case .rio: LocalizedStringResource("appIcon.rio", bundle: bundle)
            case .blackWhite: LocalizedStringResource("appIcon.blackWhite", bundle: bundle)
            case .retro: LocalizedStringResource("appIcon.retro", bundle: bundle)
            case .letters: LocalizedStringResource("appIcon.letters", bundle: bundle)
            }
        }
        #endif
    }

    /// Choosing what the app is painted in.
    public enum Appearance {
        public static let theme = LocalizedStringResource("appearance.theme", bundle: bundle)
        /// The heading over the faces picker — the same question the first run asks.
        public static let avatars = LocalizedStringResource("appearance.avatars", bundle: bundle)

        /// Light, dark, or the system's own. A `switch` with no `default`, for the same reason
        /// the colours below have none: a fourth mode should stop the build, not ship unnamed.
        public static func mode(_ mode: AppearanceMode) -> LocalizedStringResource {
            switch mode {
            case .system: LocalizedStringResource("appearance.mode.system", bundle: bundle)
            case .light: LocalizedStringResource("appearance.mode.light", bundle: bundle)
            case .dark: LocalizedStringResource("appearance.mode.dark", bundle: bundle)
            }
        }

        /// The switch that turns the plain column on or off — see `MessageLayout.compact`.
        public static let compact = LocalizedStringResource("appearance.compact", bundle: bundle)

        public static let accent = LocalizedStringResource("appearance.accent", bundle: bundle)

        /// The switch that washes the accent across the whole interface — see
        /// `AccentTheme.tintsInterfaceKey`.
        public static let tintInterface = LocalizedStringResource("appearance.tintInterface", bundle: bundle)

        /// What lies behind a conversation — see `Wallpaper`.
        public static let wallpaper = LocalizedStringResource("appearance.wallpaper", bundle: bundle)
        public static let wallpaperDimming = LocalizedStringResource("appearance.wallpaperDimming", bundle: bundle)
        public static let wallpaperChoose = LocalizedStringResource("appearance.wallpaperChoose", bundle: bundle)

        /// The name of a wallpaper, which is the only thing a picture can be read out as. A
        /// `switch` with no `default`, for the same reason the colours below have none: a seventh
        /// gradient should stop the build rather than ship unnamed.
        public static func wallpaperName(_ wallpaper: Wallpaper) -> LocalizedStringResource {
            switch wallpaper {
            case .none: LocalizedStringResource("appearance.wallpaper.none", bundle: bundle)
            case .sunset: LocalizedStringResource("appearance.wallpaper.sunset", bundle: bundle)
            case .sea: LocalizedStringResource("appearance.wallpaper.sea", bundle: bundle)
            case .forest: LocalizedStringResource("appearance.wallpaper.forest", bundle: bundle)
            case .dusk: LocalizedStringResource("appearance.wallpaper.dusk", bundle: bundle)
            case .sand: LocalizedStringResource("appearance.wallpaper.sand", bundle: bundle)
            case .night: LocalizedStringResource("appearance.wallpaper.night", bundle: bundle)
            case .photo: LocalizedStringResource("appearance.wallpaper.photo", bundle: bundle)
            }
        }

        /// Four lines of a conversation that never happened, so that a colour can be judged as
        /// what it will actually be — the fill behind everything the user ever says — rather than
        /// as a circle on a settings screen. The second one is theirs, and is the one painted.
        public static let previewAsk = LocalizedStringResource("appearance.previewAsk", bundle: bundle)
        public static let previewAnswer = LocalizedStringResource("appearance.previewAnswer", bundle: bundle)
        public static let previewReply = LocalizedStringResource("appearance.previewReply", bundle: bundle)

        /// A second line from the same person, so that the preview contains a *run*. Without one
        /// there is nothing for the compact layout's header to sit over, and the preview would
        /// fail to show the one thing that layout does.
        public static let previewFollowUp = LocalizedStringResource("appearance.previewFollowUp", bundle: bundle)

        /// Who the other person in the invented conversation is. The bubbles never say — the side
        /// of the screen does — and the compact column has nothing else to say it with. The
        /// reader's own line borrows `Message.Spoken.you` rather than a second word meaning the
        /// same thing.
        public static let previewSender = LocalizedStringResource("appearance.previewSender", bundle: bundle)

        /// What the whole little exchange is called, for VoiceOver, which should hear one thing
        /// and not be walked through an invented conversation on its way to the colours.
        public static let previewLabel = LocalizedStringResource("appearance.previewLabel", bundle: bundle)

        /// The name of a colour, which is the only thing a swatch can be read out as: a
        /// circle of colour has nothing for VoiceOver to say, and "button" is not an answer.
        ///
        /// A `switch` with no `default`, deliberately. An eighth colour added to
        /// `AccentTheme` should stop the build here, rather than ship as a swatch nobody
        /// can name.
        public static func color(_ theme: AccentTheme) -> LocalizedStringResource {
            switch theme {
            case .red: LocalizedStringResource("appearance.color.red", bundle: bundle)
            case .orange: LocalizedStringResource("appearance.color.orange", bundle: bundle)
            case .yellow: LocalizedStringResource("appearance.color.yellow", bundle: bundle)
            case .green: LocalizedStringResource("appearance.color.green", bundle: bundle)
            case .cyan: LocalizedStringResource("appearance.color.cyan", bundle: bundle)
            case .blue: LocalizedStringResource("appearance.color.blue", bundle: bundle)
            case .violet: LocalizedStringResource("appearance.color.violet", bundle: bundle)
            case .mono: LocalizedStringResource("appearance.color.mono", bundle: bundle)
            }
        }
    }

    /// The editor a waiting photo opens into from the pencil on its tile — see `PhotoEditor`.
    public enum PhotoEditor {
        /// The pencil on the tile, as VoiceOver names it.
        public static let edit = LocalizedStringResource("photoEditor.edit", bundle: bundle)
        public static let cancel = LocalizedStringResource("photoEditor.cancel", bundle: bundle)
        public static let done = LocalizedStringResource("photoEditor.done", bundle: bundle)
        public static let undo = LocalizedStringResource("photoEditor.undo", bundle: bundle)
        public static let draw = LocalizedStringResource("photoEditor.draw", bundle: bundle)
        public static let text = LocalizedStringResource("photoEditor.text", bundle: bundle)
        public static let crop = LocalizedStringResource("photoEditor.crop", bundle: bundle)
        public static let rotate = LocalizedStringResource("photoEditor.rotate", bundle: bundle)
        public static let textPrompt = LocalizedStringResource("photoEditor.textPrompt", bundle: bundle)
        public static let failed = LocalizedStringResource("photoEditor.failed", bundle: bundle)
        public static let ok = LocalizedStringResource("photoEditor.ok", bundle: bundle)
        /// The colours, as VoiceOver names them.
        public static let white = LocalizedStringResource("photoEditor.white", bundle: bundle)
        public static let black = LocalizedStringResource("photoEditor.black", bundle: bundle)
        public static let red = LocalizedStringResource("photoEditor.red", bundle: bundle)
        public static let yellow = LocalizedStringResource("photoEditor.yellow", bundle: bundle)
        public static let green = LocalizedStringResource("photoEditor.green", bundle: bundle)
        public static let blue = LocalizedStringResource("photoEditor.blue", bundle: bundle)
    }

    /// QR codes: the one that says who you are (or what a room is), and the camera that reads
    /// somebody else's. What is in the code is a `matrix.to` link — see `MatrixLink`.
    public enum QR {
        public static let title = LocalizedStringResource("qr.title", bundle: bundle)
        public static let scan = LocalizedStringResource("qr.scan", bundle: bundle)
        public static let scanHint = LocalizedStringResource("qr.scanHint", bundle: bundle)
        /// A code that is not a person or a room — a menu, a Wi-Fi password.
        public static let notMatrix = LocalizedStringResource("qr.notMatrix", bundle: bundle)
        public static let choosePicture = LocalizedStringResource("qr.choosePicture", bundle: bundle)
        public static let noCamera = LocalizedStringResource("qr.noCamera", bundle: bundle)
        public static let nothingFound = LocalizedStringResource("qr.nothingFound", bundle: bundle)
        /// A room a link pointed at: walk in, or — if you are in it already — open it.
        public static let joinRoom = LocalizedStringResource("qr.joinRoom", bundle: bundle)
        public static let openRoom = LocalizedStringResource("qr.openRoom", bundle: bundle)
        public static let roomUnknown = LocalizedStringResource("qr.roomUnknown", bundle: bundle)
        public static let inviteOnlyRoom = LocalizedStringResource("qr.inviteOnlyRoom", bundle: bundle)
    }
}

extension String {
    /// Resolves a feature string for the current locale.
    init(app resource: LocalizedStringResource) {
        self.init(localized: resource)
    }

}
