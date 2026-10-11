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

    /// Whether the microphone is still listening. False when iOS ended the recording without being
    /// asked — the five-minute cap, an incoming call, the app being put away — and what was said is
    /// sitting there waiting to be sent. See `RecordingStrip.isLive`.
    let isLive: Bool
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

    /// Where the text begins on the screen, reported as it moves — see `ComposerTravel`.
    var onTextLeading: (CGFloat) -> Void = { _ in }

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

    /// The swipe up, reported outward on every movement of the finger and not merely when it
    /// arrives.
    ///
    /// The composer draws its own `RecordLock` from this and would need no callback at all, but
    /// for the camera: a video note puts a full-screen overlay over the composer, so the pill the
    /// thumb is climbing towards is behind a blur, and the *screen* has to hand the same value to
    /// `VideoNoteComposer` to be redrawn above the shutter. The gesture stays here, where the
    /// finger is. Only its state of play travels.
    var onLockGesture: (LockGesture) -> Void = { _ in }

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

    /// Photos and videos — picked, pasted or dropped into the room — waiting to go with the next
    /// press of send. See `PendingAttachment` for why they wait at all. The screen owns them,
    /// because the drop lands on the whole room and not on this bar.
    var attachments: [PendingAttachment] = []
    var onRemoveAttachment: (PendingAttachment) -> Void = { _ in }

    /// Reads the clipboard's photos and videos into `attachments`. Asking, not reading: the screen
    /// does the reading, for the same reason it presents the pickers.
    var onPasteImage: () -> Void = {}

    /// Whether the clipboard had a photo or video on it when the "+" was opened, which is when
    /// "Paste" is offered. Looked at then and not continuously: there is no notification
    /// for the clipboard changing on the Mac, and polling it would be the app watching what the
    /// user copies.
    @State private var canPasteImage = false

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

    /// The round buttons, and the field's resting height, at whatever size the reader's text has
    /// grown them to.
    ///
    /// These hold SF Symbols, and a symbol scales with the font whether the button does or not. At
    /// the accessibility sizes the glyph simply grew out of its 44pt circle and was clipped by it —
    /// a send button with the corners bitten off. See `ScaledSize`, and note the cap: the buttons
    /// grow enough to hold their own contents, not enough to leave no room for the message.
    @ScaledSize(Theme.Size.composerControl) private var control

    init(draft: Binding<String>,
         context: ComposerContext? = nil,
         onCancelContext: @escaping () -> Void = {},
         onTextLeading: @escaping (CGFloat) -> Void = { _ in },
         onSend: @escaping () -> Void,
         onStartVideoNote: @escaping () -> Void = {},
         onFinishVideoNote: @escaping () -> Void = {},
         onCancelVideoNote: @escaping () -> Void = {},
         onLockVideoNote: @escaping () -> Void = {},
         onStartVoice: @escaping () -> Void = {},
         onFinishVoice: @escaping () -> Void = {},
         onCancelVoice: @escaping () -> Void = {},
         onLockGesture: @escaping (LockGesture) -> Void = { _ in },
         voice: VoiceRecording? = nil,
         onChoosePhoto: @escaping () -> Void,
         onChooseFile: @escaping () -> Void,
         onChooseLocation: @escaping () -> Void = {},
         attachments: [PendingAttachment] = [],
         onRemoveAttachment: @escaping (PendingAttachment) -> Void = { _ in },
         onPasteImage: @escaping () -> Void = {},
         isAttaching: Bool = false,
         locking: LockGesture = LockGesture()) {
        _draft = draft
        self.context = context
        self.onCancelContext = onCancelContext
        self.onTextLeading = onTextLeading
        self.onSend = onSend
        self.onStartVideoNote = onStartVideoNote
        self.onFinishVideoNote = onFinishVideoNote
        self.onCancelVideoNote = onCancelVideoNote
        self.onLockVideoNote = onLockVideoNote
        self.onStartVoice = onStartVoice
        self.onFinishVoice = onFinishVoice
        self.onCancelVoice = onCancelVoice
        self.onLockGesture = onLockGesture
        self.voice = voice
        self.onChoosePhoto = onChoosePhoto
        self.onChooseFile = onChooseFile
        self.onChooseLocation = onChooseLocation
        self.attachments = attachments
        self.onRemoveAttachment = onRemoveAttachment
        self.onPasteImage = onPasteImage
        _isAttaching = State(initialValue: isAttaching)
        _locking = State(initialValue: locking)
    }

    @FocusState private var isFocused: Bool

    @Environment(\.accent) private var accent

    /// Which way round the mono accent's label goes — see the foreground in `icon`.
    @Environment(\.colorScheme) private var scheme

    /// The one namespace the glass morphs across. Every piece of glass that should flow
    /// into another — the "+" and the two choices it becomes — is identified within it.
    @Namespace private var glass

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What is waiting, as far as this press of send is concerned. None while editing: an edit
    /// changes the words of a message already sent and cannot add a photograph to it, so the
    /// attachments step aside — kept, and back the moment the edit is done or abandoned.
    private var pendingAttachments: [PendingAttachment] {
        context?.isEditing == true ? [] : attachments
    }

    /// Whether there is anything to send: words, or attachments, or both.
    private var hasSomethingToSend: Bool {
        !isEmpty || !pendingAttachments.isEmpty
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

                if !pendingAttachments.isEmpty {
                    attachmentStrip
                }

                // Bottom-aligned, so the round buttons stay level with the last line of a
                // message that has grown to several lines rather than riding its middle.
                HStack(alignment: .bottom, spacing: Theme.Spacing.close) {
                    // The "+" is not offered mid-recording: attaching a photograph to a voice
                    // message you are in the middle of speaking is not a thing, and the choices
                    // would open over the strip that is telling you how to send it.
                    //
                    // Offered offline, though — and it briefly was not. An attachment goes into the
                    // same on-disk send queue as a typed message: the SDK caches its content the
                    // moment it is queued and uploads it whenever there is a network to upload it
                    // with, tomorrow if need be. The composer is the one part of this app that keeps
                    // working with no network at all, and it keeps working for photographs too.
                    if voice == nil {
                        attachButton
                    }

                    if let voice {
                        RecordingStrip(elapsed: voice.elapsed,
                                       waveform: voice.waveform,
                                       isLive: voice.isLive,
                                       onCancel: onCancelVoice)
                            // Out by shrinking as it fades, and that is not decoration: sending and
                            // cancelling both simply *stop* the recorder, and the strip was
                            // vanishing between one frame and the next — a minute of somebody's
                            // voice disappearing with less ceremony than a keystroke, and no way
                            // to tell the send from the cancel by looking. The animation that
                            // drives this is on the stack below; the transition here is only what
                            // it does with it.
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    } else {
                        TextField(String(app: Strings.Room.composerPlaceholder), text: $draft, axis: .vertical)
                            .transition(.opacity)
                            .textFieldStyle(.plain)
                            // Where the words start on the screen — the point a sent message
                            // travels across from. Measured on the bare field, inside its padding,
                            // so it is the first letter's edge and not the glass around it.
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                                onTextLeading($0)
                            }
                            .lineLimit(1...5)
                            .focused($isFocused)
                            .padding(.horizontal, Theme.Spacing.roomy)
                            .padding(.vertical, Theme.Spacing.normal)
                            .frame(minHeight: control)
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
                    } else if !hasSomethingToSend {
                        recordButton
                    } else {
                        button(systemImage: "arrow.up",
                               label: Strings.Room.send,
                               isPrimary: true,
                               action: onSend)
                    }
                }
            }
            // A recording beginning and a recording ending are the two moments this bar changes
            // shape, and both were instantaneous. Scoped to whether there *is* one — not to the
            // recording itself, which changes ten times a second as the waveform grows, and
            // animating the composer on each of those would set it breathing.
            .animation(.smooth(duration: 0.25), value: voice == nil)
            // Answering a message puts the cursor in the field and the keyboard on screen.
            //
            // Choosing "Reply" — from the menu, or by swiping the bubble — *is* the decision to
            // write something; asking for a second tap on the field afterwards is asking twice. The
            // same goes for an edit, where the words are already in the field waiting to be changed.
            //
            // Watching the context rather than the message, so that moving from answering one
            // message to answering another does not steal focus back from a field the user is
            // already typing in — they are the same gesture, and it only matters that the keyboard
            // is up, which it already is.
            .onChange(of: context == nil) { _, isPlainDraft in
                if !isPlainDraft { isFocused = true }
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
        // Above the record button, outside the `GlassEffectContainer` and deliberately so: the
        // pill is glass, and glass placed *inside* that container is gathered into the container's
        // one surface and drawn in the container's own pass — which is how the attach options
        // learned to appear over the conversation when they were supposed to be invisible. The
        // pill has nothing to morph into and nothing to morph out of. It wants no part of it.
        //
        // Lifted by the composer's own measured height, the same arithmetic the attach options
        // use, and centred over the button by taking exactly that button's width off the trailing
        // edge.
        .overlay(alignment: .bottomTrailing) {
            if locking.isVisible {
                RecordLock(gesture: locking)
                    .frame(width: control)
                    .padding(.trailing, Theme.Spacing.normal)
                    .offset(y: -(height + Theme.Spacing.close))
                    .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: Theme.Timing.chrome), value: hasSomethingToSend)
        .animation(.smooth(duration: Theme.Timing.chrome), value: pendingAttachments)
        .animation(.smooth(duration: Theme.Timing.chrome), value: context)
        .animation(.smooth(duration: Theme.Timing.chrome), value: locking.isVisible)
        // The phone answering the finger. There is nothing else that can: a hold that has taken
        // begins a recording the user cannot see (a video note's camera takes a moment to wake,
        // and a spoken message has no camera at all), so without this the first half-second of
        // every recording is the user wondering whether they are recording.
        //
        // Three moments and three different taps, because they mean three different things — the
        // recording began, the swipe caught, the recording was thrown away. Counters and not
        // booleans: `sensoryFeedback` fires on a *change*, and a second recording started after a
        // first would set an already-true flag to true and be felt by nobody.
        //
        // Heavy and at full intensity. A medium tap is what a button gives you, and the button is
        // not what happened here — the hold took, and the phone started listening. It should land
        // like the shutter of a camera, not like a keypress.
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: beats.began)
        .sensoryFeedback(.success, trigger: beats.locked)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: beats.cancelled)
        .onDisappear {
            arming?.cancel()
            arming = nil
            unlatch?.cancel()
            unlatch = nil
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

    // MARK: - Waiting photos and videos

    /// What is waiting to go, in a row above the field, each with a way to take it back.
    ///
    /// Part of the composer's own height, like the reply strip, and for the same reason: the
    /// conversation *should* move up for it, because what is about to be sent is now taller.
    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.close) {
                ForEach(pendingAttachments) { image in
                    attachmentTile(image)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(Theme.Spacing.close)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func attachmentTile(_ image: PendingAttachment) -> some View {
        Group {
            if let preview = image.preview {
                Image(decorative: preview, scale: 1).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: Theme.Size.attachmentTile, height: Theme.Size.attachmentTile)
        .clipShape(.rect(cornerRadius: Theme.Radius.control, style: .continuous))
        // A video is told from a photo by the glyph a video has worn everywhere since there were
        // videos, and nothing else: the still alone is just a photo.
        .overlay {
            if image.isVideo {
                Image(systemName: "play.fill")
                    .font(.body)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onRemoveAttachment(image)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding(Theme.Spacing.tight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Room.removeAttachment))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(image.isVideo ? Strings.Room.attachedVideo : Strings.Room.attachedPhoto))
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
        // The gesture is hung on a plain fixed-size shape, and the button is *drawn into* it —
        // rather than the gesture being hung on the button, which is where it used to be and is
        // the obvious place for it.
        //
        // It cannot live there. `icon` chooses between two branches — tinted glass while a
        // recording runs, plain glass otherwise — and a SwiftUI `if` is a change of identity, not
        // a change of appearance: when the recording starts and the button turns red, the old view
        // is destroyed and a new one is built in its place. Any gesture attached to it is
        // destroyed with it, mid-hold, with the finger still down. `onEnded` then never arrives
        // for the touch that is currently happening, which is the touch that was going to send the
        // message.
        //
        // This shape is the same shape in every state, so it survives everything drawn on top of
        // it — and the hold survives with it.
        Color.clear
            .frame(width: control, height: control)
            .overlay { icon(glyph, isPrimary: voice != nil, tint: .red) }
            .contentShape(.circle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Kept on every movement, whatever the hold is doing with it — including
                        // during `.pressing`, when the gesture has nothing to say about it yet.
                        // That is the point: see the arming task below. Written through the box
                        // rather than into `@State`, because a `@State` written here re-renders
                        // the composer on every point of a held thumb's drift — see `Travel`.
                        travel.translation = value.translation

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
                                beats.began += 1
                                publish(LockGesture(isVisible: true))

                                // The finger has been moving for a quarter of a second while we
                                // worked out whether it meant anything, and it does not wait for
                                // us to catch up: a brisk hold-and-flick up arrives at the top of
                                // its swipe *before* this task runs, and then stops. The gesture
                                // is over as far as the thumb is concerned, `onChanged` will
                                // never fire again — and the recording it started a moment ago is
                                // not locked, so letting go sends it. Which is exactly what the
                                // user was swiping up to prevent.
                                //
                                // So the swipe is read once more, now, against where the finger
                                // actually is rather than where it was when it came down.
                                steer(travel.translation)
                            }

                        case .pressing:
                            // Still deciding whether this is a tap. There is nothing recording
                            // yet, so there is nothing a swipe could cancel or lock.
                            break

                        case .holding:
                            steer(value.translation)

                        case .over:
                            // Already cancelled or locked. The finger is still on the glass and
                            // has nothing left to say.
                            break
                        }
                    }
                    .onEnded { _ in
                        let ending = hold
                        hold = .none
                        travel.translation = .zero
                        arming?.cancel()
                        arming = nil

                        // A hold that ended in a swipe has already put the pill where it belongs
                        // — gone, if the swipe cancelled; showing its shut lock, if it caught —
                        // and clearing it here would wipe out the one confirmation the user gets.
                        if ending != .over { publish(LockGesture()) }

                        switch ending {
                        case .pressing:
                            // Too quick to be a hold. Which stops a hands-free recording if one
                            // is running, and otherwise flips the button to the other kind of
                            // message.
                            if voice == nil {
                                withAnimation(.smooth(duration: Theme.Timing.chrome)) { mode.toggle() }
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
            // The hold is not a gesture VoiceOver can perform — and this used to say so and then do
            // nothing about it. The button carried a label, a hint and `.isButton`, and underneath
            // it was a `DragGesture` on a clear rectangle: VoiceOver does not synthesise a drag, so
            // a double tap on it did *nothing whatsoever*. There was no way to record a voice
            // message. The comment here explained the problem and called it the solution.
            //
            // A default action is what a double tap actually runs, so that is what recording hangs
            // off now: press once to begin, press again to finish and send. It is the hands-free
            // path — the one the swipe up gives everybody else — reached by the gesture VoiceOver
            // has. Cancelling is offered as an action of its own, because the way out of a
            // recording must not be a swipe either.
            //
            // What it *says* follows the glyph and not the mode. While a recording runs this is a
            // send button, and it used to go on announcing itself as "record a voice message" —
            // telling a VoiceOver user that the button which ends their recording will begin one.
            .accessibilityLabel(Text(recordLabel))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(Strings.Recording.hint))
            .accessibilityAction {
                if voice == nil {
                    // Nothing is running: begin, and lock it straight away. A recording that
                    // depended on a finger staying down would end the moment VoiceOver moved the
                    // focus — which it does, constantly, because that is how it is used.
                    start()
                    lock()
                } else {
                    finish()
                }
            }
            .accessibilityActions {
                // The switch is offered only when there is nothing running to switch *under*.
                // Toggling `mode` mid-recording left the composer describing a video message while
                // the microphone was still on, and `finish()` and `lock()` both dispatch on `mode`
                // — so the next thing the user did would have been routed to the wrong recorder.
                if voice == nil {
                    Button(mode == .voice ? Strings.Recording.switchToVideo
                                          : Strings.Recording.switchToVoice) {
                        mode.toggle()
                    }
                } else {
                    Button(Strings.Recording.cancel) { cancel() }
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
        case .video:
            // The keyboard goes down first. The camera comes up as an overlay over the whole
            // room, and a keyboard left standing underneath it holds the bottom half of the
            // screen: the circle is squeezed into what is left, the shutter sits above a bar of
            // letters nobody can see, and the first thing that happens when the message is sent
            // is the room jumping as the keyboard finally leaves. Nothing being recorded is
            // typed, so nothing here needs it.
            isFocused = false
            onStartVideoNote()
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

    /// Where the thumb is going, and whether it has got there.
    ///
    /// Called on every movement of a finger that is holding a live recording, and once more the
    /// moment the recording begins — see the arming task. Left throws the recording away, up
    /// carries it on without the finger, and everything short of either is the *reach*: how far
    /// along one of those two roads the thumb has come, which is the number `RecordLock` draws.
    ///
    /// Left is handled here rather than left to the strip's Cancel button because that button
    /// cannot be reached without lifting the finger — and lifting the finger is what *sends*. A
    /// recording being held has to have a way out that does not go through releasing it.
    private func steer(_ translation: CGSize) {
        guard hold == .holding else { return }

        let up = min(1, max(0, -translation.height) / Theme.Size.gestureReach)
        let left = min(1, max(0, -translation.width) / Theme.Size.gestureReach)

        // Cancel is asked first, and the reach follows whichever way the thumb is actually going,
        // so that a swipe left along a slightly wonky line does not fill the lock pill on its way
        // out. A thumb travelling left is leaving; it should not be shown as nearly arriving.
        if left >= 1 {
            hold = .over
            publish(LockGesture())
            beats.cancelled += 1
            cancel()
            return
        }

        if up >= 1 {
            hold = .over
            publish(LockGesture(reach: 1, isVisible: true, hasLocked: true))
            beats.locked += 1
            latch()
            lock()
            return
        }

        publish(LockGesture(reach: up > left ? up : 0, isVisible: true))
    }

    /// Kept here and reported out to the screen in the same breath — the composer draws its own
    /// pill from it, and the camera overlay, which is covering that pill with a blur, needs the
    /// same value to draw its own.
    private func publish(_ gesture: LockGesture) {
        guard locking != gesture else { return }
        locking = gesture
        onLockGesture(gesture)
    }

    /// Having locked, says so — for a second, and then it goes.
    ///
    /// The lock is otherwise entirely invisible: a locked recording and a held one look exactly
    /// alike, and the user has just made a movement whose whole purpose was to change which of
    /// the two they are in. So the pill stays behind with its lock shut. Long enough to be seen;
    /// short enough to be gone before the thumb comes back down for the send button beneath it.
    private func latch() {
        unlatch?.cancel()
        unlatch = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            publish(LockGesture())
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

    /// Where the finger has got to, kept from one `onChanged` to the next. A `DragGesture` hands
    /// its translation to whoever is listening at the time, and the arming task is not listening
    /// at the time — it needs to know, a quarter of a second late, where the finger went while it
    /// was making up its mind.
    ///
    /// A box, and not a `@State CGSize`, and the difference is the whole of a bug. A finger held
    /// still on a button is never actually still: `onChanged` fires on every point of drift, so a
    /// plain `@State` written from there re-renders the composer *continuously, throughout the
    /// hold* — and a composer that re-renders under a live gesture is a composer that can take
    /// that gesture away. The record button switches branch when the recording starts (see
    /// `icon`), SwiftUI rebuilds it, the `DragGesture` goes with it, and `onEnded` never comes.
    /// Nothing then ends the recording: it looked, precisely, like a voice message that had
    /// locked itself the instant it began and could only be sent by tapping the button again.
    ///
    /// Nobody draws the finger's position. It has no business in the view's state, and the box is
    /// what keeps it out: writing through a reference changes no `@State` value, so SwiftUI has
    /// nothing to invalidate and the gesture is left alone to finish what it started.
    @State private var travel = Travel()

    @MainActor
    final class Travel {
        var translation: CGSize = .zero
    }

    /// The swipe up, as the pill draws it — and as the screen passes it to the camera. Written in
    /// exactly one place, `publish`, so that the two copies can never disagree.
    ///
    /// Settable at birth for the same reason `isAttaching` is, and it is worth saying twice: the
    /// app never builds a composer mid-swipe, and `ComposerLayoutTests` does — because the pill
    /// hangs above the composer on the same arithmetic the attach menu uses, and that arithmetic
    /// has been wrong before, in a way that drew a floating control straight over the field it
    /// floats above.
    @State private var locking: LockGesture

    /// What takes the confirmation back down again a second after the lock caught. See `latch`.
    @State private var unlatch: Task<Void, Never>?

    /// The three things the phone taps back at, counted rather than flagged — see the feedback
    /// modifiers on the body for why.
    private struct Beats: Equatable {
        var began = 0
        var locked = 0
        var cancelled = 0
    }

    @State private var beats = Beats()

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
            if !isAttaching { canPasteImage = MediaPasteboard.hasMedia }
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

            if canPasteImage {
                attachOption(systemImage: "doc.on.clipboard",
                             label: Strings.Room.pasteImage,
                             id: "paste",
                             action: onPasteImage)
            }
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
            .frame(height: control)
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
            // `foreground(in:)` and not `foreground`. The difference is the whole of why the send
            // button came out blank on the colourless theme: mono's plain `foreground` is
            // `.background`, a *contextual* style meaning "the background of whatever this is drawn
            // into" — and what this is drawn into is a pill of glass, so the arrow was painted the
            // colour of the pill it was written on. `AccentTheme` already spells the pair out for
            // exactly this case; the composer was the one place still asking the other way.
            .foregroundStyle(isPrimary ? (tint != nil ? AnyShapeStyle(.white) : accent.foreground(in: scheme))
                                       : AnyShapeStyle(.primary))
            // Turned *before* the frame, so the frame still centres it. Rotation does not
            // change a view's layout size, so the glyph spins inside a square that never
            // moves — and the glass, applied after the frame, never turns at all.
            .rotationEffect(rotation)
            .frame(width: control, height: control)

        if isPrimary {
            glyph.primaryActionGlass(tint: tint ?? accent.color, in: .circle)
                .contentShape(.circle)
        } else {
            glyph.navigationGlass(in: .circle)
                .contentShape(.circle)
        }
    }
}
