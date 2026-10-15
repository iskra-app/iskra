import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import IskraDesign

/// Making a QR code and reading one out of a picture — both Core Image, so both the same on the
/// iPhone and the Mac. Reading one from the *camera* is the scanner's (`QRScannerView`).
enum QRCode {
    /// The code for `text`, one pixel per module, with a clear square in the middle for the spark —
    /// see `QRCodeImage`. Drawn larger with `.interpolation(.none)`, which keeps the modules square:
    /// scaled up smoothly, a QR code blurs into something a camera reads worse, and it looks wrong
    /// long before it stops working.
    ///
    /// Error correction `H`, and the spark is why. A code on a phone screen is seen whole and sharp,
    /// so on its own `M` was plenty — but the middle of this one is covered on purpose, and `H` is
    /// the level that gets back up to 30% of the code from what is left. The square cut out of it is
    /// under a tenth, which leaves the rest of the margin for a screen with a glare on it.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let code = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return clearingCentre(of: code)
    }

    /// How many modules across the clear square in the middle is, in a code `width` modules wide.
    ///
    /// Odd, always, and that is what puts it exactly on the squares: a QR code is an odd number of
    /// modules across, and an odd square centred in it starts and ends on the edge of a module
    /// rather than halfway through one. A little over a quarter of the width — enough for the spark
    /// to be seen as a spark, and a square of it is under a tenth of the code.
    static func centreSize(forWidth width: Int) -> Int {
        let size = Int((Double(width) * 0.28).rounded())
        return size.isMultiple(of: 2) ? size + 1 : size
    }

    /// The code with its middle whited out, whole modules at a time — so no half-module is left
    /// standing at the edge of the spark's ground, which is what makes a logo on a QR code look
    /// pasted on.
    private static func clearingCentre(of code: CGImage) -> CGImage? {
        let width = code.width, height = code.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 0, y: 0, width: width, height: height))

        let size = centreSize(forWidth: width)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: (width - size) / 2, y: (height - size) / 2, width: size, height: size))
        return context.makeImage()
    }

    /// Where the spark goes, as a fraction of the code's side: the clear square less one module
    /// of white on every side, so the spark never touches a module.
    static func sparkFraction(forWidth width: Int) -> CGFloat {
        CGFloat(centreSize(forWidth: width) - 2) / CGFloat(width)
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
                // The spark, black like the modules, in the clear square `QRCode.image` left for
                // it. Sized from the code's own module count, so it sits on the squares and not
                // across them, whatever size the code is drawn at.
                .overlay {
                    GeometryReader { proxy in
                        let side = proxy.size.width * QRCode.sparkFraction(forWidth: image.width)
                        SparkGlyph()
                            .fill(.black, style: FillStyle(eoFill: true))
                            .frame(width: side, height: side)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                }
                .padding(Theme.Spacing.roomy)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
