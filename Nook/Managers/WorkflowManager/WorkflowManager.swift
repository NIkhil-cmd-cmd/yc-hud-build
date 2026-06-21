//
//  WorkflowManager.swift
//  OpenHive — compile, list, execute workflows via EngineBridge
//

import Foundation
import OSLog
import WebKit

enum OpenHiveChatCommand: Equatable {
    case notHandled
    case compile(name: String)
    case run(workflowId: String, workflowName: String)
}

@MainActor
@Observable
final class WorkflowManager {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenHive",
        category: "WorkflowManager"
    )

    static let shared = WorkflowManager()

    var isExecuting = false
    var lastError: String?
    var compileMessage: String?

    private var executeWebView: WKWebView?

    private init() {}

    func parseChatCommand(_ text: String) -> OpenHiveChatCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        OpenHiveLogger.log("WorkflowManager", "parseChatCommand", data: ["text": text])

        if lower.hasPrefix("save") || lower.contains("remember this") || lower.contains("save this") {
            let name = extractWorkflowName(from: text) ?? "Saved workflow"
            return .compile(name: name)
        }

        if lower.hasPrefix("run ") {
            let query = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if let wf = matchWorkflow(named: query) {
                return .run(workflowId: wf.id, workflowName: wf.name)
            }
            lastError = "No workflow matching \"\(query)\""
            return .notHandled
        }

        if lower.hasPrefix("list workflows") || lower == "workflows" {
            compileMessage = EngineBridge.shared.workflows.isEmpty
                ? "No workflows saved yet"
                : EngineBridge.shared.workflows.map(\.name).joined(separator: ", ")
            return .compile(name: "") // handled without compile
        }

        if lower.contains("delete all workflow") || lower == "clear workflows" {
            deleteAllWorkflows()
            return .compile(name: "")
        }

        return .notHandled
    }

    func handleChatCommand(_ text: String) -> Bool {
        switch parseChatCommand(text) {
        case .notHandled:
            return false
        case .compile(let name):
            if name.isEmpty { return true }
            EngineBridge.shared.compileWorkflow(name: name)
            compileMessage = "Compiling \(name)..."
            return true
        case .run:
            return true
        }
    }

    func matchWorkflow(named query: String) -> EngineBridge.WorkflowSummary? {
        let q = query.lowercased()
        return EngineBridge.shared.workflows.first { $0.name.lowercased().contains(q) }
            ?? EngineBridge.shared.workflows.first { $0.id.lowercased().contains(q) }
    }

    func extractWorkflowName(from text: String) -> String? {
        let patterns = ["save this as ", "save as ", "remember this as ", "remember as "]
        let lower = text.lowercased()
        for p in patterns {
            if let r = lower.range(of: p) {
                let start = text.index(text.startIndex, offsetBy: text.distance(from: text.startIndex, to: r.upperBound))
                return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if lower.hasPrefix("save ") {
            return String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func saveCurrentSession(name: String = "Saved workflow") {
        EngineBridge.shared.compileWorkflow(name: name)
        compileMessage = "Compiling..."
    }

    func execute(workflowId: String, webView: WKWebView, params: [String: String] = [:]) {
        guard !isExecuting else { return }
        isExecuting = true
        executeWebView = webView
        lastError = nil
        compileMessage = "Running in current tab…"
        TokenDashboardManager.shared.clearLiveRun()
        EngineBridge.shared.executeWorkflow(workflowId: workflowId, params: params, webView: webView)
    }

    func cancelExecution() {
        EngineBridge.shared.cancelExecution()
        isExecuting = false
        executeWebView = nil
        TokenDashboardManager.shared.clearLiveRun()
    }

    func deleteAllWorkflows() {
        guard !isExecuting else {
            lastError = "Cancel the running workflow first"
            return
        }
        lastError = nil
        EngineBridge.shared.deleteAllWorkflows()
    }

    func onWorkflowsDeleted(count: Int) {
        isExecuting = false
        executeWebView = nil
        lastError = nil
        compileMessage = count == 0 ? "No workflows to delete" : "Deleted \(count) workflow\(count == 1 ? "" : "s")"
    }

    func onExecuteDone(hudReward: Double? = nil, hudStatus: String? = nil, hudContent: String? = nil) {
        isExecuting = false
        executeWebView = nil
        lastError = nil
        if let reward = hudReward {
            compileMessage = String(format: "HUD reward: %.0f%%", reward * 100)
        } else if hudStatus == "error" {
            compileMessage = hudContent ?? "HUD grading failed"
        } else {
            compileMessage = "Workflow finished"
        }
        TokenDashboardManager.shared.clearLiveRun()
    }
}
