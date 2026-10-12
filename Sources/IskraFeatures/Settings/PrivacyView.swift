import IskraCore
import IskraDesign
import SwiftUI

/// What other people learn about you without your writing anything: that you are here, and that you
/// are typing. Telegram's "Privacy", cut to the two things a Matrix server actually tells others.
///
/// Written straight to `@AppStorage` under `PrivacySettings`' keys, so there is no "done". Typing is
/// read on the next keystroke; presence is told to the server the moment the switch moves, because
/// "hide when I was last here" that takes effect next time is a switch that did not work today.
struct PrivacyView: View {
    let session: UserSession

    @AppStorage(PrivacySettings.hidesPresenceKey) private var hidesPresence = PrivacySettings.hidesPresenceByDefault
    @AppStorage(PrivacySettings.hidesTypingKey) private var hidesTyping = PrivacySettings.hidesTypingByDefault

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $hidesPresence) {
                    Label(Strings.Privacy.hidePresence, systemImage: "clock.badge.xmark")
                }
                .accentControl()
            } footer: {
                Text(Strings.Privacy.hidePresenceHelp)
            }

            Section {
                Toggle(isOn: $hidesTyping) {
                    Label(Strings.Privacy.hideTyping, systemImage: "ellipsis.bubble")
                }
                .accentControl()
            } footer: {
                Text(Strings.Privacy.hideTypingHelp)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Privacy.title))
        .onChange(of: hidesPresence) {
            Task { await session.applyPresence() }
        }
    }
}
