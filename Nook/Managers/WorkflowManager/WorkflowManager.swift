//
//  WorkflowManager.swift
//  OpenHive — compile, list, execute workflows via EngineBridge
//

import Foundation
import OSLog
import WebKit

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
    private var executeTask: Task<Void, Never>?

    private init() {}

    func handleChatCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("save") || lower.contains("remember this") || lower.contains("save this") {
            let name = extractWorkflowName(from: text) ?? "Saved workflow"
            EngineBridge.shared.compileWorkflow(name: name)
            compileMessage = "Compiling \(name)..."
            return true
        }
        if lower.hasPrefix("run ") {
            let name = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if let wf = EngineBridge.shared.workflows.first(where: {
                $0.name.lowercased().contains(name.lowercased())
            }) {
                return false // caller runs with webView
            }
        }
        return false
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
        TokenDashboardManager.shared.clearLiveRun()
        EngineBridge.shared.executeWorkflow(workflowId: workflowId, params: params, webView: webView)
    }

    func cancelExecution() {
        EngineBridge.shared.cancelExecution()
        isExecuting = false
        executeWebView = nil
        TokenDashboardManager.shared.clearLiveRun()
    }

    func onExecuteDone() {
        isExecuting = false
        executeWebView = nil
        TokenDashboardManager.shared.clearLiveRun()
    }
}
