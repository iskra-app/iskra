import Testing
import Foundation
@testable import IskraCore

/// Pinning and archiving, as the room list projects them: pinned rooms rise to the top, archived
/// rooms leave the main list for a shelf of their own. Both are the projection's job, and both are
/// pure enough to pin here without a homeserver.
@MainActor
struct RoomOrganizationTests {
    private func room(_ id: String,
                      at activity: Date?,
                      pinned: Bool = false,
                      archived: Bool = false) -> RoomSummary {
        RoomSummary(id: id,
                    name: id,
                    lastActivity: activity,
                    isFavourite: pinned,
                    isLowPriority: archived)
    }

    @Test("a pinned room sits above the unpinned ones, however old it is")
    func pinnedSortAboveUnpinned() {
        let now = Date.now
        let sorted = RoomListStore.byRecency([
            room("recent", at: now),
            room("older-but-pinned", at: now.addingTimeInterval(-86_400), pinned: true),
            room("newer", at: now.addingTimeInterval(60))
        ])

        #expect(sorted.first?.id == "older-but-pinned")
    }

    @Test("pinned rooms keep recency order among themselves")
    func pinnedOrderedByRecencyAmongThemselves() {
        let now = Date.now
        let sorted = RoomListStore.byRecency([
            room("pin-old", at: now.addingTimeInterval(-3600), pinned: true),
            room("pin-new", at: now, pinned: true),
            room("chat", at: now.addingTimeInterval(-60))
        ])

        #expect(sorted.map(\.id) == ["pin-new", "pin-old", "chat"])
    }

    @Test("an invitation still outranks a pin")
    func invitationsBeatPins() {
        let sorted = RoomListStore.byRecency([
            room("pinned", at: .now, pinned: true),
            RoomSummary(id: "invite", name: "invite", membership: .invited)
        ])

        #expect(sorted.first?.id == "invite")
    }

    @Test("archived rooms are split out of the active list")
    func archivedAreSplitOut() {
        let now = Date.now
        let (active, archived) = RoomListStore.partitionArchived([
            room("a", at: now),
            room("b", at: now, archived: true),
            room("c", at: now),
            room("d", at: now, archived: true)
        ])

        #expect(active.map(\.id) == ["a", "c"])
        #expect(archived.map(\.id) == ["b", "d"])
    }

    @Test("a room marked unread reads as unread even with nothing new in it")
    func markedUnreadShowsUnread() {
        let quiet = RoomSummary(id: "q", name: "q", unreadCount: 0, isMarkedUnread: true)
        #expect(quiet.hasUnread)

        let read = RoomSummary(id: "r", name: "r", unreadCount: 0, isMarkedUnread: false)
        #expect(!read.hasUnread)
    }

    @Test("every organising failure explains itself in both languages")
    func organisingFailuresAreExplained() {
        for failure in [RoomActionFailure.pin, .archive, .read, .report] {
            for language in ["en", "ru"] {
                var explanation = failure.explanation
                explanation.locale = Locale(identifier: language)
                let sentence = String(localized: explanation)

                #expect(!sentence.hasPrefix("roomAction."), "\(sentence) is a key, not a sentence")
                #expect(sentence.count > 5, "\(failure) says too little to act on")
            }
        }
    }
}
