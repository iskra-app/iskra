import Testing
@testable import IskraCore

/// If this passes, the Rust SDK is linked and callable on the host platform.
@Test func rustSDKIsLinkedAndCallable() {
    #expect(!Iskra.sdkVersion.isEmpty)
}
