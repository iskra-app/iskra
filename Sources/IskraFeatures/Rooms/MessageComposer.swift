import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// A voice message being recorded, as the composer needs to draw it: how long it has been going,
/// and what it has heard.
///
/// It used to carry whether the finger was still down, because the strip said different things
/// to a held recording and a hands-free one. It no longer needs to: the way out is a button now,
/// and a button is the same button whether or not somebody is touching something else.
struct VoiceRecording: Equatable {
    let elapsed: TimeInterval
    let waveform: [Float]
}

/// What the composer is doing besides writing a new message: answering one, or going back to
/// change one.
///
/// Two states and not a pair of booleans, because they are alternatives — you cannot be
/// answering somebody while editing your own message, and a pair of flags would let you.
enum ComposerContext: Equatable {
    case replying(Message)
    case editing(Message)

    var message: Message {
        switch self {
        case let .replying(message), let .editing(message): message
        }
    }

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }
}

/// The bar you type into.
///
/// A navigation-layer control floating over the timeline, which is exactly what Liquid
/// Glass is for. Kept out of `RoomView` so it can be rendered — and looked at — on its
/// own, without a signed-in session and a room behind it.
struct MessageComposer: View {
    @Binding var draft: String

    /// The message being answered or changed, and nil when neither. The composer only
    /// *displays* it — starting and finishing both belong to the screen, which owns the
    /// timeline the message came from.
    var context: ComposerContext?

    /// Backs out of a reply or an edit. Not "clear the draft": the words the user has typed
    /// are their own and survive.
    var onCancelContext: () -> Void = {}

    var onSend: () -> Void

    /// The four moments of a hold on the record button, in video: it began, it ended (send), it
    /// was swiped away (cancel), it was swiped up (carry on without me).
    ///
    /// Four callbacks and not one, because the recorder they drive lives on the screen — the
    /// camera comes up *while the finger is still down on this button*, so the thing that stops
    /// the recording is out here and the thing that shows it is in there. See
    /// `VideoNoteComposer.isHolding`.
    var onStartVideoNote: () -> Void = {}
    var onFinishVideoNote: () -> Void = {}
    var onCancelVideoNote: () -> Void = {}
    var onLockVideoNote: () -> Void = {}

    /// The same moments for a spoken message, and the same gestures — hold, let go to send, left
    /// to cancel, up to carry on hands-free. Deliberately the same: it is one button set two
    /// ways, and somebody who has learned it one way has learned it both.
    ///
    /// There is no `onLockVoice`, and its absence is the point: locking a spoken message asks
    /// nothing of the screen. The recorder is already running and goes on running; all that
    /// changes is that this button stops waiting for a finger to lift, which is a fact about the
    /// composer and known here. A video note is the one that needs telling, because the camera
    /// on the screen has to hear that the hold is over.
    var onStartVoice: () -> Void = {}
    var onFinishVoice: () -> Void = {}
    var onCancelVoice: () -> Void = {}

    /// What is being recorded right now, if anything. The composer draws it — a voice message
    /// has no sheet and no camera to put on one, so the recording *is* the composer for as long
    /// as it lasts.
    var voice: VoiceRecording?

    /// Asking for a picker, not opening one.
    ///
    /// Both pickers are presented from the root of `RoomView` instead of from here, and the
    /// composer only reports which one the user asked for. This composer is handed to the
    /// screen as a `safeAreaInset` — a corner of the view tree that has already eaten one
    /// picker (a `PhotosPicker` inside the attach *menu* silently never presented, which is
    /// what the menu was torn out for) — and a presentation is the one thing that belongs to
    /// the screen rather than to the bar floating over it.
    var onChoosePhoto: () -> Void
    var onChooseFile: () -> Void
    var onChooseLocation: () -> Void = {}

    /// Whether the "+" has opened into its two choices.
    ///
    /// Settable at birth, which is not for the app's benefit — nothing constructs an open
    /// composer — but for `ComposerLayoutTests`, which renders one and looks at where the
    /// choices land. They landed *on top of* the field and the buttons once, and the only
    /// honest way to know they no longer do is to draw it.
    @State private var isAttaching: Bool

