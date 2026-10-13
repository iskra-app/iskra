import SwiftUI
import IskraCore
import IskraDesign

/// Who gets a drawn creature instead of their face — two sample people, the slider and what the
/// chosen stop means. Asked under Beta features; it used to be asked on the first run as well,
/// which is gone: the app opens straight onto the conversations after signing in.
struct FaceModePicker: View {

    // The App Group's defaults, not the app's own — the notification extension reads these two,
    // and a switch only the app can see is a switch the lock screen disobeys. See `BetaFeatures`.
    @AppStorage(BetaFeatures.blobatarKey, store: BetaFeatures.faceStore)
    private var drawsCreatures = BetaFeatures.blobatarByDefault
    @AppStorage(BetaFeatures.forceBlobatarKey, store: BetaFeatures.faceStore)
    private var overridesPictures = BetaFeatures.forceBlobatarByDefault

    private var mode: FaceMode {
        FaceMode(drawsCreatures: drawsCreatures, overridesPictures: overridesPictures)
    }

    /// The slider's view of the same pair of switches. Rounded on the way in, because a slider
    /// with a step still hands over a `Double` and `Int(2.9999)` is 2 only by luck.
    private var position: Binding<Double> {
        Binding(get: { Double(mode.rawValue) },
                set: { value in
                    let chosen = FaceMode(rawValue: Int(value.rounded())) ?? .pictures
                    withAnimation(.smooth(duration: Theme.Timing.reaction)) {
                        drawsCreatures = chosen.drawsCreatures
                        overridesPictures = chosen.overridesPictures
                    }
                })
    }

    var body: some View {
    VStack(spacing: Theme.Spacing.generous) {
        faces

        VStack(spacing: Theme.Spacing.close) {
            Slider(value: position, in: 0...Double(FaceMode.allCases.count - 1), step: 1)
                .accentControl()
                .accessibilityLabel(Text(Strings.Onboarding.facesTitle))
                .accessibilityValue(Text(Strings.Onboarding.faceMode(mode)))

            // The three stops, named under the track they belong to. The chosen one is
            // the only one in full strength, because a slider handle between three
            // equally black words does not say which one it has landed on.
            HStack(alignment: .top) {
                ForEach(FaceMode.allCases) { candidate in
                    Text(Strings.Onboarding.faceMode(candidate))
                        .font(.caption)
                        .multilineTextAlignment(alignment(of: candidate))
                        .foregroundStyle(candidate == mode ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, alignment: edge(of: candidate))
                }
            }
            .accessibilityHidden(true)
        }

        Text(Strings.Onboarding.faceModeHelp(mode))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // The sentence changes with the slider, and a sentence that is replaced in
            // place reads as the same sentence being corrected.
            .id(mode)
            .transition(.opacity)
    }
    }

    private func alignment(of candidate: FaceMode) -> TextAlignment {
        switch candidate {
        case .pictures: .leading
        case .mixed: .center
        case .faces: .trailing
        }
    }

    private func edge(of candidate: FaceMode) -> Alignment {
        switch candidate {
        case .pictures: .leading
        case .mixed: .center
        case .faces: .trailing
        }
    }

    private var faces: some View {
        HStack(spacing: Theme.Spacing.generous) {
            face(name: Strings.Onboarding.picturedName,
                 caption: Strings.Onboarding.withPicture,
                 seed: "@chloe:iskra.chat",
                 hasPicture: true)

            face(name: Strings.Onboarding.unpicturedName,
                 caption: Strings.Onboarding.withoutPicture,
                 seed: "@tim:iskra.chat",
                 hasPicture: false)
        }
    }

    private func face(name: LocalizedStringResource,
                      caption: LocalizedStringResource,
                      seed: String,
                      hasPicture: Bool) -> some View {
        VStack(spacing: Theme.Spacing.close) {
            ZStack {
                if mode.drawsCreatures && (!hasPicture || mode.overridesPictures) {
                    BlobatarView(seed: seed)
                } else if hasPicture {
                    photograph
                } else {
                    Circle()
                        .fill(.quaternary)
                        .overlay {
                            Text(String(app: name).prefix(1).uppercased())
                                .font(.system(size: Theme.Size.avatarProfile * 0.4, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: Theme.Size.avatarProfile, height: Theme.Size.avatarProfile)

            Text(name)
                .font(.callout.weight(.medium))

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// A picture somebody set, drawn rather than fetched.
    ///
    /// There is no real photograph to show: these two people do not exist, and going to the
    /// network for a stranger's face to illustrate a settings screen is precisely the thing this
    /// feature exists to avoid. What matters is that it reads as *a picture* rather than as
    /// initials — so it is a filled circle with a figure in it, which is what a portrait looks
    /// like at ninety-six points.
    private var photograph: some View {
        Circle()
            .fill(LinearGradient(colors: [.orange, .pink],
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: Theme.Size.avatarProfile * 0.5))
                    .foregroundStyle(.white)
                    .offset(y: Theme.Spacing.tight)
            }
    }
}

