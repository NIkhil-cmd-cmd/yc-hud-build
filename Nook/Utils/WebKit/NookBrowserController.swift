import Foundation
import WebKit

/// Browser-level agent actions — tabs, search, navigation — using Nook APIs (not external Chrome).
@MainActor
enum NookBrowserController {
    struct Context {
        weak var browserManager: BrowserManager?
        var windowId: UUID
        var tabId: UUID
    }

    /// Actions routed through Nook chrome / WKWebView navigation APIs.
    static func isBrowserAction(_ type: String) -> Bool {
        switch type {
        case "new_tab", "search", "go_back", "go_forward", "reload", "switch_tab", "close_tab":
            return true
        default:
            return false
        }
    }

    static func perform(
        _ action: [String: Any],
        context: Context,
        webView: WKWebView
    ) async -> (success: Bool, detail: String, newTabId: UUID?) {
        guard let type = action["type"] as? String else {
            return (false, "Missing action type", nil)
        }

        switch type {
        case "new_tab":
            return await newTab(action, context: context)
        case "search":
            return search(action, on: webView)
        case "go_back":
            if webView.canGoBack { webView.goBack() } else { return (false, "Cannot go back", nil) }
            return (true, "Back", nil)
        case "go_forward":
            if webView.canGoForward { webView.goForward() } else { return (false, "Cannot go forward", nil) }
            return (true, "Forward", nil)
        case "reload":
            webView.reload()
            return (true, "Reload", nil)
        case "switch_tab":
            return switchTab(action, context: context)
        case "close_tab":
            return closeTab(action, context: context)
        default:
            return (false, "Unknown browser action: \(type)", nil)
        }
    }

    private static func newTab(_ action: [String: Any], context: Context) async -> (success: Bool, detail: String, newTabId: UUID?) {
        guard let browserManager = context.browserManager,
              let windowState = browserManager.windowRegistry?.windows[context.windowId]
        else {
            return (false, "No browser window for new_tab", nil)
        }

        let url = (action["url"] as? String ?? action["value"] as? String ?? "about:blank").trimmingCharacters(in: .whitespacesAndNewlines)
        browserManager.createNewTab(in: windowState, url: url.isEmpty ? "about:blank" : url)

        guard let tab = browserManager.currentTab(for: windowState) else {
            return (false, "new_tab failed", nil)
        }

        tab.isOpenHiveNewTab = false
        browserManager.refreshCompositor(for: windowState)
        _ = browserManager.ensureWebView(for: tab.id, in: context.windowId)

        let label = url.isEmpty || url.hasPrefix("about:") ? "New tab" : url
        return (true, "Opened tab: \(label.prefix(80))", tab.id)
    }

    static func search(_ action: [String: Any], on webView: WKWebView) -> (success: Bool, detail: String, newTabId: UUID?) {
        let query = (action["value"] as? String ?? action["query"] as? String ?? action["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return (false, "search requires query", nil) }

        let lower = query.lowercased()
        let urlString: String
        if lower.contains("youtube") || lower.hasPrefix("yt ") {
            let q = query
                .replacingOccurrences(of: "youtube", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "search", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            urlString = "https://www.youtube.com/results?search_query=\(encoded)"
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            urlString = query
        } else {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            urlString = "https://www.google.com/search?q=\(encoded)"
        }

        guard let url = URL(string: urlString) else { return (false, "Invalid search URL", nil) }
        webView.load(URLRequest(url: url))
        return (true, "Search: \(query.prefix(60))", nil)
    }

    private static func switchTab(_ action: [String: Any], context: Context) -> (success: Bool, detail: String, newTabId: UUID?) {
        guard let browserManager = context.browserManager,
              let windowState = browserManager.windowRegistry?.windows[context.windowId]
        else {
            return (false, "No window for switch_tab", nil)
        }

        let tabs = browserManager.tabsForDisplay(in: windowState)
        guard !tabs.isEmpty else { return (false, "No tabs", nil) }

        let index: Int? = {
            if let i = action["index"] as? Int { return i }
            if let s = action["value"] as? String, let i = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "tT"))) { return i }
            if let s = action["value"] as? String, let i = Int(s) { return i }
            return nil
        }()

        let tab: Tab?
        if let index, tabs.indices.contains(index) {
            tab = tabs[index]
        } else if let title = action["title"] as? String ?? action["text"] as? String {
            tab = tabs.first {
                let label = $0.name + ($0.url.absoluteString)
                return label.localizedCaseInsensitiveContains(title)
            }
        } else {
            tab = tabs.first
        }

        guard let tab else { return (false, "Tab not found", nil) }
        browserManager.selectTab(tab, in: windowState)
        tab.isOpenHiveNewTab = false
        browserManager.refreshCompositor(for: windowState)
        _ = browserManager.ensureWebView(for: tab.id, in: context.windowId)
        return (true, "Switched to tab: \(tab.name.prefix(40))", tab.id)
    }

    private static func closeTab(_ action: [String: Any], context: Context) -> (success: Bool, detail: String, newTabId: UUID?) {
        guard let browserManager = context.browserManager,
              let windowState = browserManager.windowRegistry?.windows[context.windowId]
        else {
            return (false, "No window for close_tab", nil)
        }

        let closeId: UUID = {
            if let s = action["tabId"] as? String, let id = UUID(uuidString: s) { return id }
            return context.tabId
        }()

        browserManager.tabManager.removeTab(closeId)

        guard let tab = browserManager.currentTab(for: windowState) else {
            return (true, "Closed tab", nil)
        }
        _ = browserManager.ensureWebView(for: tab.id, in: context.windowId)
        return (true, "Closed tab · now on \(tab.name.prefix(30))", tab.id)
    }
}
