import SwiftUI
import IskraDesign

/// Whether the app can reach the homeserver, made available to every screen at once.
///
/// It travels through the environment rather than being handed to each view, because the fact
/// belongs to the session and the screens that need it are in different branches of the tree — the
/// conversation list and the room. `RoomListStore.isOffline` is where it comes from, and
/// `IskraRootView` is the single place that puts it here.
private struct OfflineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var isOffline: Bool {
        get { self[OfflineKey.self] }
        set { self[OfflineKey.self] = newValue }
    }
}

/// The strip that says the network is gone.
///
/// An *inset* and not an overlay, for the same reason the search field below the conversation list
/// is one: an inset reserves its space, so the first conversation can still be scrolled clear of it
/// instead of living underneath it for as long as the network is away.
///
/// No glass on it. Liquid Glass is the navigation layer in this app — toolbars, the composer,
/// floating controls — and this is a statement about the content, sitting on top of it.
struct OfflineBanner: View {
    var body: some View {
        Text(Strings.Connection.offline)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.close)
            .background(.bar)
    }
}

extension View {
    /// Puts the strip above this screen while the app is offline, and takes it away when it is not.
    func offlineBanner() -> some View {
        modifier(OfflineBannerModifier())
    }
}

private struct OfflineBannerModifier: ViewModifier {
    @Environment(\.isOffline) private var isOffline

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if isOffline {
                    OfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // The strip appearing is news, and news that slides in reads as news. Snapping it in and
            // out — which is what an unanimated `safeAreaInset` does, geometry and all — makes the
            // whole screen jump, and a screen that jumps while somebody is reading looks like a bug
            // rather than like an answer to the question they were about to ask.
            .animation(.easeInOut(duration: Theme.Timing.chrome), value: isOffline)
    }
}
