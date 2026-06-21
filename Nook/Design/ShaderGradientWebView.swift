//
//  ShaderGradientWebView.swift
//  Bundled @shadergradient/react WebGL background (same renderer as Tera website)
//

import SwiftUI
import WebKit

struct ShaderGradientWebView: NSViewRepresentable {
    let gradientURL: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.pendingGradientURL = gradientURL
        context.coordinator.loadHostPageIfNeeded()

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyGradient(gradientURL)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingGradientURL: String?
        private var appliedGradientURL: String?
        private var hostDidLoad = false

        func loadHostPageIfNeeded() {
            guard let webView, !hostDidLoad else { return }

            guard let htmlURL = Bundle.main.url(
                forResource: "shader-gradient",
                withExtension: "html"
            ),
            let resourceURL = Bundle.main.resourceURL else {
                return
            }

            webView.loadFileURL(htmlURL, allowingReadAccessTo: resourceURL)
        }

        func applyGradient(_ urlString: String) {
            pendingGradientURL = urlString
            guard hostDidLoad else { return }
            guard urlString != appliedGradientURL else { return }

            guard let webView,
                  let json = Self.jsonStringLiteral(for: urlString) else { return }

            let script = "window.setGradientURL && window.setGradientURL(\(json))"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard error == nil else { return }
                self?.appliedGradientURL = urlString
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hostDidLoad = true
            if let pendingGradientURL {
                appliedGradientURL = nil
                applyGradient(pendingGradientURL)
            }
        }

        private static func jsonStringLiteral(for value: String) -> String? {
            // JSONSerialization rejects a top-level String and throws an ObjC
            // NSException (which `try?` cannot catch) — use JSONEncoder, which
            // encodes a top-level string and throws a catchable Swift error.
            guard let data = try? JSONEncoder().encode(value),
                  let literal = String(data: data, encoding: .utf8) else { return nil }
            return literal
        }
    }
}
