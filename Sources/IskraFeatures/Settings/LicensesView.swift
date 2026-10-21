import SwiftUI
import IskraDesign

/// Whose code ships inside the app, under which licence, and the text of every one of them.
///
/// This is not decoration. Iskra itself is GPL-3.0, every line of Matrix and of Matrix
/// cryptography here is `matrix-rust-sdk`'s under Apache-2.0, the nostr curve is libsecp256k1
/// under MIT, and the avatars are a port of blobatar, under MIT — licences that travel with the
/// binary and need somewhere in the shipped app a person can actually read them. So each row
/// opens the licence's *text*, bundled with the app, rather than a link to a page that may not
/// be there tomorrow and cannot be read offline.
struct LicensesView: View {
    @Environment(\.accent) private var accent

    /// The licence whose text is pushed over this screen — a flag, so Escape can take it back
    /// (`escapeKey`).
    @State private var opened: Licence?

    var body: some View {
        Form {
            Section {
                row(.iskra)
                PushRow { opened = .iskraStorePermission } label: {
                    Text(Strings.Licences.storePermission)
                }
            }

            Section {
                ForEach(Licence.builtOn) { row($0) }
            } header: {
                Text(Strings.Licences.builtOn)
            }
        }
        .formStyle(.grouped)
        .tint(accent.color)
        .navigationTitle(Text(Strings.About.licences))
        // Neither screen reads `dismiss` — this stack can be the sidebar's, see CLAUDE.md.
        .navigationDestination(item: $opened) { licence in
            LicenceTextView(licence: licence)
                .escapeKey { opened = nil }
        }
    }

    private func row(_ licence: Licence) -> some View {
        PushRow { opened = licence } label: {
            LabeledContent {
                EmptyView()
            } label: {
                Text(verbatim: licence.name)
                Text(verbatim: licence.kind)
            }
        }
    }
}

/// One licence the app carries: whose, which, where its text is in the bundle, and the project
/// it came from.
///
/// Names and licence names are not translated — "Apache 2.0" and "MIT" are what the licences
/// are called in every language, and the project names are proper nouns. The texts are not
/// translated either: only the English text of a licence is the licence.
struct Licence: Identifiable, Hashable {
    let name: String
    let kind: String
    /// The resource's name in `Resources/`, without its extension.
    let file: String
    let fileExtension: String
    let project: URL

    /// The row, not the file: two rows can share one text.
    var id: String { name }

    static let iskra = Licence(
        name: "Iskra", kind: "GPL-3.0",
        file: "licence-iskra", fileExtension: "txt",
        project: URL(string: "https://github.com/iskra-app/iskra")!)

    /// `LICENSE-EXCEPTION.md`, shown under its own row rather than glued to the GPL: the GPL's
    /// text is the FSF's word for word, and the permission is a separate statement on top of it.
    static let iskraStorePermission = Licence(
        name: "Iskra", kind: "GPL-3.0, section 7",
        file: "licence-iskra-exception", fileExtension: "md",
        project: URL(string: "https://github.com/iskra-app/iskra")!)

    static let builtOn: [Licence] = [
        Licence(name: "matrix-rust-sdk", kind: "Apache 2.0",
                file: "licence-matrix-rust-sdk", fileExtension: "txt",
                project: URL(string: "https://github.com/matrix-org/matrix-rust-sdk")!),
        // The Swift package that carries the SDK's binary is under the same licence, word for
        // word, so it is one text shown under two names.
        Licence(name: "matrix-rust-components-swift", kind: "Apache 2.0",
                file: "licence-matrix-rust-sdk", fileExtension: "txt",
                project: URL(string: "https://github.com/matrix-org/matrix-rust-components-swift")!),
        Licence(name: "swift-secp256k1", kind: "MIT",
                file: "licence-swift-secp256k1", fileExtension: "txt",
                project: URL(string: "https://github.com/21-DOT-DEV/swift-secp256k1")!),
        // Compiled into the app by the package above, under a copyright of its own.
        Licence(name: "libsecp256k1", kind: "MIT",
                file: "licence-libsecp256k1", fileExtension: "txt",
                project: URL(string: "https://github.com/bitcoin-core/secp256k1")!),
        Licence(name: "blobatar", kind: "MIT © 2026 Alain",
                file: "licence-blobatar", fileExtension: "txt",
                project: URL(string: "https://blobatar.dev")!),
    ]

    /// Where the text is, or `nil` if it is not in the bundle. Loaded from its file URL, as the
    /// icon previews are — a SwiftPM resource directory has no catalog to look a name up in.
    var url: URL? { Bundle.module.url(forResource: file, withExtension: fileExtension) }

    /// The text, unwrapped into paragraphs.
    ///
    /// Licence files are hard-wrapped at about 77 columns for a terminal. Shown as they are on
    /// a phone, every line breaks twice — once where the screen ends and once where the file
    /// did — so the lines inside a paragraph are joined, and blank lines stay paragraph breaks.
    /// In the Markdown file a heading becomes bold text: `##` in front of a sentence is noise,
    /// and a paragraph of `Text` has no heading to draw it with.
    var paragraphs: [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { line in
                        guard fileExtension == "md", let heading = line.firstMatch(of: /^#+\s+(.+)$/) else {
                            return line
                        }
                        return "**\(heading.1)**"
                    }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }
}

/// The text of one licence, with the way to the project it belongs to.
struct LicenceTextView: View {
    @Environment(\.accent) private var accent

    let licence: Licence

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                Link(destination: licence.project) {
                    Label {
                        Text(Strings.Licences.projectPage)
                    } icon: {
                        Image(systemName: "arrow.up.right")
                    }
                }

                ForEach(Array(licence.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    // Markdown only in the one file written in it; a licence's own text is
                    // shown verbatim, so that a `*` in it stays a `*`.
                    if licence.fileExtension == "md",
                       let styled = try? AttributedString(markdown: paragraph) {
                        Text(Self.withoutLinks(styled))
                    } else {
                        Text(verbatim: paragraph)
                    }
                }
            }
            .font(.footnote)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.roomy)
        }
        .tint(accent.color)
        .navigationTitle(Text(verbatim: licence.name))
    }

    /// The Markdown file links to its neighbours in the repository — `LICENSE`,
    /// `CONTRIBUTING.md` — by relative path. In the app there is nothing at the end of those,
    /// so a link would be a word that looks pressable and does nothing; it stays a word.
    private static func withoutLinks(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.link != nil {
            text[run.range].link = nil
        }
        return text
    }
}
