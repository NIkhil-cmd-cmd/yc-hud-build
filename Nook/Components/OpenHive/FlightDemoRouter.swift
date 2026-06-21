//
//  FlightDemoRouter.swift
//  OpenHive — Google Flights routing (learn once → scripted replay)
//

import Foundation

enum FlightDemoMode: String, Equatable {
    case none
    case learning
    case replay
}

struct FlightRoute: Equatable {
    let origin: String
    let destination: String
    let departDate: String

    var skillId: String {
        "flight_\(origin.lowercased())_\(destination.lowercased())"
    }
}

enum FlightDemoRouter {
    static let demoSkillId = "demo_flight_bos_sfo"
    static let skillName = "Book flight BOS to SFO"
    static let defaultRoute = FlightRoute(origin: "BOS", destination: "SFO", departDate: "2026-07-15")
    static let startURL = "https://www.google.com/travel/flights"

    /// Legacy alias used across the app.
    static var skillId: String { demoSkillId }
    static var origin: String { defaultRoute.origin }
    static var destination: String { defaultRoute.destination }
    static var departDate: String { defaultRoute.departDate }

    static func isFlightPrompt(_ text: String) -> Bool {
        let p = text.lowercased()
        if p.contains("flight") { return true }
        if airportCodes(in: text).count >= 2 { return true }
        if p.contains("bos") && p.contains("sfo") { return true }
        if p.contains("boston") && (p.contains("san francisco") || p.contains(" sf")) { return true }
        return false
    }

    static func parseRoute(from text: String) -> FlightRoute {
        let codes = airportCodes(in: text)
        if codes.count >= 2 {
            return FlightRoute(origin: codes[0], destination: codes[1], departDate: defaultRoute.departDate)
        }

        let lower = text.lowercased()
        var origin = defaultRoute.origin
        var dest = defaultRoute.destination

        if lower.contains("boston") || lower.contains(" bos") { origin = "BOS" }
        else if lower.contains("san francisco") || lower.contains(" sfo") { origin = "SFO" }
        else if lower.contains("los angeles") || lower.contains(" lax") { origin = "LAX" }
        else if lower.contains("new york") || lower.contains(" jfk") { origin = "JFK" }
        else if lower.contains("seattle") || lower.contains(" sea") { origin = "SEA" }
        else if lower.contains("miami") || lower.contains(" mia") { origin = "MIA" }
        else if lower.contains("chicago") || lower.contains(" ord") { origin = "ORD" }
        else if lower.contains("denver") || lower.contains(" den") { origin = "DEN" }
        else if lower.contains("atlanta") || lower.contains(" atl") { origin = "ATL" }

        if lower.contains("san francisco") || lower.contains(" sfo") || lower.contains(" sf ") { dest = "SFO" }
        else if lower.contains("los angeles") || lower.contains(" lax") { dest = "LAX" }
        else if lower.contains("new york") || lower.contains(" jfk") { dest = "JFK" }
        else if lower.contains("boston") || lower.contains(" bos") { dest = "BOS" }
        else if lower.contains("seattle") || lower.contains(" sea") { dest = "SEA" }
        else if lower.contains("miami") || lower.contains(" mia") { dest = "MIA" }
        else if lower.contains("chicago") || lower.contains(" ord") { dest = "ORD" }
        else if lower.contains("denver") || lower.contains(" den") { dest = "DEN" }
        else if lower.contains("atlanta") || lower.contains(" atl") { dest = "ATL" }

        // "from X to Y" — second city wins for destination when both appear
        if let fromRange = lower.range(of: " from ") {
            let afterFrom = String(lower[fromRange.upperBound...])
            if let toRange = afterFrom.range(of: " to ") {
                let originText = String(afterFrom[..<toRange.lowerBound])
                let destText = String(afterFrom[toRange.upperBound...])
                if let code = cityToCode(originText) { origin = code }
                if let code = cityToCode(destText) { dest = code }
            }
        }

        return FlightRoute(origin: origin, destination: dest, departDate: defaultRoute.departDate)
    }

    static func hasLearnedSkill(for route: FlightRoute, in skills: [EngineBridge.SkillSummary]) -> Bool {
        let ids = Set([demoSkillId, route.skillId, "flight_\(route.origin)_\(route.destination)".lowercased()])
        return skills.contains { ids.contains($0.id) }
    }

    static func hasLearnedSkill(in skills: [EngineBridge.SkillSummary]) -> Bool {
        hasLearnedSkill(for: defaultRoute, in: skills)
    }

    static func displayName(for route: FlightRoute) -> String {
        "Book flight \(route.origin) to \(route.destination)"
    }

    // MARK: - Private

    private static func airportCodes(in text: String) -> [String] {
        let upper = text.uppercased()
        let pattern = #"\b([A-Z]{3})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        var codes: [String] = []
        regex.enumerateMatches(in: upper, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: upper) else { return }
            let code = String(upper[r])
            if knownAirports.contains(code), !codes.contains(code) {
                codes.append(code)
            }
        }
        return codes
    }

    private static func cityToCode(_ fragment: String) -> String? {
        let f = fragment.lowercased()
        if f.contains("boston") || f.contains("bos") { return "BOS" }
        if f.contains("san francisco") || f.contains("sfo") || f.contains(" sf") { return "SFO" }
        if f.contains("los angeles") || f.contains("lax") { return "LAX" }
        if f.contains("new york") || f.contains("jfk") { return "JFK" }
        if f.contains("seattle") || f.contains("sea") { return "SEA" }
        if f.contains("miami") || f.contains("mia") { return "MIA" }
        if f.contains("chicago") || f.contains("ord") { return "ORD" }
        if f.contains("denver") || f.contains("den") { return "DEN" }
        if f.contains("atlanta") || f.contains("atl") { return "ATL" }
        return nil
    }

    private static let knownAirports: Set<String> = [
        "BOS", "SFO", "LAX", "JFK", "SEA", "MIA", "ORD", "DEN", "ATL", "EWR", "SJC", "OAK",
    ]
}
