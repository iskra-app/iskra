import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import IskraDesign

/// Making a QR code and reading one out of a picture — both Core Image, so both the same on the
/// iPhone and the Mac. Reading one from the *camera* is the scanner's (`QRScannerView`).
enum QRCode {
    /// The code for `text`, one pixel per module. Drawn larger with `.interpolation(.none)`, which
    /// keeps the modules square: scaled up smoothly, a QR code blurs into something a camera reads
    /// worse, and it looks wrong long before it stops working.
    ///
    /// Error correction `M`: a code on a phone screen is seen whole and sharp, so the extra
    /// redundancy of `Q` or `H` would only make the modules smaller for nothing.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Every QR code found in a picture, as text, largest first.
    static func read(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features
            .compactMap { $0 as? CIQRCodeFeature }
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .compactMap(\.messageString)
    }

    /// The same, for the bytes of an image file — a photo picked from the library, a file opened on
    /// the Mac.
    static func read(imageData: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return read(image)
    }
}

/// The code itself, black on white whatever the theme is — a camera reads dark modules on a light
/// ground, and an inverted code is one that half the scanners in the world refuse.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = QRCode.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(Theme.Spacing.roomy)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