    /// The composer's height, as measured. The choices hang exactly this far above the
    /// bottom edge — see the overlay below. It starts at the height of a one-line composer,
    /// which is what it is before anything has been typed and what it stays until the field
    /// wraps.
    @State private var height: CGFloat = Theme.Size.composerControl + 2 * Theme.Spacing.close

    init(draft: Binding<String>,
         context: ComposerContext? = nil,
         onCancelContext: @escaping () -> Void = {},
         onSend: @escaping () -> Void,
         onStartVideoNote: @escaping () -> Void = {},
         onFinishVideoNote: @escaping () -> Void = {},
         onCancelVideoNote: @escaping () -> Void = {},
         onLockVideoNote: @escaping () -> Void = {},
         onStartVoice: @escaping () -> Void = {},
         onFinishVoice: @escaping () -> Void = {},
         onCancelVoice: @escaping () -> Void = {},
         voice: VoiceRecording? = nil,
         onChoosePhoto: @escaping () -> Void,
         onChooseFile: @escaping () -> Void,
         onChooseLocation: @escaping () -> Void = {},
         isAttaching: Bool = false) {
        _draft = draft
        self.context = context
        self.onCancelContext = onCancelContext
        self.onSend = onSend
        self.onStartVideoNote = onStartVideoNote
        self.onFinishVideoNote = onFinishVideoNote
        self.onCancelVideoNote = onCancelVideoNote
        self.onLockVideoNote = onLockVideoNote
        self.onStartVoice = onStartVoice
        self.onFinishVoice = onFinishVoice
        self.onCancelVoice = onCancelVoice
        self.voice = voice
        self.onChoosePhoto = onChoosePhoto
        self.onChooseFile = onChooseFile
        self.onChooseLocation = onChooseLocation
        _isAttaching = State(initialValue: isAttaching)
    }

    @FocusState private var isFocused: Bool

    @Environment(\.accent) private var accent

