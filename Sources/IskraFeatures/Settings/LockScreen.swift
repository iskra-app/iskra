import SwiftUI
import IskraCore
import IskraDesign

/// The shield the app wears while it is locked. An opaque cover — so nothing behind it can be read
/// or screenshotted — with the one thing to do: unlock. It asks the system for Face ID, Touch ID,
/// or the device passcode the moment it appears, and again on the button, and comes down only when
/// the system says yes.
///
/// It carries no way out but authentication. A "Cancel" here would be a lock with a back door.
struct LockScreen: View {
    let appLock: AppLock

    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            // Opaque, over the whole screen: this is what actually hides the conversation behind it,
            // not just a tint.
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.generous) {
                Image(systemName: "lock.fill")
                    .font(.system(size: Theme.Size.avatarLarge))
                    .foregroundStyle(.secondary)

                Text(Strings.Lock.title)
                    .font(.headline)

                Button(String(app: Strings.Lock.unlock)) {
                    unlock()
                }
                .buttonStyle(.glassAction)
                .disabled(isAuthenticating)
            }
            .padding(Theme.Spacing.generous)
        }
        // Ask straight away — the button is the retry, not the first ask.
        .task { unlock() }
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            _ = await appLock.authenticate(reason: String(app: Strings.Lock.reason))
            isAuthenticating = false
        }
    }
}
