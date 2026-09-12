import Testing
import CoreMedia
import IskraCore
@testable import IskraFeatures

/// What size a round video message is actually written at — see `VideoNoteWriter.fitted`.
///
/// The camera hands over 720p or better and the message that leaves is a circle 480 points
/// across, so everything between the two is work done on pixels nobody will ever see. That is
/// invisible while it is wrong: the clip still sends, still plays, still looks right, and the
/// only symptom is a file several times the size it needed to be and a phone that got warm
/// making it. Arithmetic nobody can see the result of is arithmetic worth pinning down.
struct VideoNoteWriterTests {
    private func fitted(_ width: Int32, _ height: Int32) -> (width: Int, height: Int) {
        VideoNoteWriter.fitted(CMVideoDimensions(width: width, height: height))
    }

    @Test("a tall frame keeps its shape and loses its excess")
    func scalesPortraitByItsShorterSide() {
        let size = fitted(1080, 1920)

        // The shorter side is the one the square is cut from, so it is the one that has to land
        // on 480 exactly — anything less and the crop is scaled back up, which is a blurred
        // video message with a smaller file as its only consolation.
        #expect(size.width == VideoNote.captureDimension)
        #expect(size.height == 852)
    }

    @Test("and a wide one is measured by its height")
    func scalesLandscapeByItsShorterSide() {
        let size = fitted(1280, 720)

        #expect(size.height == VideoNote.captureDimension)
        #expect(size.width == 852)
    }

    /// H.264 in 4:2:0 cannot encode an odd dimension, and an encoder handed one either rounds it
    /// behind your back or refuses the input outright. Neither is a thing to find out on a phone.
    @Test("both sides come back even")
    func roundsToEvenDimensions() {
        let size = fitted(1001, 1999)

        #expect(size.width % 2 == 0)
        #expect(size.height % 2 == 0)
    }

    /// A camera smaller than the square is left alone. Scaling *up* to 480 would add nothing to
    /// the picture and multiply what it costs to send — the export scales it up either way, and
    /// it can do that without us encoding the enlargement twice.
    @Test("a small camera is not enlarged")
    func neverUpscales() {
        let size = fitted(320, 240)

        #expect(size.width == 320)
        #expect(size.height == 240)
    }
}
