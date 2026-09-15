import SwiftUI
import Testing
@testable import IskraFeatures

/// When the app hides its own contents from the app switcher.
///
/// A cover is the kind of thing nobody notices is broken until somebody's conversation is sitting in
/// a screenshot, so the rule is a pure function and pinned here rather than left to a view.
@Suite("PrivacyCover")
struct PrivacyCoverTests {
    @Test("with the lock off the app looks like itself, wherever it is")
    func noLockNoCover() {
        #expect(!PrivacyCover.isNeeded(lockEnabled: false, phase: .active))
        #expect(!PrivacyCover.isNeeded(lockEnabled: false, phase: .inactive))
        #expect(!PrivacyCover.isNeeded(lockEnabled: false, phase: .background))
    }

    @Test("in front, with the lock on, nothing is covered")
    func activeIsUncovered() {
        #expect(!PrivacyCover.isNeeded(lockEnabled: true, phase: .active))
    }

    @Test("leaving covers the app — including `.inactive`, which is when the picture is taken")
    func leavingCovers() {
        #expect(PrivacyCover.isNeeded(lockEnabled: true, phase: .inactive))
        #expect(PrivacyCover.isNeeded(lockEnabled: true, phase: .background))
    }
}
