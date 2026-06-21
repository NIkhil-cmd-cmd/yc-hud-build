//
//  EngineBridge.swift
//  OpenHive (forked from Nook)
//
//  WebSocket bridge to python/engine.py — observation, workflow compile, metrics.
//

import Foundation
import OSLog

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

    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let sessionId = UUID().uuidString

    struct WorkflowSummary: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        var steps: Int
    }

    private init() {}

    func connect(port: Int = defaultPort) {
        guard webSocket == nil else { return }
        let url = URL(string: "ws://localhost:\(port)")!
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        isConnected = true
        receiveLoop()
        send(["type": "attach_observer", "sessionId": sessionId])
        send(["type": "list_workflows"])
        Self.log.info("EngineBridge connected to localhost:\(port)")
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
    }

    /// Forward user action from WKWebView / sidebar to Python observer (passive capture).
    func observeEvent(_ event: [String: Any]) {
        var payload = event
        payload["type"] = event["type"] ?? "click"
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

    private func send(_ dict: [String: Any]) {
        guard let ws = webSocket,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else { return }
        ws.send(.string(text)) { error in
            if let error {
                Self.log.error("send failed: \(error.localizedDescription)")
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
                        self.handleMessage(text)
                    }
                    self.receiveLoop()
                case .failure(let error):
                    Self.log.error("receive failed: \(error.localizedDescription)")
                    self.isConnected = false
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
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
                    guard let id = w["id"] as? String,
                          let name = w["name"] as? String
                    else { return nil }
                    return WorkflowSummary(
                        id: id,
                        name: name,
                        steps: w["steps"] as? Int ?? 0
                    )
                }
            }
        case "workflow_saved":
            refreshWorkflows()
        case "token_metrics":
            TokenDashboardManager.shared.update(from: json["metrics"] as? [String: Any] ?? [:])
        default:
            break
        }
    }
}
