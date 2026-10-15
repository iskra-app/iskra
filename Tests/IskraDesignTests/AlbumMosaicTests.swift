import CoreGraphics
import Testing
@testable import IskraDesign

/// Where the pictures of an album go — see `AlbumMosaic`.
@Suite("Album mosaic")
struct AlbumMosaicTests {
    private let width: CGFloat = 280
    private let gap: CGFloat = 2

    private func frames(_ ratios: [CGFloat], maxHeight: CGFloat = 10_000) -> [CGRect] {
        AlbumMosaic.frames(ratios: ratios, width: width, spacing: gap, maxHeight: maxHeight)
    }

    /// Every count from two to ten: one frame each, all inside the width, none overlapping.
    @Test("every picture gets a place, and no two overlap", arguments: 2...10)
    func covers(count: Int) {
        let ratios = (0..<count).map { [1.5, 0.75, 1, 1.33, 0.6][$0 % 5] as CGFloat }
        let placed = frames(ratios)
        #expect(placed.count == count)
        for frame in placed {
            #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5)
            #expect(frame.width > 20 && frame.height > 20)
        }
        for (i, a) in placed.enumerated() {
            for b in placed[(i + 1)...] {
                #expect(!a.insetBy(dx: 0.5, dy: 0.5).intersects(b.insetBy(dx: 0.5, dy: 0.5)))
            }
        }
    }

    @Test("two landscape photos side by side keep their shape")
    func twoSideBySide() {
        let placed = frames([1, 1])
        #expect(placed[0].minY == placed[1].minY)
        #expect(abs(placed[0].width - placed[0].height) < 1)
    }

    /// A tall first photo gets a column of its own, the rest stacked beside it.
    @Test("a tall first photo gets the left column")
    func column() {
        let placed = frames([0.6, 1.5, 1.5])
        #expect(placed[0].minX == 0 && placed[0].minY == 0)
        #expect(placed[1].minX > placed[0].maxX && placed[2].minX > placed[0].maxX)
        #expect(placed[2].minY > placed[1].maxY)
    }

    /// A wide first photo is the album's cover: a row of its own, the rest under it.
    @Test("a wide first photo goes on top")
    func cover() {
        let placed = frames([2, 1, 1])
        #expect(placed[0].width == width)
        #expect(placed[1].minY > placed[0].maxY && placed[1].minY == placed[2].minY)
    }

    @Test("an album taller than allowed is squeezed into the limit")
    func squeezed() {
        let placed = frames([0.5, 0.5, 0.5, 0.5], maxHeight: 200)
        #expect((placed.map(\.maxY).max() ?? 0) <= 200.5)
    }

    @Test("splits cover every way of cutting into rows of up to four")
    func splits() {
        #expect(AlbumMosaic.splits(of: 3).count == 4)
        #expect(AlbumMosaic.splits(of: 5).allSatisfy { $0.reduce(0, +) == 5 && $0.allSatisfy { $0 <= 4 } })
    }
}
