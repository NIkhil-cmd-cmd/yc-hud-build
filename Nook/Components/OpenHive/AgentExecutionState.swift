//
//  AgentExecutionState.swift
//  OpenHive — Comet-style agent run feedback for in-page overlay
//

import Foundation

@MainActor
@Observable
final class AgentExecutionState {
    static let shared = AgentExecutionState()

    var isActive = false
    var isPaused = false
    var actionLabel: String?
    var currentTier: Int = 1
    var highlightRect: CGRect?

    private init() {}

    func begin(label: String? = nil, tier: Int = 3) {
        isActive = true
        isPaused = false
        actionLabel = label
        currentTier = tier
    }

    func update(label: String?, tier: Int? = nil, highlight: CGRect? = nil) {
        if let label { actionLabel = label }
        if let tier { currentTier = tier }
        if let highlight { highlightRect = highlight }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func end() {
        isActive = false
        isPaused = false
        actionLabel = nil
        highlightRect = nil
    }
}
