import Testing
@testable import IskraFeatures

/// The list under "New chat": everybody there is a conversation with, under their first letters.
@Suite("New chat")
struct NewChatTests {
    private func contact(_ name: String) -> NewChatView.Contact {
        .init(id: "@\(name.lowercased()):example.org", name: name, avatarURL: nil, roomID: "!\(name):example.org")
    }

    @Test("contacts are grouped by first letter, and anything that is not a letter goes last")
    func contactsAreGroupedByLetter() {
        let groups = NewChatView.byLetter(["Аня", "алёна", "Boris", "42", "🙂 smile", "Bella"].map(contact))

        #expect(groups.map(\.letter).last == "#")
        #expect(groups.first { $0.letter == "А" }?.people.map(\.name) == ["алёна", "Аня"])
        #expect(groups.first { $0.letter == "B" }?.people.map(\.name) == ["Bella", "Boris"])
        #expect(groups.first { $0.letter == "#" }?.people.count == 2)
    }
}
