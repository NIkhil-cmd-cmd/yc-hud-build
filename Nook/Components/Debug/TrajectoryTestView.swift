//
//  TrajectoryTestView.swift
//  OpenHive
//
//  Test view for running multi-step trajectories via EngineBridge.
//

import SwiftUI
import WebKit

struct TrajectoryTestView: View {
    @StateObject private var bridge = EngineBridge.shared
    @State private var webView = WKWebView()
    @State private var showWebView = true

    let testTasks = [
        ("BOS", "LAX", "2026-07-15"),
        ("SFO", "JFK", "2026-08-12"),
        ("SEA", "DEN", "2026-09-09"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            statusBar

            // WebView
            if showWebView {
                WebViewContainer(webView: $webView, bridge: bridge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Step log
            stepLog
                .frame(height: 200)

            Divider()

            // Controls
            controls
                .padding()
        }
        .onAppear {
            bridge.webView = webView
        }
    }

    private var statusBar: some View {
        HStack {
            // Connection status
            Circle()
                .fill(bridge.connected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            Text(bridge.connected ? "Connected" : "Disconnected")
                .font(.caption)

            Spacer()

            // Current task
            if let task = bridge.currentTask {
                Text("\(task.origin) → \(task.destination)")
                    .font(.caption.monospaced())
            }

            Spacer()

            // Step count
            Text("\(bridge.stepLog.count) steps")
                .font(.caption.monospaced())

            // Toggle webview
            Button(showWebView ? "Hide Browser" : "Show Browser") {
                showWebView.toggle()
            }
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var stepLog: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(bridge.stepLog) { step in
                        HStack {
                            Text("\(step.index)")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)

                            Text(step.actionType)
                                .font(.caption.monospaced())
                                .frame(width: 80, alignment: .leading)

                            Text(step.url)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundColor(.secondary)

                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .id(step.id)
                    }
                }
                .onChange(of: bridge.stepLog.count) { _ in
                    if let last = bridge.stepLog.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            // Connection
            HStack {
                Button(bridge.connected ? "Disconnect" : "Connect") {
                    if bridge.connected {
                        bridge.disconnect()
                    } else {
                        bridge.connect()
                    }
                }

                Button("Clear Log") {
                    bridge.stepLog.removeAll()
                }

                Spacer()
            }

            Divider()

            // Quick test tasks
            Text("Quick Tests:")
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(testTasks.enumerated()), id: \.offset) { index, task in
                    Button("\(task.0) → \(task.1)") {
                        runTask(origin: task.0, destination: task.1, date: task.2)
                    }
                    .disabled(!bridge.connected || bridge.currentTask != nil)
                }
            }

            if let error = bridge.lastError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func runTask(origin: String, destination: String, date: String) {
        guard bridge.connected else { return }

        // Clear previous state
        bridge.stepLog.removeAll()

        // Execute
        bridge.executeTask(origin: origin, destination: destination, date: date)
    }
}

/// WebView container that attaches to EngineBridge
struct WebViewContainer: NSViewRepresentable {
    @Binding var webView: WKWebView
    let bridge: EngineBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator

        DispatchQueue.main.async {
            webView = wv
            bridge.webView = wv
        }

        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[WebView] Navigation finished: \(webView.url?.absoluteString ?? "")")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[WebView] Navigation failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    TrajectoryTestView()
        .frame(width: 1200, height: 800)
}
