//
//  WorkflowManager.swift
//  OpenHive — compile, list, execute workflows via EngineBridge
//

import Foundation
import OSLog
import WebKit

extension Notification.Name {
    static let openHiveShowWorkflowToast = Notification.Name("openHiveShowWorkflowToast")
}

enum OpenHiveChatCommand: Equatable {
    case notHandled
    case compile(name: String)
    case run(workflowId: String, workflowName: String)
    case handledLocally
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

    static func postToast(_ message: String, isError: Bool = false) {
        NotificationCenter.default.post(
            name: .openHiveShowWorkflowToast,
            object: nil,
            userInfo: ["message": message, "isError": isError]
        )
    }

    func parseChatCommand(_ text: String) -> OpenHiveChatCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        OpenHiveLogger.log("WorkflowManager", "parseChatCommand", data: ["text": text])

        if WorkflowSlashCommand.parse(trimmed).isHandled {
            return .handledLocally
        }

        let lower = trimmed.lowercased()

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
            Self.postToast(lastError ?? "", isError: true)
            return .notHandled
        }

        if lower.hasPrefix("list workflows") || lower == "workflows" {
            compileMessage = EngineBridge.shared.workflows.isEmpty
                ? "No workflows saved yet"
                : EngineBridge.shared.workflows.map(\.name).joined(separator: ", ")
            Self.postToast(compileMessage ?? "")
            return .handledLocally
        }

        if lower.contains("delete all workflow") || lower == "clear workflows" {
            deleteAllWorkflows()
            return .handledLocally
        }

        return .notHandled
    }

    func handleChatCommand(_ text: String, browserManager: BrowserManager? = nil, windowState: BrowserWindowState? = nil) -> Bool {
        if WorkflowSlashCommand.parse(text).isHandled {
            guard let browserManager else { return true }
            let handled = WorkflowSlashCommandExecutor.execute(text, browserManager: browserManager)
            browserManager.showWorkflowStatus(in: windowState)
            return handled
        }

        switch parseChatCommand(text) {
        case .notHandled:
            return false
        case .handledLocally:
            browserManager?.showWorkflowStatus(in: windowState)
            return true
        case .compile(let name):
            if !EngineBridge.shared.isConnected {
                lastError = "Engine offline — run ./scripts/start_engine.sh"
                Self.postToast(lastError ?? "", isError: true)
                browserManager?.showWorkflowStatus(in: windowState)
                return true
            }
            if EngineBridge.shared.observedStepCount == 0 {
                lastError = "No steps recorded yet — browse and interact first"
                Self.postToast(lastError ?? "", isError: true)
                browserManager?.showWorkflowStatus(in: windowState)
                return true
            }
            EngineBridge.shared.compileWorkflow(name: name)
            compileMessage = "Compiling \(name)..."
            Self.postToast(compileMessage ?? "")
            browserManager?.showWorkflowStatus(in: windowState)
            return true
        case .run(let workflowId, let workflowName):
            guard let browserManager, let windowState,
                  let tab = browserManager.currentTab(for: windowState),
                  let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id)
            else {
                lastError = "Select a tab first"
                Self.postToast(lastError ?? "", isError: true)
                browserManager?.showWorkflowStatus(in: windowState)
                return true
            }
            tab.isOpenHiveNewTab = false
            execute(
                workflowId: workflowId,
                webView: webView,
                tabId: tab.id,
                windowId: windowState.id,
                browserManager: browserManager
            )
            compileMessage = "Running \(workflowName)…"
            Self.postToast(compileMessage ?? "")
            browserManager.showWorkflowStatus(in: windowState)
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
        guard EngineBridge.shared.isConnected else {
            lastError = "Engine offline — run ./scripts/start_engine.sh"
            Self.postToast(lastError ?? "", isError: true)
            return
        }
        if EngineBridge.shared.observedStepCount == 0 {
            lastError = "No steps recorded yet — browse and interact first"
            Self.postToast(lastError ?? "", isError: true)
            return
        }
        EngineBridge.shared.compileWorkflow(name: name)
        compileMessage = "Compiling \(name)..."
        Self.postToast(compileMessage ?? "")
    }

    func execute(
        workflowId: String,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager,
        params: [String: String] = [:]
    ) {
        guard !isExecuting else { return }
        isExecuting = true
        executeWebView = webView
        lastError = nil
        compileMessage = "Running in current tab…"
        TokenDashboardManager.shared.clearLiveRun()
        EngineBridge.shared.executeWorkflow(
            workflowId: workflowId,
            params: params,
            webView: webView,
            tabId: tabId,
            windowId: windowId,
            browserManager: browserManager
        )
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
            Self.postToast(lastError ?? "", isError: true)
            return
        }
        lastError = nil
        EngineBridge.shared.deleteAllWorkflows()
    }

    @discardableResult
    func openWorkflowGraph(in windowState: BrowserWindowState? = nil, browserManager: BrowserManager? = nil) -> Bool {
        guard let browserManager else {
            lastError = "Browser unavailable"
            Self.postToast(lastError ?? "", isError: true)
            return false
        }

        guard let windowState = windowState ?? browserManager.windowRegistry?.activeWindow else {
            lastError = "No active window"
            Self.postToast(lastError ?? "", isError: true)
            return false
        }

        let targetSpace =
            windowState.currentSpaceId.flatMap { id in
                browserManager.tabManager.spaces.first(where: { $0.id == id })
            }
            ?? windowState.currentProfileId.flatMap { pid in
                browserManager.tabManager.spaces.first(where: { $0.profileId == pid })
            }
        let tab = browserManager.tabManager.createNewTab(url: "about:blank", in: targetSpace)
        tab.isOpenHiveNewTab = false
        tab.openHiveWorkflowCatalog = true
        tab.openHiveGraphWorkflowId = nil
        tab.name = "Workflows"
        browserManager.selectTab(tab, in: windowState)
        EngineBridge.shared.refreshWorkflows()
        compileMessage = "Opened workflow catalog"
        Self.postToast(compileMessage ?? "")
        return true
    }

    func onWorkflowsDeleted(count: Int) {
        isExecuting = false
        executeWebView = nil
        lastError = nil
        compileMessage = count == 0 ? "No workflows to delete" : "Deleted \(count) workflow\(count == 1 ? "" : "s")"
        Self.postToast(compileMessage ?? "")
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
        Self.postToast(compileMessage ?? "")
        TokenDashboardManager.shared.clearLiveRun()
    }
}