    /// The one namespace the glass morphs across. Every piece of glass that should flow
    /// into another — the "+" and the two choices it becomes — is identified within it.
    @Namespace private var glass

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        // One container for every piece of glass in the composer. This is what lets the
        // "+" *become* the choices above it rather than have a menu drawn on top of it:
        // inside a `GlassEffectContainer`, glass with a `glassEffectID` that appears or
        // disappears is interpolated into its neighbours — the material stretches, splits
        // and merges the way the system's own controls do.
        GlassEffectContainer(spacing: Theme.Spacing.close) {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                if let context {
                    contextStrip(context)
                }

                // Bottom-aligned, so the round buttons stay level with the last line of a
                // message that has grown to several lines rather than riding its middle.
                HStack(alignment: .bottom, spacing: Theme.Spacing.close) {
                    // The "+" is not offered mid-recording: attaching a photograph to a voice
                    // message you are in the middle of speaking is not a thing, and the choices
                    // would open over the strip that is telling you how to send it.
                    if voice == nil {
                        attachButton
                    }

                    if let voice {
                        RecordingStrip(elapsed: voice.elapsed,
                                       waveform: voice.waveform,
                                       isHolding: hold == .holding,
                                       onCancel: onCancelVoice)
                            .transition(.opacity)
                    } else {
                        TextField(String(app: Strings.Room.composerPlaceholder), text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .focused($isFocused)
                            .padding(.horizontal, Theme.Spacing.roomy)
                            .padding(.vertical, Theme.Spacing.normal)
                            .frame(minHeight: Theme.Size.composerControl)
                            .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
                            .onSubmit(onSend)
                    }

                    // With nothing typed, there is one button where the send button sits, and it
                    // is the thing you can say without typing: spoken, or a round video one. One
                    // button and not two, because they are the same act — hold and speak — and a
                    // second circle beside the first only asks the thumb to aim.
                    //
                    // Except while editing, where it is not offered: there is no such thing as
                    // replacing a message you wrote with a voice message, so the button stays a
                    // send button. It is disabled on an empty field rather than swapped out,
                    // because an empty edit means "delete this", and deleting is a different act
                    // with a different confirmation.
                    if let context, context.isEditing {
                        button(systemImage: "checkmark",
                               label: Strings.Room.send,
                               isPrimary: true,
                               action: onSend)
                            .disabled(isEmpty)
                    } else if isEmpty {
                        recordButton
                    } else {
                        button(systemImage: "arrow.up",
                               label: Strings.Room.send,
                               isPrimary: true,
                               action: onSend)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
            // How tall the composer actually is right now — one line, or five. Measured,
            // because it is what the choices above have to clear, and it changes as the
            // draft grows. The starting value is the height of a one-line composer, which is
            // what it is until told otherwise.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // An overlay, not a row stacked above the composer. Stacked, the choices are
            // part of the composer's own height — and the composer is a bottom safe-area
            // inset, so growing it pushes the whole timeline up and drops it back down
            // again on every open and close. The messages have nothing to do with this
            // menu and should not move for it. In an overlay the choices are drawn over
            // them instead, and the composer stays exactly the size it was.
            //
            // Lifted by the composer's own height, from the bottom edge. This was an
            // `alignmentGuide(.top)` moved to the view's bottom, which reads beautifully and
            // does nothing: the guide is honoured for *alignment within a stack*, and an
            // overlay laid its top against the composer's top regardless — so the two choices
            // were drawn straight over the text field and the send button, which is the bug.
            // Anchoring the overlay's bottom to the composer's bottom and then pushing it up
            // past the composer is arithmetic instead of a guide, and arithmetic is a thing
            // `ComposerLayoutTests` can look at.
            //
            // Present only while the menu is open, and *gone* the rest of the time — which is
            // load-bearing, and was learned the hard way. Keeping the choices in the tree and
            // hiding them with `.opacity(0)` left them sitting over the conversation in plain
            // sight: they are glass, they live in a `GlassEffectContainer`, and the container
            // draws its material whatever a child inside it has to say about its own opacity.
            // A closed menu has to actually not be there.
            .overlay(alignment: .bottomLeading) {
                if isAttaching {
                    attachOptions
                        .padding(.horizontal, Theme.Spacing.normal)
                        .offset(y: -(height + Theme.Spacing.close))
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: isEmpty)
        .animation(.smooth(duration: 0.2), value: context)
        .onDisappear {
            arming?.cancel()
            arming = nil
        }
        // Starting to type is an answer to "what do you want to attach?" — it is "nothing".
        .onChange(of: isFocused) { _, focused in
            if focused { close() }
        }
    }

    // MARK: - Answering and changing

    /// The strip above the field: what you are answering, or what you are changing, and a way
    /// out of it.
    ///
    /// Part of the composer's own height, deliberately — unlike the attach options, which are
    /// an overlay precisely so the conversation does not move for them. This one *should* move
    /// it: the message being quoted is one the user is about to write into, and the composer
    /// genuinely has grown. Pretending otherwise would let the strip cover the last message in
    /// the room, which is very often the message being answered.
    @ViewBuilder
    private func contextStrip(_ context: ComposerContext) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            Image(systemName: context.isEditing ? "pencil" : "arrowshape.turn.up.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent.color)

            VStack(alignment: .leading, spacing: 0) {
                Text(context.isEditing ? Strings.Room.editingMessage : Strings.Room.replyingTo)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent.color)

                Text(MessageSummary.text(of: context.message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onCancelContext) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Room.stopReplying))
        }
        .padding(.leading, Theme.Spacing.roomy)
        .padding(.trailing, Theme.Spacing.tight)
        .frame(maxWidth: .infinity)
        // The same radius as the field it sits on, and not the smaller `control` it used to
        // wear: the two are one object — the composer, grown a row taller because it is now
        // answering something — and a tight rectangle stacked on a soft one reads as a panel
        // that has landed on top of the bar rather than as the bar itself.
        .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        // It slides out of the field below it rather than appearing above it, so the eye
        // follows the composer growing instead of noticing a new object.
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Recording without typing

    /// The one button for saying something instead of writing it. Tap it to choose *which* —
    /// a spoken message or a round video one — and hold it to record whichever it is showing.
    ///
    /// The two used to be two buttons, side by side, doing the same kind of thing with the same
    /// gesture. That is a choice the thumb has to make before every recording, and it makes it
    /// by aiming at a 44pt circle. Here the choice is made once, it sticks, and the button says
    /// which way it is set. The hold is then the same hold wherever the finger lands.
    ///
    /// Four moments, and the tap is what makes them awkward — a hold *begins* as a tap, and the
    /// two cannot be told apart until either the finger lifts or the clock runs out. So a press
    /// starts nothing: it starts a timer, and the recording begins when the timer does, which is
    /// what `Hold.pressing` is for. Lift before then and it was a tap, and the button flips.
    ///
    /// Two escapes, both of which the thumb can reach without letting go:
    ///
    /// - **Left** cancels. It is the way out of a recording you regret the moment it starts, and
    ///   it must not require lifting the finger — lifting is what *sends*.
    /// - **Up** locks. The recording carries on without the finger, which is the only way to
    ///   record a full minute without holding a phone rigid against your face for it.
    ///
    /// A `DragGesture` with no minimum distance rather than a `LongPressGesture`, and that is
    /// the load-bearing choice: a long press reports that it succeeded and then goes away, so
    /// there is nothing left to watch for the swipes. A drag is live for as long as the finger
    /// is, which is exactly the thing being modelled.
    ///
    /// Red while it is recording, which is the one place in the composer that colour appears
    /// besides the send button: a live microphone is the only thing here the user can forget is
    /// happening.
    private var recordButton: some View {
        icon(glyph, isPrimary: voice != nil, tint: .red)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        switch hold {
                        case .none:
                            hold = .pressing

                            // A press while a hands-free recording is running means stop, not
                            // start another — the button has become a stop button and looks like
                            // one. Nothing is armed; the release does the work.
                            guard voice == nil else { return }

                            arming = Task {
                                try? await Task.sleep(for: Theme.Timing.holdBegins)
                                guard !Task.isCancelled, hold == .pressing else { return }
                                hold = .holding
                                start()
                            }

                        case .pressing:
                            // Still deciding whether this is a tap. There is nothing recording
                            // yet, so there is nothing a swipe could cancel or lock.
                            break

                        case .holding:
                            // Left throws it away, up carries on without the finger. Left is
                            // here rather than left to the strip's Cancel button, because that
                            // button cannot be reached without lifting the finger — and lifting
                            // the finger is what *sends*. A recording being held has to have a
                            // way out that does not go through releasing it.
                            if value.translation.width < -Theme.Size.gestureReach {
                                hold = .over
                                cancel()
                            } else if value.translation.height < -Theme.Size.gestureReach {
                                hold = .over
                                lock()
                            }

                        case .over:
                            // Already cancelled or locked. The finger is still on the glass and
                            // has nothing left to say.
                            break
                        }
                    }
                    .onEnded { _ in
                        let ending = hold
                        hold = .none
                        arming?.cancel()
                        arming = nil

                        switch ending {
                        case .pressing:
                            // Too quick to be a hold. Which stops a hands-free recording if one
                            // is running, and otherwise flips the button to the other kind of
                            // message.
                            if voice == nil {
                                withAnimation(.smooth(duration: 0.2)) { mode.toggle() }
                            } else {
                                onFinishVoice()
                            }

                        case .holding:
                            finish()

                        case .none, .over:
                            break
                        }
                    }
            )
            // The hold is not a gesture VoiceOver can perform, so the button offers the two
            // things it does as actions instead. Recording goes through the video sheet, which
            // is the one path with a shutter in it that VoiceOver *can* press, and a spoken
            // message started this way is stopped by pressing the button again.
            //
            // What it *says* follows the glyph and not the mode. While a recording runs this is
            // a stop button and shows `stop.fill`, and it used to go on announcing itself as
            // "record a voice message" — telling a VoiceOver user that the button which ends
            // their recording will begin one.
            .accessibilityLabel(Text(recordLabel))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(Strings.Recording.hint))
            // And the switch is offered only when there is nothing running to switch *under*.
            // Toggling `mode` mid-recording left the composer describing a video message while
            // the microphone was still on, and `finish()` and `lock()` both dispatch on `mode`
            // — so the next thing the user did would have been routed to the wrong recorder.
            .accessibilityActions {
                if voice == nil {
                    Button(mode == .voice ? Strings.Recording.switchToVideo
                                          : Strings.Recording.switchToVoice) {
                        mode.toggle()
                    }
                }
            }
    }

