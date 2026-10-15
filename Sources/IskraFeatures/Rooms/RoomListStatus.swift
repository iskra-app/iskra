import SwiftUI
import IskraCore
import IskraDesign

/// What the title of the chat list says while the list is not simply up to date — Telegram's
/// "Waiting for network…" and "Updating…", a small spinner beside the word, in place of "Chats".
///
/// Telegram has no banner for any of this. The title is where the eye already goes to ask "is this
/// current?", and a word there costs the list nothing: no strip pushing the first conversation down,
/// no screen in front of the chats while they are being read. Offline outranks updating, because an
/// update cannot happen without the network it is waiting for.
enum RoomListStatus: Hashable {
    case waitingForNetwork
    case updating

    init?(isOffline: Bool, isUpdating: Bool) {
        if isOffline {
            self = .waitingForNetwork
        } else if isUpdating {
            self = .updating
        } else {
            return nil
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .waitingForNetwork: Strings.RoomList.waitingForNetwork
        case .updating: Strings.RoomList.updating
        }
    }
}

/// The title bar's middle: "Chats", or the status with a spinner beside it.
///
/// The three never jump sideways into each other. The bar's middle is as wide as whatever is in
/// it, and the bar re-centres it *without* animation — so a word that grew or shrank, and a spinner
/// arriving to its left, used to snap the whole title to a new place. Here the slot is as wide as
/// the widest of the three, laid out and not drawn, and never changes; inside it the title slides
/// to its new centre, the spinner fades in or out at its side, and the words cross-fade.
struct RoomListTitle: View {
    let status: RoomListStatus?

    var body: some View {
        ZStack {
            ForEach(Self.all, id: \.self) { label($0).hidden() }
            label(status)
        }
        .animation(.easeInOut(duration: Theme.Timing.chrome), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func label(_ status: RoomListStatus?) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            if status != nil {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Text(status?.title ?? Strings.RoomList.title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.opacity)
        }
    }

    private static let all: [RoomListStatus?] = [nil, .updating, .waitingForNetwork]
}

/// The chat list before the first conversation has been read out of the store — the shapes of rows,
/// gently pulsing, where the rows are about to be.
///
/// It replaces a spinner with "Loading your messages…" under it, which was a screen standing in front
/// of the chats rather than the chats arriving. Telegram draws its list's outline on a first sign-in
/// for the same reason: the eye settles on where the conversations will be, and they appear in it.
/// Since the list now comes up after its first thirty rooms rather than after all of them
/// (`RoomListStore.firstPaint`), on an ordinary launch this is gone before it is noticed.
struct RoomListSkeleton: View {
    @State private var isDim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<Self.rows, id: \.self) { index in
                row(widths: Self.widths[index % Self.widths.count])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .opacity(isDim ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDim = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(widths: (CGFloat, CGFloat)) -> some View {
        HStack(spacing: Theme.Spacing.normal) {
            Circle()
                .fill(.quaternary)
                .frame(width: Theme.Size.roomAvatar, height: Theme.Size.roomAvatar)
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                Capsule().fill(.quaternary).frame(width: widths.0, height: Theme.Spacing.normal)
                Capsule().fill(.quaternary.opacity(0.7)).frame(width: widths.1, height: Theme.Spacing.normal)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.close)
    }

    private static let rows = 9
    /// Not all the same length, so the outline reads as a list of different conversations rather
    /// than as a pattern.
    private static let widths: [(CGFloat, CGFloat)] = [(120, 200), (160, 140), (96, 220), (140, 180), (112, 160)]
}
