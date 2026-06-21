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

    struct TrajectoryStepLog: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        let actionType: String
        let url: String
    }

    struct TrajectoryTask: Equatable {
        let origin: String
        let destination: String
        let departDate: String
    }

    var trajectoryStepLog: [TrajectoryStepLog] = []
    var currentTrajectoryTask: TrajectoryTask?
    var trajectoryLastError: String?

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
    private var lastMirroredAgentURL: String?
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

    func shouldCapturePopup(for tabId: UUID) -> Bool {
        isExecuting && executeTabId == tabId
    }

    func installAutomationHooks(on webView: WKWebView) async {
        let script = """
        (function() {
            if (window.__nookAutomation) return;
            window.__nookAutomation = true;
            const origOpen = window.open;
            window.open = function(url, target, features) {
                if (url && typeof url === 'string' && url !== 'about:blank') {
                    window.location.href = url;
                    return window;
                }
                return origOpen ? origOpen.call(window, url, target, features) : null;
            };
        })();
        """
        _ = try? await webView.evaluateJavaScript(script)
    }

    func removeAutomationHooks(on webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("window.__nookAutomation = false;")
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
        lastMirroredAgentURL = nil
    }

    private func sendBrowserUsePayload(
        type: String,
        webView: WKWebView,
        extra: [String: Any],
        includeStartUrl: Bool = true
    ) {
        isExecuting = true
        executionProgress = "Syncing cookies…"
        trajectoryLastError = nil
        Task { @MainActor in
            let storage = await OpenHiveBrowserSync.exportStorageState(from: webView)
            let pageURL = webView.url?.absoluteString ?? ""
            let pageTitle = webView.title ?? ""
            var payload = extra
            payload["type"] = type
            payload["pageUrl"] = pageURL
            payload["pageTitle"] = pageTitle
            payload["storageState"] = storage
            payload["maxSteps"] = 40
            if includeStartUrl, !pageURL.isEmpty, !pageURL.hasPrefix("about:") {
                payload["startUrl"] = pageURL
            }
            guard send(payload) else {
                isExecuting = false
                clearExecutionTarget()
                let msg = connectionError ?? "Could not start agent — payload too large or engine disconnected"
                trajectoryLastError = msg
                WorkflowManager.postToast(msg, isError: true)
                return
            }
            executionProgress = "browser-use starting…"
        }
    }

    func cancelExecution() {
        send(["type": "cancel_execute"])
        isExecuting = false
        clearExecutionTarget()
    }

    func startTrajectory(
        origin: String,
        destination: String,
        departDate: String,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager
    ) {
        guard !isExecuting else {
            trajectoryLastError = "Cancel the running workflow first"
            return
        }
        executeWebView = webView
        executeTabId = tabId
        executeWindowId = windowId
        executeBrowserManager = browserManager
        trajectoryStepLog.removeAll()
        trajectoryLastError = nil
        currentTrajectoryTask = TrajectoryTask(origin: origin, destination: destination, departDate: departDate)
        sendBrowserUsePayload(
            type: "start_trajectory",
            webView: webView,
            extra: [
                "task": [
                    "origin": origin,
                    "destination": destination,
                    "departDate": departDate,
                ],
            ],
            includeStartUrl: false
        )
    }

    func cancelTrajectory() {
        send(["type": "cancel_trajectory"])
        currentTrajectoryTask = nil
        isExecuting = false
        clearExecutionTarget()
    }

    func startAgentTask(
        goal: String,
        startURL: String? = nil,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager
    ) {
        guard !isExecuting else {
            trajectoryLastError = "Cancel the running agent first"
            return
        }
        executeWebView = webView
        executeTabId = tabId
        executeWindowId = windowId
        executeBrowserManager = browserManager
        trajectoryStepLog.removeAll()
        trajectoryLastError = nil
        currentTrajectoryTask = nil
        sendBrowserUsePayload(
            type: "start_agent",
            webView: webView,
            extra: [
                "goal": goal,
                "task": ["goal": goal],
            ]
        )
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

    @discardableResult
    private func send(_ dict: [String: Any]) -> Bool {
        if !socketReady {
            enqueue(dict)
            if !isConnecting { connect() }
            return true
        }
        return sendRaw(dict, allowQueue: true)
    }

    @discardableResult
    private func sendRaw(_ dict: [String: Any], allowQueue: Bool) -> Bool {
        guard let ws = webSocket else {
            if allowQueue { enqueue(dict) }
            connectionError = "Engine not connected"
            return false
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else {
            connectionError = "Invalid agent payload (try fewer cookies — use a focused tab)"
            return false
        }
        if data.count > 512_000 {
            connectionError = "Agent payload too large (\(data.count / 1024)KB) — open the target site in one tab first"
            return false
        }

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
        return true
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
            if let wf = json["workflow"] as? [String: Any],
               let name = wf["name"] as? String,
               let steps = wf["steps"] as? Int {
                WorkflowManager.shared.compileMessage = "Saved \"\(name)\" (\(steps) steps)"
            } else {
                WorkflowManager.shared.compileMessage = "Workflow saved"
            }
            WorkflowManager.shared.lastError = nil
            WorkflowManager.postToast(WorkflowManager.shared.compileMessage ?? "Workflow saved")
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
            if backend == "browser-use" {
                executionProgress = "browser-use agent (Chromium)…"
                let cookies = json["cookiesSynced"] as? Int ?? 0
                let cookieNote = cookies > 0 ? " · \(cookies) cookies synced" : ""
                WorkflowManager.postToast("browser-use running — Nook tab mirrors agent\(cookieNote)")
            } else if backend == "playwright" {
                executionProgress = "Playwright browser…"
            } else if let webView = resolveExecuteWebView() {
                await installAutomationHooks(on: webView)
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
                if currentTrajectoryTask != nil {
                    trajectoryStepLog.append(
                        TrajectoryStepLog(
                            index: step,
                            actionType: action["type"] as? String ?? "?",
                            url: resolveExecuteWebView()?.url?.absoluteString ?? ""
                        )
                    )
                }
            }
            guard backend != "playwright",
                  let webView = resolveExecuteWebView(),
                  let action = json["action"] as? [String: Any] else { break }
            OpenHiveObservation.inject(into: webView)
            let actionType = action["type"] as? String ?? ""
            var (ok, detail) = await WebViewAutomation.perform(action, on: webView)
            if !ok, actionType == "click", let retryView = resolveExecuteWebView() {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let retry = await WebViewAutomation.perform(action, on: retryView)
                ok = retry.success
                detail = retry.detail
            }
            if !ok {
                OpenHiveLogger.error("EngineBridge", "action_failed", data: ["action": action, "detail": detail])
            } else {
                OpenHiveLogger.log("EngineBridge", "action_ok", data: ["detail": detail])
            }
            await WebViewAutomation.waitForSettle(on: webView, actionType: actionType)
            await sendExecuteState(webView: webView, lastActionOk: ok, lastActionDetail: detail)
        case "execute_done":
            isExecuting = false
            if let webView = executeWebView {
                await removeAutomationHooks(on: webView)
            }
            clearExecutionTarget()
            executionProgress = nil
            lastActionDescription = nil
            connectionError = nil
            AgentExecutionState.shared.end()
            hudReward = json["reward"] as? Double
            hudStatus = json["hudStatus"] as? String
            if currentTrajectoryTask != nil {
                currentTrajectoryTask = nil
            } else {
                WorkflowManager.shared.onExecuteDone(
                    hudReward: hudReward,
                    hudStatus: hudStatus,
                    hudContent: json["hudContent"] as? String
                )
            }
            requestTokenMetrics()
        case "agent_step":
            let step = json["step"] as? Int ?? trajectoryStepLog.count + 1
            let actionType = json["action"] as? String ?? "?"
            let provider = json["provider"] as? String ?? "llm"
            let model = json["model"] as? String
            let stepURL = json["url"] as? String ?? ""
            let label = model.map { "\(provider)/\($0)" } ?? provider
            lastActionDescription = "[\(label)] \(actionType)"
            executionProgress = "Agent step \(step): \(actionType)"
            if json["mirrorUrl"] as? Bool == true,
               let webView = resolveExecuteWebView(),
               !stepURL.isEmpty {
                OpenHiveBrowserSync.mirrorURLIfNeeded(
                    stepURL,
                    on: webView,
                    lastMirrored: &lastMirroredAgentURL,
                    force: false
                )
            }
            trajectoryStepLog.append(
                TrajectoryStepLog(
                    index: step,
                    actionType: "\(actionType) (\(provider))",
                    url: stepURL.isEmpty ? (resolveExecuteWebView()?.url?.absoluteString ?? "") : stepURL
                )
            )
        case "trajectory_complete":
            currentTrajectoryTask = nil
            isExecuting = false
            if let finalURL = json["finalUrl"] as? String,
               json["mirrorUrl"] as? Bool == true,
               let webView = resolveExecuteWebView(),
               !finalURL.isEmpty {
                OpenHiveBrowserSync.mirrorURLIfNeeded(
                    finalURL,
                    on: webView,
                    lastMirrored: &lastMirroredAgentURL,
                    force: true
                )
            }
            clearExecutionTarget()
            executionProgress = nil
            let success = json["success"] as? Bool ?? false
            let steps = json["steps"] as? Int ?? trajectoryStepLog.count
            if success {
                WorkflowManager.postToast("Trajectory complete (\(steps) steps)")
            } else {
                let reason = json["reason"] as? String ?? "failed"
                trajectoryLastError = "Trajectory \(reason)"
                WorkflowManager.postToast(trajectoryLastError ?? "Trajectory failed", isError: true)
            }
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
                isExecuting = false
                clearExecutionTarget()
                WorkflowManager.shared.lastError = msg
                WorkflowManager.postToast(msg ?? "Engine error", isError: true)
            } else if currentTrajectoryTask != nil {
                trajectoryLastError = msg
                currentTrajectoryTask = nil
                WorkflowManager.postToast(msg ?? "Trajectory error", isError: true)
            } else {
                WorkflowManager.shared.lastError = msg
                WorkflowManager.postToast(msg ?? "Engine error", isError: true)
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
        async let elementsTask = BrowserToolExecutor.interactiveElements(from: webView)
        async let candidatesTask = BrowserToolExecutor.trajectoryCandidates(from: webView)
        async let pageTextTask = BrowserToolExecutor.pageText(from: webView)
        let elements = await elementsTask
        let candidates = await candidatesTask
        let pageText = await pageTextTask
        let tree: [String: Any] = [
            "elements": elements,
            "count": elements.count,
            "candidates": candidates,
        ]
        var payload: [String: Any] = [
            "type": "execute_state",
            "url": webView.url?.absoluteString ?? "",
            "title": webView.title ?? "",
            "accessibilityTree": tree,
            "candidates": candidates,
            "pageText": pageText,
        ]
        if let lastActionOk { payload["lastActionOk"] = lastActionOk }
        if let lastActionDetail { payload["lastActionDetail"] = lastActionDetail }
        send(payload)
    }

    private func describeAction(_ action: [String: Any]) -> String {
        let type = action["type"] as? String ?? "?"
        switch type {
        case "click":
            if let ref = action["ref"] as? String, !ref.isEmpty {
                return "Click: \(ref)"
            }
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
