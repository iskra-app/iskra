import IskraCore
import IskraDesign
import SwiftUI

/// What happens to a photo or a video on its way out: whether it loses its metadata, and whether
/// — and how hard — it is compressed.
///
/// Written straight to `@AppStorage`, under the keys and defaults `MediaSettings` spells out, and
/// read by `TimelineStore` at the moment of sending — so there is no "done", and the next photo
/// already goes the new way. Video notes are outside all of it (`MediaSettings.videoNote`).
///
/// One footer, under auto-download. The switches below it are named for what they do — "Send
/// without metadata" — and a sentence under each repeated the name at greater length.
struct MediaSettingsView: View {
    @AppStorage(MediaSettings.stripsMetadataKey) private var stripsMetadata = MediaSettings.stripsMetadataByDefault
    @AppStorage(MediaSettings.compressesKey) private var compresses = MediaSettings.compressesByDefault
    @AppStorage(MediaSettings.compressionKey) private var compression = MediaSettings.compressionByDefault
    @AppStorage(MediaSettings.autoDownloadKey) private var autoDownload = MediaSettings.autoDownloadByDefault

    var body: some View {
        Form {
            // First, because it is the one about what *arrives* — and the one people come to this
            // screen with on a roaming tariff.
            Section {
                Picker(selection: $autoDownload.animation(.smooth(duration: Theme.Timing.reaction))) {
                    ForEach(MediaAutoDownload.allCases) { choice in
                        Text(Strings.Media.autoDownloadLabel(choice)).tag(choice)
                    }
                } label: {
                    Label(Strings.Media.autoDownload, systemImage: "arrow.down.circle")
                }
            } footer: {
                // The one footer kept: "Wi-Fi only" does not say what is shown instead, and the
                // answer — a blurred outline and a button — is worth knowing before choosing it.
                Text(Strings.Media.autoDownloadHelp(autoDownload))
            }

            Section {
                Toggle(isOn: $stripsMetadata.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Media.stripMetadata, systemImage: "location.slash")
                }
                .accentControl()
            }

            Section {
                Toggle(isOn: $compresses.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Media.compress, systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .accentControl()

                // Appears with the switch it depends on rather than sitting there greyed out — the
                // same rule as the generated-faces pair in `BetaView`.
                if compresses {
                    Picker(selection: $compression.animation(.smooth(duration: Theme.Timing.reaction))) {
                        ForEach(MediaCompression.allCases) { level in
                            Text(Strings.Media.compressionLabel(level)).tag(level)
                        }
                    } label: {
                        Label(Strings.Media.compression, systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .formStyle(.groupedRows)
        .navigationTitle(Text(Strings.Media.title))
    }
}
