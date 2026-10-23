import SwiftUI

/// A grouped form whose rows' titles start in one column on a Mac, whatever symbol stands in front
/// of them.
///
/// On iPhone and iPad a `Form` already does this: a `Label` in a row gets a fixed-width icon column
/// from the system. A Mac form does not. Each `Label` there is its own symbol and then its title, so
/// a row is only as indented as its symbol is wide — `bubble.left.and.bubble.right` pushes "Chats"
/// several points right of "Language" under `globe`, and a settings list reads as ragged. The fix is
/// the iOS one, done by hand: every symbol stands centred in the same `Theme.Size.rowIcon`.
///
/// It is a form style, and not a `.labelStyle` put on the screen, on purpose. A label style is
/// environment, and environment reaches a `.toolbar` declared under it — the toolbar's buttons
/// would be drawn with their titles beside their icons. Here the style touches only the form's own
/// rows (`configuration.content`), and whatever the screen declares on the `Form` stays as it was.
///
/// Use it wherever `.formStyle(.grouped)` would go: `.formStyle(.groupedRows)`.
public struct GroupedRowsFormStyle: FormStyle {
    public func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        MacGroupedForm(configuration: configuration)
        #else
        Form(configuration)
            .formStyle(.grouped)
        #endif
    }
}

#if os(macOS)
/// The Mac's grouped form, with its cards no wider than `Theme.Size.formCardMaximum`.
///
/// The form runs to the column's edges and its *content* is held in by side margins worked out from
/// its width. A frame round the form, which is what it was, drew the scroll edge under the toolbar
/// only as wide as the cards — a dark band hanging in the middle of the title bar.
///
/// A margin is part of a view's least width, and on its own it made the window's least width rise
/// with the window — to 1712 points after one wide moment. The `minWidth: 0` frame outside it is
/// what stops that: the column, not the margin, decides how narrow the page can go.
private struct MacGroupedForm: View {
    let configuration: FormStyleConfiguration

    /// The width the page was last given, from which the margins are worked out.
    @State private var width: CGFloat = 0

    private var margin: CGFloat {
        max(0, (width - Theme.Size.formCardMaximum) / 2)
    }

    var body: some View {
        Form {
            configuration.content
                .labelStyle(RowLabelStyle())
                .buttonStyle(RoleColouredButtonStyle())
                // White cards on the grey page, as on the phone — see `Color.groupedCard`. A row
                // that asks for no card (a portrait, a bare control) keeps asking: its own setting
                // is nearer to it than this one.
                .listRowBackground(Color.groupedCard)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        // The phone's grouped page under the form, not the window's grey — see `Color.groupedPage`.
        .background(Color.groupedPage)
    }
}

/// A form's own buttons as the Mac draws them, except that a `.destructive` one is red — as it is on
/// the phone, where the role alone does it and the Mac's push button ignores it. A button that
/// chose a style of its own keeps it: that style is nearer to it than this one.
private struct RoleColouredButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
        }
        .buttonStyle(.automatic)
        .destructiveTint(configuration.role == .destructive)
    }
}
#endif

extension View {
    /// Red, on the Mac as well, for a button that does something that cannot be taken back.
    ///
    /// The phone paints a `.destructive` button red by itself, and a `.bordered` one by its
    /// `.tint(.red)`; the Mac does neither from the role. Both are set here: the words red, and the
    /// tint red — because in a *key* window a Mac button draws its title in the tint, and the tint at
    /// the root of this app is `.primary`, so the red words came out white whenever the window was
    /// active and red only when it was not.
    @ViewBuilder
    public func destructiveTint(_ isDestructive: Bool = true) -> some View {
        #if os(macOS)
        if isDestructive {
            foregroundStyle(.red).tint(.red)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension FormStyle where Self == GroupedRowsFormStyle {
    public static var groupedRows: GroupedRowsFormStyle { GroupedRowsFormStyle() }
}

/// A row's symbol in a column of its own, then its title — what an iOS form does for a `Label`.
/// Public so that a `List` of rows on a Mac can stand its symbols in the same column.
public struct RowLabelStyle: LabelStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            configuration.icon
                .frame(width: Theme.Size.rowIcon)
            configuration.title
        }
    }
}
