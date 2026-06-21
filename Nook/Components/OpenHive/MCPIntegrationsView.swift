//
//  MCPIntegrationsView.swift
//  OpenHive — Dia-style connected services (MCP)
//

import SwiftUI

struct MCPIntegrationsView: View {
  @Environment(AIConfigService.self) private var configService
  @Environment(MCPManager.self) private var mcpManager
  @State private var configuringPreset: MCPServerPreset?
  @State private var envDraft: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Connected apps")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Text("\(connectedCount)/\(MCPServerPresets.all.count)")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      Text("Connect services once — the agent can take actions in any of them.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      VStack(spacing: 0) {
        ForEach(MCPServerPresets.all) { preset in
          integrationRow(preset)
          if preset.id != MCPServerPresets.all.last?.id {
            Divider().padding(.leading, 44)
          }
        }
      }
      .background {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
          }
      }

      if mcpManager.allTools.isEmpty == false {
        Text("\(mcpManager.allTools.count) MCP tools available to agent")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .sheet(item: $configuringPreset) { preset in
      configureSheet(preset)
    }
    .onAppear { ensurePresetsInstalled() }
  }

  private var connectedCount: Int {
    MCPServerPresets.all.filter { preset in
      let state = mcpManager.connectionState(for: preset.id)
      return state.isConnected
    }.count
  }

  private func ensurePresetsInstalled() {
    let merged = MCPServerPresets.mergeIntoConfig(configService.mcpServers)
    if merged.count != configService.mcpServers.count {
      configService.mcpServers = merged
    }
  }

  @ViewBuilder
  private func integrationRow(_ preset: MCPServerPreset) -> some View {
    let config = configService.mcpServers.first { $0.id == preset.id }
    let state = mcpManager.connectionState(for: preset.id)
    let missingKeys = config?.missingRequiredKeys ?? preset.requiredEnvKeys

    HStack(spacing: 12) {
      Image(systemName: preset.icon)
        .font(.system(size: 16))
        .foregroundStyle(.primary)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))

      VStack(alignment: .leading, spacing: 2) {
        Text(preset.name)
          .font(.system(size: 13, weight: .medium))
        Text(preset.summary)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if !missingKeys.isEmpty && config?.isEnabled == true {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .help("Missing: \(missingKeys.joined(separator: ", "))")
      }

      connectionBadge(state)

      Menu {
        if state.isConnected {
          Button("Disconnect") { toggle(preset, enabled: false) }
        } else {
          Button("Connect…") { openConfigure(preset) }
        }
        Button("Configure credentials…") { openConfigure(preset) }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private func connectionBadge(_ state: MCPConnectionState) -> some View {
    switch state {
    case .connected:
      Circle().fill(.green).frame(width: 7, height: 7)
    case .connecting:
      ProgressView().controlSize(.mini)
    case .error:
      Circle().fill(.orange).frame(width: 7, height: 7)
    case .disconnected:
      Circle().fill(.quaternary).frame(width: 7, height: 7)
    }
  }

  private func openConfigure(_ preset: MCPServerPreset) {
    let existing = configService.mcpServers.first { $0.id == preset.id }
    envDraft = preset.requiredEnvKeys.reduce(into: [:]) { acc, key in
      acc[key] = existing?.envVars[key] ?? ""
    }
    configuringPreset = preset
  }

  @ViewBuilder
  private func configureSheet(_ preset: MCPServerPreset) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Connect \(preset.name)")
        .font(.headline)
      Text(preset.setupHint)
        .font(.caption)
        .foregroundStyle(.secondary)

      ForEach(preset.requiredEnvKeys, id: \.self) { key in
        VStack(alignment: .leading, spacing: 4) {
          Text(key)
            .font(.caption.weight(.semibold))
          SecureField(key, text: Binding(
            get: { envDraft[key] ?? "" },
            set: { envDraft[key] = $0 }
          ))
          .textFieldStyle(.roundedBorder)
        }
      }

      HStack {
        Button("Cancel") { configuringPreset = nil }
        Spacer()
        Button("Connect") {
          saveAndConnect(preset)
          configuringPreset = nil
        }
        .buttonStyle(.borderedProminent)
        .disabled(preset.requiredEnvKeys.contains { (envDraft[$0] ?? "").isEmpty })
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func saveAndConnect(_ preset: MCPServerPreset) {
    var config = preset.makeConfig(envValues: envDraft, enabled: true)
    if let idx = configService.mcpServers.firstIndex(where: { $0.id == preset.id }) {
      configService.updateMCPServer(config)
    } else {
      configService.addMCPServer(config)
    }
    mcpManager.reconnectServer(config)
    EngineBridge.shared.syncMcpTools(from: mcpManager)
  }

  private func toggle(_ preset: MCPServerPreset, enabled: Bool) {
    guard var config = configService.mcpServers.first(where: { $0.id == preset.id }) else { return }
    config.isEnabled = enabled
    configService.updateMCPServer(config)
    if enabled {
      mcpManager.reconnectServer(config)
    } else {
      mcpManager.disconnectServer(preset.id)
    }
    EngineBridge.shared.syncMcpTools(from: mcpManager)
  }
}
