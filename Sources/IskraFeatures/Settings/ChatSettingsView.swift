import IskraCore
import IskraDesign
import SwiftUI

/// How conversations behave rather than how they look: which grey lines they keep, what Return
/// does, and — with more than one account — whose chats the share sheet offers.
///
/// Every switch is `@AppStorage` (the share choice is the App Group's, see below), read where it
/// is obeyed, so there is no "done".
struct ChatSettingsView: View {
    @AppStorage(ServiceEventSettings.hidesNameChangesKey) private var hidesNameChanges = false
    @AppStorage(ServiceEventSettings.hidesMembershipChangesKey) private var hidesMembershipChanges = false
    @AppStorage(ComposerReturnKey.sendsWithCommandReturnKey)
    private var sendsWithCommandReturn = ComposerReturnKey.sendsWithCommandReturnByDefault

    @Environment(\.accountSwitcher) private var switcher

    /// In the App Group's defaults, not `.standard` — the share extension is the one that reads it,
    /// and an extension's `.standard` is its own and empty. So it is plain state, written through.
    @State private var shareAccount = ChatDirectory.shareAccount()
    @State private var widgetAccount = ChatDirectory.widgetAccount()
    /// The same, for the notification extension — see `ChatDirectory.namesAccountInNotifications`.
    @State private var namesAccount = ChatDirectory.namesAccountInNotifications()

    /// Seeded from `ThreadSettings.shown()` rather than the bare default, so that somebody who had
    /// switched the old single toggle off sees "Never" here, which is what the rooms obey.
    @AppStorage(ThreadSettings.shownKey) private var threadsShown = ThreadSettings.shown()
    @AppStorage(ThreadSettings.hidesRepliesKey) private var hidesThreadReplies = ThreadSettings.hidesRepliesByDefault

    var body: some View {
        Form {
            // The choices inline, each a row with a tick, rather than a menu: "In chats of over 100
            // people" does not fit beside a label on a phone.
            Section {
                Picker(selection: $threadsShown) {
                    Text(Strings.Chats.threadsAlways).tag(ThreadSettings.Shown.always)
                    Text(Strings.Chats.threadsLargeRooms).tag(ThreadSettings.Shown.inLargeRooms)
                    Text(Strings.Chats.threadsNever).tag(ThreadSettings.Shown.never)
                } label: {
                    Text(Strings.Chats.threads)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(Strings.Chats.threads)
            }

            Section {
                Toggle(isOn: $hidesThreadReplies) {
                    Label(Strings.Chats.threadsHideReplies, systemImage: "bubble.left.and.text.bubble.right")
                }
                .accentControl()
                .disabled(threadsShown == .never)
            } footer: {
                Text(Strings.Chats.threadsHelp)
            }

            Section {
                Toggle(isOn: $hidesNameChanges) {
                    Label(Strings.Chats.hideNameChanges, systemImage: "character.cursor.ibeam")
                }
                .accentControl()
                Toggle(isOn: $hidesMembershipChanges) {
                    Label(Strings.Chats.hideMembershipChanges, systemImage: "person.2.badge.minus")
                }
                .accentControl()
            } header: {
                Text(Strings.Chats.serviceSection)
            } footer: {
                Text(Strings.Chats.serviceHelp)
            }

            if ComposerReturnKey.isOffered {
                Section {
                    Toggle(isOn: $sendsWithCommandReturn) {
                        Label(Strings.Chats.commandReturn, systemImage: "command")
                    }
                    .accentControl()
                } header: {
                    Text(Strings.Chats.keyboardSection)
                } footer: {
                    Text(sendsWithCommandReturn ? Strings.Chats.commandReturnOnHelp : Strings.Chats.commandReturnOffHelp)
                }
            }

            // iPhone and iPad only — the share extension is UIKit's — and only with somebody to
            // choose between.
            #if os(iOS)
            if let switcher, switcher.hasSeveral {
                Section {
                    Picker(selection: $shareAccount) {
                        Text(Strings.Chats.shareActive).tag(ChatDirectory.ShareAccount.active)
                        ForEach(switcher.accounts, id: \.sessionID) { account in
                            Text(verbatim: AccountSwitcher.name(of: account))
                                .tag(ChatDirectory.ShareAccount.account(account.sessionID))
                        }
                        Text(Strings.Chats.shareAll).tag(ChatDirectory.ShareAccount.all)
                    } label: {
                        Label(Strings.Chats.shareAccount, systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text(Strings.Chats.shareSection)
                } footer: {
                    Text(Strings.Chats.shareHelp)
                }
                .onChange(of: shareAccount) { _, choice in
                    ChatDirectory.setShareAccount(choice)
                }

                Section {
                    Picker(selection: $widgetAccount) {
                        Text(Strings.Chats.shareActive).tag(ChatDirectory.ShareAccount.active)
                        ForEach(switcher.accounts, id: \.sessionID) { account in
                            Text(verbatim: AccountSwitcher.name(of: account))
                                .tag(ChatDirectory.ShareAccount.account(account.sessionID))
                        }
                        Text(Strings.Chats.shareAll).tag(ChatDirectory.ShareAccount.all)
                    } label: {
                        Label(Strings.Chats.shareAccount, systemImage: "square.grid.2x2")
                    }
                } header: {
                    Text(Strings.Chats.widgetSection)
                } footer: {
                    Text(Strings.Chats.widgetHelp)
                }
                .onChange(of: widgetAccount) { _, choice in
                    ChatDirectory.setWidgetAccount(choice)
                    WidgetRefresh.directoryChanged()
                }

                Section {
                    Toggle(isOn: $namesAccount) {
                        Label(Strings.Chats.namesAccount, systemImage: "person.crop.circle.badge")
                    }
                    .accentControl()
                } footer: {
                    Text(Strings.Chats.namesAccountHelp)
                }
                .onChange(of: namesAccount) { _, names in
                    ChatDirectory.setNamesAccountInNotifications(names)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Chats.title))
    }
}
