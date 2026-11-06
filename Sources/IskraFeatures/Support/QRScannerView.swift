#if os(iOS)
import AVFoundation
import PhotosUI
import SwiftUI
import IskraCore
import IskraDesign

/// Reading somebody's QR code: the camera, or a picture of the code from the library.
///
/// Only Matrix links are taken — a person or a room, in any of the spellings `MatrixLink` reads.
/// Anything else the camera sees (a menu, a Wi-Fi password) is said to be not one, and the camera
/// keeps looking: pointing a phone at the wrong code is not a mistake worth a dialog.
///
/// iPhone and iPad only — the Mac has no scanner at all (see `NewChatView`).
struct QRScannerView: View {
    var onFound: (MatrixLink) -> Void

    @State private var note: LocalizedStringResource?
    @State private var noteClear: Task<Void, Never>?
    @State private var cameraAllowed: Bool?
    @State private var picked: PhotosPickerItem?

    var body: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            camera

            Text(note ?? Strings.QR.scanHint)
                .font(.callout)
                .foregroundStyle(note == nil ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.generous)
                .animation(.smooth(duration: Theme.Timing.chrome), value: note == nil)

            choosePicture
                .padding(.bottom, Theme.Spacing.generous)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(Text(Strings.QR.scan))
        .toolbarTitleDisplayMode(.inline)
    }

    // MARK: - The camera

    @ViewBuilder
    private var camera: some View {
        Group {
            switch cameraAllowed {
            case .some(true):
                CameraScanner { read([$0]) }
            case .some(false):
                Text(Strings.QR.noCamera)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(Theme.Spacing.generous)
            case nil:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.top, Theme.Spacing.roomy)
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: cameraAllowed = true
            case .notDetermined: cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
            default: cameraAllowed = false
            }
        }
    }

    // MARK: - A picture of the code

    @ViewBuilder
    private var choosePicture: some View {
        // The system's picker runs outside the app and hands back only what was chosen, so it needs
        // no access to the library — the same reason the composer uses it.
        PhotosPicker(selection: $picked, matching: .images) {
            Label(String(app: Strings.QR.choosePicture), systemImage: "photo")
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                readPicture(data)
            }
        }
    }

    // MARK: - What was read

    private func readPicture(_ data: Data) {
        let codes = QRCode.read(imageData: data)
        guard !codes.isEmpty else {
            say(Strings.QR.nothingFound)
            return
        }
        read(codes)
    }

    private func read(_ codes: [String]) {
        if let link = codes.lazy.compactMap(MatrixLink.init(parsing:)).first {
            onFound(link)
        } else {
            say(Strings.QR.notMatrix)
        }
    }

    /// A sentence in place of the hint, for a few seconds — and then the hint again, because the
    /// camera is still looking.
    private func say(_ words: LocalizedStringResource) {
        note = words
        noteClear?.cancel()
        noteClear = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            note = nil
        }
    }
}

/// The camera, reading QR codes as it goes. `AVCaptureMetadataOutput` does the reading on the
/// device's own hardware, which is why there is no Vision in it and no frame ever reaches us.
private struct CameraScanner: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = context.coordinator.session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // `layerClass` above is what makes this cast true.
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    /// Owns the session. `@unchecked Sendable` because the session is configured once, here, and
    /// then only started and stopped — on its own queue, which is what AVFoundation asks for:
    /// `startRunning` blocks, and on the main thread it holds the screen still while the camera
    /// warms up.
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        var onCode: (String) -> Void
        private let queue = DispatchQueue(label: "wtf.iskra.qr-camera")
        /// The last code reported, so a code held in front of the camera is reported once and not
        /// thirty times a second.
        private var lastCode: String?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            super.init()

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        func start() {
            let session = self.session
            queue.async { session.startRunning() }
        }

        func stop() {
            let session = self.session
            queue.async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let code = metadataObjects.lazy
                .compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                .first,
                  code != lastCode else { return }
            lastCode = code
            MainActor.assumeIsolated { onCode(code) }
        }
    }
}
#endif
