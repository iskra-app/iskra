import SwiftUI
import Observation
import IskraCore
import IskraDesign

/// The accounts on this device, as the screens that offer to switch between them see them.
///
/// Owned by `IskraRootView`, which is the only view that can do either thing it offers — switching
/// closes one session and opens another, and adding one puts a sign-in sheet over the whole app.
/// So the screens below do not do anything themselves: they *ask*, by setting `requestedAccount` or
/// `isAddingAccount`, and the root answers. That keeps both out of the sidebar's navigation stack,
/// where a screen that dismisses itself hangs the Mac (see `CLAUDE.md`).
@MainActor
@Observable
public final class AccountSwitcher {
    /// Everyone signed in, in the order they were added, the one on screen included.
    public private(set) var accounts: [AccountRecord] = []

    /// The account on screen.
    public private(set) var activeID: String?

    /// Whether there is anything to switch between here at all. False in the demo and under
    /// `--mock-signin`, which are not the device's accounts and must not appear beside them.
    public private(set) var isAvailable = false

    /// Unread counts of every account, from `UnreadCounts` — the one on screen live, the others as
    /// of their last push.
    public private(set) var unread: [String: Int] = [:]

    /// Set by a screen to ask for another account; the root switches and clears it.
    public var requestedAccount: String?

    /// Set by a screen to ask for the sign-in sheet; the root presents it.
    public var isAddingAccount = false

    /// Set by a screen to sign out of an account that is not on screen; the root does it and
    /// clears it. The one on screen is signed out of by settings' own red button, not this.
    public var requestedSignOut: String?

    /// The accounts being signed out of right now, so their rows can say so rather than sit there
    /// looking untouched for the ten seconds a slow server can take.
    public internal(set) var signingOut: Set<String> = []

    public init() {}

    /// Everyone except the account on screen.
    public var others: [AccountRecord] {
        accounts.filter { $0.sessionID != activeID }
    }

    public var hasSeveral: Bool { accounts.count > 1 }

    public func switchTo(_ id: String) {
        guard id != activeID else { return }
        requestedAccount = id
    }

    public func addAccount() {
        isAddingAccount = true
    }

    public func signOut(_ id: String) {
        guard id != activeID, !signingOut.contains(id) else { return }
        signingOut.insert(id)
        requestedSignOut = id
    }

    /// Re-reads the list, after anything that could have changed it.
    func reload(accounts: [AccountRecord], activeID: String?, isAvailable: Bool) {
        self.accounts = accounts
        self.activeID = activeID
        self.isAvailable = isAvailable
        refreshUnread()
    }

    func refreshUnread() {
        let counts = UnreadCounts.all()
        if counts != unread { unread = counts }
    }

    /// What to call an account in a list: the name it goes by, or its Matrix ID.
    static func name(of account: AccountRecord) -> String {
        guard let name = account.displayName, !name.isEmpty else { return account.userID }
        return name
    }
}

public extension EnvironmentValues {
    /// The account switcher, from the root. Nil in previews and wherever the root has put none up.
    @Entry var accountSwitcher: AccountSwitcher?
}

/// One account in a list: its face, its name, its Matrix ID, and how much is waiting in it.
struct AccountRow: View {
    let account: AccountRecord
    let unread: Int
    var isSigningOut = false

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Avatar(name: AccountSwitcher.name(of: account),
                   url: account.avatarURL,
                   size: Theme.Size.avatar,
                   seed: account.userID)
            VStack(alignment: .leading, spacing: Theme.Spacing.withinRun) {
                Text(verbatim: AccountSwitcher.name(of: account))
                    .foregroundStyle(.primary)
                Text(verbatim: account.userID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isSigningOut {
                ProgressView()
                    .controlSize(.small)
            } else if unread > 0 {
                Text(unread, format: .number)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(Strings.Accounts.unread(unread)))
            }
        }
        // The whole row is the button, not just the words and the face drawn on it: a `.plain`
        // button on a Mac takes clicks only where something is painted, and the spacer is not.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(Strings.Accounts.switchHint))
    }
}

/// The accounts, on a long press — of the face in the corner of the chat list on iPhone, and of the
/// gear in the sidebar on iPad and Mac. The same list settings shows, for the moment somebody wants
/// the other account now and not three taps from now.
private struct AccountMenu: ViewModifier {
    @Environment(\.accountSwitcher) private var switcher

    func body(content: Content) -> some View {
        if let switcher, switcher.isAvailable {
            content.contextMenu {
                ForEach(switcher.accounts) { account in
                    Button {
                        switcher.switchTo(account.sessionID)
                    } label: {
                        if account.sessionID == switcher.activeID {
                            Label {
                                Text(verbatim: AccountSwitcher.name(of: account))
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(verbatim: AccountSwitcher.name(of: account))
                        }
                    }
                }
                Divider()
                Button {
                    switcher.addAccount()
                } label: {
                    Label(String(app: Strings.Accounts.add), systemImage: "person.crop.circle.badge.plus")
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func accountMenu() -> some View {
        modifier(AccountMenu())
    }
}
