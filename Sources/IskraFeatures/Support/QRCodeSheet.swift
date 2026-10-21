import SwiftUI
import IskraCore
import IskraDesign
#if os(iOS)
import CoreMotion
#endif

/// A face, a name and a code to point a camera at — yours from settings, a person's or a public
/// room's from its info screen. A white card held up to the viewer, after Threads' invitation:
/// it holds its place as the phone turns (on a Mac, it sways a little by itself), turns under a
/// finger to show the spark on its back, and a rainbow comes up across it as it tilts.
///
/// What the code holds is an `s.iskra.wtf` link, not the bare ID — see `MatrixLink`, which is
/// where that choice is argued. The ID is written under the code as well, for the person standing next
/// to you who would rather type it.
struct QRCodeSheet: View {
    let name: String
    /// The Matrix ID or the room's address, written out under the code.
    let subtitle: String
    let avatarURL: String?
    var seed: String?
    var shape: AvatarShape = .circle
    let link: MatrixLink

    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaLoader) private var loader
    @AppStorage(BetaFeatures.blobatarKey, store: BetaFeatures.faceStore) private var blobatarEnabled = BetaFeatures.blobatarByDefault
    @AppStorage(BetaFeatures.forceBlobatarKey, store: BetaFeatures.faceStore) private var forceBlobatar = BetaFeatures.forceBlobatarByDefault

    /// The picture on the card, fetched here rather than by an `Avatar` — the card is also drawn
    /// into the picture that is shared, and a renderer runs no `.task`.
    @State private var avatar: Image?
    /// The front of the card, drawn once into a picture for the share sheet.
    @State private var card: Image?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.generous) {
                Spacer(minLength: 0)

                SpinningCard {
                    QRCardFront(name: name, subtitle: subtitle, link: link, face: face, holo: $0)
                } back: {
                    QRCardBack(holo: $0)
                }

                Spacer(minLength: 0)

                // The front of the card, as a picture — what somebody sharing a QR code means to
                // send: something to show on another screen or to print, that a camera can read.
                if let card {
                    ShareLink(item: card, preview: SharePreview(name, image: card)) {
                        Label(String(app: Strings.Profile.share), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glassAction)
                }
            }
            .padding(Theme.Spacing.generous)
            .frame(maxWidth: .infinity)
            .navigationTitle(Text(Strings.QR.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .leaving) { dismiss() } label: {
                        Label(String(app: Strings.Recovery.close), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .task(id: "\(link.url)\u{0}\(avatarURL ?? "")") {
            card = renderCard()
            await loadAvatar()
            card = renderCard()
        }
        #if os(macOS)
        // A Mac sheet is as small as its content will let it be.
        .frame(minWidth: Theme.Size.qrCardWidth + Theme.Spacing.generous * 4,
               minHeight: Theme.Size.qrCardWidth * 2)
        #endif
    }

    private var face: QRCardFace {
        QRCardFace(name: name, picture: avatar, seed: seed, shape: shape,
                   blobatarEnabled: blobatarEnabled, forceBlobatar: forceBlobatar)
    }

    /// From the avatar cache when the face was on screen a moment ago — it nearly always was, on
    /// the profile this sheet was opened from — and from the server otherwise. Not at all when a
    /// creature is going to be drawn over it: see `Avatar.load`.
    private func loadAvatar() async {
        guard let avatarURL, !(forceBlobatar && blobatarEnabled && seed != nil) else { return }
        if let cached = AvatarCache.shared.image(for: avatarURL) {
            avatar = cached
            return
        }
        guard let loader,
              let data = try? await loader.avatar(url: avatarURL, size: Int(Theme.Size.qrCardFace * 3)),
              let loaded = Image(mediaData: data) else { return }
        AvatarCache.shared.store(loaded, for: avatarURL)
        avatar = loaded
    }
}

extension QRCodeSheet {
    @MainActor
    func renderCard() -> Image? {
        Self.card(name: name, subtitle: subtitle, link: link, face: face)
            .map { Image(decorative: $0, scale: 3) }
    }

    /// The front of the card, flat, as a picture — a `CGImage`, so a test can read the code back
    /// out of it. White whatever the appearance, because a QR code on a dark background is one a
    /// camera may not read, and transparent past the rounded corners, so it is a card wherever it
    /// lands and not a white rectangle.
    @MainActor
    static func card(name: String, subtitle: String, link: MatrixLink, face: QRCardFace,
                     holo: Holo = .resting) -> CGImage? {
        let renderer = ImageRenderer(content: QRCardFront(name: name, subtitle: subtitle, link: link,
                                                          face: face, holo: holo))
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

/// How much rainbow there is on the card and where its colours stand — worked out from the card's
/// angle by `SpinningCard`, fixed for the picture that is shared.
struct Holo {
    var phase: Double
    var strength: Double

    /// Face on and still: the watermark only just there.
    static let resting = Holo(phase: 0, strength: 0.3)
}

/// The face at the top of the card: the picture, the creature or the initials, by the same rule as
/// `Avatar` — but drawn from what it is handed, so the renderer that makes the shared picture sees
/// the same face as the screen.
struct QRCardFace: View {
    let name: String
    let picture: Image?
    let seed: String?
    let shape: AvatarShape
    let blobatarEnabled: Bool
    let forceBlobatar: Bool

    var body: some View {
        let outline = AvatarOutline(shape: shape)
        let creature = Avatar.drawsBlobatar(enabled: blobatarEnabled, forced: forceBlobatar,
                                            seed: seed, hasPicture: picture != nil)
        outline
            .fill(creature ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary))
            .overlay {
                if creature, let seed {
                    BlobatarView(seed: seed)
                } else if let picture {
                    picture
                        .resizable()
                        .scaledToFill()
                        .clipShape(outline)
                } else {
                    Text(Initials.of(name))
                        .font(.system(size: Theme.Size.qrCardFace * 0.4, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Theme.Size.qrCardFace, height: Theme.Size.qrCardFace)
            .accessibilityHidden(true)
    }
}

/// The face of the card: who it is, the code, and the address under it.
struct QRCardFront: View {
    let name: String
    let subtitle: String
    let link: MatrixLink
    let face: QRCardFace
    let holo: Holo

    var body: some View {
        VStack(spacing: Theme.Spacing.normal) {
            face

            Text(name)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // No plate of its own: the rainbow runs under the code as well. `QRCardTests` holds
            // that a camera still reads it with the rainbow at its brightest.
            QRCodeImage(text: link.url.absoluteString, plate: false)

            Text(verbatim: subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.black)
        // The code brings its own margin inside its plate, so the sides take less than the ends.
        .padding(.horizontal, Theme.Spacing.close)
        .padding(.vertical, Theme.Spacing.generous)
        .frame(width: Theme.Size.qrCardWidth)
        .background { QRCardGround(holo: holo) }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.qrCard, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

/// The back: the spark, flat and in outline, grey on the same white — a mark on the back of a
/// card, quieter than anything on its face. Larger than the card and off to the left, so the card's
/// edges cut it: printed across the card, not set in the middle of it.
struct QRCardBack: View {
    let holo: Holo

    var body: some View {
        QRCardGround(holo: holo)
            .overlay {
                SparkGlyph()
                    .stroke(Color(white: 0.6), lineWidth: 3)
                    .frame(width: Theme.Size.qrCardSpark, height: Theme.Size.qrCardSpark)
                    .offset(x: -Theme.Size.qrCardSparkShift)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.qrCard, style: .continuous))
    }
}

/// The white with the rainbow in it, the same on both sides.
private struct QRCardGround: View {
    let holo: Holo

    var body: some View {
        Color.white
            .overlay { HoloWatermark(phase: holo.phase, strength: holo.strength) }
    }
}

/// The card in the hand: on a phone it holds its place in the air as the phone turns — turn the
/// phone right and the card turns left — and on a Mac, or anywhere without the sensor, it sways a
/// little on its own. It turns under a finger and comes to rest face on, front or back, whichever
/// it was let go nearer to. A tap turns it over.
///
/// The angle is an animatable value of `TurnedCard` and the sway or the phone's turn is not, so a
/// spring back to rest and either of those can run at once without one cancelling the other. While
/// a finger has the card, the phone's turn is not followed; it comes back a moment after the card
/// has settled, measured from wherever the phone is then, and eases in from nothing as the sway
/// does — so the card never jumps. With Reduce Motion on, there is neither: the root's
/// `respectsReduceMotion` only takes the animation out of a transaction, and a `TimelineView`
/// would go on turning the card regardless.
private struct SpinningCard<Front: View, Back: View>: View {
    @ViewBuilder let front: (Holo) -> Front
    @ViewBuilder let back: (Holo) -> Back

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the card rests, in degrees about the vertical: a multiple of 180.
    @State private var yaw: Double = 0
    @State private var dragYaw: Double = 0
    @State private var pitch: Double = 0
    @State private var isDragging = false
    /// When the sway last started, so that it starts from zero — and, on a phone, when the card was
    /// last let go, which is what the phone's turn waits out before it is followed again.
    @State private var swayStart = Date()
    /// The first time the phone's turn is followed it is not waited for: there is nothing to wait out.
    @State private var settledOnce = false
    #if os(iOS)
    @State private var motion = CardMotion()
    #endif

    var body: some View {
        TimelineView(.animation(paused: isDragging || reduceMotion)) { context in
            let drift = swaying ? drift(at: context.date) : (yaw: 0, pitch: 0)
            TurnedCard(yaw: yaw + dragYaw, pitch: pitch,
                       swayYaw: drift.yaw, swayPitch: drift.pitch,
                       front: front, back: back)
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .onTapGesture {
            letGo()
            withAnimation(settle) { yaw += 180 }
        }
        #if os(iOS)
        .onAppear { if !reduceMotion { motion.start() } }
        .onDisappear { motion.stop() }
        .onChange(of: reduceMotion) { _, reduced in reduced ? motion.stop() : motion.start() }
        #endif
    }

    private var swaying: Bool { !isDragging && !reduceMotion }

    private var settle: Animation? {
        reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.3)
    }

    /// What turns the card besides a finger: the phone's own turn where there is a sensor to tell
    /// it, the sway where there is not.
    private func drift(at now: Date) -> (yaw: Double, pitch: Double) {
        #if os(iOS)
        if motion.isAvailable {
            let since = settledOnce ? now.timeIntervalSince(swayStart) - Self.motionPause : 1
            guard since > 0 else { return (0, 0) }
            let turn = motion.turn()
            let ease = min(1, since / 0.6)
            return (yaw: turn.yaw * ease, pitch: turn.pitch * ease)
        }
        #endif
        return Self.sway(since: swayStart, now: now)
    }

    /// How long after the card is let go the phone's turn is followed again — long enough for the
    /// spring to settle, so the two do not tug at the card together.
    private static var motionPause: TimeInterval { 1 }

    /// The card has just been put down: the sway starts again from nothing, and the phone's turn,
    /// once it is followed again, is measured from wherever the phone is by then.
    private func letGo() {
        swayStart = .now
        settledOnce = true
        #if os(iOS)
        motion.rest()
        #endif
    }

    /// A slow figure of eight, coming up over the first second and a half after a rest.
    private static func sway(since start: Date, now: Date) -> (yaw: Double, pitch: Double) {
        let t = max(0, now.timeIntervalSince(start))
        let ease = min(1, t / 1.5)
        return (yaw: sin(t * 0.8) * 12 * ease, pitch: sin(t * 0.55) * 5 * ease)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDragging {
                    // Whatever the sway or the phone had turned the card to becomes where the
                    // finger picks it up.
                    yaw += reduceMotion ? 0 : drift(at: .now).yaw
                    isDragging = true
                }
                dragYaw = value.translation.width * 0.5
                pitch = min(18, max(-18, -value.translation.height * 0.15))
            }
            .onEnded { value in
                let thrown = yaw + value.predictedEndTranslation.width * 0.5
                yaw += dragYaw
                dragYaw = 0
                isDragging = false
                letGo()
                withAnimation(settle) {
                    yaw = (thrown / 180).rounded() * 180
                    pitch = 0
                }
            }
    }
}

#if os(iOS)
/// The phone's turn since a moment of rest, as the card's answer to it: the other way, and no
/// further than `limit`. Read on every frame the card draws rather than pushed from a queue — the
/// card is drawn every frame anyway, and nothing has to cross from a sensor thread.
///
/// `deviceMotion` asks for no permission: it is the activity and pedometer APIs that do.
@MainActor
private final class CardMotion {
    private let manager = CMMotionManager()
    /// Where the phone was when the card was last at rest; the turn is measured from here.
    private var reference: CMAttitude?

    /// How far the card turns at most, in degrees, however far the phone does.
    private static let limit: Double = 20

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates()
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
    }

    /// Forget where the phone was: the next reading is the new rest.
    func rest() { reference = nil }

    /// In degrees: `yaw` about the card's vertical, from the phone turning left or right in the
    /// hand; `pitch` about its horizontal, from the phone tipping towards or away.
    func turn() -> (yaw: Double, pitch: Double) {
        guard let attitude = manager.deviceMotion?.attitude.copy() as? CMAttitude else { return (0, 0) }
        guard let reference else {
            reference = attitude
            return (0, 0)
        }
        attitude.multiply(byInverseOf: reference)
        func degrees(_ radians: Double) -> Double {
            min(Self.limit, max(-Self.limit, radians * 180 / .pi))
        }
        return (yaw: -degrees(attitude.roll), pitch: -degrees(attitude.pitch))
    }
}
#endif

/// The card at an angle. `Animatable`, so that which side is showing is decided from the angle as
/// it is in the middle of a turn, not from where the turn will end.
private struct TurnedCard<Front: View, Back: View>: View, Animatable {
    var yaw: Double
    var pitch: Double
    let swayYaw: Double
    let swayPitch: Double
    let front: (Holo) -> Front
    let back: (Holo) -> Back

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(yaw, pitch) }
        set { (yaw, pitch) = (newValue.first, newValue.second) }
    }

    var body: some View {
        let turn = yaw + swayYaw
        let tilt = pitch + swayPitch
        let radians = turn * .pi / 180
        let showsFront = cos(radians) >= 0
        // Bright as it turns away from face on, and a little with the tilt.
        let holo = Holo(phase: (turn + tilt * 2) * .pi / 180,
                        strength: 0.3 + 0.6 * abs(sin(radians)) + 0.3 * abs(sin(tilt * .pi / 180)))

        ZStack {
            front(holo)
                .opacity(showsFront ? 1 : 0)
                .accessibilityHidden(!showsFront)
            back(holo)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(showsFront ? 0 : 1)
                .accessibilityHidden(true)
        }
        .fixedSize()
        // The side turned away from the light, a shade darker — the one thing that makes a white
        // card read as turned and not as squeezed.
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.qrCard, style: .continuous)
                .fill(.black.opacity(0.12 * abs(sin(radians))))
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.2), radius: Theme.Spacing.generous, y: Theme.Spacing.normal)
        .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(turn), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
    }
}

/// Where a link — scanned, tapped, opened from another app — leads: a person's page, or a room
/// to step into.
///
/// Never straight into a room. A QR code is somebody else's choice of where to send you, and
/// joining is visible to everyone already there; so a room is shown first, with what the server
/// will say about it, and entered with a press. A room this account is already in simply opens.
struct MatrixLinkView: View {
    let session: UserSession
    let link: MatrixLink
    /// The conversation to put on screen — the caller closes whatever this is standing in.
    var onOpen: (String) -> Void

    var body: some View {
        switch link {
        case .user(let userID):
            PersonLinkView(session: session, userID: userID, onOpen: onOpen)
        case .room(let room, let via):
            RoomLinkView(session: session, address: room, via: via, onOpen: onOpen)
        }
    }
}

private struct PersonLinkView: View {
    let session: UserSession
    let userID: String
    var onOpen: (String) -> Void

    @State private var person: PersonProfile?

    var body: some View {
        Group {
            if let person {
                MemberProfileView(member: RoomMemberSummary(person: person),
                                  roles: [], canRemove: false, canBlock: false,
                                  setRole: { _ in }, remove: {}, block: {},
                                  showsRole: false)
                    // "Write" ends here: the conversation is put on screen by whoever opened this.
                    .environment(\.openRoom, onOpen)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // A name and a face to show while it loads would be a guess; the ID is enough to write
            // to, and the profile, when the server gives it, is the real one.
            person = await session.profile(of: userID)
        }
    }
}

private struct RoomLinkView: View {
    let session: UserSession
    let address: String
    let via: [String]
    var onOpen: (String) -> Void

    @State private var isLoading = true
    @State private var joined: String?
    @State private var preview: PublicRoom?
    @State private var isJoining = false
    @State private var failure: RoomJoinFailure?

    var body: some View {
        Form {
            Section {
                ProfileHeader(name: preview?.title ?? address,
                              avatarURL: preview?.avatarURL,
                              subtitle: subtitle,
                              seed: preview?.id ?? address,
                              isSubtitleSelectable: true)
                    .profileHeaderRow()
            }

            if let topic = preview?.topic, !topic.isEmpty {
                Section {
                    Text(topic)
                        .font(.callout)
                        .textSelection(.enabled)
                } header: {
                    Text(Strings.Room.about)
                }
            }

            Section {
                Button {
                    Task { await enter() }
                } label: {
                    HStack {
                        Spacer()
                        if isJoining {
                            ProgressView()
                        } else {
                            Text(joined == nil ? Strings.QR.joinRoom : Strings.QR.openRoom)
                        }
                        Spacer()
                    }
                }
                .disabled(isLoading || isJoining)
            } footer: {
                if !isLoading, joined == nil {
                    if preview == nil {
                        Text(Strings.QR.roomUnknown)
                    } else if preview?.isOpen == false {
                        Text(Strings.QR.inviteOnlyRoom)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .profileScreen()
        .failureAlert($failure)
        .task {
            joined = await session.joinedRoom(address)
            if joined == nil {
                preview = await session.roomPreview(address, via: via)
            }
            isLoading = false
        }
    }

    private var subtitle: String {
        var parts = [preview?.alias ?? address]
        if let preview, preview.memberCount > 0 {
            parts.append(String(app: Strings.Room.participants(preview.memberCount)))
        }
        return parts.joined(separator: " · ")
    }

    private func enter() async {
        if let joined {
            onOpen(joined)
            return
        }
        isJoining = true
        do {
            onOpen(try await session.joinRoom(address, via: via))
        } catch {
            failure = error
        }
        isJoining = false
    }
}
