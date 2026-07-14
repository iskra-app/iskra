import SwiftUI
import IskraCore
import IskraDesign

/// What the app is keeping on this device, and the one part of it you are allowed to throw away.
///
/// The three stores are shown separately rather than as one number, because one number answers
/// the wrong question. "Iskra: 640 MB" tells you to delete the app; "photos and messages you can
/// re-download: 480 MB, keys you cannot: 4 MB" tells you what to press. So each row carries a
/// sentence about what losing it would cost, and only what can be thrown away has a button.
///
/// There are two, and they are not the same button with a different scope. One is about space and
/// takes the cache (and the index with it). The other takes the index alone, and it is there for a
/// reason nobody would guess from the word "cache": a message deleted long enough ago can have left
/// its words behind in the index, and wiping the index is the only way to take them back.
struct StorageView: View {
    /// Owned, not handed in, and that is the whole difference between this screen working and
    /// this screen reading "Zero KB" over twenty-two megabytes of cache.
    ///
    /// `session.storage()` mints a store, and the `navigationDestination` that builds this screen
    /// runs again on every pass of the settings screen's `body` — which re-runs on every keystroke
    /// in the name field. As a plain `let` this view was handed a *fresh, empty* store each time,
    /// so the one that had done the measuring was thrown away and the one on screen had never
    /// measured anything. `@State` keeps the first, which is the one whose `.task` is running.
    @State private var storage: StorageStore

    /// What the app does once the cache is gone: build itself a new client. The SDK requires it —
    /// see `StorageStore.clearCache` — and this screen cannot do it, because the session it would
    /// replace is the one holding this screen up.
    let onCleared: () -> Void

    init(storage: @autoclosure () -> StorageStore, onCleared: @escaping () -> Void) {
        _storage = State(wrappedValue: storage())
        self.onCleared = onCleared
    }