    /// What the button is called, which follows what it is showing — see `glyph`.
    private var recordLabel: LocalizedStringResource {
        if voice != nil { return Strings.Recording.send }
        return mode == .voice ? Strings.Voice.record : Strings.VideoNote.record
    }

    /// What the button is showing: the microphone, the camera, or — while a hands-free recording
    /// runs — the arrow that sends what has been said.
    ///
    /// An arrow and not a square. Pressing it does stop the recorder, but stopping is not what
    /// anybody presses it *for*: the message goes the moment it stops, and there is nowhere in
    /// this app where a stopped recording sits waiting to be looked at. A stop square promises
    /// that pause, and there is no pause. The same arrow is on the camera's shutter, for the same
    /// reason — see `VideoNoteComposer.shutter`.
    private var glyph: String {
        if voice != nil { return "arrow.up" }
        return mode == .voice ? "mic.fill" : "video.fill"
    }

    private func start() {
        switch mode {
        case .voice: onStartVoice()
        case .video: onStartVideoNote()
        }
    }

    private func finish() {
        switch mode {
        case .voice: onFinishVoice()
        case .video: onFinishVideoNote()
        }
    }

    private func cancel() {
        switch mode {
        case .voice: onCancelVoice()
        case .video: onCancelVideoNote()
        }
    }

