import IskraDesign
import SwiftUI

/// "Тонировать интерфейс": a single translucent sheet of the accent, laid over a whole window.
///
/// An *overlay* and not a background: the screens sit on the system's own grouped-list and page
/// backgrounds, which are opaque and answer to no colour handed down, so a tint laid under them
/// would never be seen. Over everything, ignoring the safe area and deaf to touches, it reaches the
/// backgrounds, the content and the words with one lever. Faint enough (`Theme.Tint.interface`) that
/// it colours rather than dims.
///
/// At the root, and again on every sheet (`pageSheet`, `reactorsSheet`): an overlay at the root sits
/// *under* a sheet, which on a Mac is a window of its own.
struct InterfaceWash: ViewModifier {
    @AppStorage(AccentTheme.storageKey) private var accent: AccentTheme = .default
    @AppStorage(AccentTheme.tintsInterfaceKey) private var isOn = AccentTheme.tintsInterfaceByDefault
    @State private var holes = WashHoles()

    func body(content: Content) -> some View {
        content
            .environment(\.washHoles, holes)
            .overlay {
                if isOn {
                    GeometryReader { window in
                        let origin = window.frame(in: .global).origin
                        WashSheet(holes: holes.frames.values.map { $0.moved(by: origin) })
                            .fill(accent.color.opacity(accent.washOpacity), style: FillStyle(eoFill: true))
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
            .animation(.smooth(duration: Theme.Timing.reaction), value: isOn)
    }
}

extension View {
    func interfaceWash() -> some View {
        modifier(InterfaceWash())
    }

    /// Cuts this view out of the wash: a home icon or a wallpaper being chosen has to look as it will
    /// look, and the icon on the home screen is not yellow. Measured rather than drawn above the
    /// wash, because the wash is over the whole window and nothing inside a screen can stand on it.
    func outsideWash(cornerRadius: CGFloat) -> some View {
        modifier(OutsideWash(cornerRadius: cornerRadius))
    }
}

extension EnvironmentValues {
    @Entry var washHoles: WashHoles?
}

/// What the wash leaves out, in global coordinates. Global, because a pushed screen and the root
/// that owns the wash are not always in one SwiftUI coordinate space.
@MainActor @Observable
final class WashHoles {
    struct Hole: Equatable {
        var frame: CGRect
        var cornerRadius: CGFloat

        func moved(by origin: CGPoint) -> Hole {
            Hole(frame: frame.offsetBy(dx: -origin.x, dy: -origin.y), cornerRadius: cornerRadius)
        }
    }

    var frames: [UUID: Hole] = [:]
}

private struct WashSheet: Shape {
    let holes: [WashHoles.Hole]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes {
            path.addRoundedRect(in: hole.frame,
                                cornerSize: CGSize(width: hole.cornerRadius, height: hole.cornerRadius),
                                style: .continuous)
        }
        return path
    }
}

private struct OutsideWash: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.washHoles) private var holes
    @State private var id = UUID()
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                self.frame = frame
                report(frame)
            }
            // Told again on the way back from a pushed screen: nothing has moved, so the geometry
            // has nothing to say, and the hole went when the screen was covered.
            .onAppear { if let frame { report(frame) } }
            .onDisappear { holes?.frames[id] = nil }
    }

    private func report(_ frame: CGRect) {
        holes?.frames[id] = WashHoles.Hole(frame: frame, cornerRadius: cornerRadius)
    }
}
