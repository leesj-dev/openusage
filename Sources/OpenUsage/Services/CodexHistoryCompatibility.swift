import Foundation

enum CodexHistoryCompatibility {
    private static let labels: Set<String> = ["Today", "Yesterday", "Last 30 Days", "Usage Trend"]

    static func cachedSnapshot(_ snapshot: ProviderSnapshot, ownsHistory: Bool, staleIdentity: Bool) -> ProviderSnapshot {
        guard ProviderAccountID.family(of: snapshot.providerID) == "codex" else { return snapshot }
        var result = snapshot
        if !ownsHistory {
            result.usageHistory = nil
            result.lines.removeAll { labels.contains($0.label) }
        } else if snapshot.providerID == "codex", staleIdentity, snapshot.usageHistory != nil {
            // Local history survives identity upgrades; the previous login's limits and plan do not.
            result.plan = nil
            result.lines.removeAll { !labels.contains($0.label) }
        }
        return result
    }
}