    /// Swiped up: the recording carries on without the finger.
    ///
    /// Only the video note has anything to hear about it — see the callbacks above. A spoken
    /// message needs nothing said: `hold` is already `.over`, so the release will do nothing,
    /// and the button has already become a stop button because `voice` is not nil.
    private func lock() {
        if case .video = mode { onLockVideoNote() }
    }

    /// Which kind of message the button records, and therefore which one it is showing. It is
    /// remembered for as long as the room is open: a person who sends video messages sends
    /// several, and asking them to flip the button before each one would be worse than the two
    /// buttons this replaced.
    enum RecordingMode {
        case voice, video

        mutating func toggle() {
            self = self == .voice ? .video : .voice
        }
    }

    @State private var mode: RecordingMode = .voice

    /// Where the finger is in the hold, which a `DragGesture` on its own cannot say.
    ///
    /// `pressing` is a finger that is down but has not been down long enough to mean anything
    /// yet — the state a tap lives and dies in. `over` is the one that matters most: once a
    /// swipe has cancelled or locked the recording, the finger is still down and `onChanged`
    /// keeps firing, and without somewhere to record "this hold is finished" the same swipe
    /// would cancel it four hundred more times on the way to the edge of the screen.
    private enum Hold {
        case none, pressing, holding, over
    }

    @State private var hold: Hold = .none

    /// The timer that turns a press into a hold, held onto so that lifting the finger can call
    /// it off. Cancelled on release, and cancelled again when the view goes away with the finger
    /// still down — a task that outlives the composer would start a recording into a room the
    /// user has already left.
    @State private var arming: Task<Void, Never>?

    // MARK: - Attaching

