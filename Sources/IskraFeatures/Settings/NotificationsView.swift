import SwiftUI
import UserNotifications
import IskraCore
import IskraDesign

#if os(iOS)
import UIKit
#endif

/// What the account notifies about, before any one chat has an opinion.
///
/// This row existed for a long time as a greyed-out label with a footer promising a screen. The
/// promise is kept here, and the thing it turns out to be is not a list of device preferences: the
/// rules live on the homeserver, so everything on this screen is about the *account* and reaches
/// every client signed into it. See `NotificationRulesStore`, which says why the two defaults are
/// written to four push rules.
///
/// The permission comes first, above the rules, and that order is the point. Every switch below
/// decides what the server sends; none of it arrives if the system is holding the door shut. A
/// person who tapped "Don't Allow" months ago would otherwise sit here turning things on and
/// hearing nothing, with no line on the screen explaining why — which is the shape of an app that
/// looks broken while working perfectly.
struct NotificationsView: View {
    /// Built by the screen that pushes this one, and owned by it — the store holds an SDK
    /// `NotificationSettings` with a listener registration behind it, so it is made when this
    /// screen is opened rather than carried by the session for the lifetime of the app.
    let rules: NotificationRulesStore

    /// Whether the system is letting anything through. Read on appearance and again when the app
    /// comes back — a trip to Settings to switch notifications on is precisely the journey this
    /// row invites, and a status that still said "blocked" on return would be the screen arguing
    /// with something the user had just done.
    @State private var permission: UNAuthorizationStatus = .notDetermined

    @Environment(\.scenePhase) private var phase
    @Environment(\.isOffline) private var isOffline

    var body: some View {
        Form {
            systemPermission

            if rules.didFailToLoad {
                Section {
                    Text(Strings.Notifications.failed)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if !rules.isLoaded {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else {
                defaults
                mentions
                everythingElse
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Notifications.title))
        .toolbarTitleDisplayMode(.inline)
        .task {
            await readPermission()
            await rules.load()
        }
        .onChange(of: phase) { _, new in
            guard new == .active else { return }
            Task { await readPermission() }
        }
        // `Bindable`, not `$rules` — the store is a plain `let` here, exactly as on every other
        // screen in this app that holds one it does not own.
        .failureAlert(Bindable(rules).failure)
    }

    /// The system's answer, and — when it is no — the one thing this app can do about it, which is
    /// to open the page where it can be changed. It cannot ask again: iOS asks once per install,
    /// and after a refusal `requestAuthorization` returns false without showing anything. A button
    /// labelled "Allow notifications" that silently does nothing is worse than a button that takes
    /// you where the switch actually is.
    @ViewBuilder
    private var systemPermission: some View {
        Section {
            Label {
                Text(permissionExplanation)
            } icon: {
                Image(systemName: permissionIcon)
                    .foregroundStyle(permissionColor)
            }

            #if os(iOS)
            if permission == .denied {
                Button {
                    open()
                } label: {
                    LabeledContent {
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(Strings.Notifications.openSystem)
                    }
                }
            }
            #endif
        } header: {
            Text(Strings.Notifications.system)
        } footer: {
            // Only where it is true. Under an allowed permission this sentence would be a warning
            // about nothing, sitting at the top of the screen where the eye lands first.
            if permission == .denied {
                Text(Strings.Notifications.systemFooter)
            }
        }
    }

    /// The two questions people actually have: how loud are my personal chats, and how loud is
    /// everything else.
    private var defaults: some View {
        Section {
            picker(Strings.Notifications.direct, isOneToOne: true)
            picker(Strings.Notifications.groups, isOneToOne: false)
        } header: {
            Text(Strings.Notifications.defaults)
        } footer: {
            Text(Strings.Notifications.defaultsFooter)
        }
    }

    private var mentions: some View {
        Section {
            toggle(Strings.Notifications.mentionsMe,
                   isOn: rules.mentionsMe) { await rules.setMentionsMe($0) }

            toggle(Strings.Notifications.roomMentions,
                   isOn: rules.roomMentions) { await rules.setRoomMentions($0) }
        } header: {
            Text(Strings.Notifications.mentions)
        } footer: {
            Text(Strings.Notifications.mentionsFooter)
        }
    }

    private var everythingElse: some View {
        Section {
            toggle(Strings.Notifications.invitations,
                   isOn: rules.invitations) { await rules.setInvitations($0) }

            toggle(Strings.Notifications.calls,
                   isOn: rules.calls) { await rules.setCalls($0) }
        } header: {
            Text(Strings.Notifications.other)
        } footer: {
            Text(Strings.Notifications.otherFooter)
        }
    }

    /// The same three answers a single chat is given on its own info screen, in the same words —
    /// `Room.Manage.alerts`. Shared on purpose: "Only mentions" here and something else there
    /// would make two settings that do the same thing look like two different settings.
    private func picker(_ title: LocalizedStringResource, isOneToOne: Bool) -> some View {
        Picker(selection: Binding(get: { isOneToOne ? rules.directChats : rules.groupChats },
                                  set: { choice in
                                      Task { await rules.setDefault(choice, isOneToOne: isOneToOne) }
                                  })) {
            ForEach(RoomAlerts.allCases) { choice in
                Text(Strings.Room.Manage.alerts(choice)).tag(choice)
            }
        } label: {
            Text(title)
        }
        // Every one of these is a request to the homeserver, and none of them is queued. A switch
        // that moved and then silently did not take would be the worst kind of setting.
        .disabled(isOffline)
    }

    private func toggle(_ title: LocalizedStringResource,
                        isOn: Bool,
                        set: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { value in Task { await set(value) } })) {
            Text(title)
        }
        .accentControl()
        .disabled(isOffline)
    }

    private var permissionExplanation: LocalizedStringResource {
        switch permission {
        case .notDetermined: Strings.Notifications.systemUnknown
        case .denied: Strings.Notifications.systemOff
        default: Strings.Notifications.systemOn
        }
    }

    private var permissionIcon: String {
        switch permission {
        case .notDetermined: "bell.badge.slash"
        case .denied: "bell.slash.fill"
        default: "bell.fill"
        }
    }

    private var permissionColor: Color {
        switch permission {
        case .notDetermined: .secondary
        case .denied: .orange
        default: .green
        }
    }

    private func readPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    #if os(iOS)
    private func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}
