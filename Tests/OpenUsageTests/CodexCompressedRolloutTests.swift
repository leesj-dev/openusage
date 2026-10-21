import Foundation
import Testing
import libzstd
@testable import OpenUsage

struct CodexCompressedRolloutTests {
    private let now = OpenUsageISO8601.date(from: "2026-05-12T09:00:00Z")!

    private func rollout(input: Int = 100) -> String {
        [
            CodexLogFixture.turnContext(timestamp: "2026-05-12T08:00:00Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(timestamp: "2026-05-12T08:01:00Z",
                                       last: CodexLogFixture.usage(input: input, output: 20))
        ].joined(separator: "\n") + "\n"
    }

    private func compressed(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        var result = Data(count: ZSTD_compressBound(bytes.count))
        let size = result.withUnsafeMutableBytes { output in
            bytes.withUnsafeBytes { input in
                ZSTD_compress(output.baseAddress, output.count, input.baseAddress, input.count, 3)
            }
        }
        #expect(ZSTD_isError(size) == 0)
        result.count = size
        return result
    }

    private func writeArchive(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try compressed(text).write(to: url)
    }

    @Test(arguments: ["sessions", "archived_sessions"])
    func compressedOnlyFreshScan(directory: String) async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeArchive(rollout(), to: home.appendingPathComponent("\(directory)/rollout.jsonl.zst"))
        let result = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: TestPricing.bundled)
        #expect(result?.series.daily.first?.totalTokens == 120)
        #expect(result?.modelUsage?.daily.first?.models.map(\.model) == ["gpt-5.2"])
        #expect((result?.series.daily.first?.costUSD ?? 0) > 0)
    }

    @Test
    func discoveryOnlyOptsCodexIntoCompressedLogs() throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/active.jsonl": rollout()])
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try writeArchive(rollout(), to: dir.appendingPathComponent("older.jsonl.zst"))
        try Data().write(to: dir.appendingPathComponent("unrelated.zst"))
        #expect(JSONLScanning.jsonlFiles(under: dir).count == 1)
        #expect(JSONLScanning.jsonlFiles(under: dir, includeCompressed: true).count == 2)
    }

    @Test(arguments: [false, true])
    func activeCopyWinsAcrossFormats(compressedActive: Bool) async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let active = home.appendingPathComponent("sessions/rollout.jsonl")
        let archived = home.appendingPathComponent("archived_sessions/rollout.jsonl")
        try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        if compressedActive {
            try writeArchive(rollout(), to: active.appendingPathExtension("zst"))
            try rollout(input: 999).write(to: archived, atomically: true, encoding: .utf8)
        } else {
            try rollout().write(to: active, atomically: true, encoding: .utf8)
            try writeArchive(rollout(input: 999), to: archived.appendingPathExtension("zst"))
            try writeArchive(rollout(input: 888), to: active.appendingPathExtension("zst"))
        }
        let result = await CodexLogFixture.scanner(home: home).scan(now: now, pricing: TestPricing.bundled)
        #expect(result?.series.daily.first?.totalTokens == 120)
    }

    @Test
    func replacingPlainFileWithArchiveDoesNotLoseOrDoubleCountUsage() async throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/rollout.jsonl": rollout()])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexLogFixture.scanner(home: home)
        let before = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let plain = home.appendingPathComponent("sessions/rollout.jsonl")
        try writeArchive(rollout(), to: plain.appendingPathExtension("zst"))
        let overlapping = await scanner.scan(now: now, pricing: TestPricing.bundled)
        try FileManager.default.removeItem(at: plain)
        let after = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let warm = await scanner.scan(now: now, pricing: TestPricing.bundled)
        #expect(before?.series.daily.first?.totalTokens == 120)
        #expect(overlapping?.series.daily.first?.totalTokens == 120)
        #expect(after?.series.daily.first?.totalTokens == 120)
        #expect(warm?.series.daily.first?.totalTokens == 120)
    }

    @Test
    func streamingPreservesReplayModelTierAndDeltas() throws {
        let created = "2026-05-12T08:00:00Z"
        let epoch = Int(try #require(OpenUsageISO8601.date(from: created)).timeIntervalSince1970)
        let padding = String(repeating: "x", count: JSONLStreamingReader.readChunkBytes + 17)
        let text = [
            CodexLogFixture.subagentSessionMeta(timestamp: created),
            CodexLogFixture.tokenCount(timestamp: created, totals: CodexLogFixture.usage(input: 1_000, output: 200)),
            #"{"type":"response_item","payload":"\#(padding)"}"#,
            CodexLogFixture.turnContext(timestamp: created, model: "gpt-6-astra"),
            CodexLogFixture.threadSettingsApplied(timestamp: created, serviceTier: "priority"),
            CodexLogFixture.taskStarted(timestamp: created, startedAt: epoch),
            CodexLogFixture.tokenCount(timestamp: "2026-05-12T08:01:00Z",
                                       totals: CodexLogFixture.usage(input: 1_100, output: 220))
        ].joined(separator: "\n")
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let archive = home.appendingPathComponent("sessions/rollout.jsonl.zst")
        try writeArchive(text, to: archive)
        let parser = CodexLogUsageScanner.tailParser
        let streamed = try #require(try parser.read(archive.path, 0, nil, nil))
        #expect(streamed.items == CodexLogUsageScanner.parseFile(Data(text.utf8)))
        #expect(streamed.items?.map(\.input) == [100])
        #expect(streamed.items?.map(\.isFast) == [true])
        #expect(streamed.items?.map(\.model) == ["gpt-6-astra"])
    }

    @Test
    func concatenatedFramesAndArchiveReplacementNeverResumeCompressedOffsets() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let archive = home.appendingPathComponent("sessions/rollout.jsonl.zst")
        try writeArchive(rollout(), to: archive)
        let scanner = CodexLogFixture.scanner(home: home)
        let first = await scanner.scan(now: now, pricing: TestPricing.bundled)
        #expect(first?.series.daily.first?.totalTokens == 120)
        let extra = CodexLogFixture.tokenCount(timestamp: "2026-05-12T08:02:00Z",
                                               last: CodexLogFixture.usage(input: 30, output: 10)) + "\n"
        try (compressed(rollout()) + compressed(extra)).write(to: archive)
        let second = await scanner.scan(now: now, pricing: TestPricing.bundled)
        #expect(second?.series.daily.first?.totalTokens == 160)
        let file = try #require(JSONLScanning.jsonlFiles(under: home, includeCompressed: true).first)
        let parsed = JSONLTailIO.parse(request: JSONLParseRequest(file: file, resume: nil),
                                      strategy: .tail(CodexLogUsageScanner.tailParser))
        guard case .replaced(_, let offset, let state, let fingerprint) = parsed.outcome else {
            Issue.record("Expected a full archive parse")
            return
        }
        #expect(offset == nil && state == nil && fingerprint == nil)
    }

    @Test(arguments: ["empty", "invalid", "truncated"])
    func badArchivesFailWithoutCachingPartialUsage(kind: String) async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let archive = home.appendingPathComponent("sessions/rollout.jsonl.zst")
        var bytes = try compressed(rollout())
        switch kind {
        case "empty": bytes = Data()
        case "invalid": bytes = Data("not zstd".utf8)
        default: bytes.removeLast(3)
        }
        try bytes.write(to: archive)
        #expect(throws: (any Error).self) {
            _ = try CodexLogUsageScanner.tailParser.read(archive.path, 0, nil, nil)
        }
        let file = try #require(JSONLScanning.jsonlFiles(under: home, includeCompressed: true).first)
        let parsed = JSONLTailIO.parse(request: JSONLParseRequest(file: file, resume: nil),
                                      strategy: .tail(CodexLogUsageScanner.tailParser))
        guard case .unreadable = parsed.outcome else {
            Issue.record("Bad archives must be reported unreadable")
            return
        }
        let scanner = CodexLogFixture.scanner(home: home)
        _ = await scanner.scan(now: now, pricing: TestPricing.bundled)
        try writeArchive(rollout(), to: archive)
        let repaired = await scanner.scan(now: now, pricing: TestPricing.bundled)
        #expect(repaired?.series.daily.first?.totalTokens == 120)
    }

    @Test
    func compressedSharedHistoryBelongsOnlyToItsPhysicalHome() async throws {
        let owner = try CodexLogFixture.makeHome()
        let foreign = try CodexLogFixture.makeHome()
        defer {
            try? FileManager.default.removeItem(at: owner)
            try? FileManager.default.removeItem(at: foreign)
        }
        try writeArchive(rollout(), to: owner.appendingPathComponent("sessions/rollout.jsonl.zst"))
        try FileManager.default.removeItem(at: foreign.appendingPathComponent("sessions"))
        try FileManager.default.createSymbolicLink(at: foreign.appendingPathComponent("sessions"),
                                                  withDestinationURL: owner.appendingPathComponent("sessions"))
        let scanner = CodexLogFixture.scanner(home: owner)
        let owned = await scanner.scan(homes: CodexLogHomes(read: [owner], foreign: [foreign], cache: [owner, foreign]),
                                       now: now, pricing: TestPricing.bundled)
        let excluded = await scanner.scan(homes: CodexLogHomes(read: [foreign], foreign: [owner], cache: [owner, foreign]),
                                          now: now, pricing: TestPricing.bundled)
        #expect(owned?.series.daily.first?.totalTokens == 120)
        #expect(excluded == nil)
    }

    @Test
    func compressedEventsSurviveDiskCacheRelaunch() async throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeArchive(rollout(), to: home.appendingPathComponent("sessions/rollout.jsonl.zst"))
        let persistence = JSONLScanCachePersistence(namespace: "codex-test", schemaVersion: 1,
                                                   directory: home.appendingPathComponent("cache"))
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"), includeCompressed: true)
        let first = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let original = await first.items(from: files, since: .distantPast, tailParser: CodexLogUsageScanner.tailParser)
        await first.flushPendingWrites()
        let relaunched = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        // A failing parser proves this read uses the persisted parsed events.
        let neverRead = JSONLTailParser<CodexLogUsageScanner.Event>(read: { _, _, _, _ in
            Issue.record("Unchanged archive should be loaded from disk cache")
            return nil
        })
        let cached = await relaunched.items(from: files, since: .distantPast, tailParser: neverRead)
        #expect(original?.count == 1)
        #expect(cached == original)
    }

    @Test
    func oversizedRecordsStayBoundedAfterDecompression() throws {
        let home = try CodexLogFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let archive = home.appendingPathComponent("sessions/rollout.jsonl.zst")
        let oversized = String(repeating: "x", count: JSONLStreamingReader.maximumRecordBytes + 1) + "\n"
        try writeArchive(oversized + rollout(), to: archive)
        let parsed = try #require(try CodexLogUsageScanner.tailParser.read(archive.path, 0, nil, nil))
        #expect(parsed.oversizedRecordCount == 1)
        #expect(parsed.items?.map(\.input) == [100])
        #expect(parsed.endsAtLineBoundary)
    }
}
