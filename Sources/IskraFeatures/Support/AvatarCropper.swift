import SwiftUI
import IskraDesign

/// A picked picture, waiting to be cut into an avatar — what a sheet is presented for.
struct AvatarCropRequest: Identifiable {
    let id = UUID()
    let image: CGImage
}

/// Cutting a new avatar out of a picture: a square, with the face's own outline drawn in it — a
/// circle, or a space's rounded square — and everything outside that outline still there, under a
/// dark veil, so it is plain what is left out and where to move to take it in.
///
/// Move and zoom, nothing else: no rotating, no drawing. A pinch zooms; on a Mac, which may have
/// only a mouse, a slider under the picture does too. The square itself is what is uploaded — the
/// outline is how it will be shown, not a cut — see `AvatarCrop`.
struct AvatarCropper: View {
    let image: CGImage
    var shape: AvatarShape = .circle
    let onCancel: () -> Void
    let onDone: (Data) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Where a drag or a pinch started from, so the gesture moves the picture from there.
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?

    private var imageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.roomy) {
                GeometryReader { geometry in
                    let side = max(1, min(geometry.size.width, geometry.size.height) - Theme.Spacing.generous * 2)
                    let crop = AvatarCrop(imageSize: imageSize, side: side, zoom: zoom, offset: offset)
                    let shown = crop.clamped(offset)

                    ZStack {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: crop.displayedSize.width, height: crop.displayedSize.height)
                            .offset(shown)

                        Veil(hole: CGSize(width: side, height: side), shape: shape)
                            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                            .allowsHitTesting(false)

                        AvatarOutline(shape: shape)
                            .stroke(.white.opacity(0.8), lineWidth: 1)
                            .frame(width: side, height: side)
                            .allowsHitTesting(false)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .contentShape(.rect)
                    .gesture(move(crop).simultaneously(with: pinch(crop)))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(app: Strings.AvatarCrop.done)) {
                                var final = crop
                                final.offset = shown
                                if let data = final.render(image) { onDone(data) }
                            }
                        }
                    }
                }

                #if os(macOS)
                Slider(value: Binding(get: { zoom }, set: { zoom = AvatarCrop.clampedZoom($0) }),
                       in: 1...AvatarCrop.maxZoom) {
                    Text(Strings.AvatarCrop.zoom)
                } minimumValueLabel: {
                    Image(systemName: "minus.magnifyingglass")
                } maximumValueLabel: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .labelsHidden()
                .padding(.horizontal, Theme.Spacing.generous)
                .padding(.bottom, Theme.Spacing.roomy)
                #endif
            }
            .background(.black)
            .environment(\.colorScheme, .dark)
            .navigationTitle(Text(Strings.AvatarCrop.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.AvatarCrop.cancel), action: onCancel)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: Theme.Size.avatarCropper, minHeight: Theme.Size.avatarCropper)
        #endif
    }

    private func move(_ crop: AvatarCrop) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop.clamped(offset)
                if dragStart == nil { dragStart = start }
                offset = CGSize(width: start.width + value.translation.width,
                                height: start.height + value.translation.height)
            }
            .onEnded { _ in
                dragStart = nil
                offset = crop.clamped(offset)
            }
    }

    private func pinch(_ crop: AvatarCrop) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? zoom
                if zoomStart == nil { zoomStart = start }
                zoom = AvatarCrop.clampedZoom(start * value.magnification)
            }
            .onEnded { _ in
                zoomStart = nil
                var settled = crop
                settled.zoom = zoom
                offset = settled.clamped(offset)
            }
    }
}

/// The whole frame, less the avatar's outline in the middle of it — filled even-odd, that is the
/// veil over everything the avatar will not show.
private struct Veil: Shape {
    let hole: CGSize
    let shape: AvatarShape

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let inner = CGRect(x: rect.midX - hole.width / 2, y: rect.midY - hole.height / 2,
                           width: hole.width, height: hole.height)
        path.addPath(AvatarOutline(shape: shape).path(in: inner))
        return path
    }
}
