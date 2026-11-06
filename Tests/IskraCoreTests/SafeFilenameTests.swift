import Foundation
import Testing
@testable import IskraCore

/// Names chosen by another app or another person, before they reach the disk.
@Suite struct SafeFilenameTests {
    @Test func anOrdinaryNameIsLeftAlone() {
        #expect(SafeFilename.make("IMG_0042.HEIC", fallback: "x") == "IMG_0042.HEIC")
        #expect(SafeFilename.make("Отчёт за март.pdf", fallback: "x") == "Отчёт за март.pdf")
    }

    @Test func aNameCannotClimbOutOrHide() {
        #expect(SafeFilename.make("../../x", fallback: "f") == "x")
        #expect(SafeFilename.make("../../Library/Preferences/wtf.iskra.plist", fallback: "f")
                == "wtf.iskra.plist")
        #expect(SafeFilename.make("..", fallback: "f") == "f")
        #expect(SafeFilename.make(".", fallback: "f") == "f")
        #expect(SafeFilename.make("", fallback: "f") == "f")
        #expect(SafeFilename.make(".hidden", fallback: "f") == "hidden")
        #expect(SafeFilename.make("a:b\\c\u{0}", fallback: "f") == "a-b-c-")
    }

    @Test func anOutboxEntryResolvesOnlyInsideTheOutbox() {
        let outbox = URL(filePath: "/container/Outbox", directoryHint: .isDirectory)
        let good = ChatDirectory.OutboxAttachment(kind: .image, filename: "A1B2/IMG_1.jpg")
        let location = good.location(in: outbox)
        #expect(location?.file.path == "/container/Outbox/A1B2/IMG_1.jpg")
        #expect(location?.slot.path == "/container/Outbox/A1B2")
        #expect(good.displayName == "IMG_1.jpg")

        for filename in ["../../x", "A1B2/../../x", "A1B2/..", "IMG_1.jpg", "a/b/c", "/abs/x", "A1B2/"] {
            #expect(ChatDirectory.OutboxAttachment(kind: .file, filename: filename).location(in: outbox) == nil,
                    "\(filename)")
        }
    }
}
