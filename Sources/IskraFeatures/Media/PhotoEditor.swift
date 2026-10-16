import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import IskraCore
import IskraDesign

// MARK: - What was done to the photo

/// Everything done to a photo in the editor, as a value: kept apart from the picture, so that it
/// can be undone one step at a time and drawn twice — small on the screen, and once more at full
/// size when the user says "Done".
///
/// Every coordinate is in **pixels of the photo as turned**: a stroke drawn on a turned photo is in
/// the turned photo's pixels, and turning it again carries the strokes, the words and the frame
/// round with it (`turn()`). Not fractions of the screen — the screen is a different size on every
/// device and a different size again at export, and the one thing all of them agree on is the
/// picture.
struct PhotoEdits: Equatable {
    /// The photo as it arrived, upright (its EXIF orientation already applied).
    let base: CGSize
    /// Quarter turns counter-clockwise, as the Photos app turns: 0…3.
    private(set) var turns = 0
    /// The part of the turned photo that will be sent.
    var crop: CGRect
    var strokes: [Stroke] = []
    var labels: [Label] = []

    init(base: CGSize) {
        self.base = base
        self.crop = CGRect(origin: .zero, size: base)
    }

    /// The turned photo's size.
    var size: CGSize { turns.isMultiple(of: 2) ? base : CGSize(width: base.height, height: base.width) }

    var isUntouched: Bool { self == PhotoEdits(base: base) }

    /// How thick a new line is and how big new words are: a share of the frame's shorter side, so
    /// that a felt-tip line looks like the same felt-tip line on a screenshot and on a 48 MP photo.
    var penWidth: CGFloat { min(crop.width, crop.height) * 0.012 }
    var textSize: CGFloat { min(crop.width, crop.height) * 0.07 }

    struct Stroke: Equatable {
        var points: [CGPoint]
        var color: PhotoInk
        var width: CGFloat
    }

    struct Label: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var center: CGPoint
        var color: PhotoInk
        var size: CGFloat

        /// Roughly where the words are, for a finger to find them. A guess from the length rather
        /// than a measurement — it only has to be generous enough to land on.
        var bounds: CGRect {
            let width = max(CGFloat(max(text.count, 1)) * size * 0.6, size)
            let height = size * 1.4
            return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        }
    }

    /// A quarter turn counter-clockwise, taking everything drawn on the photo with it.
    ///
    /// A point (x, y) of a W-wide photo lands at (y, W − x): the left edge becomes the bottom.
    /// The words move with the photo but stay level, the way they do in every editor — words on
    /// their side are words nobody reads.
    mutating func turn() {
        let width = size.width
        func turned(_ point: CGPoint) -> CGPoint { CGPoint(x: point.y, y: width - point.x) }
        strokes = strokes.map { stroke in
            var stroke = stroke
            stroke.points = stroke.points.map(turned)
            return stroke
        }
        labels = labels.map { label in
            var label = label
            label.center = turned(label.center)
            return label
        }
        crop = CGRect(x: crop.minY, y: width - crop.maxX, width: crop.height, height: crop.width)
        turns = (turns + 1) % 4
    }

    /// What takes the upright photo into the turned one's pixels — the same mapping as `turn()`,
    /// once per quarter, so that the picture and what is drawn on it cannot disagree.
    var turning: CGAffineTransform {
        var transform = CGAffineTransform.identity
        var width = base.width
        var height = base.height
        for _ in 0..<turns {
            transform = transform.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width))
            swap(&width, &height)
        }
        return transform
    }
}

/// The colours there are to draw and write in. Few on purpose: this is a marker on a photo for a
/// friend, not a paint program.
enum PhotoInk: CaseIterable, Identifiable {
    case white, black, red, yellow, green, blue

    var id: Self { self }

    var color: Color {
        switch self {
        case .white: .white
        case .black: .black
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        }
    }

    var name: LocalizedStringResource {
        switch self {
        case .white: Strings.PhotoEditor.white
        case .black: Strings.PhotoEditor.black
        case .red: Strings.PhotoEditor.red
        case .yellow: Strings.PhotoEditor.yellow
        case .green: Strings.PhotoEditor.green
        case .blue: Strings.PhotoEditor.blue
        }
    }
}

