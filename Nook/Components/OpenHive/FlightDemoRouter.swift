//
//  FlightDemoRouter.swift
//  OpenHive — hardcoded flight demo (learn once → fast MDP replay)
//

import Foundation

enum FlightDemoMode: String, Equatable {
    case none
    case learning
    case replay
}

enum FlightDemoRouter {
    static let skillId = "demo_flight_bos_sfo"
    static let skillName = "Book flight BOS to SFO"
    static let origin = "BOS"
    static let destination = "SFO"
    static let departDate = "2026-07-15"
    static let startURL = "https://www.google.com/travel/flights"

    static func isFlightPrompt(_ text: String) -> Bool {
        let p = text.lowercased()
        if p.contains("flight") { return true }
        if p.contains("bos") && p.contains("sfo") { return true }
        if p.contains("boston") && (p.contains("san francisco") || p.contains(" sf")) { return true }
        return false
    }

    static func hasLearnedSkill(in skills: [EngineBridge.SkillSummary]) -> Bool {
        skills.contains { $0.id == skillId }
    }
}
