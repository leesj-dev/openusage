import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CodexConnectionStore {
    private(set) var accounts: [CodexConnectedAccounts.Account] = []
    private(set) var isConnecting = false
    private(set) var restartRequired = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var session: CodexLoginSession?
    private let repository: CodexConnectedAccounts

    init(repository: CodexConnectedAccounts = CodexConnectedAccounts()) {
        self.repository = repository
        reload()
    }

    func connect(replacing account: CodexConnectedAccounts.Account? = nil) {
        guard !isConnecting else { return }
        errorMessage = nil
        guard let executable = CodexLoginSession.desktopExecutable() else {
            report(CodexConnectionError.missingDesktop)
            return
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-login-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { report(error); return }
        let login = CodexLoginSession()
        session = login
        isConnecting = true
        login.start(executable: executable, home: temporary) { [weak self] result in
            defer {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { AppLog.error(.config, "Codex sign-in: temporary credential cleanup failed") }
            }
            guard let self else { return }
            self.session = nil
            self.isConnecting = false
            do {
                try result.get()
                let authText = try String(contentsOf: temporary.appendingPathComponent("auth.json"), encoding: .utf8)
                try self.repository.save(authText: authText, replacing: account)
                self.restartRequired = true
                self.reload()
                AppLog.info(.config, "Codex account connection saved; restart required")
            } catch CodexConnectionError.cancelled {
                // Cancellation is a user action, not a failure.
            } catch { self.report(error) }
        }
    }

    func cancel() { session?.cancel() }

    func disconnect(_ account: CodexConnectedAccounts.Account) {
        guard !isConnecting else { return }
        do {
            try repository.remove(account)
            restartRequired = true
            errorMessage = nil
            reload()
            AppLog.info(.config, "Codex account connection removed; restart required")
        } catch { report(error) }
    }

    func restart() {
        guard !isConnecting else { return }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            errorMessage = "Quit and reopen OpenUsage to apply account changes."
            return
        }
        // Wait for this process (and its instance lock) to exit before opening the same app bundle.
        // Positional arguments keep paths out of shell source. No credentials enter this helper.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"",
                            "openusage-restart", String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch { report(error) }
    }

    private func reload() {
        do { accounts = try repository.accounts() }
        catch { report(error) }
    }

    private func report(_ error: Error) {
        // File/process errors can contain sensitive paths; only known, curated errors reach the UI.
        errorMessage = (error as? CodexConnectionError)?.errorDescription
            ?? "OpenUsage couldn't update the Codex connection. Check file access and try again."
        AppLog.error(.config, "Codex account connection failed: \(error is CodexConnectionError ? error.localizedDescription : "local storage or process error")")
    }
}
