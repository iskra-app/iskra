import Foundation
import MatrixRustSDK

/// One positional change to an ordered list.
///
/// This is the SDK's `TimelineDiff` with the SDK taken out of it, and the point of taking the SDK
/// out of it is that the result can be *tested*. `TimelineItem` is a Rust object handle: it cannot
/// be constructed in a test, so nothing that spoke in terms of it could ever be given a list to
/// apply diffs to. And what is being applied is not a formality — it is a dozen positional
/// operations, several of which can address an item the list does not hold, and the decision about
/// what to do when they do is the difference between a conversation that is right and one that is
/// quietly, permanently wrong.
///
/// So the arithmetic lives here, generic over the element, with a test that hands it strings; and
/// the two stores that receive real diffs map them across and get the same arithmetic. See
/// `Array.apply(_:)`.
enum ListDiff<Element> {
    case append([Element])
    case clear
    case pushFront(Element)
    case pushBack(Element)
    case popFront
    case popBack
    case insert(Int, Element)
    case set(Int, Element)
    case remove(Int)
    case truncate(Int)
    case reset([Element])
}

/// Whether the list still agrees with the SDK about what it is holding.
enum DiffOutcome: Equatable {
    case applied

    /// The SDK addressed an item we do not have — and that is not a small thing to step over. It is
    /// the SDK talking about a list that is not the list we are holding, which means our copy has
    /// already come apart from its own, and every positional diff after this one lands in the wrong
    /// place too. The string says which one, for the log.
    case desynced(String)
}

extension Array {
    /// Applies a batch of diffs in order, stopping at the first one that does not fit.
    ///
    /// The three bounds checks are the whole reason this exists as a named thing. They used to
    /// clamp and swallow — `insert` put the item on the end instead of where it was asked to go,
    /// `set` and `remove` did nothing at all — and the array stayed quietly wrong with no crash, no
    /// log and nothing to find. That is how a reordering bug hid in the timeline for as long as it
    /// did: a race applied two batches out of order, these guards absorbed the impossible indices
    /// that followed, and the conversation was left shuffled with no trace of why. `PinnedStore`
    /// was still doing exactly that, in its own copy of this code, on the day this was written.
    ///
    /// An impossible index therefore *means* something now: it is the list saying it can no longer
    /// be trusted, and the answer to that is to go and read it again.
    ///
    /// `popFront` and `popBack` on an empty list are **not** in that category, and the asymmetry is
    /// deliberate rather than an oversight. They carry no index and make no claim about what the
    /// list contains; the SDK is entitled to pop an empty list and mean nothing by it.
    mutating func apply(_ diffs: [ListDiff<Element>]) -> DiffOutcome {
        for diff in diffs {
            switch diff {
            case let .append(values):
                append(contentsOf: values)

            case .clear:
                removeAll()

            case let .pushFront(value):
                insert(value, at: 0)

            case let .pushBack(value):
                append(value)

            case .popFront:
                if !isEmpty { removeFirst() }

            case .popBack:
                if !isEmpty { removeLast() }

            case let .insert(index, value):
                // `<=`, not `<`: inserting *at the end* is a legitimate insert, and the one place
                // this differs from the checks below it.
                guard index >= 0, index <= count else {
                    return .desynced("insert at \(index) of \(count)")
                }
                insert(value, at: index)

            case let .set(index, value):
                guard indices.contains(index) else {
                    return .desynced("set at \(index) of \(count)")
                }
                self[index] = value

            case let .remove(index):
                guard indices.contains(index) else {
                    return .desynced("remove at \(index) of \(count)")
                }
                remove(at: index)

            case let .truncate(length):
                guard length >= 0, length <= count else {
                    return .desynced("truncate to \(length) of \(count)")
                }
                removeSubrange(length...)

            case let .reset(values):
                self = values
            }
        }

        return .applied
    }
}

extension TimelineDiff {
    /// The same change, said without the SDK in it. Purely mechanical — every case maps to the one
    /// with its name — and it exists so that the arithmetic above can be written once and tested.
    var asListDiff: ListDiff<TimelineItem> {
        switch self {
        case let .append(values): .append(values)
        case .clear: .clear
        case let .pushFront(value): .pushFront(value)
        case let .pushBack(value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case let .insert(index, value): .insert(Int(index), value)
        case let .set(index, value): .set(Int(index), value)
        case let .remove(index): .remove(Int(index))
        case let .truncate(length): .truncate(Int(length))
        case let .reset(values): .reset(values)
        }
    }
}
