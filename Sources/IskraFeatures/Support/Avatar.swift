import SwiftUI
import IskraCore
import IskraDesign

/// A round avatar: the picture if there is one, something standing in for it until it arrives,
/// and that stand-in for good if there is none.
///
/// The stand-in is not a spinner. Most people in most rooms have no picture at all, and a
/// list of grey circles quietly spinning would be an app pretending to be busy — so the
/// fallback is drawn immediately, as though it were the answer, and the photograph replaces
/// it when it lands. Nothing about the row moves when that happens: the circle is the same
/// size either way.
///
/// What the stand-in *is* depends on one switch in Beta features: initials, or the creature the
/// person's identifier comes out as. See `Blobatar`.
/// The two silhouettes an avatar can wear. A round one is a person or an ordinary chat; a
/// square-cornered one is a space — so a space is told apart from a conversation at a glance, before
/// a single word is read.
enum AvatarShape {
    case circle
    case roundedSquare
}

/// The outline of an avatar of either shape, at whatever size it is drawn. A space's corners are
/// rounded at a fixed fraction of its size, so the square scales with the face and never turns
/// into a sharp-cornered tile at the large accessibility sizes.
struct AvatarOutline: Shape {
    let shape: AvatarShape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle:
            Circle().path(in: rect)
        case .roundedSquare:
            RoundedRectangle(cornerRadius: rect.width * 0.28, style: .continuous).path(in: rect)
        }
    }
}

struct Avatar: View {
    let name: String
    /// The `mxc://` URL the homeserver gives out beside the name. Nil for the very many
    /// people who never set one.
    let url: String?
    let size: CGFloat
    var shape: AvatarShape = .circle

    /// What a generated face is computed from — a Matrix user ID, or a room ID.
    ///
    /// **An identifier, never the display name.** A name is something people change, and a face
    /// that changes when somebody edits their profile is not a face. Left nil where a generated
    /// creature makes no sense — a space is not a person — and nil is also what turns the feature
    /// off at a call site: no seed, no creature, initials as before.
    var seed: String?

    @Environment(\.mediaLoader) private var loader
    @AppStorage(BetaFeatures.blobatarKey, store: BetaFeatures.faceStore) private var blobatarEnabled = BetaFeatures.blobatarByDefault
    @AppStorage(BetaFeatures.forceBlobatarKey, store: BetaFeatures.faceStore) private var forceBlobatar = BetaFeatures.forceBlobatarByDefault

    /// The face grows with the name beside it. A 28pt circle next to a line of text that is twice
    /// its height at the accessibility sizes reads as a bug in the layout, because it is one — see
    /// `TextScale`, and note the cap: text may take all the room it needs, furniture takes some and
    /// then stops.
    @TextScale private var textScale

    @State private var image: Image?

    /// What is actually drawn, as opposed to what the caller asked for.
    private var diameter: CGFloat { size * textScale }

    /// The outline, one `Shape` so the fill and the clip agree.
    private var outline: AvatarOutline { AvatarOutline(shape: shape) }

    /// Whether a creature is standing in here, rather than a letter or a photograph.
    ///
    /// Normally only where there is nothing else. Forced, it wins over a picture somebody
    /// actually set — which is a thing to ask for and never a default, and is also the only way
    /// to see this feature at all in an account where everybody has a face already.
    private var drawsBlobatar: Bool {
        blobatarEnabled && seed != nil && (image == nil || forceBlobatar)
    }

    var body: some View {
        outline
            // No grey plate under a creature. A blobatar draws its own body and is meant to sit
            // directly on whatever is behind it — its darkest tone is floored against a dark page
            // for exactly that — so a disc behind it would only put it in a box nothing else is
            // in.
            .fill(drawsBlobatar ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary))
            .frame(width: diameter, height: diameter)
            .overlay {
                if drawsBlobatar, let seed {
                    BlobatarView(seed: seed)
                } else if let image {
                    image
                        .resizable()
                        .scaledToFill()
                        .clipShape(outline)
                } else {
                    Text(initials)
                        .font(.system(size: diameter * 0.4, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            // The picture arrives late by definition, and swapping it in on the spot makes a
            // room list twitch as it syncs. It fades instead.
            .animation(.smooth(duration: Theme.Timing.reaction), value: image == nil)
            // The flag is part of the identity of this request, not just of how it is drawn:
            // turning it on has to *stop* the fetch, not merely cover up what it returned.
            .task(id: "\(forceBlobatar)\u{0}\(url ?? "")") { await load() }
            .accessibilityHidden(true)
    }

    private func load() async {
        image = nil
        // Nothing to fetch when a creature is going to be drawn over it anyway. Worth saying out
        // loud, because the alternative — download the photograph and then hide it — is what this
        // would do by itself, and it would be a switch that quietly costs a person their data.
        guard !(forceBlobatar && blobatarEnabled && seed != nil) else { return }
        guard let url, let loader else { return }

        // Cached across every row that shows the same face — and there are many: one person
        // in a busy conversation is an avatar beside a dozen messages, and each of those is a
        // separate view that would otherwise ask the SDK for the same bytes on every scroll.
        if let cached = AvatarCache.shared.image(for: url) {
            image = cached
            return
        }

        // Points are not pixels. Asking the server for a 28-pixel picture and drawing it in a
        // 28-*point* circle produces a smeared thumbnail on every device Apple has shipped
        // this decade, so the request is made at the screen's own scale — and at the size the
        // circle has actually grown to, not the one it was asked for.
        let pixels = Int(diameter * 3)

        guard let data = try? await loader.avatar(url: url, size: pixels),
              let loaded = Image(mediaData: data) else { return }

        AvatarCache.shared.store(loaded, for: url)
        image = loaded
    }

    private var initials: String { Initials.of(name) }
}

/// The faces already fetched, kept for as long as the app is running.
///
/// Deliberately not written to disk. An avatar is public, so there is nothing here that has
/// to be protected — but the SDK's own store is the only cache this app keeps, and adding a
/// second one on the side is how a cache directory full of people's faces appears in a backup
/// nobody meant to make. Memory is enough: the pictures are small, there are as many of them
/// as there are people in your rooms, and the cost of losing them is one fetch at launch.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    private var images: [String: Image] = [:]

    func image(for url: String) -> Image? {
        images[url]
    }

    func store(_ image: Image, for url: String) {
        images[url] = image
    }
}