// MARK: - Drawing it

/// The photo with its edits on it, showing `region` of the turned photo at `scale` points a pixel.
///
/// One view for the screen and for the file. The editor draws it from a small preview at whatever
/// scale fits; "Done" hands the same view the full photo at a scale of one to `ImageRenderer`. Two
/// drawing routines — one on screen, one in Core Graphics for the export — would be two places for
/// a line to come out a different thickness from the one the user drew.
struct PhotoEditCanvas: View {
    let image: CGImage
    let edits: PhotoEdits
    let region: CGRect
    let scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.minX, y: -region.minY)

            var picture = context
            picture.concatenate(edits.turning)
            picture.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: edits.base))

            for stroke in edits.strokes {
                context.stroke(path(of: stroke), with: .color(stroke.color.color),
                               style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
            }

            for label in edits.labels where !label.text.isEmpty {
                var words = context
                // A shadow, so that white words stay words on a white wall.
                words.addFilter(.shadow(color: .black.opacity(0.5), radius: label.size * 0.08))
                words.draw(Text(label.text)
                    .font(.system(size: label.size, weight: .bold))
                    .foregroundStyle(label.color.color),
                           at: label.center)
            }
        }
        .frame(width: region.width * scale, height: region.height * scale)
    }

    private func path(of stroke: PhotoEdits.Stroke) -> Path {
        var path = Path()
        guard let first = stroke.points.first else { return path }
        path.move(to: first)
        if stroke.points.count == 1 {
            // A tap is a dot, and a path of one point has no length to stroke.
            path.addLine(to: first)
        }
        for point in stroke.points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

// MARK: - The photo, in and out

/// The photo the editor works on, read once: small for the screen, and full-size only at the end.
struct EditablePhoto {
    let source: CGImageSource
    let preview: CGImage
    /// The upright size, in pixels.
    let size: CGSize
    let hasAlpha: Bool

    /// The longest side the screen's copy is decoded at. A phone screen is under 3000 pixels
    /// across, and the editor redraws on every movement of a finger.
    private static let previewSide = 2048

    /// The longest side of what is sent. The "light" step of `MediaSettings` goes no further, and
    /// a full 48 MP frame rendered in memory is two hundred megabytes on a phone.
    static let exportSide: CGFloat = 4096

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let preview = Self.upright(source, side: Self.previewSide) else { return nil }
        self.source = source
        self.preview = preview

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? CGFloat(preview.width)
        let height = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? CGFloat(preview.height)
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // Orientations 5…8 are the ones on their side: the stored width is the upright height.
        self.size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        self.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// The photo upright, its longest side at most `side`.
    private static func upright(_ source: CGImageSource, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ] as CFDictionary)
    }

    /// The edited photo, as the bytes of a new file — PNG where the original could be see-through,
    /// JPEG otherwise. Nil if it would not draw.
    ///
    /// The metadata is gone by construction: this is a new picture, drawn. It still goes through
    /// `MediaPreparation` at send like any other, which checks that and does not take it on trust.
    @MainActor
    func render(_ edits: PhotoEdits) -> Data? {
        let longest = max(edits.crop.width, edits.crop.height)
        let scale = min(1, Self.exportSide / longest)
        // Decoded at the size it will be drawn at, not larger: a 4096-pixel crop of a 48 MP photo
        // needs the whole photo, a 4096-pixel export of the whole photo does not.
        let side = Int((max(size.width, size.height) * scale).rounded(.up))
        guard let full = Self.upright(source, side: side) else { return nil }

        let renderer = ImageRenderer(content: PhotoEditCanvas(image: full, edits: edits, region: edits.crop, scale: scale))
        renderer.scale = 1
        renderer.isOpaque = !hasAlpha
        guard let image = renderer.cgImage else { return nil }

        let type: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - The screen

/// A photo waiting in the composer, opened to be marked up before it goes: words on it, a line
/// drawn on it, a part cut out of it, turned the right way up.
///
/// It hands back new bytes, or nothing if the user cancelled — and never touches what is already
/// waiting in the composer until "Done", so a cancelled edit is the photo exactly as it was.
struct PhotoEditor: View {
    let photo: EditablePhoto
    let onDone: (Data) -> Void
    let onCancel: () -> Void

    enum Tool: Hashable { case draw, text, crop }

    @State private var edits: PhotoEdits
    @State private var history: [PhotoEdits] = []
    @State private var tool: Tool? = .draw
    @State private var ink: PhotoInk = .white

    /// The stroke being drawn, while a finger is down.
    @State private var drawing = false
    /// The words being moved, and where they were when the drag began.
    @State private var moving: (id: PhotoEdits.Label.ID, from: CGPoint)?
    /// What the frame is doing under the finger in crop mode, and the frame it started from.
    @State private var framing: (handle: CropHandle, from: CGRect)?

    @State private var editingLabel: PhotoEdits.Label.ID?
    @FocusState private var isTyping: Bool

    @State private var failed = false

    init(photo: EditablePhoto, onDone: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        self.photo = photo
        self.onDone = onDone
        self.onCancel = onCancel
        _edits = State(initialValue: PhotoEdits(base: photo.size))
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.normal) {
            topBar
            GeometryReader { proxy in
                stage(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(.horizontal, Theme.Spacing.roomy)
            if editingLabel != nil { textField }
            if tool == .draw || tool == .text { palette }
            toolBar
        }
        .padding(.vertical, Theme.Spacing.normal)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
        .alert(Text(Strings.PhotoEditor.failed), isPresented: $failed) {
            Button(role: .cancel) {} label: { Text(Strings.PhotoEditor.ok) }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.close) {
            Button(action: onCancel) { Text(Strings.PhotoEditor.cancel) }
                .buttonStyle(.glassSecondary)
                .keyboardShortcut(.cancelAction)
            Spacer()
            iconButton("arrow.uturn.backward", Strings.PhotoEditor.undo, action: undo)
                .disabled(history.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
            Spacer()
            Button(action: finish) { Text(Strings.PhotoEditor.done) }
                .buttonStyle(.glassAction)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Spacing.roomy)
    }

    private var toolBar: some View {
        HStack(spacing: Theme.Spacing.generous) {
            toolButton(.draw, "pencil.tip", Strings.PhotoEditor.draw)
            toolButton(.text, "textformat", Strings.PhotoEditor.text)
            toolButton(.crop, "crop", Strings.PhotoEditor.crop)
            iconButton("rotate.left", Strings.PhotoEditor.rotate) {
                change { $0.turn() }
            }
        }
    }

    private func toolButton(_ which: Tool, _ symbol: String, _ name: LocalizedStringResource) -> some View {
        let isOn = tool == which
        return Button {
            endTyping()
            tool = isOn ? nil : which
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                .background(isOn ? Color.white : Color.clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, _ name: LocalizedStringResource,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(Text(name))
    }

    private var palette: some View {
        HStack(spacing: Theme.Spacing.normal) {
            ForEach(PhotoInk.allCases) { choice in
                Button {
                    ink = choice
                    if let id = editingLabel { recolour(id, choice) }
                } label: {
                    Circle()
                        .fill(choice.color)
                        .frame(width: Theme.Size.inkSwatch, height: Theme.Size.inkSwatch)
                        .overlay {
                            Circle().strokeBorder(.white, lineWidth: ink == choice ? Theme.Border.thick : Theme.Border.hairline)
                        }
                        .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(choice.name))
                .accessibilityAddTraits(ink == choice ? .isSelected : [])
            }
        }
    }

    private var textField: some View {
        TextField(text: labelText, prompt: Text(Strings.PhotoEditor.textPrompt)) { EmptyView() }
            .textFieldStyle(.plain)
            .focused($isTyping)
            .onSubmit(endTyping)
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.close)
            .navigationGlass(in: .capsule)
            .padding(.horizontal, Theme.Spacing.roomy)
            .onChange(of: isTyping) { _, typing in if !typing { endTyping() } }
    }

    /// The words being typed, read from and written straight into the label on the photo, so the
    /// photo shows them as they are typed.
    private var labelText: Binding<String> {
        Binding {
            edits.labels.first { $0.id == editingLabel }?.text ?? ""
        } set: { text in
            guard let index = edits.labels.firstIndex(where: { $0.id == editingLabel }) else { return }
            edits.labels[index].text = text
        }
    }

    // MARK: The photo

    /// The photo, fitted to the space there is. Outside crop mode only the frame is shown — that is
    /// the picture that will be sent; in crop mode all of it, with the frame drawn over it.
    @ViewBuilder
    private func stage(in space: CGSize) -> some View {
        let region = tool == .crop ? CGRect(origin: .zero, size: edits.size) : edits.crop
        let scale = min(space.width / region.width, space.height / region.height)
        PhotoEditCanvas(image: photo.preview, edits: edits, region: region, scale: scale)
            .overlay {
                if tool == .crop {
                    CropFrame(rect: edits.crop.scaled(by: scale))
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { drag in
                touched(drag, region: region, scale: scale, ended: false)
            }.onEnded { drag in
                touched(drag, region: region, scale: scale, ended: true)
            })
    }

    private func touched(_ drag: DragGesture.Value, region: CGRect, scale: CGFloat, ended: Bool) {
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: region.minX + point.x / scale, y: region.minY + point.y / scale)
        }
        switch tool {
        case .draw: draw(at: pixel(drag.location), ended: ended)
        case .text: text(drag, pixel: pixel, scale: scale, ended: ended)
        case .crop: frame(drag, scale: scale, ended: ended)
        case nil: break
        }
    }

    private func draw(at point: CGPoint, ended: Bool) {
        if !drawing {
            drawing = true
            history.append(edits)
            edits.strokes.append(.init(points: [point], color: ink, width: edits.penWidth))
        } else if let last = edits.strokes.indices.last {
            edits.strokes[last].points.append(point)
        }
        if ended { drawing = false }
    }

    /// In text mode a finger on words moves them and a tap on words edits them; a tap anywhere
    /// else puts new words there.
    private func text(_ drag: DragGesture.Value, pixel: (CGPoint) -> CGPoint, scale: CGFloat, ended: Bool) {
        let start = pixel(drag.startLocation)
        if moving == nil, let label = edits.labels.last(where: { $0.bounds.contains(start) }) {
            history.append(edits)
            moving = (label.id, label.center)
        }
        if let moving, let index = edits.labels.firstIndex(where: { $0.id == moving.id }) {
            edits.labels[index].center = CGPoint(x: moving.from.x + drag.translation.width / scale,
                                                 y: moving.from.y + drag.translation.height / scale)
        }
        guard ended else { return }

        let wasTap = hypot(drag.translation.width, drag.translation.height) < Theme.Spacing.tight
        if let moving, wasTap {
            // Nothing moved, so the step pushed for the move is not a step.
            history.removeLast()
            beginTyping(moving.id)
        } else if moving == nil, wasTap {
            endTyping()
            history.append(edits)
            let label = PhotoEdits.Label(text: "", center: start, color: ink, size: edits.textSize)
            edits.labels.append(label)
            beginTyping(label.id)
        }
        self.moving = nil
    }

    private func frame(_ drag: DragGesture.Value, scale: CGFloat, ended: Bool) {
        if framing == nil {
            let handle = CropHandle.at(drag.startLocation, in: edits.crop.scaled(by: scale))
            framing = handle.map { ($0, edits.crop) }
            if framing != nil { history.append(edits) }
        }
        if let framing {
            edits.crop = framing.handle.move(framing.from,
                                             by: CGSize(width: drag.translation.width / scale,
                                                        height: drag.translation.height / scale),
                                             within: CGRect(origin: .zero, size: edits.size))
        }
        if ended {
            if let framing, framing.from == edits.crop { history.removeLast() }
            framing = nil
        }
    }

    // MARK: Changes

    private func change(_ make: (inout PhotoEdits) -> Void) {
        endTyping()
        history.append(edits)
        make(&edits)
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        editingLabel = nil
        isTyping = false
        edits = previous
    }

    private func recolour(_ id: PhotoEdits.Label.ID, _ ink: PhotoInk) {
        guard let index = edits.labels.firstIndex(where: { $0.id == id }) else { return }
        edits.labels[index].color = ink
    }

    private func beginTyping(_ id: PhotoEdits.Label.ID) {
        editingLabel = id
        if let label = edits.labels.first(where: { $0.id == id }) { ink = label.color }
        isTyping = true
    }

    /// Words left empty are taken off the photo, and the step that added them with them.
    private func endTyping() {
        guard let id = editingLabel else { return }
        editingLabel = nil
        isTyping = false
        if let label = edits.labels.first(where: { $0.id == id }),
           label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            edits.labels.removeAll { $0.id == id }
            if let previous = history.last, !previous.labels.contains(where: { $0.id == id }) {
                history.removeLast()
            }
        }
    }

    private func finish() {
        endTyping()
        guard !edits.isUntouched else { return onCancel() }
        guard let data = photo.render(edits) else {
            Log.media.error("an edited photo would not render")
            failed = true
            return
        }
        onDone(data)
    }
}

// MARK: - The crop frame

/// Which part of the frame a finger took hold of.
enum CropHandle {
    case topLeft, topRight, bottomLeft, bottomRight, body

    /// How far from a corner a finger may land and still have it.
    static let reach = Theme.Size.minimumTapTarget / 2

    /// The smallest a frame may be made, in pixels of the photo.
    static let smallest: CGFloat = 64

    static func at(_ point: CGPoint, in rect: CGRect) -> CropHandle? {
        let corners: [(CropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        if let nearest = corners.min(by: { distance($0.1, point) < distance($1.1, point) }),
           distance(nearest.1, point) <= reach {
            return nearest.0
        }
        return rect.contains(point) ? .body : nil
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// `rect` with this part of it dragged by `offset`, kept inside `bounds` and no smaller than
    /// `smallest` (or the photo, if the photo is smaller still).
    func move(_ rect: CGRect, by offset: CGSize, within bounds: CGRect) -> CGRect {
        let least = min(Self.smallest, bounds.width, bounds.height)
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch self {
        case .body:
            let dx = min(max(offset.width, bounds.minX - rect.minX), bounds.maxX - rect.maxX)
            let dy = min(max(offset.height, bounds.minY - rect.minY), bounds.maxY - rect.maxY)
            return rect.offsetBy(dx: dx, dy: dy)
        case .topLeft:
            minX = min(max(rect.minX + offset.width, bounds.minX), maxX - least)
            minY = min(max(rect.minY + offset.height, bounds.minY), maxY - least)
        case .topRight:
            maxX = max(min(rect.maxX + offset.width, bounds.maxX), minX + least)
            minY = min(max(rect.minY + offset.height, bounds.minY), maxY - least)
        case .bottomLeft:
            minX = min(max(rect.minX + offset.width, bounds.minX), maxX - least)
            maxY = max(min(rect.maxY + offset.height, bounds.maxY), minY + least)
        case .bottomRight:
            maxX = max(min(rect.maxX + offset.width, bounds.maxX), minX + least)
            maxY = max(min(rect.maxY + offset.height, bounds.maxY), minY + least)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The frame over the photo in crop mode: what is outside it dimmed, a thin line round it, and
/// the corners drawn heavier because they are what to take hold of.
private struct CropFrame: View {
    let rect: CGRect

    var body: some View {
        Canvas { context, size in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(rect)
            context.fill(outside, with: .color(.black.opacity(Theme.Backdrop.dim)), style: FillStyle(eoFill: true))
            context.stroke(Path(rect), with: .color(.white), lineWidth: Theme.Border.hairline)

            let arm = min(Theme.Size.cropCorner, rect.width / 2, rect.height / 2)
            var corners = Path()
            for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                                   (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
                corners.move(to: CGPoint(x: x + arm * dx, y: y))
                corners.addLine(to: CGPoint(x: x, y: y))
                corners.addLine(to: CGPoint(x: x, y: y + arm * dy))
            }
            context.stroke(corners, with: .color(.white), lineWidth: Theme.Border.thick * 2)
        }
        .allowsHitTesting(false)
    }
}

private extension CGRect {
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}

/// Which waiting photo the editor is open on, for the room that presents it.
struct EditingPhoto: Identifiable {
    let id = UUID()
    let attachmentID: PendingAttachment.ID
    let photo: EditablePhoto
}
