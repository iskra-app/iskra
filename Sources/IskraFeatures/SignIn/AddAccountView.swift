import SwiftUI
import IskraCore

/// Signing in to one more account, on a sheet over the one that is open.
///
/// The same sign-in screen as the first time, with the same service — so the bridge, the OAuth
/// dance and every error read exactly as they do there — and one thing more: a way back. The first
/// sign-in has nowhere to go back *to*; this one has the account that is still underneath it.
struct AddAccountView: View {
    let authentication: AuthenticationService
    var address: String = ""
    let onSignedIn: @MainActor (UserSession) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            SignInView(authentication: authentication, address: address, onSignedIn: onSignedIn)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(app: Strings.Accounts.cancel)) {
                            onCancel()
                        }
                    }
                }
        }
    }
}
