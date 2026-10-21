import XCTest
@testable import OpenUsage

@MainActor
final class CodexPresentationTests: XCTestCase {
    func testCombinedHistoryCountsCopiedRolloutsAcrossHomesOnce() async throws {
        let timestamp = "2026-10-21T10:00:00Z"
        let rollout = [
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.2"),
            CodexLogFixture.tokenCount(timestamp: timestamp, last: CodexLogFixture.usage(input: 100, output: 50))
        ].joined(separator: "\n")
        let first = try CodexLogFixture.makeHome(files: ["sessions/first.jsonl": rollout])
        let second = try CodexLogFixture.makeHome(files: ["sessions/copied.jsonl": rollout])
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let scanner = CodexLogUsageScanner(
            environment: FakeEnvironment(["CODEX_HOME": first.path]),
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
            additionalHomes: [second.path]
        )
        let provider = CodexProvider.isolated(logUsageScanner: scanner,
                                             now: { OpenUsageISO8601.date(from: "2026-10-21T11:00:00Z")! })
        let snapshot = await provider.snapshot(mapped: CodexMappedUsage(plan: "Pro", lines: []))
        let history = try XCTUnwrap(snapshot.usageHistory)
        XCTAssertEqual(history.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        let total = TotalSpendAggregator.total(for: .today, providers: [provider.provider], snapshots: ["codex": snapshot])
        XCTAssertEqual(total.slices.map(\.provider.displayName), ["Codex"])
        XCTAssertEqual(total.totalTokens, 150)
    }

    func testCurrentLoginMovesAboveOtherCodexCardsWithoutChangingSavedOrder() {
        let store = makeLayout()
        let saved = store.orderedProviderIDs()
        store.activeCodexProviderID = "codex@other"
        XCTAssertEqual(store.displayGroups.map(\.provider.id), ["claude", "codex@other", "codex", "cursor"])
        XCTAssertEqual(store.orderedProviderIDs(), saved)
        store.activeCodexProviderID = "codex"
        XCTAssertEqual(store.displayGroups.map(\.provider.id), saved)
    }

    func testExistingPinsFollowCurrentLoginAndNeverShowBothAccounts() {
        let store = makeLayout()
        store.setPinned(true, for: "codex.session")
        store.setPinned(true, for: "codex.weekly")
        store.setPinned(true, for: "codex@other.session")
        store.activeCodexProviderID = "codex@other"
        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["codex@other"])
        XCTAssertEqual(store.pinnedGroups.flatMap { $0.metrics.map(\.id) },
                       ["codex@other.session", "codex@other.weekly"])
        store.activeCodexProviderID = "codex"
        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["codex"])
        XCTAssertTrue(store.isPinned("codex@other.session"))
        store.activeCodexProviderID = nil
        XCTAssertTrue(store.pinnedGroups.isEmpty)
    }

    func testSecondaryAccountDoesNotScanOrPublishLocalHistory() async {
        let provider = CodexProvider(
            provider: CodexProvider.makeProvider(id: "codex@other"), includesLocalHistory: false,
            pricing: {
                XCTFail("Quota-only cards must not scan history")
                return ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [:]), secondary: PricingCatalog(entries: [:]))
            }
        )
        let mapped = CodexMappedUsage(plan: "Pro", lines: [.progress(label: "Session", used: 12, limit: 100, format: .percent)])
        let snapshot = await provider.snapshot(mapped: mapped)
        XCTAssertEqual(snapshot.lines, mapped.lines)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.warning)
        XCTAssertFalse(provider.widgetDescriptors.contains(where: \.isSpendTile))
    }

    func testActiveAccountReadsDefaultHomeInsteadOfSavedAccount() async {
        let files = FakeFiles([
            "/test/default/auth.json": CodexMultiAccountFixtures.codexAuth(accountID: "B", email: "b@test")
        ])
        let reader = CodexActiveAccount(authStore: CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/test/default"]), files: files,
            keychain: FakeKeychain()
        ))
        let identity = await reader.identity()
        XCTAssertEqual(identity?.key, "b|b@test")
    }

    func testLegacyHistorySurvivesIdentityUpgradeAndSecondaryCachedSpendIsDiscarded() {
        let defaults = makeScratchDefaults()
        let primary = CodexProvider.isolated()
        let secondary = CodexProvider(provider: CodexProvider.makeProvider(id: "codex@other"), includesLocalHistory: false)
        let registry = WidgetRegistry.from([primary, secondary])
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        for id in ["codex", "codex@other"] {
            cache.store(ProviderSnapshot(providerID: id, displayName: id, plan: "Old Plan", lines: [
                .progress(label: "Session", used: 99, limit: 100, format: .percent),
                .values(label: "Today", values: [.init(number: 20, kind: .dollars)])
            ], usageHistory: history))
        }
        let store = WidgetDataStore(registry: registry, providers: [primary, secondary], cache: cache,
                                    defaults: defaults, providerIdentityKeys: ["codex": "new|user@test"])
        XCTAssertNotNil(store.snapshots["codex"]?.usageHistory)
        XCTAssertNotNil(store.snapshots["codex"]?.line(label: "Today"))
        XCTAssertNil(store.snapshots["codex"]?.line(label: "Session"))
        XCTAssertNil(store.snapshots["codex"]?.plan)
        XCTAssertNil(store.snapshots["codex@other"]?.usageHistory)
        XCTAssertNil(store.snapshots["codex@other"]?.line(label: "Today"))
        XCTAssertNotNil(store.snapshots["codex@other"]?.line(label: "Session"))
        let document = store.localHistoryDocument(deviceID: "test", deviceName: "Test")
        XCTAssertEqual(Set(document.providers.keys), ["codex"])
        XCTAssertNil(document.identities?["codex"])
    }

    private func makeLayout() -> LayoutStore {
        let providers = ["claude", "codex", "codex@other", "cursor"].map {
            Provider(id: $0, displayName: $0, icon: .providerMark("codex"))
        }
        let descriptors = providers.flatMap { provider in
            ["session", "weekly"].map { WidgetDescriptor.percent(id: "\(provider.id).\($0)", provider: provider, title: $0) }
        }
        let registry = WidgetRegistry(providers: providers, descriptors: descriptors)
        let store = LayoutStore(registry: registry, defaults: makeScratchDefaults(),
                                defaultMetricIDs: descriptors.map(\.id), defaultPinnedMetricIDs: [], defaultExpandedMetricIDs: [])
        store.codexAccountIDs = ["codex", "codex@other"]
        return store
    }
}
