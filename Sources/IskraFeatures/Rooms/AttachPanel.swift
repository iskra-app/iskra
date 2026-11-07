import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// The "+" items that grow into a window at the bottom of the screen. The raw value is the name
/// the item's glass and the window's glass share, which is what makes one flow into the other.
///
/// A file is not here: picking one is the system's importer and nothing else, and it has no window
/// of its own to grow into.
enum AttachPanelKind: String {
    case photos = "photo"
    case location
    case poll
}

/// How big the window is. Arithmetic rather than layout, so that a test can look at it.
enum AttachPanelLayout {
    /// About three by four, as wide as the composer lets it — and shorter wherever there is less
    /// room above it than that: a phone on its side, or the keyboard up under a poll.
    static func size(composerWidth: CGFloat, composerBottom: CGFloat) -> CGSize {
        let width = min(max(composerWidth - 2 * Theme.Spacing.normal, 0), Theme.Size.attachPanelMaxWidth)
        let room = max(composerBottom - Theme.Size.attachPanelTopClearance, 0)
        return CGSize(width: width, height: min(width * 4 / 3, room))
    }
}

/// Where the window sits: in the middle of the composer's width, whatever `AttachPanelLayout` left
/// of it, and from the composer's bottom on past it, nearly to the edge of the screen. Only the
/// container's safe area is ignored and not the keyboard's, so a poll being typed
/// stays above the keys.
///
/// For what is in the window, which is drawn outside the composer's glass container. The glass it
/// stands on is the choice itself and gets to the same pixels by padding — see `MessageComposer`.
struct AttachPanelPlacement: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.bottom, Theme.Spacing.close)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// What is in a window growing with the glass around it, in the window's own coordinates.
///
/// Laid out at its final size throughout, because the picker and the map would lay themselves out
/// afresh on every frame otherwise; so it is cut to the shape the glass has at that moment, the
/// glass being on the same spring in the same transaction. Fading in over the window instead, it
/// looked like something laid on top of the glass and not something inside it.
///
/// Animatable, so that the body runs on every frame and the fade can end before the growth does.
struct AttachPanelReveal: ViewModifier, Animatable {
    var progress: CGFloat
    let origin: CGRect
    let startRadius: CGFloat
    let size: CGSize

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let shape = RevealShape(rect: CGRect(x: origin.minX * (1 - progress),
                                             y: origin.minY * (1 - progress),
                                             width: origin.width + (size.width - origin.width) * progress,
                                             height: origin.height + (size.height - origin.height) * progress),
                                radius: startRadius + (Theme.Radius.attachPanel - startRadius) * progress)
        let anchor = UnitPoint(x: size.width > 0 ? origin.midX / size.width : 0,
                               y: size.height > 0 ? origin.midY / size.height : 1)
        content
            .scaleEffect(0.9 + 0.1 * progress, anchor: anchor)
            // Nothing for the first moment, while the shape is still the size of a choice.
            .opacity(min(max((progress - 0.1) * 2.5, 0), 1))
            .clipShape(shape)
    }

    private struct RevealShape: Shape {
        let rect: CGRect
        let radius: CGFloat

        func path(in _: CGRect) -> Path {
            Path(roundedRect: rect, cornerRadius: min(radius, min(rect.width, rect.height) / 2), style: .continuous)
        }
    }
}

extension AnyTransition {
    static func attachPanelReveal(from origin: CGRect, startRadius: CGFloat, size: CGSize) -> AnyTransition {
        .modifier(active: AttachPanelReveal(progress: 0, origin: origin, startRadius: startRadius, size: size),
                  identity: AttachPanelReveal(progress: 1, origin: origin, startRadius: startRadius, size: size))
    }
}

/// What every window has: its content filling it, opaque, and floating over the bottom of that a
/// way back on the left and the one thing to do on the right.
///
/// Opaque, because what is in here is content and glass does not go on content. The surface under
/// it is glass only so that there is something to morph: the choice in `MessageComposer`, grown.
struct AttachPanelChrome<Content: View, Above: View, Action: View>: View {
    let onBack: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let above: Above
    @ViewBuilder let action: Action

