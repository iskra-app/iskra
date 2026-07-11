import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// The bar you type into.
///
/// A navigation-layer control floating over the timeline, which is exactly what Liquid
/// Glass is for. Kept out of `RoomView` so it can be rendered — and looked at — on its
/// own, without a signed-in session and a room behind it.
struct MessageComposer: View {
    @Binding var draft: String

    var onSend: () -> Void
    var onRecordVideoNote: () -> Void
    var onPickedMedia: (PhotosPickerItem) -> Void
    var onPickedFile: (URL) -> Void

    @State private var pickedItem: PhotosPickerItem?
    @State private var isChoosingFile = false
    @FocusState private var isFocused: Bool

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: Theme.Spacing.close) {
            // Bottom-aligned, so the round buttons stay level with the last line of a
            // message that has grown to several lines rather than riding its middle.
            HStack(alignment: .bottom, spacing: Theme.Spacing.close) {
                attachMenu

                TextField(String(app: Strings.Room.composerPlaceholder), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .padding(.horizontal, Theme.Spacing.roomy)
                    .padding(.vertical, Theme.Spacing.normal)
                    .frame(minHeight: Theme.Size.composerControl)
                    .navigationGlass(in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    .onSubmit(onSend)

                // With nothing typed, the primary action is a video message — the same
                // place, and the same thumb, as the send button it replaces.
                if isEmpty {
                    button(systemImage: "video.fill",
                           label: Strings.VideoNote.record,
                           isPrimary: false,
                           action: onRecordVideoNote)
                } else {
                    button(systemImage: "arrow.up",
                           label: Strings.Room.send,
                           isPrimary: true,
                           action: onSend)
                }
            }
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
        }
        .animation(.smooth(duration: 0.2), value: isEmpty)
    }

    /// A circle exactly as tall as the text field, so the three controls read as one
    /// row rather than as a field with two lumps beside it.
    private func button(systemImage: String,
                        label: LocalizedStringResource,
                        isPrimary: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon(systemImage, isPrimary: isPrimary)
        }
        // Not `.buttonStyle(.glass)`. That style wraps the label in padding of its own,
        // on top of whatever frame we set, which is what made these bulge. The glass
        // goes on the circle itself instead, at the size we actually want.
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private func icon(_ systemImage: String, isPrimary: Bool) -> some View {
        let glyph = Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(isPrimary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: Theme.Size.composerControl, height: Theme.Size.composerControl)

        if isPrimary {
            glyph.primaryActionGlass(tint: .accentColor, in: .circle)
                .contentShape(.circle)
        } else {
            glyph.navigationGlass(in: .circle)
                .contentShape(.circle)
        }
    }

    /// Photos and videos come from the system picker; everything else from the file
    /// importer. Both are the standard components, which is what gets us the system's
    /// own permission prompts, iCloud Drive and Files browsing for free.
    private var attachMenu: some View {
        Menu {
            PhotosPicker(selection: $pickedItem, matching: .any(of: [.images, .videos])) {
                Label(Strings.Room.attachPhoto, systemImage: "photo")
            }

            Button {
                isChoosingFile = true
            } label: {
                Label(Strings.Room.attachFile, systemImage: "doc")
            }
        } label: {
            icon("plus", isPrimary: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(Strings.Room.attach))
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            onPickedMedia(item)
            pickedItem = nil
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            onPickedFile(url)
        }
    }
}
