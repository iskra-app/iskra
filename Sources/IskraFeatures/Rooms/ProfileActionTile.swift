import SwiftUI
import IskraCore
import IskraDesign

/// One of the buttons under a person's portrait — Telegram's row of actions, drawn as a round piece
/// of Liquid Glass with the word under it.
///
/// Glass, though glass in this app is kept to the navigation layer (`Glass.swift`): these float over
/// the profile as controls, not as content — the same standing as the floating buttons over a
/// conversation — and that is what the author asked them to be. `navigationGlass` is the modifier
/// for it, used unchanged; the name fits, because these are a way *out* of the page, to a chat or a
/// share sheet.
struct ProfileActionTile: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileActionTileLabel(title: title, systemImage: systemImage, isBusy: isBusy)
        }
        .buttonStyle(.plain)
    }
}

/// The circle and the word, for a tile whose button is somebody else's — a `ShareLink`, a `Menu`.
struct ProfileActionTileLabel: View {
    let title: LocalizedStringResource
    let systemImage: String
    var isBusy = false

    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            ZStack {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(accent.color)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: Theme.Size.profileAction, height: Theme.Size.profileAction)
            .navigationGlass(in: .circle)
            .contentShape(.circle)

            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