    /// How far the floating buttons reach up from the bottom of the window, for content that
    /// scrolls and has to be able to get out from under them.
    static var buttonClearance: CGFloat {
        Theme.Size.composerControl + 2 * Theme.Spacing.roomy
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .overlay(alignment: .bottom) {
                NavigationGlassGroup(spacing: Theme.Spacing.close) {
                    VStack(spacing: Theme.Spacing.close) {
                        above
                        HStack(spacing: Theme.Spacing.close) {
                            AttachPanelCircle(systemImage: "chevron.backward",
                                              label: Strings.Room.attachBack,
                                              action: onBack)
                                .keyboardShortcut(.cancelAction)
                            Spacer(minLength: 0)
                            action
                        }
                    }
                }
                .padding(Theme.Spacing.roomy)
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.attachPanel, style: .continuous))
            .contentShape(.rect(cornerRadius: Theme.Radius.attachPanel, style: .continuous))
    }
}

extension AttachPanelChrome where Above == EmptyView {
    init(onBack: @escaping () -> Void,
         @ViewBuilder content: () -> Content,
         @ViewBuilder action: () -> Action) {
        self.init(onBack: onBack, content: content, above: { EmptyView() }, action: action)
    }
}

/// A round button floating over a window: the way back, or "my location".
struct AttachPanelCircle: View {
    let systemImage: String
    let label: LocalizedStringResource
    let action: () -> Void

    @ScaledSize(Theme.Size.composerControl) private var control

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: control, height: control)
                .navigationGlass(in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// A capsule floating over a window. Primary is the one that finishes the job, painted the accent
/// the way the composer's send button is; one that cannot be pressed yet goes back to plain glass,
/// because an accent says "press me".
struct AttachPanelAction: View {
    let label: LocalizedStringResource
    var systemImage: String?
    var isPrimary = false
    var isEnabled = true
    let action: () -> Void

    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme
    @ScaledSize(Theme.Size.composerControl) private var control

    var body: some View {
        Button(action: action) {
            title
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, Theme.Spacing.roomy)
                .frame(height: control)
                .modifier(Surface(isTinted: isPrimary && isEnabled, tint: accent.color))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var title: some View {
        if let systemImage {
            Label { Text(label) } icon: { Image(systemName: systemImage) }
        } else {
            Text(label)
        }
    }

    private var foreground: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.secondary) }
        return isPrimary ? accent.foreground(in: scheme) : AnyShapeStyle(.primary)
    }

    private struct Surface: ViewModifier {
        let isTinted: Bool
        let tint: Color

        @ViewBuilder
        func body(content: Content) -> some View {
            if isTinted {
                content.primaryActionGlass(tint: tint, in: .capsule)
            } else {
                content.navigationGlass(in: .capsule)
            }
        }
    }
}

/// The photo window: the system's own picker, drawn in place.
///
/// The system's and not a grid of our own, because this one runs out of process and needs no
/// permission. A grid of our own would need `NSPhotoLibraryUsageDescription`, the very key
/// `project.yml` explains the absence of: a messenger asking to see every photograph somebody has.
///
/// Ticks and not a tap that sends, up to the same ten the full picker allows. The moment something
/// is ticked, "All Photos" has become "Add": two ways out of one grid with two different results
/// would ask somebody to work out which ticks a second picker keeps.
struct PhotoAttachPanel: View {
    let onBack: () -> Void
    let onAllPhotos: () -> Void
    let onAdd: ([PhotosPickerItem]) -> Void

    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        AttachPanelChrome(onBack: onBack) {
            PhotosPicker(selection: $selection,
                         maxSelectionCount: PendingAttachment.pickLimit,
                         selectionBehavior: .continuousAndOrdered,
                         matching: .any(of: [.images, .videos])) {
                EmptyView()
            }
            .photosPickerStyle(.inline)
            .photosPickerDisabledCapabilities([.selectionActions, .search, .collectionNavigation, .stagingArea])
            .photosPickerAccessoryVisibility(.hidden, edges: .all)
            .ignoresSafeArea()
        } action: {
            if selection.isEmpty {
                AttachPanelAction(label: Strings.Room.attachAllPhotos, action: onAllPhotos)
            } else {
                AttachPanelAction(label: Strings.Room.attachAddPhotos(selection.count), isPrimary: true) {
                    onAdd(selection)
                }
            }
        }
        .animation(.smooth(duration: Theme.Timing.chrome), value: selection.isEmpty)
    }
}
