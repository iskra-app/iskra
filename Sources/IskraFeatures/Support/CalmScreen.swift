import IskraCore
import IskraDesign
import SwiftUI

/// The calm look's pieces that know about screens: the backdrop, and the forms and lists on it. See `DesignLanguage`; in the classic look all of this is nothing.
extension View {
    /// The look's type, for everything below. On the root, and on the shield, which lives in a window
    /// of its own. No `foregroundStyle` here: set this high it overrides the grey of a form's footers
    /// and the red of a destructive button.
    func calmType(_ design: DesignLanguage) -> some View {
        modifier(CalmType(design: design))
    }

    /// The capsule that carries white words over a photograph: the clock in its corner. A dark
    /// plate in the classic look, dark glass in the calm one, dark because the words are white
    /// whatever the appearance.
    func photoPlate() -> some View {
        modifier(PhotoPlate())
    }

    /// What goes under a banner's wash. The chat list scrolls beneath its banners, and a wash alone
    /// lets the rows show through the words.
    func bannerGround() -> some View {
        modifier(BannerGround())
    }

    /// A row of a plain list, letting the backdrop show through: a plain `List` paints its rows
    /// opaque otherwise. Not in a sidebar, whose selection is drawn there.
    func calmListRow() -> some View {
        modifier(CalmListRow())
    }

    /// Reads the colour of a conversation's avatar, for everything below that stands on its shade:
    /// the conversation and its info screen.
    func calmRoomHue(avatarURL: String?) -> some View {
        modifier(CalmRoomHue(avatarURL: avatarURL))
    }

    /// The same for settings and everything pushed from them: the colour of your own avatar.
    func calmOwnHue() -> some View {
        modifier(CalmOwnHue())
    }

    /// Stands a screen on the calm backdrop, in the shade of the conversation it belongs to if it
    /// belongs to one, and otherwise the shade of the person using it: the list, settings.
    func calmScreen(isDimmed: Bool = false) -> some View {
        modifier(CalmScreen(isDimmed: isDimmed))
    }
}

private struct CalmType: ViewModifier {
    let design: DesignLanguage

    @AppStorage(BetaFeatures.calmRoundedFontKey) private var isRounded = BetaFeatures.calmRoundedFontByDefault
    @AppStorage(AccentTheme.lastShadeKey) private var lastShade = AccentTheme.noShade

    func body(content: Content) -> some View {
        switch design {
        case .classic:
            content
        case .calm:
            content
                .fontDesign(isRounded ? .rounded : nil)
                // For whatever has no screen of its own yet: the wait at launch, in the shade the
                // chat list had last time, since the account is not known yet.
                .background { CalmBackdrop(hue: lastShade == AccentTheme.noShade ? nil : lastShade) }
        }
    }
}

private struct BannerGround: ViewModifier {
    @Environment(\.design) private var design

    func body(content: Content) -> some View {
        content.background(design == .calm ? Theme.Calm.surface : Color.page)
    }
}

private extension View {
    @ViewBuilder
    func calmListBackground(onSheetGlass: Bool) -> some View {
        if onSheetGlass {
            // Plain: the grouped style's margins are for a card, and there is none here.
            listStyle(.plain).scrollContentBackground(.hidden).glassSheetBackground()
        } else {
            calmScreen()
        }
    }
}

private struct PhotoPlate: ViewModifier {
    @Environment(\.design) private var design

    func body(content: Content) -> some View {
        switch design {
        case .classic:
            content.background(.black.opacity(Theme.Backdrop.plate), in: Capsule())
        case .calm:
            content.contentGlass(in: .capsule).environment(\.colorScheme, .dark)
        }
    }
}

/// The hue a screen is tinted in, or nil with "tint the interface" off: its conversation's avatar's
/// colour, and without one the account's own shade, the one the chat list wears.
struct CalmHue: DynamicProperty {
    @AppStorage(AccentTheme.tintsChatsKey) private var isTinted = AccentTheme.tintsChatsByDefault
    @Environment(\.calmRoomHue) private var roomHue
    @Environment(\.currentUserID) private var userID

    var value: Double? {
        guard isTinted else { return nil }
        return roomHue ?? (userID.isEmpty ? nil : CalmBackdrop.hue(for: userID))
    }
}

private struct CalmScreen: ViewModifier {
    let isDimmed: Bool

    @Environment(\.design) private var design
    @Environment(\.calmRoomHue) private var roomHue
    @AppStorage(AccentTheme.lastShadeKey) private var lastShade = AccentTheme.noShade
    private let hue = CalmHue()

