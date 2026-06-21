//
//  TrajectoryTestView.swift
//  OpenHive
//
//  Debug panel for Google Flights trajectory smoke tests in the current tab.
//

import SwiftUI

struct TrajectoryTestView: View {
    @EnvironmentObject private var browserManager: BrowserManager

    private var bridge: EngineBridge { EngineBridge.shared }

    let testTasks = [
        ("BOS", "LAX", "2026-07-15"),
        ("SFO", "JFK", "2026-08-12"),
        ("SEA", "DEN", "2026-09-09"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            statusBar
            stepLog
            controls
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(bridge.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(bridge.isConnected ? "Engine connected" : "Engine offline")
                .font(.caption)

            Spacer()

            if let task = bridge.currentTrajectoryTask {
                Text("\(task.origin) → \(task.destination) · \(task.departDate)")
                    .font(.caption.monospaced())
            }

            Text("\(bridge.trajectoryStepLog.count) steps")
                .font(.caption.monospaced())
        }
    }

    private var stepLog: some View {
        GroupBox("Step log") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if bridge.trajectoryStepLog.isEmpty {
                        Text("Run a quick test to see steps here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bridge.trajectoryStepLog) { step in
                            HStack(spacing: 8) {
                                Text("\(step.index)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                Text(step.actionType)
                                    .font(.caption.monospaced())
                                    .frame(width: 72, alignment: .leading)
                                Text(step.url)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(bridge.isConnected ? "Reconnect" : "Connect Engine") {
                    bridge.connect()
                }
                Button("Clear Log") {
                    bridge.trajectoryStepLog.removeAll()
                }
                if bridge.currentTrajectoryTask != nil || bridge.isExecuting {
                    Button("Cancel") {
                        bridge.cancelTrajectory()
                    }
                }
                Spacer()
            }

            Text("Runs via browser-use (Chromium). Your Nook tab mirrors agent URLs; cookies sync from the current profile.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Quick tests")
                .font(.caption.weight(.semibold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(testTasks.enumerated()), id: \.offset) { _, task in
                    Button("\(task.0) → \(task.1)") {
                        runTask(origin: task.0, destination: task.1, date: task.2)
                    }
                    .disabled(!canRun)
                }
            }

            if let error = bridge.trajectoryLastError ?? bridge.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var canRun: Bool {
        bridge.isConnected && !bridge.isExecuting && bridge.currentTrajectoryTask == nil
    }

    private func runTask(origin: String, destination: String, date: String) {
        guard canRun else { return }
        guard let tab = browserManager.currentTabForActiveWindow(),
              let windowId = browserManager.windowRegistry?.activeWindow?.id,
              let webView = browserManager.getWebView(for: tab.id, in: windowId) else {
            bridge.trajectoryLastError = "Select a tab in the main window first"
            return
        }

        bridge.trajectoryStepLog.removeAll()
        bridge.startTrajectory(
            origin: origin,
            destination: destination,
            departDate: date,
            webView: webView,
            tabId: tab.id,
            windowId: windowId,
            browserManager: browserManager
        )
    }
}

#Preview {
    TrajectoryTestView()
        .environmentObject(BrowserManager())
}
