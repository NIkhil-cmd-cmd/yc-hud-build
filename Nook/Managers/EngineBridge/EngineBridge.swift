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
    var lastActionDescription: String?
    var executionProgress: String?
    var hudReward: Double?
    var hudStatus: String?

    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private let sessionId = UUID().uuidString
    private var reconnectTask: Task<Void, Never>?
    private var executeWebView: WKWebView?
    private var executeTabId: UUID?
    private var executeWindowId: UUID?
    private weak var executeBrowserManager: BrowserManager?
    private var pendingExaSearches: [String: (Result<String, Error>) -> Void] = [:]
    private var pendingAgentActions: [String: CheckedContinuation<(success: Bool, detail: String, resultURL: String?), Never>] = [:]
    private var outboundQueue: [[String: Any]] = []
    private var socketReady = false
    private var isConnecting = false
    private var reconnectAttempt = 0

    struct WorkflowSummary: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        var steps: Int
    }

    private init() {}

    func connect(port: Int = defaultPort) {
        guard !isConnecting else { return }
        isConnecting = true
        socketReady = false
        isConnected = false
        reconnectTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        outboundQueue.removeAll()

        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let ws = session.webSocketTask(with: url)
        webSocket = ws
        connectionError = nil
        OpenHiveLogger.log("EngineBridge", "connect_attempt", data: ["port": port])

        ws.resume()
        receiveLoop()

        // Wait for TCP+WS handshake via ping before sending
        ws.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isConnecting = false
                if let error {
                    self.connectionError = "Engine offline — run ./scripts/start_engine.sh"
                    OpenHiveLogger.error("EngineBridge", "ping_failed", data: ["error": error.localizedDescription])
                    self.scheduleReconnect()
                    return
                }
                self.socketReady = true
                self.reconnectAttempt = 0
                self.enqueue([
                    "type": "attach_observer",
                    "sessionId": self.sessionId,
                ])
                self.enqueue(["type": "list_workflows"])
                self.enqueue(["type": "get_token_metrics"])
                self.flushQueue()
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        socketReady = false
        isConnected = false
        isConnecting = false
        outboundQueue.removeAll()
    }

    func observeEvent(_ event: [String: Any]) {
        guard isConnected else { return }
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

    func refreshWorkflows() { send(["type": "list_workflows"]) }
    func requestTokenMetrics() { send(["type": "get_token_metrics"]) }

    func deleteAllWorkflows() {
        send(["type": "delete_all_workflows"])
    }

    func executeWorkflow(
        workflowId: String,
        params: [String: String] = [:],
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager
    ) {
        executeWebView = webView
        executeTabId = tabId
        executeWindowId = windowId
        executeBrowserManager = browserManager
        isExecuting = true
        send(["type": "execute_workflow", "workflowId": workflowId, "params": params])
    }

    private func resolveExecuteWebView() -> WKWebView? {
        if let tabId = executeTabId,
           let windowId = executeWindowId,
           let browserManager = executeBrowserManager,
           let live = browserManager.getWebView(for: tabId, in: windowId) {
            executeWebView = live
            return live
        }
        return executeWebView
    }

    private func clearExecutionTarget() {
        executeWebView = nil
        executeTabId = nil
        executeWindowId = nil
        executeBrowserManager = nil
    }

    func cancelExecution() {
        send(["type": "cancel_execute"])
        isExecuting = false
        clearExecutionTarget()
    }

    func exaSearch(query: String, timeoutSeconds: TimeInterval = 10, completion: @escaping (Result<String, Error>) -> Void) {
        guard isConnected else {
            completion(.failure(NSError(domain: "OpenHive", code: URLError.notConnectedToInternet.rawValue, userInfo: [NSLocalizedDescriptionKey: "Engine not connected"])))
            return
        }
        let requestId = UUID().uuidString
        pendingExaSearches[requestId] = completion
        send(["type": "exa_search", "requestId": requestId, "query": query])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if let pending = pendingExaSearches.removeValue(forKey: requestId) {
                pending(.failure(NSError(domain: "OpenHive", code: URLError.timedOut.rawValue, userInfo: [NSLocalizedDescriptionKey: "Exa search timed out"])))
            }
        }
    }

    func exaSearch(query: String, completion: @escaping (Result<String, Error>) -> Void) {
        exaSearch(query: query, timeoutSeconds: 10, completion: completion)
    }

    /// Run click/type/navigate in headed Playwright Chromium (real mouse + keyboard).
    func performAgentAction(
        pageURL: String?,
        action: [String: Any],
        timeoutSeconds: TimeInterval = 45
    ) async -> (success: Bool, detail: String, resultURL: String?) {
        guard isConnected else {
            return (false, "Engine not connected — run ./scripts/start_engine.sh", nil)
        }
        return await withCheckedContinuation { continuation in
            let requestId = UUID().uuidString
            pendingAgentActions[requestId] = continuation
            var payload: [String: Any] = [
                "type": "agent_action",
                "requestId": requestId,
                "action": action,
            ]
            if let pageURL, !pageURL.isEmpty { payload["url"] = pageURL }
            send(payload)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if let cont = pendingAgentActions.removeValue(forKey: requestId) {
                    cont.resume(returning: (false, "Playwright action timed out", nil))
                }
            }
        }
    }

    func relayLog(component: String, message: String, data: [String: Any]) {
        guard isConnected, socketReady else { return }
        var payload: [String: Any] = ["type": "client_log", "component": component, "message": message]
        if !data.isEmpty { payload["data"] = data }
        sendRaw(payload, allowQueue: false)
    }

    private func enqueue(_ dict: [String: Any]) {
        outboundQueue.append(dict)
    }

    private func flushQueue() {
        guard socketReady else { return }
        let batch = outboundQueue
        outboundQueue.removeAll()
        for msg in batch { sendRaw(msg, allowQueue: true) }
    }

    private func send(_ dict: [String: Any]) {
        if !socketReady {
            enqueue(dict)
            if !isConnecting { connect() }
            return
        }
        sendRaw(dict, allowQueue: true)
    }

    private func sendRaw(_ dict: [String: Any], allowQueue: Bool) {
        guard let ws = webSocket else {
            if allowQueue { enqueue(dict) }
            return
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else { return }

        ws.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    guard let self else { return }
                    if dict["type"] as? String == "exa_search",
                       let requestId = dict["requestId"] as? String,
                       let completion = self.pendingExaSearches.removeValue(forKey: requestId) {
                        completion(.failure(error))
                    }
                    // Do NOT reconnect on every send failure — receive/ping handles that
                    if self.isConnected {
                        self.isConnected = false
                        self.socketReady = false
                        self.connectionError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)) * 0.5)
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.reconnectTask = nil
            self.connect()
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
                    self.isConnected = false
                    self.socketReady = false
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
        case "observer_attached":
            isConnected = true
            connectionError = nil
            OpenHiveLogger.log("EngineBridge", "observer_attached", data: ["sessionId": sessionId])
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
        case "workflows_deleted":
            workflows = []
            if isExecuting {
                isExecuting = false
                executeWebView = nil
            }
            WorkflowManager.shared.onWorkflowsDeleted(count: json["count"] as? Int ?? 0)
        case "token_metrics", "run_metric":
            if type == "run_metric" {
                if let reward = json["reward"] as? Double {
                    hudReward = reward
                }
                TokenDashboardManager.shared.updateLiveRun(
                    tokens: json["tokens"] as? Int ?? 0,
                    elapsedMs: json["elapsedMs"] as? Int ?? 0,
                    tier: json["tier"] as? Int ?? 1,
                    reward: json["reward"] as? Double
                )
            }
            if let metrics = json["metrics"] as? [String: Any] {
                TokenDashboardManager.shared.update(from: metrics)
            } else if type == "run_metric" {
                TokenDashboardManager.shared.refresh()
            }
        case "execute_started":
            isExecuting = true
            lastActionDescription = nil
            executionProgress = "Starting…"
            hudReward = nil
            hudStatus = nil
            let backend = json["backend"] as? String ?? "webkit"
            if backend == "playwright" {
                executionProgress = "Playwright browser…"
            } else if let webView = resolveExecuteWebView() {
                await sendExecuteState(webView: webView)
            }
        case "execute_action":
            let backend = json["backend"] as? String ?? "webkit"
            if let action = json["action"] as? [String: Any] {
                let step = json["step"] as? Int ?? 0
                let total = json["total"] as? Int ?? 0
                if total > 0 {
                    executionProgress = backend == "playwright"
                        ? "Playwright \(step)/\(total)"
                        : "Step \(step)/\(total)"
                }
                let desc = describeAction(action)
                lastActionDescription = desc
                AgentExecutionState.shared.update(
                    label: desc,
                    tier: json["tier"] as? Int ?? 1
                )
            }
            guard backend != "playwright",
                  let webView = resolveExecuteWebView(),
                  let action = json["action"] as? [String: Any] else { break }
            OpenHiveObservation.inject(into: webView)
            let actionType = action["type"] as? String ?? ""
            var (ok, detail) = await BrowserToolExecutor.performWorkflowAction(action, on: webView)
            if !ok, actionType == "click", let retryView = resolveExecuteWebView() {
                try? await Task.sleep(nanoseconds: 900_000_000)
                let retry = await BrowserToolExecutor.performWorkflowAction(action, on: retryView)
                if retry.success {
                    ok = retry.success
                    detail = retry.detail
                }
            }
            if !ok {
                OpenHiveLogger.error("EngineBridge", "action_failed", data: ["action": action, "detail": detail])
            } else {
                OpenHiveLogger.log("EngineBridge", "action_ok", data: ["detail": detail])
            }
            let waitNs: UInt64
            switch actionType {
            case "navigate": waitNs = 3_000_000_000
            case "type", "fill": waitNs = 3_500_000_000
            default: waitNs = 1_500_000_000
            }
            try? await Task.sleep(nanoseconds: waitNs)
            await sendExecuteState(webView: webView, lastActionOk: ok, lastActionDetail: detail)
        case "execute_done":
            isExecuting = false
            clearExecutionTarget()
            executionProgress = nil
            lastActionDescription = nil
            connectionError = nil
            AgentExecutionState.shared.end()
            hudReward = json["reward"] as? Double
            hudStatus = json["hudStatus"] as? String
            WorkflowManager.shared.onExecuteDone(
                hudReward: hudReward,
                hudStatus: hudStatus,
                hudContent: json["hudContent"] as? String
            )
            requestTokenMetrics()
        case "execute_cancelled":
            isExecuting = false
            clearExecutionTarget()
            executionProgress = nil
            lastActionDescription = nil
        case "error":
            let msg = json["message"] as? String
            // Don't surface noisy log-relay errors during active runs
            if isExecuting, msg?.contains("log_event") == true { break }
            connectionError = msg
            if isExecuting {
                WorkflowManager.shared.lastError = msg
            }
        case "exa_search_result":
            if let requestId = json["requestId"] as? String,
               let completion = pendingExaSearches.removeValue(forKey: requestId) {
                if let err = json["error"] as? String {
                    completion(.failure(NSError(domain: "OpenHive", code: 1, userInfo: [NSLocalizedDescriptionKey: err])))
                } else {
                    completion(.success(json["answer"] as? String ?? ""))
                }
            }
        case "agent_action_result":
            if let requestId = json["requestId"] as? String,
               let continuation = pendingAgentActions.removeValue(forKey: requestId) {
                if let err = json["error"] as? String {
                    continuation.resume(returning: (false, err, json["url"] as? String))
                } else {
                    let ok = json["ok"] as? Bool ?? false
                    let detail = json["detail"] as? String ?? (ok ? "OK" : "Failed")
                    continuation.resume(returning: (ok, detail, json["url"] as? String))
                }
            }
        default:
            break
        }
    }

    private func sendExecuteState(webView: WKWebView, lastActionOk: Bool? = nil, lastActionDetail: String? = nil) async {
        let elements = await BrowserToolExecutor.interactiveElements(from: webView)
        let tree: [String: Any] = ["elements": elements, "count": elements.count]
        var payload: [String: Any] = [
            "type": "execute_state",
            "url": webView.url?.absoluteString ?? "",
            "title": webView.title ?? "",
            "accessibilityTree": tree,
        ]
        if let lastActionOk { payload["lastActionOk"] = lastActionOk }
        if let lastActionDetail { payload["lastActionDetail"] = lastActionDetail }
        send(payload)
    }

    private func describeAction(_ action: [String: Any]) -> String {
        let type = action["type"] as? String ?? "?"
        switch type {
        case "click":
            return "Click: \(action["text"] as? String ?? action["name"] as? String ?? "element")"
        case "type", "fill":
            let val = action["value"] as? String ?? action["text"] as? String ?? ""
            return "Type: \(val.prefix(40))"
        case "navigate":
            return "Go to: \((action["url"] as? String ?? "").prefix(50))"
        default:
            return type
        }
    }
}
