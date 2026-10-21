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
        Form {
            configuration.content
                .labelStyle(RowLabelStyle())
        }
        .formStyle(.grouped)
        #else
        Form(configuration)
            .formStyle(.grouped)
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
