//
//  MCPServerPresets.swift
//  Nook — Dia-style service integrations via MCP
//

import Foundation

struct MCPServerPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let summary: String
    let transport: MCPTransportType
    let requiredEnvKeys: [String]
    let setupHint: String

    func makeConfig(envValues: [String: String] = [:], enabled: Bool = false) -> MCPServerConfig {
        var env = envValues
        for key in requiredEnvKeys where env[key]?.isEmpty != false {
            env[key] = ""
        }
        return MCPServerConfig(
            id: id,
            name: name,
            transport: transport,
            envVars: env,
            isEnabled: enabled,
            toolNamespace: MCPServerConfig.normalizeNamespace(name),
            iconName: icon,
            presetId: id
        )
    }
}

enum MCPServerPresets {
    static let all: [MCPServerPreset] = [
        MCPServerPreset(
            id: "preset-github",
            name: "GitHub",
            icon: "chevron.left.forwardslash.chevron.right",
            summary: "Issues, PRs, repos, and code search",
            transport: .stdio(
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-github"]
            ),
            requiredEnvKeys: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
            setupHint: "Create a token at github.com/settings/tokens with repo scope."
        ),
        MCPServerPreset(
            id: "preset-gmail",
            name: "Gmail",
            icon: "envelope.fill",
            summary: "Read and send email via Google APIs",
            transport: .stdio(
                command: "npx",
                args: ["-y", "@anthropic-ai/mcp-server-gmail"]
            ),
            requiredEnvKeys: ["GMAIL_CREDENTIALS_PATH"],
            setupHint: "OAuth credentials JSON from Google Cloud Console (Gmail API enabled)."
        ),
        MCPServerPreset(
            id: "preset-google-calendar",
            name: "Google Calendar",
            icon: "calendar",
            summary: "List and create calendar events",
            transport: .stdio(
                command: "npx",
                args: ["-y", "@anthropic-ai/mcp-server-google-calendar"]
            ),
            requiredEnvKeys: ["GOOGLE_CALENDAR_CREDENTIALS_PATH"],
            setupHint: "OAuth credentials JSON with Calendar API enabled."
        ),
        MCPServerPreset(
            id: "preset-google-drive",
            name: "Google Drive",
            icon: "externaldrive.fill",
            summary: "Search, read, and manage Drive files",
            transport: .stdio(
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-gdrive"]
            ),
            requiredEnvKeys: ["GDRIVE_CREDENTIALS_PATH"],
            setupHint: "OAuth credentials JSON with Drive API enabled."
        ),
        MCPServerPreset(
            id: "preset-linkedin",
            name: "LinkedIn",
            icon: "link",
            summary: "Profile and messaging (browser session)",
            transport: .stdio(
                command: "npx",
                args: ["-y", "mcp-linkedin"]
            ),
            requiredEnvKeys: ["LINKEDIN_COOKIE"],
            setupHint: "Export li_at cookie from linkedin.com after signing in."
        ),
        MCPServerPreset(
            id: "preset-notion",
            name: "Notion",
            icon: "doc.text.fill",
            summary: "Pages, databases, and workspace search",
            transport: .stdio(
                command: "npx",
                args: ["-y", "@notionhq/notion-mcp-server"]
            ),
            requiredEnvKeys: ["NOTION_API_KEY"],
            setupHint: "Create an integration at notion.so/my-integrations and share pages with it."
        ),
    ]

    static func preset(for id: String) -> MCPServerPreset? {
        all.first { $0.id == id }
    }

    /// Install preset configs that are not already in the user's list.
    static func mergeIntoConfig(_ servers: [MCPServerConfig]) -> [MCPServerConfig] {
        var merged = servers
        for preset in all {
            if !merged.contains(where: { $0.id == preset.id || $0.presetId == preset.id }) {
                merged.append(preset.makeConfig())
            }
        }
        return merged
    }
}
