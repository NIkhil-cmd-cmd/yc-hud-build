//
//  TokenDashboardManager.swift
//  OpenHive (forked from Nook)
//
//  Measured token usage — session, tier breakdown, recent runs.
//

import Foundation
import OSLog

@MainActor
@Observable
final class TokenDashboardManager {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenHive",
        category: "TokenDashboard"
    )

    static let shared = TokenDashboardManager()

    var sessionTotal = 0
    var todayTotal = 0
    var allTimeTotal = 0
    var byTier: [Int: Int] = [1: 0, 2: 0, 3: 0]
    var recentRuns: [RunMetric] = []

    /// Live metrics during workflow execution (sidebar strip).
    var currentRunTokens = 0
    var currentRunElapsedMs = 0
    var currentRunTier = 1
    var currentRunReward: Double?

    struct RunMetric: Identifiable, Equatable {
        let id = UUID()
        var workflowName: String
        var runType: String
        var tokens: Int
        var elapsedMs: Int
        var tierLog: [Int]
    }

    private init() {}

    func refresh() {
        EngineBridge.shared.requestTokenMetrics()
    }

    func update(from json: [String: Any]) {
        sessionTotal = json["sessionTotal"] as? Int ?? 0
        todayTotal = json["todayTotal"] as? Int ?? 0
        allTimeTotal = json["allTimeTotal"] as? Int ?? 0

        if let tierMap = json["byTier"] as? [String: Int] {
            byTier = Dictionary(
                uniqueKeysWithValues: tierMap.compactMap { key, value in
                    guard let k = Int(key) else { return nil }
                    return (k, value)
                }
            )
        }

        if let runs = json["recentRuns"] as? [[String: Any]] {
            recentRuns = runs.compactMap { r in
                RunMetric(
                    workflowName: r["workflowName"] as? String ?? "Unknown",
                    runType: r["runType"] as? String ?? "execute",
                    tokens: r["tokens"] as? Int ?? 0,
                    elapsedMs: r["elapsedMs"] as? Int ?? 0,
                    tierLog: r["tierLog"] as? [Int] ?? []
                )
            }
        }
    }

    func updateLiveRun(tokens: Int, elapsedMs: Int, tier: Int, reward: Double? = nil) {
        currentRunTokens = tokens
        currentRunElapsedMs = elapsedMs
        currentRunTier = tier
        if let reward { currentRunReward = reward }
    }

    func clearLiveRun() {
        currentRunTokens = 0
        currentRunElapsedMs = 0
        currentRunTier = 1
        currentRunReward = nil
    }
}
