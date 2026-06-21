//
//  AgentModelCatalog.swift
//  OpenHive — agent model presets for the new-tab picker
//

import SwiftUI

struct AgentModelOption: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let provider: String
    let model: String
    let brand: AgentModelBrand

    var engineLabel: String { "\(name) · \(model)" }
}

enum AgentModelBrand: String, Codable, CaseIterable {
    case openai
    case claude
    case deepseek
    case minimax
    case llama
    case exa
    case gemini

    var accent: Color {
        switch self {
        case .openai: return Color(red: 0.07, green: 0.64, blue: 0.50)
        case .claude: return Color(red: 0.84, green: 0.47, blue: 0.34)
        case .deepseek: return Color(red: 0.24, green: 0.52, blue: 0.96)
        case .minimax: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .llama: return Color(red: 0.10, green: 0.55, blue: 0.82)
        case .exa: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }

    var monogram: String {
        switch self {
        case .openai: return "GPT"
        case .claude: return "C"
        case .deepseek: return "DS"
        case .minimax: return "MM"
        case .llama: return "🦙"
        case .exa: return "E"
        case .gemini: return "G"
        }
    }

    var usesEmojiLogo: Bool {
        self == .llama
    }

    /// Four-stop palette for new-tab ShaderGradient-style background (dark base + brand accent).
    var shaderGradientColors: [Color] {
        let base = Color(red: 0.035, green: 0.035, blue: 0.035)
        switch self {
        case .openai:
            return [
                base,
                Color(red: 0.06, green: 0.10, blue: 0.09),
                Color(red: 0.07, green: 0.64, blue: 0.50),
                Color(red: 0.04, green: 0.28, blue: 0.24),
            ]
        case .claude:
            return [
                base,
                Color(red: 0.12, green: 0.09, blue: 0.07),
                Color(red: 0.84, green: 0.47, blue: 0.34),
                Color(red: 0.45, green: 0.22, blue: 0.14),
            ]
        case .deepseek:
            return [
                base,
                Color(red: 0.06, green: 0.09, blue: 0.16),
                Color(red: 0.24, green: 0.52, blue: 0.96),
                Color(red: 0.10, green: 0.22, blue: 0.48),
            ]
        case .minimax:
            return [
                base,
                Color(red: 0.10, green: 0.07, blue: 0.14),
                Color(red: 0.55, green: 0.36, blue: 0.96),
                Color(red: 0.28, green: 0.14, blue: 0.52),
            ]
        case .llama:
            return [
                base,
                Color(red: 0.06, green: 0.11, blue: 0.16),
                Color(red: 0.10, green: 0.55, blue: 0.82),
                Color(red: 0.05, green: 0.26, blue: 0.42),
            ]
        case .exa:
            return [
                base,
                Color(red: 0.08, green: 0.08, blue: 0.09),
                Color(red: 0.42, green: 0.42, blue: 0.44),
                Color(red: 0.18, green: 0.18, blue: 0.20),
            ]
        case .gemini:
            return [
                base,
                Color(red: 0.07, green: 0.10, blue: 0.18),
                Color(red: 0.26, green: 0.52, blue: 0.96),
                Color(red: 0.12, green: 0.28, blue: 0.62),
            ]
        }
    }
}

enum AgentModelCatalog {
    static let defaultOption = gpt4o

    static let gpt4o = AgentModelOption(
        id: "gpt-4o",
        name: "GPT-4o",
        subtitle: "OpenAI",
        provider: "openai",
        model: "gpt-4o-mini",
        brand: .openai
    )

    static let claude = AgentModelOption(
        id: "claude-sonnet",
        name: "Claude",
        subtitle: "Anthropic",
        provider: "claude",
        model: "anthropic/claude-sonnet-4.5",
        brand: .claude
    )

    static let deepseek = AgentModelOption(
        id: "deepseek-v3",
        name: "DeepSeek",
        subtitle: "V3.1",
        provider: "deepseek",
        model: "deepseek/deepseek-chat-v3.1:free",
        brand: .deepseek
    )

    static let minimax = AgentModelOption(
        id: "minimax",
        name: "MiniMax",
        subtitle: "Text-01",
        provider: "minimax",
        model: "MiniMax-Text-01",
        brand: .minimax
    )

    static let llamaLocal = AgentModelOption(
        id: "llama-local",
        name: "Llama",
        subtitle: "Local (Ollama)",
        provider: "ollama",
        model: "llama3.2",
        brand: .llama
    )

    static let exa = AgentModelOption(
        id: "exa",
        name: "Exa",
        subtitle: "Search + agent",
        provider: "exa",
        model: "gpt-4o-mini",
        brand: .exa
    )

    static let gemini = AgentModelOption(
        id: "gemini",
        name: "Gemini",
        subtitle: "2.0 Flash",
        provider: "openrouter",
        model: "google/gemini-2.0-flash-001",
        brand: .gemini
    )

    static let all: [AgentModelOption] = [
        gpt4o, claude, deepseek, minimax, llamaLocal, exa, gemini,
    ]

    static func option(id: String) -> AgentModelOption? {
        all.first { $0.id == id }
    }
}
