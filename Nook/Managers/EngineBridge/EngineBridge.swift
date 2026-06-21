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

    weak var mcpManager: MCPManager?
    private(set) var mcpTools: [[String: Any]] = []

    func attachMCPManager(_ manager: MCPManager) {
        mcpManager = manager
        syncMcpTools(from: manager)
    }

    func syncMcpTools(from manager: MCPManager) {
        mcpTools = manager.exportToolsPayload()
        guard isConnected, !mcpTools.isEmpty else { return }
        send(["type": "mcp_tools_updated", "tools": mcpTools])
    }

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
    private var didSessionBootstrap = false
    private var executeWebView: WKWebView?
    private var executeTabId: UUID?
    private var executeWindowId: UUID?
    private weak var executeBrowserManager: BrowserManager?
    private var lastMirroredAgentURL: String?
    private var pendingExaSearches: [String: (Result<String, Error>) -> Void] = [:]
    private var pendingAgentActions: [String: CheckedContinuation<(success: Bool, detail: String, resultURL: String?), Never>] = [:]
    private var pendingWorkflowFetches: [String: CheckedContinuation<[String: Any]?, Never>] = [:]
    private var outboundQueue: [[String: Any]] = []
    private var socketReady = false
    private var isConnecting = false
    private var reconnectAttempt = 0
    private var activePlanId: String?
    private var activePlanSubtaskIndex: Int = 0

    struct WorkflowSummary: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        var steps: Int
        var category: String
        var tags: [String]
        var seeded: Bool

        init(
            id: String,
            name: String,
            steps: Int,
            category: String = "other",
            tags: [String] = [],
            seeded: Bool = false
        ) {
            self.id = id
            self.name = name
            self.steps = steps
            self.category = category
            self.tags = tags
            self.seeded = seeded
        }
    }

    struct SkillSummary: Identifiable, Equatable {
        var id: String
        var name: String
        var steps: Int
        var bucketId: String?
    }

    struct BucketSummary: Identifiable, Equatable {
        var id: String
        var label: String
        var skillIds: [String]
    }

    var skills: [SkillSummary] = []
    var buckets: [BucketSummary] = []
    var lastBenchmark: HUDBenchmarkResult = HUDBenchmarkResult()
    var pendingMatchPrompt: String?
    /// True when engine was started with OPENHIVE_USE_BROWSER_USE=1
    var browserUseEnabled = false
    /// In-tab agent available (LLM key configured) — runs in the current Nook WKWebView tab.
    var inTabAgentEnabled = false
    var engineReady = false
    var agentModel = "gpt-4o"
    var engineKeysConfigured = false
    /// Set when engine routes a first-run flight demo to learning mode.
    var flightDemoLearnPending = false
    /// Set when engine found a learned flight skill — auto-replay without confirm sheet.
    var flightDemoReplayMatch: SkillMatch?

    private init() {}

    func enqueueMigrateSkills() {
        guard !didSessionBootstrap else { return }
        send(["type": "migrate_skills"])
    }

    func refreshSkills() {
        send(["type": "list_skills"])
    }

    func refreshBuckets() {
        send(["type": "list_buckets"])
    }

    func matchTask(prompt: String) {
        pendingMatchPrompt = prompt
        send(["type": "match_task", "prompt": prompt])
    }

    func confirmRunSkill(
        skillId: String,
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
        send(["type": "confirm_run_skill", "skillId": skillId, "params": params])
    }

    func runNativeAgent(
        goal: String,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager
    ) {
        // In-tab agent: engine drives the current WKWebView (snapshot/@ref loop, no external Chrome).
        startAgentTask(
            goal: goal,
            webView: webView,
            tabId: tabId,
            windowId: windowId,
            browserManager: browserManager
        )
    }

    func startPlan(
        prompt: String,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager
    ) {
        executeWebView = webView
        executeTabId = tabId
        executeWindowId = windowId
        executeBrowserManager = browserManager
        activePlanId = nil
        activePlanSubtaskIndex = 0
        send(["type": "start_plan", "prompt": prompt])
    }

    func runSubtask(planId: String, index: Int) {
        send(["type": "run_subtask", "planId": planId, "index": index])
    }

    private func advancePlanAfterStep(success: Bool) {
        guard let planId = activePlanId else { return }
        let index = activePlanSubtaskIndex
        send([
            "type": "run_subtask",
            "planId": planId,
            "index": index,
            "markDone": true,
            "success": success,
        ])
        let runState = TaskRunState.shared
        let nextIndex = index + 1
        if nextIndex < runState.subtasks.count {
            activePlanSubtaskIndex = nextIndex
            runState.currentSubtaskIndex = nextIndex
            runSubtask(planId: planId, index: nextIndex)
        } else {
            activePlanId = nil
            runState.completeRun(success: success)
            WorkflowManager.postToast(success ? "Plan complete" : "Plan finished with errors", isError: !success)
        }
    }

    private func executeOrchestratorResolution(_ json: [String: Any]) {
        guard let resolution = json["resolution"] as? [String: Any],
              let planId = json["planId"] as? String,
              let index = json["index"] as? Int,
              let webView = resolveExecuteWebView(),
              let tabId = executeTabId,
              let windowId = executeWindowId,
              let browserManager = executeBrowserManager
        else { return }

        activePlanId = planId
        activePlanSubtaskIndex = index
        TaskRunState.shared.beginRun(skillName: nil, skillId: nil, tabId: tabId)

        let mode = resolution["mode"] as? String ?? "agent"
        if mode == "mdp", let skillId = resolution["skillId"] as? String {
            confirmRunSkill(
                skillId: skillId,
                webView: webView,
                tabId: tabId,
                windowId: windowId,
                browserManager: browserManager
            )
            return
        }

        var goal = resolution["goal"] as? String ?? TaskRunState.shared.prompt
        var startURL: String? = nil
        if let sub = json["subtask"] as? [String: Any],
           sub["type"] as? String == "navigate" {
            goal = sub["description"] as? String ?? "Open Google Flights"
            startURL = "https://www.google.com/travel/flights"
        }

        var taskPayload: [String: Any] = ["goal": goal]
        if let params = resolution["params"] as? [String: Any] {
            for (key, value) in params {
                taskPayload[key] = value
            }
        }

        startAgentTask(
            goal: goal,
            startURL: startURL,
            webView: webView,
            tabId: tabId,
            windowId: windowId,
            browserManager: browserManager,
            task: taskPayload
        )
    }

    func startHUDBenchmark(prompt: String? = nil, skillId: String? = nil, mode: String = "task") {
        lastBenchmark = HUDBenchmarkResult(isRunning: true, phase: "Native arm…")
        var payload: [String: Any] = ["type": "start_hud_benchmark", "mode": mode]
        if let prompt { payload["prompt"] = prompt }
        if let skillId { payload["skillId"] = skillId }
        send(payload)
    }

    func reinforceSkill(skillId: String, success: Bool = true) {
        send([
            "type": "reinforce_skill",
            "skillId": skillId,
            "sessionId": sessionId,
            "success": success,
        ])
    }

    func connect(port: Int = defaultPort) {
        guard !isConnecting else { return }
        if socketReady, let existing = webSocket, existing.state == .running {
            return
        }
        isConnecting = true
        socketReady = false
        isConnected = false
        reconnectTask?.cancel()
        // Preserve in-flight agent commands across reconnect — connect() used to wipe these.
        let preserved = outboundQueue.filter { Self.isCriticalOutbound($0) }
        if let old = webSocket {
            old.cancel(with: .normalClosure, reason: nil)
        }
        webSocket = nil
        outboundQueue = preserved

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
                self.enqueue(["type": "list_skills"])
                self.didSessionBootstrap = true
                self.enqueue(["type": "get_token_metrics"])
                self.flushQueue()
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        webSocket?.cancel(with: .normalClosure, reason: nil)
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

    func setAgentModelPreference(provider: String, model: String) {
        agentModel = model
        TaskRunState.shared.agentModel = "\(provider)/\(model)"
        send([
            "type": "set_agent_model",
            "provider": provider,
            "model": model,
        ])
    }

    private func agentModelPayload() -> [String: Any] {
        let option = TaskRunState.shared.selectedAgentModel
        return [
            "agentProvider": option.provider,
            "agentModel": option.model,
        ]
    }

    func fetchWorkflow(id: String, timeoutSeconds: TimeInterval = 8) async -> [String: Any]? {
        guard isConnected else { return nil }
        return await withCheckedContinuation { continuation in
            let requestId = UUID().uuidString
            pendingWorkflowFetches[requestId] = continuation
            send(["type": "get_workflow", "requestId": requestId, "workflowId": id])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if let cont = pendingWorkflowFetches.removeValue(forKey: requestId) {
                    cont.resume(returning: nil)
                }
            }
        }
    }

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
            // Dismiss common cookie/consent banners so clicks aren't blocked
            const dismiss = ['Accept','Accept all','Agree','I agree','Got it','OK','Close','Reject all'];
            for (const el of document.querySelectorAll('button, [role=button], a')) {
                const t = (el.innerText || el.getAttribute('aria-label') || '').trim();
                if (dismiss.some(d => t === d || t.startsWith(d))) {
                    try { el.click(); } catch (_) {}
                    break;
                }
            }
        })();
        """
        _ = try? await webView.evaluateJavaScript(script)
        await OpenHiveObservation.installAgentAutomation(on: webView)
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
        includeStartUrl: Bool = true,
        includeStorageState: Bool = true
    ) {
        isExecuting = true
        executionProgress = includeStorageState ? "Syncing cookies…" : "Starting…"
        trajectoryLastError = nil
        Task { @MainActor in
            let storage: [String: Any] = includeStorageState
                ? await OpenHiveBrowserSync.exportStorageState(from: webView)
                : ["cookies": [] as [[String: Any]], "origins": [] as [[String: Any]]]
            let pageURL = webView.url?.absoluteString ?? ""
            let pageTitle = webView.title ?? ""
            var payload = extra
            payload["type"] = type
            payload["pageUrl"] = pageURL
            payload["pageTitle"] = pageTitle
            payload["storageState"] = storage
            payload["maxSteps"] = 40
            if includeStartUrl {
                if let explicit = extra["startUrl"] as? String, !explicit.isEmpty {
                    payload["startUrl"] = explicit
                } else if !pageURL.isEmpty, !pageURL.hasPrefix("about:") {
                    payload["startUrl"] = pageURL
                } else {
                    payload["startUrl"] = "https://www.google.com"
                }
            }

            guard await waitForSocketReady(timeoutSeconds: 12) else {
                isExecuting = false
                clearExecutionTarget()
                TaskRunState.shared.phase = .idle
                let msg = connectionError ?? "Engine not connected — run ./scripts/start_engine.sh"
                trajectoryLastError = msg
                WorkflowManager.postToast(msg, isError: true)
                return
            }

            payload["requireBrowserUse"] = false
            if !mcpTools.isEmpty {
                payload["mcpTools"] = mcpTools
            }
            guard await sendCriticalAndWait(payload) else {
                isExecuting = false
                clearExecutionTarget()
                TaskRunState.shared.phase = .idle
                let msg = connectionError ?? "Could not deliver agent task to engine — retry after engine reconnects"
                trajectoryLastError = msg
                WorkflowManager.postToast(msg, isError: true)
                return
            }
            OpenHiveLogger.log("EngineBridge", "agent_payload_sent", data: ["type": type, "goal": extra["goal"] as? String ?? ""])
            executionProgress = "Agent starting in this tab…"
        }
    }

    /// Deliver agent payloads synchronously — fire-and-forget send() was losing messages on reconnect.
    private func sendCriticalAndWait(_ dict: [String: Any]) async -> Bool {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else {
            connectionError = "Invalid agent payload"
            return false
        }
        if data.count > 512_000 {
            connectionError = "Agent payload too large (\(data.count / 1024)KB)"
            return false
        }
        guard let ws = webSocket, socketReady else {
            connectionError = "Engine socket not ready"
            return false
        }
        return await withCheckedContinuation { continuation in
            ws.send(.string(text)) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.connectionError = error.localizedDescription
                        self?.socketReady = false
                        self?.isConnected = false
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(returning: true)
                    }
                }
            }
        }
    }

    /// Make the tab the agent is driving the visible, selected tab so the user
    /// watches each step live (not just the final state). Safe to call repeatedly.
    private func revealCompositorForAgentRun() {
        guard let tabId = executeTabId,
              let windowId = executeWindowId,
              let browserManager = executeBrowserManager,
              let windowState = browserManager.windowRegistry?.windows[windowId],
              let tab = browserManager.tabManager.allTabs().first(where: { $0.id == tabId })
        else { return }
        tab.isOpenHiveNewTab = false
        tab.openHiveWorkflowCatalog = false
        tab.openHiveGraphWorkflowId = nil
        // Mark this tab as the active run so showsOpenHiveAgentHome drops the
        // landing overlay for the whole run, across every entry point.
        TaskRunState.shared.activeTabId = tabId
        if browserManager.currentTab(for: windowState)?.id != tabId {
            browserManager.selectTab(tab, in: windowState)
        }
        browserManager.refreshCompositor(for: windowState)
    }

    /// Wait until WebSocket handshake completes before sending agent payloads.
    private func waitForSocketReady(timeoutSeconds: Double) async -> Bool {
        if socketReady { return true }
        if !isConnecting { connect() }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if socketReady { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return socketReady
    }

    private static func isCriticalOutbound(_ dict: [String: Any]) -> Bool {
        guard let type = dict["type"] as? String else { return false }
        switch type {
        case "start_agent", "run_agent", "start_trajectory", "execute_workflow",
             "confirm_run_skill", "cancel_trajectory", "cancel_execute":
            return true
        default:
            return false
        }
    }

    func cancelExecution() {
        send(["type": "cancel_execute"])
        isExecuting = false
        clearExecutionTarget()
    }

    func startFlightDemoLearn(
        route: FlightRoute,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager
    ) {
        startFlightTrajectory(
            route: route,
            webView: webView,
            tabId: tabId,
            windowId: windowId,
            browserManager: browserManager,
            flightDemoLearn: true
        )
    }

    func startFlightDemoReplay(
        route: FlightRoute,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager
    ) {
        startFlightTrajectory(
            route: route,
            webView: webView,
            tabId: tabId,
            windowId: windowId,
            browserManager: browserManager,
            flightDemoReplay: true
        )
    }

    private func startFlightTrajectory(
        route: FlightRoute,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager,
        flightDemoLearn: Bool = false,
        flightDemoReplay: Bool = false
    ) {
        startTrajectory(
            origin: route.origin,
            destination: route.destination,
            departDate: route.departDate,
            webView: webView,
            tabId: tabId,
            windowId: windowId,
            browserManager: browserManager,
            flightDemoLearn: flightDemoLearn,
            flightDemoReplay: flightDemoReplay
        )
    }

    func startTrajectory(
        origin: String,
        destination: String,
        departDate: String,
        webView: WKWebView,
        tabId: UUID,
        windowId: UUID,
        browserManager: BrowserManager,
        flightDemoLearn: Bool = false,
        flightDemoReplay: Bool = false
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
        isExecuting = true
        revealCompositorForAgentRun()
        sendBrowserUsePayload(
            type: "start_trajectory",
            webView: webView,
            extra: [
                "task": [
                    "origin": origin,
                    "destination": destination,
                    "departDate": departDate,
                    "flightDemoLearn": flightDemoLearn,
                    "flightDemoReplay": flightDemoReplay,
                ],
            ],
            includeStartUrl: false,
            includeStorageState: false
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
        browserManager: BrowserManager,
        task: [String: Any]? = nil
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
        revealCompositorForAgentRun()
        var extra: [String: Any] = [
            "goal": goal,
            "task": task ?? ["goal": goal],
        ]
        let modelFields = agentModelPayload()
        extra.merge(modelFields) { _, new in new }
        if var taskDict = extra["task"] as? [String: Any] {
            taskDict.merge(modelFields) { _, new in new }
            extra["task"] = taskDict
        }
        if let startURL, !startURL.isEmpty {
            extra["startUrl"] = startURL
        }
        sendBrowserUsePayload(
            type: "start_agent",
            webView: webView,
            extra: extra
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
            engineReady = true
            if let flag = json["browserUse"] as? Bool {
                browserUseEnabled = flag
            }
            if let flag = json["inTabAgent"] as? Bool {
                inTabAgentEnabled = flag
            } else {
                inTabAgentEnabled = engineReady && !browserUseEnabled
            }
            if let cfg = json["engineConfig"] as? [String: Any] {
                applyEngineConfig(cfg)
            }
            OpenHiveLogger.log("EngineBridge", "observer_attached", data: ["sessionId": sessionId, "browserUse": browserUseEnabled, "model": agentModel])
            if !mcpTools.isEmpty {
                send(["type": "mcp_tools_updated", "tools": mcpTools])
            }
        case "step_observed":
            observedStepCount = json["count"] as? Int ?? observedStepCount
        case "match_task_result":
            let runState = TaskRunState.shared
            if json["flightDemoLearn"] as? Bool == true {
                runState.phase = .idle
                flightDemoLearnPending = true
                break
            }
            if json["flightDemoReplay"] as? Bool == true,
               let best = json["bestSkill"] as? [String: Any],
               let skillId = best["skillId"] as? String,
               let name = best["name"] as? String {
                let confidence = best["confidence"] as? Double ?? 0.99
                let mdpId = best["mdpId"] as? String ?? skillId
                runState.phase = .idle
                flightDemoReplayMatch = SkillMatch(
                    skillId: skillId,
                    name: name,
                    confidence: confidence,
                    mdpId: mdpId
                )
                break
            }
            if let best = json["bestSkill"] as? [String: Any],
               let skillId = best["skillId"] as? String,
               let name = best["name"] as? String,
               json["meetsThreshold"] as? Bool == true {
                let confidence = best["confidence"] as? Double ?? 0
                let mdpId = best["mdpId"] as? String ?? skillId
                runState.presentConfirmation(SkillMatch(skillId: skillId, name: name, confidence: confidence, mdpId: mdpId))
            } else if runState.agentModeEnabled {
                if FlightDemoRouter.isFlightPrompt(runState.prompt) {
                    runState.phase = .idle
                } else {
                    runState.shouldRunAgentAfterMiss = true
                }
            } else {
                runState.phase = .idle
                WorkflowManager.postToast("No matching skill — enable Agent mode", isError: true)
            }
        case "flight_demo_saved":
            refreshSkills()
            if let msg = json["message"] as? String {
                WorkflowManager.postToast(msg, isError: false)
            }
        case "skills_list":
            if let raw = json["skills"] as? [[String: Any]] {
                skills = raw.compactMap { s in
                    guard let id = s["id"] as? String else { return nil }
                    return SkillSummary(
                        id: id,
                        name: s["name"] as? String ?? id,
                        steps: (s["stats"] as? [String: Any])?["runs"] as? Int ?? 0,
                        bucketId: s["bucketId"] as? String
                    )
                }
            }
        case "buckets_list":
            if let raw = json["buckets"] as? [[String: Any]] {
                buckets = raw.compactMap { b in
                    guard let id = b["id"] as? String else { return nil }
                    return BucketSummary(
                        id: id,
                        label: b["label"] as? String ?? id,
                        skillIds: b["skillIds"] as? [String] ?? []
                    )
                }
            }
        case "plan_created":
            let runState = TaskRunState.shared
            runState.planId = json["planId"] as? String
            if let subs = json["subtasks"] as? [[String: Any]] {
                runState.subtasks = subs.enumerated().compactMap { idx, st in
                    guard let type = st["type"] as? String else { return nil }
                    return PlanSubtask(
                        id: "\(idx)",
                        index: st["index"] as? Int ?? idx,
                        type: type,
                        description: st["description"] as? String ?? type,
                        status: st["status"] as? String ?? "pending"
                    )
                }
            }
            runState.phase = .planning
            if let tabId = executeTabId {
                runState.beginRun(skillName: "Plan", skillId: nil, tabId: tabId)
            }
            if let planId = runState.planId {
                activePlanId = planId
                activePlanSubtaskIndex = 0
                runState.currentSubtaskIndex = 0
                runSubtask(planId: planId, index: 0)
            }
        case "plan_progress":
            let runState = TaskRunState.shared
            if let subs = json["subtasks"] as? [[String: Any]] {
                runState.subtasks = subs.enumerated().compactMap { idx, st in
                    guard let type = st["type"] as? String else { return nil }
                    return PlanSubtask(
                        id: "\(idx)",
                        index: st["index"] as? Int ?? idx,
                        type: type,
                        description: st["description"] as? String ?? type,
                        status: st["status"] as? String ?? "pending"
                    )
                }
            }
            runState.currentSubtaskIndex = json["currentIndex"] as? Int ?? runState.currentSubtaskIndex
        case "orchestrator_step":
            let runState = TaskRunState.shared
            if let sub = json["subtask"] as? [String: Any] {
                runState.appendStep(sub["description"] as? String ?? "Subtask")
            }
            executeOrchestratorResolution(json)
        case "mdp_step":
            let runState = TaskRunState.shared
            let stateId = json["stateId"] as? String ?? ""
            let nextId = json["nextStateId"] as? String ?? ""
            let action = json["action"] as? String ?? "step"
            runState.handleMDPStep(stateId: stateId, nextStateId: nextId, action: action)
            AgentNotchPanelController.shared.reposition()
        case "benchmark_progress":
            var bench = lastBenchmark
            bench.isRunning = true
            if let phase = json["phase"] as? String {
                bench.phase = phase == "native" ? "Native arm…" : "HUD browser…"
            }
            if let result = json["result"] as? [String: Any], json["phase"] as? String == "native" {
                bench.nativeMs = result["elapsedMs"] as? Int ?? 0
                bench.nativeTokens = result["tokens"] as? Int ?? 0
                bench.nativeGrade = result["hudGrade"] as? Double ?? 0
            }
            if let result = json["result"] as? [String: Any], json["phase"] as? String == "hud" {
                bench.hudMs = result["elapsedMs"] as? Int ?? 0
                bench.hudTokens = result["tokens"] as? Int ?? 0
                bench.hudGrade = result["hudGrade"] as? Double ?? 0
            }
            lastBenchmark = bench
        case "benchmark_complete":
            var bench = HUDBenchmarkResult()
            bench.isRunning = false
            bench.runId = json["runId"] as? String
            if let comparison = json["comparison"] as? [String: Any] {
                bench.nativeMs = comparison["nativeMs"] as? Int ?? 0
                bench.hudMs = comparison["hudMs"] as? Int ?? 0
                bench.nativeTokens = comparison["nativeTokens"] as? Int ?? 0
                bench.hudTokens = comparison["hudTokens"] as? Int ?? 0
                bench.speedup = comparison["speedup"] as? Double ?? 1
            }
            if let native = json["native"] as? [String: Any] {
                bench.nativeGrade = native["hudGrade"] as? Double ?? 0
            }
            if let hud = json["hud"] as? [String: Any] {
                bench.hudGrade = hud["hudGrade"] as? Double ?? 0
            }
            lastBenchmark = bench
            TaskRunState.shared.lastBenchmarkRunId = bench.runId
        case "skill_reinforced":
            refreshSkills()
            WorkflowManager.postToast("Skill reinforced")
        case "skills_migrated":
            didSessionBootstrap = true
            refreshSkills()
            refreshBuckets()
        case "workflows_list":
            if let raw = json["workflows"] as? [[String: Any]] {
                workflows = raw.compactMap { w in
                    guard let id = w["id"] as? String, let name = w["name"] as? String else { return nil }
                    return WorkflowSummary(
                        id: id,
                        name: name,
                        steps: w["steps"] as? Int ?? 0,
                        category: w["category"] as? String ?? "other",
                        tags: w["tags"] as? [String] ?? [],
                        seeded: w["seeded"] as? Bool ?? false
                    )
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
        case "agent_progress":
            if let message = json["message"] as? String {
                executionProgress = message
            }
            revealCompositorForAgentRun()
        case "execute_started":
            isExecuting = true
            lastActionDescription = nil
            executionProgress = "Starting…"
            hudReward = nil
            hudStatus = nil
            revealCompositorForAgentRun()
            AgentNotchPanelController.shared.show()
            AgentNotchViewModel.shared.open()
            let backend = json["backend"] as? String ?? "webkit"
            if backend == "browser-use" {
                executionProgress = "External browser-use (Chromium)…"
                let cookies = json["cookiesSynced"] as? Int ?? 0
                let cookieNote = cookies > 0 ? " · \(cookies) cookies synced" : ""
                WorkflowManager.postToast("External browser-use — separate Chromium window\(cookieNote)")
            } else if backend == "playwright" {
                executionProgress = "Playwright browser…"
            } else {
                executionProgress = currentTrajectoryTask != nil
                    ? "Running flight workflow…"
                    : "Agent running in this tab…"
                // Trajectory sends its own navigate action first — don't race with execute_state.
                if currentTrajectoryTask == nil, let webView = resolveExecuteWebView() {
                    await installAutomationHooks(on: webView)
                    await sendExecuteState(webView: webView)
                }
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
            await installAutomationHooks(on: webView)
            OpenHiveObservation.inject(into: webView)
            let actionType = action["type"] as? String ?? ""
            var ok: Bool
            var detail: String

            if actionType == "mcp_call" {
                let namespace = action["server"] as? String ?? action["namespace"] as? String ?? ""
                let toolName = action["tool"] as? String ?? ""
                let args = action["arguments"] as? [String: Any] ?? action["args"] as? [String: Any] ?? [:]
                if let mcpManager {
                    do {
                        let result = try await mcpManager.callTool(namespace: namespace, name: toolName, arguments: args)
                        ok = true
                        detail = String(result.prefix(4000))
                    } catch {
                        ok = false
                        detail = "MCP \(namespace).\(toolName): \(error.localizedDescription)"
                    }
                } else {
                    ok = false
                    detail = "MCP manager not available — connect apps in agent home"
                }
            } else if NookBrowserController.isBrowserAction(actionType),
               let tabId = executeTabId,
               let windowId = executeWindowId,
               let browserManager = executeBrowserManager {
                let ctx = NookBrowserController.Context(
                    browserManager: browserManager,
                    windowId: windowId,
                    tabId: tabId
                )
                let result = await NookBrowserController.perform(action, context: ctx, webView: webView)
                ok = result.success
                detail = result.detail
                if let newTabId = result.newTabId {
                    executeTabId = newTabId
                    executeWebView = browserManager.ensureWebView(for: newTabId, in: windowId)
                    if let newView = executeWebView {
                        await installAutomationHooks(on: newView)
                    }
                }
            } else {
                var pageResult = await WebViewAutomation.perform(action, on: webView)
                ok = pageResult.success
                detail = pageResult.detail
                if !ok, actionType == "click", let retryView = resolveExecuteWebView() {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    pageResult = await WebViewAutomation.perform(action, on: retryView)
                    ok = pageResult.success
                    detail = pageResult.detail
                }
                if !ok, (actionType == "type" || actionType == "fill"), let retryView = resolveExecuteWebView() {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    pageResult = await WebViewAutomation.perform(action, on: retryView)
                    ok = pageResult.success
                    detail = pageResult.detail
                }
            }
            if !ok {
                OpenHiveLogger.error("EngineBridge", "action_failed", data: ["action": action, "detail": detail])
            } else {
                OpenHiveLogger.log("EngineBridge", "action_ok", data: ["detail": detail])
            }
            await WebViewAutomation.waitForSettle(on: webView, actionType: actionType == "wait" ? "click" : actionType)
            await sendExecuteState(webView: webView, lastActionOk: ok, lastActionDetail: detail)
        case "execute_done":
            let planWasActive = activePlanId != nil
            let planSuccess = json["hudStatus"] as? String != "partial"
            isExecuting = false
            if let webView = executeWebView {
                await removeAutomationHooks(on: webView)
            }
            if planWasActive {
                if TaskRunState.shared.isRecording {
                    compileWorkflow(name: TaskRunState.shared.prompt.prefix(40).description)
                }
                advancePlanAfterStep(success: planSuccess)
            } else {
                clearExecutionTarget()
                executionProgress = nil
                lastActionDescription = nil
                connectionError = nil
                AgentExecutionState.shared.end()
                TaskRunState.shared.completeRun(success: planSuccess)
                if TaskRunState.shared.isRecording {
                    compileWorkflow(name: TaskRunState.shared.prompt.prefix(40).description)
                }
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
            }
        case "agent_step":
            let step = json["step"] as? Int ?? trajectoryStepLog.count + 1
            let actionType = json["action"] as? String ?? "?"
            let mode = json["mode"] as? String ?? "agent"
            let prefix: String
            switch mode {
            case "learning": prefix = "Learn"
            case "replay": prefix = "Replay"
            default: prefix = "Agent"
            }
            TaskRunState.shared.appendStep("\(prefix): \(actionType)")
            if let model = json["model"] as? String {
                TaskRunState.shared.agentModel = model
                agentModel = model
            }
            AgentNotchPanelController.shared.reposition(animated: true)
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
            let success = json["success"] as? Bool ?? false
            if activePlanId != nil {
                if TaskRunState.shared.isRecording {
                    compileWorkflow(name: TaskRunState.shared.prompt.prefix(40).description)
                }
                advancePlanAfterStep(success: success)
            } else {
                TaskRunState.shared.completeRun(success: success)
                TaskRunState.shared.notchExpanded = true
                if TaskRunState.shared.isRecording {
                    compileWorkflow(name: TaskRunState.shared.prompt.prefix(40).description)
                }
            }
            AgentNotchPanelController.shared.reposition(animated: true)
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
            if activePlanId == nil {
                clearExecutionTarget()
            }
            executionProgress = nil
            let steps = json["steps"] as? Int ?? trajectoryStepLog.count
            if activePlanId == nil {
                if success {
                    WorkflowManager.postToast("Agent complete (\(steps) steps)")
                } else {
                    let reason = json["reason"] as? String ?? "failed"
                    trajectoryLastError = "Agent \(reason)"
                    WorkflowManager.postToast(trajectoryLastError ?? "Agent failed", isError: true)
                }
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
                TaskRunState.shared.phase = .idle
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
        case "workflow_loaded":
            if let requestId = json["requestId"] as? String,
               let continuation = pendingWorkflowFetches.removeValue(forKey: requestId) {
                if let workflow = json["workflow"] as? [String: Any] {
                    continuation.resume(returning: workflow)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        default:
            break
        }
    }

    private func sendExecuteState(webView: WKWebView, lastActionOk: Bool? = nil, lastActionDetail: String? = nil) async {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        async let candidatesTask = OpenHiveObservation.agentCandidates(from: webView)
        async let pageTextTask = BrowserToolExecutor.pageText(from: webView)
        let candidates = await candidatesTask
        let pageText = await pageTextTask
        let tree: [String: Any] = [
            "elements": candidates,
            "count": candidates.count,
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

    private func applyEngineConfig(_ cfg: [String: Any]) {
        if let model = cfg["agentModel"] as? String {
            agentModel = model
            TaskRunState.shared.agentModel = model
        }
        if let bu = cfg["browserUse"] as? Bool {
            browserUseEnabled = bu
        }
        if let tab = cfg["inTabAgent"] as? Bool {
            inTabAgentEnabled = tab
        }
        if let keys = cfg["keys"] as? [String: Bool] {
            engineKeysConfigured = keys["OPENAI_API_KEY"] == true
        }
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
        case "search":
            return "Search: \((action["value"] as? String ?? action["query"] as? String ?? "").prefix(50))"
        case "new_tab":
            return "New tab: \((action["url"] as? String ?? "blank").prefix(50))"
        case "scroll":
            return "Scroll: \(action["value"] as? String ?? action["direction"] as? String ?? "down")"
        case "mcp_call":
            let server = action["server"] as? String ?? action["namespace"] as? String ?? "?"
            let tool = action["tool"] as? String ?? "?"
            return "MCP \(server).\(tool)"
        case "click_option":
            return "Pick option: \((action["value"] as? String ?? "").prefix(40))"
        case "extract":
            return "Extract text"
        case "hover":
            return "Hover: \(action["ref"] as? String ?? "?")"
        case "check", "uncheck":
            return "\(type == "check" ? "Check" : "Uncheck"): \(action["ref"] as? String ?? "?")"
        case "switch_tab":
            return "Switch tab: \(action["value"] as? String ?? "?")"
        case "close_tab":
            return "Close tab"
        case "go_back", "go_forward", "reload":
            return type.replacingOccurrences(of: "_", with: " ").capitalized
        default:
            return type
        }
    }
}