    /// The "+", which turns into an "×" and back.
    ///
    /// Deliberately not a `Menu`. A menu draws a fresh surface *over* the button that
    /// opened it — the button stays where it is, greyed, with a panel on top — and that is
    /// the one thing Liquid Glass is not supposed to look like. Here the same glass that
    /// draws the button flows upward into the choices, because they are all in one
    /// `GlassEffectContainer` and all named in one namespace.
    private var attachButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                isAttaching.toggle()
            }
        } label: {
            // The turn is handed *into* the icon rather than applied to what comes out of
            // it. Rotating the finished control turned the glass circle as well as the
            // glyph — a circle looks the same at any angle, but the material inside it does
            // not, and the "+" visibly drifted out of the middle of its own button. Turning
            // the glyph alone, inside a frame that centres it, leaves nothing that can
            // drift: the frame is square to the world however far round the "+" has gone.
            icon("plus", isPrimary: false, rotation: .degrees(isAttaching ? 45 : 0))
        }
        .buttonStyle(.plain)
        .glassEffectID("attach", in: glass)
        .accessibilityLabel(Text(Strings.Room.attach))
        .accessibilityAddTraits(isAttaching ? .isSelected : [])
    }

    /// What the "+" becomes: photos from the system picker, everything else from the file
    /// importer. Both are the standard components, which is what gets us the system's own
    /// permission prompts, iCloud Drive and Files browsing for free.
    private var attachOptions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            attachOption(systemImage: "photo",
                         label: Strings.Room.attachPhoto,
                         id: "photo",
                         action: onChoosePhoto)

            attachOption(systemImage: "doc",
                         label: Strings.Room.attachFile,
                         id: "file",
                         action: onChooseFile)

            attachOption(systemImage: "mappin.and.ellipse",
                         label: Strings.Location.attach,
                         id: "location",
                         action: onChooseLocation)
        }
    }

    private func attachOption(systemImage: String,
                              label: LocalizedStringResource,
                              id: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            // Closed first: the picker it opens is a full-screen sheet, and coming back
            // from it to a composer still holding its choices open would be the app
            // asking a question it has already been answered.
            close()
            action()
        } label: {
            Label {
                Text(label)
                    .font(.body)
            } icon: {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Spacing.roomy)
            .frame(height: Theme.Size.composerControl)
            .navigationGlass(in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffectID(id, in: glass)
        // Each choice grows out of the button that produced it, rather than fading in
        // somewhere above it.
        .transition(.scale(scale: 0.1, anchor: .bottomLeading).combined(with: .opacity))
    }

    private func close() {
        guard isAttaching else { return }
        withAnimation(.smooth(duration: 0.3)) { isAttaching = false }
    }

    // MARK: - Buttons

    /// A circle exactly as tall as the text field, so the three controls read as one
    /// row rather than as a field with two lumps beside it.
    private func button(systemImage: String,
                        label: LocalizedStringResource,
                        isPrimary: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon(systemImage, isPrimary: isPrimary)
        }
        // Not `.buttonStyle(.glass)`. That style wraps the label in padding of its own,
        // on top of whatever frame we set, which is what made these bulge. The glass
        // goes on the circle itself instead, at the size we actually want.
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .transition(.scale.combined(with: .opacity))
    }

    /// Send keeps the accent — it is the one control in the room that is *about* the
    /// message you are writing, so it is painted the colour that message will arrive in.
    /// Everything else in the chrome is monochrome (see `IskraRootView`); the tint here is
    /// the exception the glass guidelines ask for, marking the one primary action.
    /// `tint` overrides the accent for the one control that is not about the accent: the
    /// microphone, while it is live. Red is not a colour this app chooses — it is what a
    /// recording light has been for a hundred years.
    @ViewBuilder
    private func icon(_ systemImage: String,
                      isPrimary: Bool,
                      tint: Color? = nil,
                      rotation: Angle = .zero) -> some View {
        let glyph = Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(isPrimary ? (tint != nil ? AnyShapeStyle(.white) : accent.foreground)
                                       : AnyShapeStyle(.primary))
            // Turned *before* the frame, so the frame still centres it. Rotation does not
            // change a view's layout size, so the glyph spins inside a square that never
            // moves — and the glass, applied after the frame, never turns at all.
            .rotationEffect(rotation)
            .frame(width: Theme.Size.composerControl, height: Theme.Size.composerControl)

        if isPrimary {
            glyph.primaryActionGlass(tint: tint ?? accent.color, in: .circle)
                .contentShape(.circle)
        } else {
            glyph.navigationGlass(in: .circle)
                .contentShape(.circle)
        }
    }
}
