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

    var body: some View {
        Form {
            Section {
                row(nil)
                ForEach(AppLanguage.supported, id: \.self) { row($0) }
            } footer: {
                Text(Strings.Settings.languageHelp)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Settings.language))
    }

    private func row(_ code: String?) -> some View {
        Button {
            AppLanguage.chosen = code
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
