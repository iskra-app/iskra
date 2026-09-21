import SwiftUI
import WebKit
import IskraCore
import IskraDesign

/// One call, full screen.
///
/// Almost nothing on this screen is ours, and the screen is honest about that rather than
/// pretending otherwise. Element Call draws the faces, the buttons, the mute and the hang-up; what
/// this view adds is a bar above it with the room's name and a way out, because the page's own
/// header is hidden (`hideHeader`) and the way out went with it.
///
/// The bar is the only part of the app's own design language here, and that is the right amount.
/// Dressing a web application in bubbles and glass would not make it ours — it would make it a
/// web application that is harder to recognise as one.
struct CallScreen: View {
    let store: CallStore
    let roomName: String
    let intent: CallIntent
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The pipe to the page. Held here because messages start arriving from the SDK before the
    /// web view exists — see `CallBridge`, which is the whole of the fix.
    @State private var bridge = CallBridge()

    var body: some View {
        ZStack {
            // Behind everything, including while the page is still blank. A call that starts as a
            // white flash on a dark screen is a call that looks broken before it looks like
            // anything.
            Color.black.ignoresSafeArea()

            switch store.state {
            case .idle, .preparing:
                connecting
            case let .ready(url):
                CallWebView(url: url) { json in
                    store.incoming(json)
                } onReady: { webView in
                    bridge.attach(webView)
                }
                .ignoresSafeArea()
            case let .failed(failure):
                CallFailureView(failure: failure)
            }
        }
        .safeAreaInset(edge: .top) { bar }
        .task {
            await store.start(intent: intent,
                              theme: colorScheme == .dark ? .dark : .light,
                              language: Locale.current.identifier)
        }
        .task {
            for await message in store.outgoing {
                bridge.deliver(message)
            }
        }
        .onDisappear {
            bridge.detach()
            store.stop()
        }
    }

    private var bar: some View {
        HStack {
            Text(roomName)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.normal)

            Button(String(app: Strings.Call.leave)) {
                store.stop()
                onClose()
            }
            .font(.headline)
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.close)
            .navigationGlass()
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.vertical, Theme.Spacing.close)
    }

    private var connecting: some View {
        VStack(spacing: Theme.Spacing.roomy) {
            ProgressView()
            Text(String(app: Strings.Call.connecting))
                .foregroundStyle(.secondary)
        }
    }
}

/// What is shown instead of a call that did not happen.
private struct CallFailureView: View {
    let failure: CallFailure

    var body: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Text(String(app: Strings.Call.failedTitle))
                .font(.headline)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.generous)
    }

    private var reason: String {
        switch failure {
        case .unavailable: String(app: Strings.Call.unavailable)
        case .couldNotStart: String(app: Strings.Call.couldNotStart)
        }
    }
}

extension View {
    /// Puts a call on screen the way each platform puts a call on screen.
    ///
    /// A call takes the whole phone — it is not a panel over the conversation, and a sheet that
    /// can be swiped half away during a conversation with a person is a sheet that will be. The
    /// Mac has no such thing as a full-screen cover, and a window-modal sheet is what a Mac
    /// application does with something that has its own way out.
    func callPresentation(isPresented: Binding<Bool>,
                          @ViewBuilder content: @escaping () -> some View) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented, content: content)
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
}

/// Holds messages for the page until there is a page.
///
/// The SDK's widget driver starts talking as soon as it is running, which is before the web view
/// has been made — and a message dropped in that window is not a late message, it is a call that
/// never connects, because the first thing the driver sends is the handshake. So anything that
/// arrives early waits here and goes in the moment the view exists.
@MainActor
@Observable
final class CallBridge {
    private var webView: WKWebView?
    private var waiting: [String] = []

    func attach(_ webView: WKWebView) {
        self.webView = webView
        for message in waiting {
            CallWebView.deliver(message, to: webView)
        }
        waiting = []
    }

    func deliver(_ json: String) {
        if let webView {
            CallWebView.deliver(json, to: webView)
        } else {
            waiting.append(json)
        }
    }

    func detach() {
        webView = nil
        waiting = []
    }
}