    @State private var isConfirmingClear = false
    @State private var isConfirmingSearchClear = false
    @State private var didFail = false
    @State private var didFailSearch = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if storage.isMeasuring, storage.amounts.isEmpty {
                        Text(Strings.Storage.measuring)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(size(storage.total))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                } label: {
                    Label(Strings.Storage.total, systemImage: "internaldrive")
                }
            }

            Section {
                bar

                ForEach(storage.amounts) { amount in
                    row(for: amount)
                }
            }

            // The button is a section of its own, and it names the number it will win back: a
            // "clear cache" that does not say what clearing costs or gains is asking for a
            // decision with the facts left out.
            Section {
                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    HStack {
                        Text(storage.isClearing ? Strings.Storage.clearing : Strings.Storage.clear)
                        Spacer()
                        if storage.isClearing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(size(storage.reclaimable))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .disabled(storage.isClearing || storage.reclaimable == 0)
            } footer: {
                Text(Strings.Storage.cacheExplained)
            }

            // Its own section, because it answers a different question. The button above is about
            // space; this one is about a message somebody deleted whose words the index may still be
            // holding — and nobody would guess that from "clear cache".
            Section {
                Button(role: .destructive) {
                    isConfirmingSearchClear = true
                } label: {
                    HStack {
                        Text(storage.isClearing ? Strings.Storage.clearing : Strings.Storage.clearSearch)
                        Spacer()
                        if !storage.isClearing {
                            Text(size(storage.searchIndexBytes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .disabled(storage.isClearing || storage.searchIndexBytes == 0)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Storage.title))
        .toolbarTitleDisplayMode(.inline)
        // Measured when the screen opens, and again after a clear — the SDK writes to these
        // stores continuously, so an answer given once is a number that is quietly going stale on
        // the screen. Once per visit is honest; polling would be a settings screen doing `stat` on
        // ten thousand files in a loop.
        .task { await storage.measure() }
        .confirmationDialog(Text(Strings.Storage.confirmTitle),
                            isPresented: $isConfirmingClear,
                            titleVisibility: .visible) {
            Button(String(app: Strings.Storage.confirmAction), role: .destructive) {
                Task { await clear() }
            }
            Button(String(app: Strings.Storage.cancel), role: .cancel) {}
        } message: {
            Text(Strings.Storage.confirmBody)
        }
        .confirmationDialog(Text(Strings.Storage.clearSearchTitle),
                            isPresented: $isConfirmingSearchClear,
                            titleVisibility: .visible) {
            Button(String(app: Strings.Storage.confirmAction), role: .destructive) {
                Task { await clearSearchIndex() }
            }
            Button(String(app: Strings.Storage.cancel), role: .cancel) {}
        } message: {
            Text(Strings.Storage.clearSearchBody)
        }
        .alert(Text(Strings.Storage.failed), isPresented: $didFail) {
            Button(String(app: Strings.Problem.ok)) {}
        }
        .alert(Text(Strings.Storage.clearSearchFailed), isPresented: $didFailSearch) {
            Button(String(app: Strings.Problem.ok)) {}
        }
    }

    /// One bar, three bands, in proportion — the answer to "what is taking the space, and how much
    /// of it" given at a glance, before a single number has been read.
    ///
    /// The bands are drawn from the *measured* amounts rather than at some fixed ratio, and a band
    /// too small to see is drawn at the smallest mark that can be seen rather than at nothing. A
    /// chart that quietly rounds a category away is a chart that has answered the question wrongly
    /// while looking authoritative about it.
    private var bar: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(storage.amounts) { amount in
                    colour(of: amount.kind)
                        .frame(width: width(of: amount, across: proxy.size.width))
                }
            }
            // The empty bar of a freshly installed app, and of the moment before the walk of the
            // directories comes back. A hairline of nothing reads as broken; a track reads as a
            // measurement that has not landed yet.
            .background(Color.primary.opacity(Theme.Backdrop.wash))
        }
        .frame(height: Theme.Size.storageBar)
        .clipShape(.capsule)
        .animation(.smooth, value: storage.amounts)
        .listRowInsets(EdgeInsets(top: Theme.Spacing.normal,
                                  leading: Theme.Spacing.roomy,
                                  bottom: Theme.Spacing.normal,
                                  trailing: Theme.Spacing.roomy))
        .accessibilityElement()
        .accessibilityLabel(Text(Strings.Storage.total))
        .accessibilityValue(Text(size(storage.total)))
    }

    /// A band's share of the bar, in points.
    ///
    /// The floor is applied per band and the bands are *not* renormalised afterwards, so three
    /// slivers can push the bar a few points past its own width — which is why the whole thing is
    /// clipped to a capsule. The alternative is arithmetic nobody can read, to save a rounding
    /// error nobody can see.
    private func width(of amount: StorageAmount, across full: CGFloat) -> CGFloat {
        guard storage.total > 0, amount.bytes > 0 else { return 0 }
        let share = CGFloat(amount.bytes) / CGFloat(storage.total)
        return max(Theme.Size.storageBarLeast, full * share)
    }

    private func row(for amount: StorageAmount) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            LabeledContent {
                Text(size(amount.bytes))
                    .monospacedDigit()
            } label: {
                // The symbol wears the band's colour, which is what makes the bar above legible
                // without a key of its own: the row *is* the key.
                Label {
                    Text(name(of: amount.kind))
                } icon: {
                    Image(systemName: symbol(of: amount.kind))
                        .foregroundStyle(colour(of: amount.kind))
                }
            }

            Text(explanation(of: amount.kind))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    private func clear() async {
        do {
            try await storage.clearCache()
            onCleared()
        } catch {
            didFail = true
        }
    }

    /// Same ending as `clear()`, and for the same reason: the store was pulled out from under a
    /// client that had it open, and the app owes itself a new one. `onCleared` is what gets it.
    private func clearSearchIndex() async {
        do {
            try await storage.clearSearchIndex()
            onCleared()
        } catch {
            didFailSearch = true
        }
    }

    /// Bytes as a person reads them. `.file` rather than `.memory`, because this is the number the
    /// Settings app would show for the same directories, and two apps disagreeing about how many
    /// megabytes the same files are is its own small betrayal.
    private func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private func name(of kind: StorageKind) -> LocalizedStringResource {
        switch kind {
        case .session: Strings.Storage.session
        case .cache: Strings.Storage.cache
        case .search: Strings.Storage.search
        }
    }

    private func explanation(of kind: StorageKind) -> LocalizedStringResource {
        switch kind {
        case .session: Strings.Storage.sessionExplained
        case .cache: Strings.Storage.cacheExplained
        case .search: Strings.Storage.searchExplained
        }
    }

    /// The band's colour, by its place in `StorageKind` — see `Theme.Storage`. Positional rather
    /// than a `switch`, so that a fourth kind of data arrives on the screen already coloured
    /// instead of arriving grey because nobody remembered this function existed.
    private func colour(of kind: StorageKind) -> Color {
        let place = StorageKind.allCases.firstIndex(of: kind) ?? 0
        return Theme.Storage.band(place)
    }

    private func symbol(of kind: StorageKind) -> String {
        switch kind {
        case .session: "key"
        case .cache: "photo.on.rectangle"
        case .search: "magnifyingglass"
        }
    }
}
