import SwiftUI

/// Owns the Accounts window. A `Window` scene in the app body would open
/// at launch as the app's main window (SwiftUI opens the first window
/// scene), which an `LSUIElement` menu bar app must not do.
@MainActor
final class AccountsWindowController {
    static let shared = AccountsWindowController()
    private var window: NSWindow?

    func show(store: UsageStore) {
        if window == nil {
            let host = NSHostingController(rootView: AccountsView(store: store))
            let window = NSWindow(contentViewController: host)
            window.title = "Accounts"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 680))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AccountsView: View {
    let store: UsageStore
    @State private var name = ""
    @State private var confirmation: AccountConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Accounts").font(.title2.bold())
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
            }
            Text("Claude accounts that Meridian can route to. Use an account to make Meridian send new requests through it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            operationStatus
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.accounts.isEmpty {
                        Text("No accounts found.").foregroundStyle(.secondary)
                    }
                    ForEach(store.accounts) { account in
                        accountRow(account)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Add an account").font(.headline)
                HStack {
                    TextField("Account name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Add and sign in") {
                        store.addAccount(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(!store.canManageAccounts)
                Text("Use letters, numbers, hyphens, or underscores. Choose the intended account in the browser before completing sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 500)
        .task { await store.refresh() }
        .alert(item: $confirmation) { action in
            Alert(
                title: Text(action.remove ? "Remove \(action.account.name)?" : "Sign out of \(action.account.name)?"),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.remove ? "Remove" : "Sign out")) {
                    if action.remove { store.removeAccount(action.account) }
                    else { store.logoutAccount(action.account) }
                },
                secondaryButton: .cancel())
        }
    }

    @ViewBuilder private var operationStatus: some View {
        if let operation = store.accountOperation {
            HStack {
                ProgressView().controlSize(.small)
                Text(operation).font(.callout)
                Spacer()
                Button("Cancel") { store.cancelAccountOperation() }
            }
        }
        if let error = store.accountError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if let notice = store.accountNotice {
            Text(notice).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.name).font(.headline)
                if account.isActive { Badge(text: "ACTIVE", color: .blue) }
                if !account.isLoggedIn { Badge(text: "SIGN-IN REQUIRED", color: .orange) }
                Spacer()
            }
            if let email = account.email {
                Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if !account.isActive {
                    Button("Use account") { store.activateAccount(account) }
                        .disabled(!account.isLoggedIn)
                }
                if account.supportsLogin {
                    Button(account.isLoggedIn ? "Sign in again" : "Sign in") {
                        store.loginAccount(account)
                    }
                    if account.isLoggedIn {
                        Button("Sign out") {
                            confirmation = AccountConfirmation(account: account, remove: false)
                        }
                    }
                }
                Spacer()
                if account.canRemove {
                    Button("Remove", role: .destructive) {
                        confirmation = AccountConfirmation(account: account, remove: true)
                    }
                }
            }
            .controlSize(.small)
            .disabled(!store.canManageAccounts)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AccountConfirmation: Identifiable {
    let account: ManagedAccount
    let remove: Bool
    var id: String { account.id + (remove ? ":remove" : ":logout") }

    var message: String {
        remove
            ? "This removes the Meridian profile and its local profile directory. Other profiles are unchanged."
            : "This signs out the selected account. Running CLI sessions may keep their current login until restarted."
    }
}
