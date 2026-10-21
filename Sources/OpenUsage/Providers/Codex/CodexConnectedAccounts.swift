import Foundation

/// OpenUsage-owned OAuth sessions, separate from Desktop's default login. No tokens in defaults.
struct CodexConnectedAccounts: Sendable {
    struct Account: Identifiable, Equatable, Sendable {
        let id: UUID
        let identity: CodexAccountIdentity
        let home: URL
    }

    let root: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        root = Self.root(homeDirectory: homeDirectory)
    }

    static func root(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/OpenUsage/CodexAccounts", isDirectory: true)
    }

    func accounts() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { home in
                guard let id = UUID(uuidString: home.lastPathComponent),
                      try home.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return nil }
                guard let identity = try CodexHomeScanner.signedInIdentity(home: home.path, files: LocalTextFileAccessor())
                else { throw CodexConnectionError.invalidLogin }
                return Account(id: id, identity: identity, home: home)
            }
    }

    /// Validate before replacing an existing connection. A fresh login has its own refresh token;
    /// copying Desktop's rotating token would race with Desktop and is deliberately unsupported.
    @discardableResult
    func save(authText: String, replacing account: Account? = nil) throws -> Account {
        guard let auth = CodexAuthStore.parseAuth(authText),
              auth.tokens?.accessToken?.nilIfEmpty != nil,
              auth.tokens?.refreshToken?.nilIfEmpty != nil,
              let identity = CodexAccountIdentity(auth: auth), !identity.accountID.isEmpty
        else { throw CodexConnectionError.invalidLogin }
        if let account, account.identity != identity { throw CodexConnectionError.wrongAccount }
        let existing = try accounts().first { $0.identity == identity }
        let id = account?.id ?? existing?.id ?? UUID()
        let home = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if account != nil || existing != nil {
            try LocalTextFileAccessor().writeText(home.appendingPathComponent("auth.json").path, authText)
        } else {
            // Publish a complete home at once: a failed save must not leave a discoverable partial login.
            let staging = root.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer {
                if FileManager.default.fileExists(atPath: staging.path) {
                    do { try FileManager.default.removeItem(at: staging) }
                    catch { AppLog.error(.config, "Codex connection staging cleanup failed") }
                }
            }
            try LocalTextFileAccessor().writeText(staging.appendingPathComponent("auth.json").path, authText)
            try FileManager.default.moveItem(at: staging, to: home)
        }
        return Account(id: id, identity: identity, home: home)
    }

    func remove(_ account: Account) throws {
        // Reconstruct the path from the identifier; never delete a path supplied by credential data.
        try FileManager.default.removeItem(at: root.appendingPathComponent(account.id.uuidString))
    }
}

enum CodexConnectionError: Error, LocalizedError, Equatable {
    case missingDesktop, invalidLogin, wrongAccount, loginFailed, timedOut, invalidResponse, browserFailed, cancelled

    var errorDescription: String? {
        switch self {
        case .missingDesktop: "Codex Desktop couldn't be found. Install Codex Desktop and try again."
        case .invalidLogin: "The login didn't provide a usable Codex account. Please try again."
        case .wrongAccount: "You signed in to a different account. The existing connection hasn't changed."
        case .loginFailed: "Codex couldn't complete sign-in. Please try again."
        case .timedOut: "Sign-in timed out. Please try again."
        case .invalidResponse: "Codex returned an unexpected sign-in response. Update Codex Desktop and try again."
        case .browserFailed: "The sign-in page couldn't be opened. Please try again."
        case .cancelled: "Sign-in was cancelled."
        }
    }
}
