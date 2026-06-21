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

    /// ShaderGradient query URL — same renderer + grain settings as the Tera marketing site hero.
    var shaderGradientURL: String {
        switch self {
        case .openai:
            return Self.gradientURL(color1: "#090909", color2: "#0c1814", color3: "#12a884")
        case .claude:
            return Self.gradientURL(color1: "#090909", color2: "#181210", color3: "#d67857")
        case .deepseek:
            return Self.gradientURL(color1: "#090909", color2: "#0e1420", color3: "#3d85f5")
        case .minimax:
            return Self.gradientURL(color1: "#090909", color2: "#120e1a", color3: "#8c5cf5")
        case .llama:
            return Self.gradientURL(color1: "#090909", color2: "#0e1820", color3: "#1a8cd1")
        case .exa:
            return Self.gradientURL(
                color1: "#070707",
                color2: "#111111",
                color3: "#1a1a18",
                grainBlending: 0.38,
                uStrength: 1.6,
                uSpeed: 0.10,
                type: "plane"
            )
        case .gemini:
            return Self.gradientURL(color1: "#090909", color2: "#0e1428", color3: "#4285f4")
        }
    }

    private static func gradientURL(
        color1: String,
        color2: String,
        color3: String,
        grainBlending: Double = 0.48,
        uStrength: Double = 2.4,
        uSpeed: Double = 0.18,
        type: String = "waterPlane"
    ) -> String {
        let c1 = encodeColor(color1)
        let c2 = encodeColor(color2)
        let c3 = encodeColor(color3)
        return "https://www.shadergradient.co/customize?animate=on&axesHelper=off&brightness=0.72&cAzimuthAngle=170&cDistance=5.4&cPolarAngle=88&cameraZoom=1&color1=\(c1)&color2=\(c2)&color3=\(c3)&embedMode=off&enableTransition=on&envPreset=city&grain=on&grainBlending=\(grainBlending)&lightType=3d&pixelDensity=1.5&positionY=0.1&reflection=0.18&rotation=0&shader=defaults&type=\(type)&uAmplitude=0&uDensity=1&uFrequency=4.2&uSpeed=\(uSpeed)&uStrength=\(uStrength)&wireframe=false"
    }

    private static func encodeColor(_ hex: String) -> String {
        hex.replacingOccurrences(of: "#", with: "%23")
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
