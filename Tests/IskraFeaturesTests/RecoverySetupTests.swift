import Testing
import IskraCore
@testable import IskraFeatures

/// The one decision in the recovery flow that can be tested at all — and the one it would be worst
/// to get wrong.
///
/// Everything else in `RecoverySetupModel` needs a live server, an encrypted store and a second
/// device on the account, and `swift test` has none of the three. `route(for:)` is a pure function of
/// one enum precisely so that this much can be pinned, because the cost of it being wrong is not a
/// bad screen: routing an account that *has* a backup into `.creating` would call `enableRecovery`
/// on it, reset the backup, and destroy the history the user signed in to read.
@Suite("Where the account's state sends the user")
struct RecoverySetupTests {
    @Test("an account with no backup is given one, and a code")
    func noBackupMakesOne() {
        #expect(RecoverySetupModel.route(for: .off) == .creating)
    }

    @Test("an account whose history this device cannot open offers both ways in")
    func lockedHistoryAsks() {
        #expect(RecoverySetupModel.route(for: .keyNeeded) == .choose)
    }

    @Test("an account that is already in order is not detained")
    func settledAccountPassesThrough() {
        #expect(RecoverySetupModel.route(for: .on) == .done)
    }

    /// The important one, and the reason `.unknown` is a case at all rather than being folded into
    /// `.off`. "I don't know yet" and "there is no backup" are the same word to a switch statement
    /// that is not paying attention — and acting on the first as though it were the second is how you
    /// reset a perfectly good backup belonging to somebody whose server was merely slow to answer.
    ///
    /// Letting them into the app is the safe failure: the banner is still there, settings are still
    /// there, and nothing has been destroyed.
    @Test("an account the SDK cannot yet describe is never acted on")
    func unknownIsNeverGuessedAt() {
        #expect(RecoverySetupModel.route(for: .unknown) == .done)
        #expect(RecoverySetupModel.route(for: .unknown) != .creating)
    }
}
