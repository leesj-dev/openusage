import Foundation
import Testing
@testable import OpenUsage

@Suite @MainActor
struct CodexConnectedAccountsTests {
    private func withRepository(_ test: (CodexConnectedAccounts, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try test(CodexConnectedAccounts(homeDirectory: home), home)
    }

    private func auth(_ workspace: String, email: String = "person@test") throws -> String {
        let claims: [String: Any] = ["email": email, "https://api.openai.com/auth": ["chatgpt_account_id": workspace]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).test-signature"
        return String(decoding: try JSONEncoder().encode(CodexAuth(tokens: CodexTokens(
            accessToken: token, refreshToken: "test-refresh", idToken: token, accountID: workspace
        ))), as: UTF8.self)
    }

    @Test func independentConnectionsUsePrivateFilesAndDeduplicateAccounts() throws {
        try withRepository { repository, _ in
            let first = try repository.save(authText: auth("A"))
            let second = try repository.save(authText: auth("B"))
            #expect(first.id != second.id)
            #expect(try repository.accounts().count == 2)
            let renewed = try repository.save(authText: auth("A"))
            #expect(renewed.id == first.id)
            for account in try repository.accounts() {
                let file = try FileManager.default.attributesOfItem(atPath: account.home.appendingPathComponent("auth.json").path)
                #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                let directory = try FileManager.default.attributesOfItem(atPath: account.home.path)
                #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            }
            try repository.remove(first)
            #expect(try repository.accounts().map(\.id) == [second.id])
        }
    }

    @Test func reconnectRejectsAnotherIdentityBeforeChangingSavedAuth() throws {
        try withRepository { repository, _ in
            let original = try auth("A")
            let account = try repository.save(authText: original)
            #expect(throws: CodexConnectionError.self) {
                try repository.save(authText: auth("B"), replacing: account)
            }
            #expect(try String(contentsOf: account.home.appendingPathComponent("auth.json"), encoding: .utf8) == original)
            #expect(try repository.accounts().count == 1)
        }
    }

    @Test func invalidCredentialsNeverCreateAConnection() throws {
        try withRepository { repository, _ in
            for text in ["{}", #"{"OPENAI_API_KEY":"test"}"#, #"{"tokens":{"access_token":"test"}}"#] {
                #expect(throws: CodexConnectionError.self) { try repository.save(authText: text) }
            }
            let accounts = try repository.accounts()
            #expect(accounts.isEmpty)
        }
    }

    private struct EmptyEnvironment: EnvironmentReading {
        func value(for name: String) -> String? { nil }
    }

    @Test func connectionsStayDiscoverableAfterDesktopLoginIsRemoved() throws {
        try withRepository { repository, home in
            let connected = try repository.save(authText: auth("B"))
            let desktop = home.appendingPathComponent(".codex/auth.json")
            try LocalTextFileAccessor().writeText(desktop.path, auth("A"))
            let scanner = CodexHomeScanner(environment: EmptyEnvironment(), files: LocalTextFileAccessor(),
                homeDirectory: { home })
            #expect(Set(scanner.logins().map(\.identity.accountID)) == ["a", "b"])
            try FileManager.default.removeItem(at: desktop)
            #expect(scanner.logins().map(\.identity) == [connected.identity])
        }
    }

    @Test func loginProtocolAcceptsOfficialFlowAndRejectsUntrustedURLs() throws {
        func event(_ text: String) throws -> CodexLoginSession.Event {
            try CodexLoginSession.event(from: Data(text.utf8))
        }
        #expect(try event(#"{"id":1,"result":{}}"#) == .initialized)
        #expect(try event(#"{"id":2,"result":{"authUrl":"https://auth.openai.com/oauth/authorize"}}"#)
            == .authorize(URL(string: "https://auth.openai.com/oauth/authorize")!))
        for url in ["http://auth.openai.com/test", "https://example.com", "https://auth.openai.com.evil.test"] {
            let data = try JSONSerialization.data(withJSONObject: ["id": 2, "result": ["authUrl": url]])
            #expect(throws: CodexConnectionError.self) { try CodexLoginSession.event(from: data) }
        }
        #expect(try event(#"{"method":"account/login/completed","params":{"success":true}}"#) == .completed)
        #expect(try event(#"{"method":"account/login/completed","params":{"success":false,"error":"private"}}"#) == .failed)
        #expect(try event(#"{"id":2,"error":{"message":"private"}}"#) == .failed)
    }

    @Test(arguments: [true, false])
    func helperCompletesHandshakeAndHandlesBrowserFailure(browserOpens: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r initialized
        read -r request
        printf '%s\\n' '{"id":2,"result":{"authUrl":"https://auth.openai.com/oauth/authorize"}}'
        printf '%s\\n' '{"method":"account/login/completed","params":{"success":true}}'
        while read -r request; do :; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var openedBrowser = false
        let session = CodexLoginSession(openBrowser: { _ in openedBrowser = true; return browserOpens })
        let result: Result<Void, CodexConnectionError> = await withCheckedContinuation { continuation in
            session.start(executable: script, home: home) { continuation.resume(returning: $0) }
        }
        #expect(openedBrowser)
        if browserOpens { try result.get() }
        else {
            guard case .failure(let error) = result else { Issue.record("Expected browser failure"); return }
            #expect(error == .browserFailed)
        }
        withExtendedLifetime(session) {}
    }

    @Test func cancellingLoginDoesNotReturnSuccess() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r initialized
        read -r request
        printf '%s\\n' '{"id":2,"result":{"authUrl":"https://auth.openai.com/oauth/authorize"}}'
        while read -r request; do :; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var session: CodexLoginSession?
        session = CodexLoginSession(openBrowser: { _ in
            Task { @MainActor in session?.cancel() }
            return true
        })
        let result: Result<Void, CodexConnectionError> = await withCheckedContinuation { continuation in
            session?.start(executable: script, home: home) { continuation.resume(returning: $0) }
        }
        guard case .failure(let error) = result else { Issue.record("Cancelled login returned success"); return }
        #expect(error == .cancelled)
        session = nil
    }
}
