import Testing
import Foundation
@testable import IskraCore

/// What the app is allowed to write down about a failure.
///
/// This is a security test wearing the clothes of a formatting test. Every error in the app now
/// reaches the system log through `Log.describe`, marked `.public` — which means whatever it returns
/// is readable by anyone holding the phone and looking at the console. The property being pinned is
/// therefore not "it produces a nice string": it is **the payload does not come out**.
///
/// The payload is where the user's life is. An `NSError` from Foundation or Photos carries
/// `NSFilePath` in its `userInfo`, so a failure to open an attachment used to write the name of the
/// file into the log — and the file is called `паспорт_скан.pdf`. The SDK's `ClientError.generic`
/// carries the homeserver's own response. Both used to go straight in.
@Suite("What a failure is allowed to say about itself")
struct LogTests {
    /// The shape of the SDK's errors, and of ours: an enum whose case carries the interesting and
    /// dangerous part.
    private enum Failure: Error {
        case generic(message: String, details: String)
        case refused
    }

    @Test("an error's payload is not written to the log")
    func thePayloadStaysOut() {
        let secret = "паспорт_скан.pdf"
        let described = Log.describe(Failure.generic(message: secret, details: "M_FORBIDDEN"))

        #expect(!described.contains(secret))
        #expect(!described.contains("M_FORBIDDEN"))

        // And it still says which failure it was, which is the entire point of the line.
        #expect(described.contains("generic"))
    }

    @Test("a case with nothing in it is named")
    func aBareCaseIsNamed() {
        #expect(Log.describe(Failure.refused).contains("refused"))
    }

    /// The other half. A real `NSError` is not an enum, and its `userInfo` is the thing that must
    /// not travel — `NSFilePath` above all, which Foundation puts there without being asked.
    @Test("an NSError's userInfo does not travel with it")
    func userInfoStaysOut() {
        let error = NSError(domain: NSCocoaErrorDomain,
                            code: 260,
                            userInfo: [NSFilePathErrorKey: "/Users/boris/паспорт_скан.pdf"])

        let described = Log.describe(error)

        #expect(!described.contains("паспорт"))
        #expect(!described.contains("/Users"))

        // What is left is what a person debugging this actually needs: which step, and which
        // failure. 260 is "no such file", and it gives away no file.
        #expect(described.contains(NSCocoaErrorDomain))
        #expect(described.contains("260"))
    }
}