    func body(content: Content) -> some View {
        switch design {
        case .classic:
            content
        case .calm:
            content
                .onChange(of: hue.value, initial: true) { _, value in
                    if roomHue == nil { lastShade = value ?? AccentTheme.noShade }
                }
                .environment(\.calmShadeHue, hue.value)
                .scrollContentBackground(.hidden)
                .background { CalmBackdrop(hue: hue.value, isDimmed: isDimmed) }
        }
    }
}

private struct CalmOwnHue: ViewModifier {
    @Environment(\.currentUserAvatarURL) private var avatarURL

    func body(content: Content) -> some View {
        content.calmRoomHue(avatarURL: avatarURL)
    }
}

private struct CalmRoomHue: ViewModifier {
    let avatarURL: String?

    @Environment(\.design) private var design
    @Environment(\.mediaLoader) private var loader
    @State private var hue: Double?

    func body(content: Content) -> some View {
        content
            .environment(\.calmRoomHue, hue)
            .task(id: "\(design)\u{0}\(avatarURL ?? "")") { await load() }
    }

    private func load() async {
        guard design == .calm, let avatarURL, let loader else {
            hue = nil
            return
        }
        if let known = CalmAvatarHues.known[avatarURL] {
            hue = known
            return
        }
        // The smallest picture the server will give: all of it is about to be averaged away.
        guard let data = try? await loader.avatar(url: avatarURL, size: Theme.Calm.Shade.sampleSide * 4) else {
            hue = nil
            return
        }
        let found = await Task.detached { CalmBackdrop.dominantHue(of: data) }.value
        CalmAvatarHues.known[avatarURL] = found
        hue = found
    }
}

/// What each avatar's colour came out as, so that a room opened twice does not read it twice. Nil
/// is an answer too: a picture with no colour in it.
@MainActor
private enum CalmAvatarHues {
    static var known: [String: Double?] = [:]
}

extension EnvironmentValues {
    /// The colour of the conversation's avatar, when it has one with a colour — see `CalmHue`.
    @Entry var calmRoomHue: Double?
}

private struct CalmListRow: ViewModifier {
    @Environment(\.design) private var design
    @Environment(\.calmListIsSidebar) private var isSidebar

    func body(content: Content) -> some View {
        if design == .calm, !isSidebar {
            content.listRowBackground(Color.clear)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Whether a form's page is darker than the shade — not in the info column beside a chat on a
    /// Mac, whose shade has to match the chat's across the seam.
    @Entry var calmDimsForms: Bool = true

    /// Whether a list of chats stands in a sidebar — see `calmListRow`.
    @Entry var calmListIsSidebar: Bool = false
}

/// A `Form` that can stand on the calm backdrop.
///
/// `listRowBackground` on the group reaches every row of every section in it. In the classic look
/// this is a plain `Form`.
struct ScreenForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.design) private var design
    @Environment(\.calmDimsForms) private var dimsForms

    var body: some View {
        switch design {
        case .classic:
            Form { content() }
        case .calm:
            Form {
                Group { content() }
                    .listRowBackground(CalmRowMaterial())
            }
            .calmScreen(isDimmed: dimsForms)
        }
    }
}

/// The same, for a `List`. Its rows are plain, as the chat list's are: the backdrop shows through.
///
/// `onSheetGlass` is for a list in a sheet of glass, which keeps its hands off the background so the
/// glass shows through.
struct ScreenList<Content: View>: View {
    var onSheetGlass = false
    @ViewBuilder let content: () -> Content

    @Environment(\.design) private var design

    var body: some View {
        switch design {
        case .classic:
            List { content() }
        case .calm:
            List {
                Group { content() }
                    .listRowBackground(Color.clear)
            }
            .calmListBackground(onSheetGlass: onSheetGlass)
        }
    }
}

/// What is behind a row of a form. A rectangle: the section clips it to its own corners.
///
/// Glass per row draws its rim around every row, so a section comes out as a stack of bright seams,
/// and there is no way to put one sheet of glass behind a whole section of a `Form`.
struct CalmRowMaterial: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.calmShadeHue) private var hue

    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .overlay {
                if let hue {
                    CalmBackdrop.surfaceShade(hue: hue, in: scheme).opacity(Theme.Calm.Shade.surfaceTint)
                }
            }
            .overlay(Color.white.opacity(scheme == .dark ? Theme.Calm.Form.rowLift : Theme.Calm.Form.rowLiftLight))
    }
}
