import AppKit
import Foundation
import Darwin

/// A short-lived app-server used only for interactive login. It stops before the provider owns token
/// refresh. Both stdout and stderr are private: OAuth URLs and protocol errors may contain secrets.
@MainActor
final class CodexLoginSession {
    enum Event: Equatable {
        case initialized, authorize(URL), completed, failed, ignore
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var timeout: Task<Void, Never>?
    private var killTask: Task<Void, Never>?
    private var outcome: Result<Void, CodexConnectionError>?
    private var completion: ((Result<Void, CodexConnectionError>) -> Void)?
    private let openBrowser: (URL) -> Bool

    init(openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openBrowser = openBrowser
    }

    static func desktopExecutable() -> URL? {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let candidates = [app, URL(fileURLWithPath: "/Applications/Codex.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app")]
        return candidates.compactMap { $0?.appendingPathComponent("Contents/Resources/codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start(executable: URL, home: URL, completion: @escaping (Result<Void, CodexConnectionError>) -> Void) {
        self.completion = completion
        process.executableURL = executable
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"] { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.exited() }
        }
        do {
            // A helper exiting between startup and a write must report EPIPE, not terminate the app.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw CodexConnectionError.loginFailed
            }
            try process.run()
            try send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "openusage", "version": "1.0.0"]
            ]])
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.finish(.failure(.timedOut))
            }
        } catch {
            finish(.failure(.loginFailed))
        }
    }

    func cancel() {
        if outcome != nil {
            // A successful notification can precede process teardown. Cancel still wins until the
            // completion callback publishes credentials to the store.
            outcome = .failure(.cancelled)
        } else {
            finish(.failure(.cancelled))
        }
    }

    private func receive(_ data: Data) {
        guard outcome == nil, !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { finish(.failure(.invalidResponse)); return }
        while let newline = buffer.firstIndex(of: 10), outcome == nil {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            do {
                switch try Self.event(from: line) {
                case .initialized:
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/login/start", "params": ["type": "chatgpt"]])
                case .authorize(let url):
                    if !openBrowser(url) { finish(.failure(.browserFailed)) }
                case .completed: finish(.success(()))
                case .failed: finish(.failure(.loginFailed))
                case .ignore: break
                }
            } catch { finish(.failure(.invalidResponse)) }
        }
    }

    /// Parse only the login surface, never exposing raw protocol bodies to UI or logs.
    static func event(from data: Data) throws -> Event {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexConnectionError.invalidResponse
        }
        if message["error"] != nil { return .failed }
        if let id = message["id"] as? Int {
            if id == 1, message["result"] is [String: Any] { return .initialized }
            if id == 2 {
                guard let result = message["result"] as? [String: Any],
                      let raw = result["authUrl"] as? String, let url = URL(string: raw),
                      url.scheme == "https", let host = url.host,
                      ["auth.openai.com", "chatgpt.com"].contains(host),
                      url.user == nil, url.password == nil else { throw CodexConnectionError.invalidResponse }
                return .authorize(url)
            }
        }
        if message["method"] as? String == "account/login/completed" {
            let params = message["params"] as? [String: Any]
            return params?["success"] as? Bool == true ? .completed : .failed
        }
        return .ignore
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func finish(_ result: Result<Void, CodexConnectionError>) {
        guard outcome == nil else { return }
        outcome = result
        timeout?.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            killTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.process.isRunning else { return }
                kill(self.process.processIdentifier, SIGKILL)
            }
        } else { exited() }
    }

    private func exited() {
        output.fileHandleForReading.readabilityHandler = nil
        timeout?.cancel()
        killTask?.cancel()
        let callback = completion
        completion = nil
        callback?(outcome ?? .failure(.loginFailed))
    }
}
