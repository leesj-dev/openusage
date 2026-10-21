import SwiftUI

struct CodexAccountsSettingsSection: View {
    @Bindable var connections: CodexConnectionStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var disconnecting: CodexConnectedAccounts.Account?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Codex Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                Text("Connect accounts to keep their limits visible when you switch accounts in Codex Desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                ForEach(connections.accounts) { account in
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.identity.email ?? "Codex Account")
                            .font(.subheadline.weight(.medium))
                            .textSelection(.enabled)
                        Text("Workspace \(account.identity.accountID.prefix(8))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Reconnect") { connections.connect(replacing: account) }
                            Spacer()
                            Button("Disconnect", role: .destructive) { disconnecting = account }
                        }
                        .disabled(connections.isConnecting)
                    }
                    .padding(12)
                }
                Divider()
                if connections.isConnecting {
                    HStack(spacing: 8) {
                        MotionAwareProgressView(controlSize: .small)
                        Text("Finish Sign-In in Your Browser")
                            .font(.caption)
                        Spacer(minLength: 0)
                        Button("Cancel") { connections.cancel() }
                    }
                    .padding(12)
                } else {
                    Button { connections.connect() } label: {
                        Label("Add Codex Account…", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(12)
                }
                if let error = connections.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                        .padding([.horizontal, .bottom], 12)
                }
                if connections.restartRequired {
                    Text("Restart OpenUsage to apply account changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    Button("Restart OpenUsage") { connections.restart() }
                        .disabled(connections.isConnecting)
                        .padding(12)
                }
            }
            .cardSurface()
        }
        .alert("Disconnect Codex Account?", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }
        )) {
            Button("Cancel", role: .cancel) { disconnecting = nil }
            Button("Disconnect", role: .destructive) {
                if let account = disconnecting { connections.disconnect(account) }
                disconnecting = nil
            }
        } message: {
            Text("This removes OpenUsage's saved connection. Your Codex Desktop login stays unchanged.")
        }
    }
}
