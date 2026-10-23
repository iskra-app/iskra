import SwiftUI
import IskraCore
import IskraDesign

/// The app's language, on a Mac: the system's, or one of the seven the app is complete in — each
/// named in itself, so it is found by somebody who reads only it. Applied at once; see
/// `AppLanguage` for how, and for the part of the screen that waits for the next launch.
///
/// iPhone and iPad have no such screen: the language is chosen in the app's page of the system
/// Settings, where iOS wants it chosen, and the row in settings goes there.
struct LanguageView: View {
    /// Read so the ticks move when the choice does; written through `AppLanguage.chosen`, which
    /// also tells the system.
    @AppStorage(AppLanguage.key) private var stored = ""

    /// Whether "Restart now?" is up — asked after every change, since the menus take a language
    /// only at launch.
    @State private var isOfferingRestart = false

    var body: some View {
        Form {
            Section {
                row(nil)
                ForEach(AppLanguage.supported, id: \.self) { row($0) }
            } footer: {
                Text(Strings.Settings.languageHelp)
            }
        }
        .formStyle(.groupedRows)
        .navigationTitle(Text(Strings.Settings.language))
        #if os(macOS)
        .alert(Text(Strings.Settings.languageRestartTitle), isPresented: $isOfferingRestart) {
            Button(String(app: Strings.Settings.languageRestart)) { Relaunch.now() }
            Button(String(app: Strings.Settings.languageRestartLater), role: .cancel) {}
        } message: {
            Text(Strings.Settings.languageRestartMessage)
        }
        #endif
    }

    private func row(_ code: String?) -> some View {
        Button {
            guard AppLanguage.chosen != code else { return }
            AppLanguage.chosen = code
            isOfferingRestart = true
        } label: {
            HStack {
                if let code {
                    Text(verbatim: AppLanguage.name(of: code))
                } else {
                    Text(Strings.Settings.languageSystem)
                }
                Spacer(minLength: 0)
                if (stored.isEmpty ? nil : stored) == code {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits((stored.isEmpty ? nil : stored) == code ? .isSelected : [])
    }
}
