import IskraCore
import IskraDesign
import SwiftUI

/// The face beside a conversation.
///
/// Three answers, in order, and the order is the whole of it:
///
/// - the room's own picture, when somebody set one;
/// - the people in it, when it is a group and the server has named a few — the cluster below;
/// - one stand-in for the room itself, which is initials or a creature depending on the switch.
///
/// A personal chat never reaches the middle case, because it has already borrowed the other
/// person's picture and the other person's seed a layer down in `RoomSummary` — the face beside
/// a chat with Аня is Аня's, in every form it can take.
struct RoomAvatar: View {
    let name: String
    let url: String?
    let size: CGFloat
    var shape: AvatarShape = .circle
    /// What a stand-in creature for the *room* is computed from. See `RoomSummary.avatarSeed`.
    var seed: String?
    /// The few members the server names as a description of this room. Empty for anything that
    /// is not a group.
    var faces: [RoomFace] = []

    @AppStorage(BetaFeatures.blobatarKey) private var blobatarEnabled = BetaFeatures.blobatarByDefault

    var body: some View {
        if url == nil, blobatarEnabled, faces.count > 1 {
            FaceCluster(faces: faces, size: size, shape: shape)
        } else {
            // One hero is not a cluster, and it must not become one: a group drawn with the single
            // face of whoever the server happened to list first is a group labelled with a
            // stranger. It gets the room's own creature instead.
            Avatar(name: name, url: url, size: size, shape: shape, seed: seed)
        }
    }
}

/// Two or three of the people in a group, overlapping.
///
/// The arrangement is iMessage's, because iMessage's is right: a cluster has to say "several
/// people" at 28 points, where nobody can make out a face and everybody can count circles.
///
/// A photograph punches a ring of clear through whatever is already drawn, rather than carrying a
/// coloured border — so the gap holds on a row, on a wallpaper and in both appearances without
/// anything having to know what colour it is sitting on. **A creature does not**, and that is not
/// a shortcut: a blobatar is a body on a transparent field, not a disc, so a circular gap cut
/// around one leaves a bite of background floating beside it where the creature never reached.
/// Two creatures need no gap anyway — they are different shapes in different colours, which is
/// the whole of what a gap was for.
private struct FaceCluster: View {
    let faces: [RoomFace]
    let size: CGFloat
    let shape: AvatarShape

    /// The circles grow with the text beside them, exactly as a single avatar does — and the
    /// arithmetic below is in the grown box, so the layout cannot drift apart from the faces in
    /// it at the accessibility sizes.
    @TextScale private var textScale

    private var diameter: CGFloat { size * textScale }

    /// The ring of clear between two faces, as a fraction of the whole rather than as a fixed
    /// number of points: a 4pt gap that looks right at 96 swallows a 28pt cluster whole.
    private var gap: CGFloat { diameter * 0.05 }

    /// Where each face sits and how big it is, as fractions of the box.
    ///
    /// Two go on a diagonal, which reads as a pair rather than as one circle with something stuck
    /// to it. Three make a triangle with the odd one on top, which is the shape a group of three
    /// is drawn as everywhere and therefore the one nobody has to work out.
    private var places: [(x: CGFloat, y: CGFloat, fraction: CGFloat)] {
        faces.count == 2
            ? [(0.31, 0.33, 0.72), (0.69, 0.67, 0.72)]
            : [(0.5, 0.26, 0.64), (0.26, 0.73, 0.64), (0.74, 0.73, 0.64)]
    }

    var body: some View {
        ZStack {
            ForEach(Array(zip(faces.prefix(3), places)), id: \.0.id) { face, place in
                // A creature gets a roomier slot than a photograph, because it does not fill the
                // one it is given: a blobatar's body is about three quarters of its box, on
                // purpose, and sizing it as though it were a thumbnail leaves three specks
                // floating in a 44pt circle. Two photographs at that size would overlap instead
                // of sitting beside each other, so the slot follows what is in it.
                //
                // 1.12 and no more: three quarters of that still has to fit inside the clip at
                // the outermost centre, or the creature at the edge is served with a flat side.
                let inner = size * place.fraction * (face.avatarURL == nil ? 1.12 : 1)
                let center = CGPoint(x: diameter * place.x, y: diameter * place.y)

                // The gap under a photograph, cut out of everything already drawn.
                // `destinationOut` needs the whole stack in one layer to have something to cut
                // *into* — see `.compositingGroup()`.
                if face.avatarURL != nil {
                    Circle()
                        .frame(
                            width: inner * textScale + gap * 2,
                            height: inner * textScale + gap * 2
                        )
                        .position(center)
                        .blendMode(.destinationOut)
                }

                Avatar(name: face.name, url: face.avatarURL, size: inner, seed: face.id)
                    .position(center)
            }
        }
        .frame(width: diameter, height: diameter)
        .compositingGroup()
        .clipShape(shape == .circle
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: diameter * 0.28, style: .continuous)))
        .accessibilityHidden(true)
    }
}
