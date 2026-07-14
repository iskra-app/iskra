import Testing
@testable import IskraCore

/// The arithmetic that keeps a conversation in step with the SDK.
///
/// It had no test at all, in either of the two places it was written, and it could not have had
/// one: it was phrased in terms of `TimelineItem`, which is a Rust object handle that no test can
/// construct. So the loop that decides where every message in the app goes was verified by reading
/// it. Twice, differently — the two copies had drifted, and the pinned one was still doing the
/// thing the other one's comments describe as a bug.
///
/// Generic over the element, it takes strings, and then it is just a list and some indices.
@Suite("Applying diffs to an ordered list")
struct ListDiffTests {
    /// A short list to push around. `apply` returns an outcome and mutates in place, so each test
    /// starts from its own copy.
    private func list() -> [String] { ["a", "b", "c"] }

    @Test("the eleven ordinary operations put things where they belong")
    func theOrdinaryCases() {
        var items = list()
        #expect(items.apply([.append(["d", "e"])]) == .applied)
        #expect(items == ["a", "b", "c", "d", "e"])

        items = list()
        #expect(items.apply([.clear]) == .applied)
        #expect(items.isEmpty)

        items = list()
        #expect(items.apply([.pushFront("z")]) == .applied)
        #expect(items == ["z", "a", "b", "c"])

        items = list()
        #expect(items.apply([.pushBack("z")]) == .applied)
        #expect(items == ["a", "b", "c", "z"])

        items = list()
        #expect(items.apply([.popFront]) == .applied)
        #expect(items == ["b", "c"])

        items = list()
        #expect(items.apply([.popBack]) == .applied)
        #expect(items == ["a", "b"])

        items = list()
        #expect(items.apply([.insert(1, "z")]) == .applied)
        #expect(items == ["a", "z", "b", "c"])

        items = list()
        #expect(items.apply([.set(1, "z")]) == .applied)
        #expect(items == ["a", "z", "c"])

        items = list()
        #expect(items.apply([.remove(1)]) == .applied)
        #expect(items == ["a", "c"])

        items = list()
        #expect(items.apply([.truncate(1)]) == .applied)
        #expect(items == ["a"])

        items = list()
        #expect(items.apply([.reset(["x", "y"])]) == .applied)
        #expect(items == ["x", "y"])
    }

    @Test("a batch is applied in order, not all at once")
    func aBatchIsOrdered() {
        var items = list()
        #expect(items.apply([.popFront, .pushBack("d"), .set(0, "B")]) == .applied)
        #expect(items == ["B", "c", "d"])
    }

    /// Inserting *at the end* is an ordinary insert, not an off-by-one. This is the one place the
    /// bound is `<=` rather than `<`, and getting it wrong would desync the timeline every time the
    /// SDK appended by index.
    @Test("inserting one past the last item is inserting at the end")
    func insertAtTheEnd() {
        var items = list()
        #expect(items.apply([.insert(3, "d")]) == .applied)
        #expect(items == ["a", "b", "c", "d"])
    }

    /// The whole reason this code is worth a test. An index we do not hold means the SDK is talking
    /// about a list that is not ours — so every positional diff after it lands in the wrong place
    /// too, and clamping it (which is what both stores used to do, and what the pinned one was
    /// still doing) leaves the conversation permanently, silently shuffled.
    @Test("an index we do not have is a desync, not something to step over")
    func impossibleIndicesDesync() {
        let impossible: [(String, ListDiff<String>)] = [
            ("insert past the end", .insert(4, "z")),
            ("insert at a negative index", .insert(-1, "z")),
            ("set past the end", .set(3, "z")),
            ("set on a negative index", .set(-1, "z")),
            ("remove past the end", .remove(3)),
            ("remove at a negative index", .remove(-1)),
            ("truncate to more than we hold", .truncate(4)),
        ]

        for (what, diff) in impossible {
            var items = list()
            let outcome = items.apply([diff])

            guard case .desynced = outcome else {
                Issue.record("\(what) should have desynced, and did not")
                continue
            }

            #expect(items == list(), "\(what) should have changed nothing")
        }
    }

    /// And the batch stops there. Applying the rest of it would be applying diffs whose indices are
    /// measured against a list we have already established we are not holding.
    @Test("nothing after a desync is applied")
    func aDesyncStopsTheBatch() {
        var items = list()
        let outcome = items.apply([.popFront, .remove(9), .clear])

        guard case .desynced = outcome else {
            Issue.record("the impossible remove should have desynced")
            return
        }

        // The pop landed; the clear, which came after the bad index, did not.
        #expect(items == ["b", "c"])
    }

    /// Popping an empty list carries no index and makes no claim about what the list contains. The
    /// SDK is entitled to do it and mean nothing by it, so it is not a desync — the asymmetry with
    /// the bounds checks above is deliberate.
    @Test("popping an empty list is not an error")
    func poppingNothing() {
        var items: [String] = []
        #expect(items.apply([.popFront, .popBack]) == .applied)
        #expect(items.isEmpty)
    }

    @Test("truncating to nothing empties the list, and to its own length changes nothing")
    func truncationEdges() {
        var items = list()
        #expect(items.apply([.truncate(0)]) == .applied)
        #expect(items.isEmpty)

        items = list()
        #expect(items.apply([.truncate(3)]) == .applied)
        #expect(items == list())
    }
}
