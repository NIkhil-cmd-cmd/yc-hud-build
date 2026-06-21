//
//  WorkflowSlashCommands.swift
//  Nook — /save, /run, /workflows, etc.
//

import Foundation
import WebKit

enum WorkflowSlashCommand: Equatable {
    case notSlash
    case unknown(String)
    case save(name: String)
    case run(query: String)
    case list
    case deleteAll
    case cancel
    case status
    case help
    case agent(goal: String)

    static let catalog: [(command: String, summary: String)] = [
        ("/save [name]", "Save recorded steps as a workflow"),
        ("/run [name]", "Run a saved workflow in the current tab"),
        ("/agent [goal]", "Run LLM agent on the current tab"),
        ("/workflows", "List saved workflows"),
        ("/delete", "Delete all saved workflows"),
        ("/cancel", "Cancel a running workflow"),
        ("/status", "Engine connection and step count"),
        ("/help", "Show slash commands"),
    ]

    static func parse(_ text: String) -> WorkflowSlashCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .notSlash }

        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let verb = parts.first.map { String($0).lowercased() } ?? ""
        let arg = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch verb {
        case "save", "s":
            return .save(name: arg.isEmpty ? "Saved workflow" : arg)
        case "run", "r":
            return .run(query: arg)
        case "workflows", "list", "ls", "w":
            return .list
        case "delete", "clear", "rm":
            return .deleteAll
        case "cancel", "stop":
            return .cancel
        case "agent", "a":
            return .agent(goal: arg)
        case "status", "st":
            return .status
        case "help", "h", "?":
            return .help
        default:
            return .unknown(verb.isEmpty ? trimmed : "/\(verb)")
        }
    }

    var isHandled: Bool {
        switch self {
        case .notSlash, .unknown:
            return false
        default:
            return true
        }
    }
}

@MainActor
enum WorkflowSlashCommandExecutor {
    @discardableResult
    static func execute(
        _ text: String,
        browserManager: BrowserManager
    ) -> Bool {
        let command = WorkflowSlashCommand.parse(text)
        guard command.isHandled else { return false }

        let workflows = WorkflowManager.shared
        let engine = EngineBridge.shared

        switch command {
        case .notSlash:
            return false
        case .unknown(let token):
            workflows.lastError = "Unknown command: \(token). Try /help"
            return true

        case .save(let name):
            workflows.saveCurrentSession(name: name)
            workflows.compileMessage = "Saving \"\(name)\"…"
            return true

        case .run(let query):
            guard !query.isEmpty else {
                workflows.lastError = "Usage: /run [workflow name]"
                return true
            }
            guard let wf = workflows.matchWorkflow(named: query) else {
                workflows.lastError = "No workflow matching \"\(query)\""
                return true
            }
            guard let tab = browserManager.currentTabForActiveWindow(),
                  let windowId = browserManager.windowRegistry?.activeWindow?.id,
                  let webView = browserManager.getWebView(for: tab.id, in: windowId)
            else {
                workflows.lastError = "Select a tab first"
                return true
            }
            tab.isOpenHiveNewTab = false
            workflows.compileMessage = "Running \"\(wf.name)\"…"
            workflows.execute(
                workflowId: wf.id,
                webView: webView,
                tabId: tab.id,
                windowId: windowId,
                browserManager: browserManager
            )
            return true

        case .agent(let goal):
            guard !goal.isEmpty else {
                workflows.lastError = "Usage: /agent [goal — e.g. book BOS to LAX July 15]"
                return true
            }
            guard engine.isConnected else {
                workflows.lastError = "Engine offline — run ./scripts/start_engine.sh"
                return true
            }
            guard let tab = browserManager.currentTabForActiveWindow(),
                  let windowId = browserManager.windowRegistry?.activeWindow?.id,
                  let webView = browserManager.getWebView(for: tab.id, in: windowId)
            else {
                workflows.lastError = "Select a tab first"
                return true
            }
            tab.isOpenHiveNewTab = false
            workflows.compileMessage = "Agent running: \(goal.prefix(60))…"
            engine.startAgentTask(
                goal: goal,
                webView: webView,
                tabId: tab.id,
                windowId: windowId,
                browserManager: browserManager
            )
            return true

        case .list:
            if engine.workflows.isEmpty {
                workflows.compileMessage = "No workflows saved yet"
            } else {
                workflows.compileMessage = engine.workflows
                    .map { "• \($0.name) (\($0.steps) steps)" }
                    .joined(separator: "\n")
            }
            return true

        case .deleteAll:
            workflows.deleteAllWorkflows()
            return true

        case .cancel:
            workflows.cancelExecution()
            EngineBridge.shared.cancelTrajectory()
            workflows.compileMessage = "Cancelled"
            return true

        case .status:
            workflows.compileMessage = engine.isConnected
                ? "Engine online · \(engine.observedStepCount) steps recorded · \(engine.workflows.count) saved"
                : "Engine offline — run ./scripts/start_engine.sh"
            return true

        case .help:
            workflows.compileMessage = WorkflowSlashCommand.catalog
                .map { "\($0.command) — \($0.summary)" }
                .joined(separator: "\n")
            return true
        }
    }

    static func isSlashCommand(_ text: String) -> Bool {
        WorkflowSlashCommand.parse(text).isHandled
            || text.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }
}
