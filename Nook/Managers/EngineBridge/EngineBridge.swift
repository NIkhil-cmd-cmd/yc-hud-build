//
//  EngineBridge.swift
//  OpenHive — WebSocket bridge to python/engine.py
//

import Foundation
import OSLog
import WebKit

@MainActor
@Observable
final class EngineBridge {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenHive",
        category: "EngineBridge"
    )

    static let defaultPort = 8765
    static let shared = EngineBridge()

    var isConnected = false
    var observedStepCount = 0
    var workflows: [WorkflowSummary] = []
    var isExecuting = false
    var connectionError: String?

    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let sessionId = UUID().uuidString
    private var reconnectTask: Task<Void, Never>?
    private var executeWebView: WKWebView?
    private var executeParams: [String: String] = [:]

    struct WorkflowSummary: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        var steps: Int
    }

    private init() {}

    func connect(port: Int = defaultPort) {
        reconnectTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        let url = URL(string: "ws://localhost:\(port)")!
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        isConnected = true
        connectionError = nil
        receiveLoop()
        send(["type": "attach_observer", "sessionId": sessionId])
        send(["type": "list_workflows"])
        send(["type": "get_token_metrics"])
        Self.log.info("EngineBridge connected localhost:\(port)")
    }

    func disconnect() {
        reconnectTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
    }

    func observeEvent(_ event: [String: Any]) {
        var payload = event
        if payload["type"] == nil { payload["type"] = "click" }
        send([
            "type": "observe_event",
            "sessionId": sessionId,
            "event": payload,
        ])
    }

    func compileWorkflow(name: String) {
        send([
            "type": "compile_workflow",
            "sessionId": sessionId,
            "name": name,
        ])
    }

    func refreshWorkflows() {
        send(["type": "list_workflows"])
    }

    func requestTokenMetrics() {
        send(["type": "get_token_metrics"])
    }

    func executeWorkflow(workflowId: String, params: [String: String], webView: WKWebView) {
        executeWebView = webView
        executeParams = params
        isExecuting = true
        send([
            "type": "execute_workflow",
            "workflowId": workflowId,
            "params": params,
        ])
    }

    func cancelExecution() {
        send(["type": "cancel_execute"])
        isExecuting = false
        executeWebView = nil
    }

    private func send(_ dict: [String: Any]) {
        guard let ws = webSocket,
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                Self.log.error("send failed: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.connectionError = error.localizedDescription
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.reconnectTask = nil
            if !self.isConnected || self.connectionError != nil {
                self.connect()
            }
        }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        await self.handleMessage(text)
                    }
                    self.receiveLoop()
                case .failure(let error):
                    Self.log.error("receive failed: \(error.localizedDescription)")
                    self.isConnected = false
                    self.connectionError = error.localizedDescription
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "step_observed":
            observedStepCount = json["count"] as? Int ?? observedStepCount
        case "workflows_list":
            if let raw = json["workflows"] as? [[String: Any]] {
                workflows = raw.compactMap { w in
                    guard let id = w["id"] as? String, let name = w["name"] as? String else { return nil }
                    return WorkflowSummary(id: id, name: name, steps: w["steps"] as? Int ?? 0)
                }
            }
        case "workflow_saved":
            refreshWorkflows()
            WorkflowManager.shared.compileMessage = "Workflow saved"
        case "token_metrics", "run_metric":
            if type == "run_metric" {
                let tokens = json["tokens"] as? Int ?? 0
                let tier = json["tier"] as? Int ?? 1
                let elapsed = json["elapsedMs"] as? Int ?? 0
                TokenDashboardManager.shared.updateLiveRun(tokens: tokens, elapsedMs: elapsed, tier: tier)
            }
            if let metrics = json["metrics"] as? [String: Any] {
                TokenDashboardManager.shared.update(from: metrics)
            } else if type == "run_metric" {
                TokenDashboardManager.shared.refresh()
            }
        case "execute_started":
            if let webView = executeWebView {
                await sendExecuteState(webView: webView)
            }
        case "execute_action":
            if let webView = executeWebView,
               let action = json["action"] as? [String: Any] {
                _ = await OpenHiveObservation.perform(action: action, on: webView)
                try? await Task.sleep(nanoseconds: 800_000_000)
                await sendExecuteState(webView: webView)
            }
        case "execute_done":
            isExecuting = false
            executeWebView = nil
            WorkflowManager.shared.onExecuteDone()
            requestTokenMetrics()
        case "execute_cancelled":
            isExecuting = false
            executeWebView = nil
        case "error":
            connectionError = json["message"] as? String
            WorkflowManager.shared.lastError = connectionError
        default:
            break
        }
    }

    private func sendExecuteState(webView: WKWebView) async {
        let url = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        let tree = await OpenHiveObservation.accessibilitySnapshot(from: webView)
        send([
            "type": "execute_state",
            "url": url,
            "title": title,
            "accessibilityTree": tree ?? NSNull(),
        ])
    }
}
