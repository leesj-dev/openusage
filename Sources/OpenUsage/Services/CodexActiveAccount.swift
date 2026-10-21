import Foundation

/// Reads only the default login, never a saved sibling, Swap slot, or OpenUsage connection.
struct CodexActiveAccount: Sendable {
    var authStore = CodexAuthStore()

    func identity() async -> CodexAccountIdentity? {
        let fileIdentity = await loadOffMainActor { [authStore] in
            authStore.loadAuthCandidates().first(where: \.hasUsableAccessToken)
                .flatMap { CodexAccountIdentity(auth: $0.auth) }
        }
        if let fileIdentity { return fileIdentity }
        return await loadOffMainActor { [authStore] in
            authStore.loadKeychainAuth().flatMap { CodexAccountIdentity(auth: $0.auth) }
        }
    }
}
