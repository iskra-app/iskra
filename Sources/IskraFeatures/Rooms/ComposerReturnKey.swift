import SwiftUI
#if os(iOS)
import GameController
import UIKit
#endif

/// What Return does in the composer on a hardware keyboard — Settings → Chats, on iPad and Mac.
///
/// Two ways round, as in Telegram's desktop apps: Return sends and Shift-Return (or Option-Return)
/// starts a new line, or Return starts a new line and ⌘-Return sends. The first is what a chat app
/// is expected to do; the second is for people who write paragraphs and have sent one half-finished
/// too many times.
///
/// The two platforms need two different mechanisms, and that is not tidiness lost:
///
/// - **Mac.** A vertical `TextField` already submits on Return and puts a newline in on
///   Option-Return. `onKeyPress` sees the key before the field does, so the swap is made there.
/// - **iPad.** A vertical `TextField` puts a newline in on Return and never submits, and
///   `onKeyPress` does not see a key the text view consumes. So ⌘-Return is the send button's
///   keyboard shortcut, and "Return sends" is recognised afterwards: the newline that just landed,
///   with a hardware keyboard attached and neither Shift nor Option held, is taken back out and
///   the message sent. The on-screen keyboard is never second-guessed — its Return key has no
///   Shift beside it to mean anything else.
enum ComposerReturnKey {
    static let sendsWithCommandReturnKey = "composer.sendsWithCommandReturn"
    static let sendsWithCommandReturnByDefault = false

    /// Whether the setting means anything here. Not on iPhone, which has no keyboard that would
    /// ask the question.
    static var isOffered: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        true
        #endif
    }

    /// Whether ⌘-Return is what sends, on this device, now.
    static func sendsWithCommandReturn(_ stored: Bool) -> Bool {
        isOffered && stored
    }

    #if os(iOS)
    /// Whether Shift or Option is down on an attached keyboard. Nil without a hardware keyboard,
    /// which is the case where nothing should be second-guessed.
    static var newlineModifierHeld: Bool? {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return nil }
        let keys: [GCKeyCode] = [.leftShift, .rightShift, .leftAlt, .rightAlt]
        return keys.contains { input.button(forKeyCode: $0)?.isPressed == true }
    }
    #endif
}

extension View {
    /// The Return key in the composer's field, by the setting above. `send` is the composer's own
    /// send; `text` and `selection` are the field's, for putting a newline where the cursor is.
    func composerReturnKey(text: Binding<String>,
                           selection: Binding<TextSelection?>,
                           send: @escaping () -> Void) -> some View {
        modifier(ComposerReturnKeyModifier(text: text, selection: selection, send: send))
    }
}

private struct ComposerReturnKeyModifier: ViewModifier {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let send: () -> Void

    @AppStorage(ComposerReturnKey.sendsWithCommandReturnKey)
    private var stored = ComposerReturnKey.sendsWithCommandReturnByDefault

    private var commandSends: Bool { ComposerReturnKey.sendsWithCommandReturn(stored) }

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.command) {
                    send()
                    return .handled
                }
                let wantsNewline = commandSends || press.modifiers.contains(.shift)
                    || press.modifiers.contains(.option)
                guard wantsNewline else { return .ignored }
                insertNewline()
                return .handled
            }
            // Return, unmodified, in the "Return sends" mode: the field's own submit.
            .onSubmit { if !commandSends { send() } }
        #else
        content
            .onChange(of: text) { old, new in
                guard ComposerReturnKey.isOffered, !commandSends,
                      ComposerReturnKey.newlineModifierHeld == false,
                      new.count == old.count + 1,
                      let removed = withoutInsertedNewline(old: old, new: new) else { return }
                text = removed
                send()
            }
        #endif
    }

    /// `new` minus the single newline that turned `old` into it — nil if that is not what happened
    /// (a paste, an autocorrection, a character that is not a newline).
    private func withoutInsertedNewline(old: String, new: String) -> String? {
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let index = new.index(new.startIndex, offsetBy: prefix)
        guard new[index] == "\n" else { return nil }
        var result = new
        result.remove(at: index)
        return result == old ? result : nil
    }

    /// A newline where the cursor is, replacing whatever is selected — the field's own behaviour,
    /// done by hand because the key that would have done it was taken for sending.
    private func insertNewline() {
        guard let selection, case let .selection(range) = selection.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else {
            text.append("\n")
            return
        }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: "\n")
        self.selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset + 1))
    }
}
