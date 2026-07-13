import SwiftUI

/// Lays views out in a row, and starts a new row when the current one runs out of width.
///
/// SwiftUI has no wrapping stack, and the obvious substitutes are both wrong for what
/// this is used for — the emoji under a message. An `HStack` refuses to wrap and instead
/// squeezes its children until they are unreadable; a horizontal `ScrollView` hides half
/// of them behind a gesture nobody knows to make. Reactions have to be *all* visible, at
/// their natural size, however many there are.
///
/// `alignment` is which edge each row is pushed to — the trailing edge under your own
/// messages, the leading edge under everyone else's, so the emoji line up with the bubble
/// they belong to rather than floating off its corner.
public struct FlowLayout: Layout {
    private let spacing: CGFloat
    private let alignment: HorizontalAlignment

    public init(spacing: CGFloat, alignment: HorizontalAlignment = .leading) {
        self.spacing = spacing
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, within: proposal.replacingUnspecifiedDimensions().width)

        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0

        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect,
                              proposal: ProposedViewSize,
                              subviews: Subviews,
                              cache: inout ()) {
        var y = bounds.minY

        for row in rows(of: subviews, within: bounds.width) {
            // The row's own leftover width is what alignment spends: nothing at the
            // leading edge, all of it at the trailing edge.
            var x = switch alignment {
            case .trailing: bounds.maxX - row.width
            default: bounds.minX
            }

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                // Centred within the row, so a taller pill does not drag the shorter ones
                // up to its own top edge.
                let y = y + (row.height - size.height) / 2

                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }

            y += row.height + spacing
        }
    }

    /// Greedy, single-pass: keep adding to the current row until the next one will not
    /// fit, then start another. The same walk answers both `sizeThatFits` and
    /// `placeSubviews`, so the two can never disagree about where a row breaks.
    private func rows(of subviews: Subviews, within maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithThis = current.isEmpty ? size.width : current.width + spacing + size.width

            // A subview wider than the whole container still has to go somewhere, so a row
            // that is empty always accepts one rather than looping forever.
            if !current.isEmpty && widthWithThis > maxWidth {
                rows.append(current)
                current = Row()
            }

            current.add(index: index, size: size, spacing: spacing)
        }

        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private struct Row {
        var indices: [Subviews.Index] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        var isEmpty: Bool { indices.isEmpty }

        mutating func add(index: Subviews.Index, size: CGSize, spacing: CGFloat) {
            width += isEmpty ? size.width : spacing + size.width
            height = max(height, size.height)
            indices.append(index)
        }
    }
}
