import IskraCore
import IskraDesign
import SwiftUI

/// The calm look's pieces that know about screens: the backdrop, and the forms and lists on it. See `DesignLanguage`; in the classic look all of this is nothing.
extension View {
    /// The look's type and ink, for everything below. On the root, and on the shield, which lives
    /// in a window of its own.
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

    /// Stands a screen on the calm backdrop, in the shade of the person using it: the list,
    /// settings, anything that belongs to you rather than to a conversation.
    func calmScreen(isDimmed: Bool = false) -> some View {
        modifier(CalmScreen(isDimmed: isDimmed))
    }
}

private struct CalmType: ViewModifier {
    let design: DesignLanguage

    @AppStorage(BetaFeatures.calmRoundedFontKey) private var isRounded = BetaFeatures.calmRoundedFontByDefault

    func body(content: Content) -> some View {
        switch design {
        case .classic:
            content
        case .calm:
            content
                .fontDesign(isRounded ? .rounded : nil)
                .foregroundStyle(Theme.Calm.ink)
                // For whatever has no screen of its own yet: the wait at launch.
                .background { CalmBackdrop(seed: nil) }
        }
    }
}

private struct BannerGround: ViewModifier {
    @Environment(\.design) private var design

    func body(content: Content) -> some View {
        content.background(design == .calm ? Theme.Calm.surface : Color.page)
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

private struct CalmScreen: ViewModifier {
    let isDimmed: Bool

    @Environment(\.design) private var design
    @Environment(\.currentUserID) private var userID

    func body(content: Content) -> some View {
        switch design {
        case .classic:
            content
        case .calm:
            content
                .scrollContentBackground(.hidden)
                .background { CalmBackdrop(seed: userID.isEmpty ? nil : userID, isDimmed: isDimmed) }
        }
    }
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

    var body: some View {
        switch design {
        case .classic:
            Form { content() }
        case .calm:
            Form {
                Group { content() }
                    .listRowBackground(CalmRowMaterial())
            }
            .calmScreen(isDimmed: true)
        }
    }
}

/// The same, for a `List`. Its rows are plain, as the chat list's are: the backdrop shows through.
struct ScreenList<Content: View>: View {
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
            .calmScreen()
        }
    }
}

/// What is behind a row of a form. A rectangle: the section clips it to its own corners.
///
/// Glass per row draws its rim around every row, so a section comes out as a stack of bright seams,
/// and there is no way to put one sheet of glass behind a whole section of a `Form`.
struct CalmRowMaterial: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .overlay(Color.white.opacity(scheme == .dark ? Theme.Calm.Form.rowLift : Theme.Calm.Form.rowLiftLight))
    }
}
