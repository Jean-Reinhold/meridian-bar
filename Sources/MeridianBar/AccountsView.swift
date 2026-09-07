import SwiftUI

struct AccountsView: View {
    let store: UsageStore
    @State private var provider = AccountProvider.codex
    @State private var name = ""
    @State private var confirmation: AccountConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Accounts").font(.title2.bold())
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
            }
            Text("Claude switches Meridian routing. Codex switches the login for new local Codex sessions and, when enabled below, joins OMP's OpenAI account pool.")
                .font(.callout)
                .foregroundStyle(.secondary)
            operationStatus
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(AccountProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(provider.title).font(.headline)
                            let accounts = store.accounts.filter { $0.provider == provider }
                            if accounts.isEmpty {
                                Text("No accounts found.").foregroundStyle(.secondary)
                            }
                            ForEach(accounts) { account in
                                accountRow(account)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
            Divider()
            ompSection
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Add an account").font(.headline)
                HStack {
                    Picker("Provider", selection: $provider) {
                        ForEach(AccountProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    TextField("Account name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Add and sign in") {
                        store.addAccount(provider: provider, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// OMP load-balances GPT requests across every `openai-codex` credential
    /// it holds; this keeps that pool equal to the Codex accounts saved here.
    private var ompSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(
                    "Route OMP's GPT requests through these Codex accounts",
                    isOn: Binding(get: { store.ompSyncEnabled }, set: { store.ompSyncEnabled = $0 })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Button("Sync now") { store.syncOMPNow() }
                    .controlSize(.small)
                    .disabled(!store.canManageAccounts || !store.ompSyncEnabled || !store.omp.isManageable)
            }
            .disabled(!store.canManageAccounts)
            Text(ompStatusText)
                .font(.caption)
                .foregroundStyle(store.omp.error == nil ? Color.secondary : Color.orange)
            Text("Each account is copied into OMP once; OMP refreshes its copy on its own. Removing or signing out an account here also drops it from OMP.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ompStatusText: String {
        if let error = store.omp.error { return error.errorDescription ?? "OMP is unavailable." }
        let pooled = store.omp.entries.count
        let routed = store.accounts.filter { $0.provider == .codex && store.isRoutedInOMP($0) }.count
        if pooled == 0 { return "OMP has no OpenAI accounts yet." }
        let unmanaged = pooled - routed
        var text = "OMP routes through \(pooled) OpenAI account\(pooled == 1 ? "" : "s"), \(routed) managed here."
        if unmanaged > 0 { text += " \(unmanaged) added elsewhere (omp auth-broker login)." }
        return text
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.name).font(.headline)
                if account.isActive { Badge(text: "ACTIVE", color: .blue) }
                if store.isRoutedInOMP(account) { Badge(text: "OMP", color: .purple) }
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
        if remove {
            return account.provider == .claude
                ? "This removes the Meridian profile and its local profile directory. Other profiles are unchanged."
                : "This removes the saved Codex account. Removing the active account also signs it out. Other accounts and session history are unchanged."
        }
        return "This signs out the selected account. Running CLI sessions may keep their current login until restarted."
    }
}
