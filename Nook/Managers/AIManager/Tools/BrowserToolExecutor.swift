//
//  BrowserToolExecutor.swift
//  Nook
//
//  Executes browser tool calls using BrowserManager and WebView APIs
//

import Foundation
import OSLog
import WebKit

/// JSON-encode a Swift String for safe embedding in JavaScript (JSONSerialization cannot encode bare strings).
private func jsStringLiteral(_ value: String) -> String {
    if let data = try? JSONEncoder().encode(value),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

@MainActor
class BrowserToolExecutor {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "BrowserToolExecutor")

    weak var browserManager: BrowserManager?
    weak var windowState: BrowserWindowState?

    init(browserManager: BrowserManager? = nil, windowState: BrowserWindowState? = nil) {
        self.browserManager = browserManager
        self.windowState = windowState
    }

    // MARK: - Tool Definitions

    func availableToolDefinitions(enabledTools: Set<String>) -> [AIToolDefinition] {
        BrowserTools.allTools.filter { enabledTools.contains($0.name) }
    }

    /// Callback for requesting user confirmation before executing dangerous tools.
    /// Set by AIService to route through the standard approval UI.
    var confirmationHandler: ((_ toolName: String, _ args: [String: Any]) async -> Bool)?

    // MARK: - Execute Tool Call

    func execute(_ toolCall: AIToolCall) async throws -> AIToolResult {
        guard let browserManager = browserManager,
              let windowState = windowState else {
            return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "Browser not available", isError: true)
        }

        // SECURITY: executeJavaScript ALWAYS requires user confirmation regardless of execution mode,
        // because it can run arbitrary code on the current page.
        if toolCall.name == "executeJavaScript" {
            if let handler = confirmationHandler {
                let approved = await handler(toolCall.name, toolCall.arguments)
                if !approved {
                    Self.log.warning("User denied executeJavaScript execution")
                    return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "User denied execution of executeJavaScript.", isError: true)
                }
            } else {
                Self.log.error("executeJavaScript called without a confirmation handler — denying by default")
                return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "executeJavaScript requires user confirmation but no confirmation handler is available.", isError: true)
            }
        }

        let result: String

        switch toolCall.name {
        case "navigateToURL":
            result = try await executeNavigateToURL(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "readPageContent":
            result = try await executeReadPageContent(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "clickElement":
            result = try await executeClickElement(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "getInteractiveElements":
            result = try await executeGetInteractiveElements(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "extractStructuredData":
            result = try await executeExtractStructuredData(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "summarizePage":
            result = try await executeSummarizePage(browserManager: browserManager, windowState: windowState)
        case "searchInPage":
            result = try await executeSearchInPage(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "getTabList":
            result = executeGetTabList(browserManager: browserManager, windowState: windowState)
        case "switchTab":
            result = try executeSwitchTab(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "createTab":
            result = try executeCreateTab(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "getSelectedText":
            result = try await executeGetSelectedText(browserManager: browserManager, windowState: windowState)
        case "executeJavaScript":
            result = try await executeJavaScript(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        default:
            return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "Unknown tool: \(toolCall.name)", isError: true)
        }

        return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: result)
    }

    // MARK: - Tool Implementations

    private func getWebView(browserManager: BrowserManager, windowState: BrowserWindowState) -> WKWebView? {
        guard let currentTab = browserManager.currentTab(for: windowState) else { return nil }
        return browserManager.getWebView(for: currentTab.id, in: windowState.id)
    }

    private func executeNavigateToURL(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
            return "Invalid URL"
        }

        let newTab = args["newTab"] as? Bool ?? false

        if newTab {
            browserManager.createNewTab(in: windowState)
            // Give the new tab a moment to initialize
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let request = URLRequest(url: url)
        webView.load(request)

        return "Navigated to \(urlString)\(newTab ? " in new tab" : "")"
    }

    private func executeReadPageContent(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let maxLength = args["maxLength"] as? Int ?? 8000
        let selector = args["selector"] as? String

        let script: String
        if let selector = selector {
            let selectorJSON = jsStringLiteral(selector)
            script = """
            (function() {
                const el = document.querySelector(\(selectorJSON));
                if (!el) return { error: 'Element not found' };
                return {
                    title: document.title,
                    url: window.location.href,
                    content: el.innerText.substring(0, \(maxLength))
                };
            })();
            """
        } else {
            script = """
            (function() {
                const clone = document.body.cloneNode(true);
                clone.querySelectorAll('script, style, noscript').forEach(el => el.remove());
                let text = clone.innerText || clone.textContent || '';
                text = text.replace(/\\s+/g, ' ').trim();
                if (text.length > \(maxLength)) text = text.substring(0, \(maxLength)) + '...';
                return { title: document.title, url: window.location.href, content: text };
            })();
            """
        }

        let result = try await webView.evaluateJavaScript(script)
        if let dict = result as? [String: Any] {
            if let error = dict["error"] as? String {
                return "Error: \(error)"
            }
            let title = dict["title"] as? String ?? ""
            let url = dict["url"] as? String ?? ""
            let content = dict["content"] as? String ?? ""
            return "Title: \(title)\nURL: \(url)\n\n\(content)"
        }

        return "Failed to read page content"
    }

    private func executeClickElement(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        // Support clicking by CSS selector OR by visible text
        if let selector = args["selector"] as? String, !selector.isEmpty {
            let selectorJSON = jsStringLiteral(selector)
            let script = """
            (function() {
                const sel = \(selectorJSON);
                const el = document.querySelector(sel);
                if (!el) return 'Element not found: ' + sel;
                el.scrollIntoView({block: 'center'});
                el.click();
                return 'Clicked element: ' + (el.textContent || '').substring(0, 100).trim();
            })();
            """
            let result = try await webView.evaluateJavaScript(script)
            return result as? String ?? "Click executed"
        } else if let text = args["text"] as? String, !text.isEmpty {
            let textJSON = jsStringLiteral(text)
            let script = """
            (function() {
                const query = \(textJSON).toLowerCase();
                const candidates = document.querySelectorAll('a, button, input[type="submit"], input[type="button"], [role="button"], [onclick], [tabindex]');
                let best = null;
                let bestScore = Infinity;
                for (const el of candidates) {
                    if (el.offsetParent === null && el.style.display !== 'contents') continue;
                    const label = (el.textContent || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '').trim();
                    const lower = label.toLowerCase();
                    if (lower === query) {
                        best = el;
                        bestScore = 0;
                        break;
                    }
                    if (lower.includes(query) && label.length < bestScore) {
                        best = el;
                        bestScore = label.length;
                    }
                }
                if (!best) return 'No clickable element found matching: ' + query;
                best.scrollIntoView({block: 'center'});
                best.click();
                return 'Clicked: ' + (best.textContent || best.value || '').substring(0, 100).trim();
            })();
            """
            let result = try await webView.evaluateJavaScript(script)
            return result as? String ?? "Click executed"
        } else {
            return "Provide either 'selector' (CSS) or 'text' (visible text) to identify the element"
        }
    }

    private func executeGetInteractiveElements(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let filter = args["filter"] as? String ?? ""
        let limit = args["limit"] as? Int ?? 50
        let filterJSON = jsStringLiteral(filter)

        let script = """
        (function() {
            const filter = \(filterJSON).toLowerCase();
            const limit = \(limit);
            const selectors = 'a[href], button, input, select, textarea, [role="button"], [role="link"], [role="menuitem"], [onclick], [tabindex]';
            const elements = document.querySelectorAll(selectors);
            const results = [];

            for (const el of elements) {
                if (results.length >= limit) break;
                if (el.offsetParent === null && el.style.display !== 'contents' && !el.closest('label')) continue;

                const tag = el.tagName.toLowerCase();
                const type = el.getAttribute('type') || '';
                const text = (el.textContent || '').trim().substring(0, 80);
                const value = el.value || '';
                const ariaLabel = el.getAttribute('aria-label') || '';
                const placeholder = el.getAttribute('placeholder') || '';
                const href = el.getAttribute('href') || '';
                const role = el.getAttribute('role') || '';
                const name = el.getAttribute('name') || '';
                const id = el.id || '';
                const classes = el.className && typeof el.className === 'string' ? el.className.split(' ').slice(0, 3).join('.') : '';

                const label = text || ariaLabel || placeholder || value;
                if (filter && !label.toLowerCase().includes(filter) && !ariaLabel.toLowerCase().includes(filter) && !placeholder.toLowerCase().includes(filter)) continue;
                if (!label && tag === 'input' && type === 'hidden') continue;

                let selector = '';
                if (id) selector = '#' + CSS.escape(id);
                else if (name) selector = tag + '[name="' + name + '"]';
                else if (ariaLabel) selector = tag + '[aria-label="' + ariaLabel.replace(/"/g, '\\\\"') + '"]';
                else if (classes) selector = tag + '.' + classes.split('.').map(c => CSS.escape(c.trim())).filter(c => c).join('.');

                const entry = { tag, text: text.substring(0, 60) };
                if (type) entry.type = type;
                if (href) entry.href = href.substring(0, 100);
                if (ariaLabel) entry.ariaLabel = ariaLabel;
                if (placeholder) entry.placeholder = placeholder;
                if (selector) entry.selector = selector;
                if (role) entry.role = role;

                results.push(entry);
            }
            return JSON.stringify(results);
        })();
        """

        let result = try await webView.evaluateJavaScript(script)
        if let jsonString = result as? String {
            return jsonString
        }
        return "[]"
    }

    private func executeExtractStructuredData(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let type = args["type"] as? String else {
            return "Missing type parameter"
        }

        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let script: String
        switch type {
        case "schema_org":
            script = """
            (function() {
                const scripts = document.querySelectorAll('script[type="application/ld+json"]');
                const data = [];
                scripts.forEach(s => { try { data.push(JSON.parse(s.textContent)); } catch(e) {} });
                return JSON.stringify(data, null, 2);
            })();
            """
        case "open_graph":
            script = """
            (function() {
                const og = {};
                document.querySelectorAll('meta[property^="og:"]').forEach(m => {
                    og[m.getAttribute('property')] = m.getAttribute('content');
                });
                return JSON.stringify(og, null, 2);
            })();
            """
        case "meta":
            script = """
            (function() {
                const meta = {};
                document.querySelectorAll('meta[name], meta[property]').forEach(m => {
                    const key = m.getAttribute('name') || m.getAttribute('property');
                    meta[key] = m.getAttribute('content');
                });
                return JSON.stringify(meta, null, 2);
            })();
            """
        case "custom":
            guard let selectors = args["selectors"] as? [String] else {
                return "Missing selectors for custom extraction"
            }
            let selectorsJSON = (try? String(data: JSONSerialization.data(withJSONObject: selectors), encoding: .utf8)) ?? "[]"
            script = """
            (function() {
                const selectors = \(selectorsJSON);
                const results = {};
                selectors.forEach(s => {
                    const els = document.querySelectorAll(s);
                    results[s] = Array.from(els).map(e => e.innerText.trim()).filter(t => t);
                });
                return JSON.stringify(results, null, 2);
            })();
            """
        default:
            return "Unknown extraction type: \(type)"
        }

        let result = try await webView.evaluateJavaScript(script)
        return result as? String ?? "No data found"
    }

    private func executeSummarizePage(browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let script = """
        (function() {
            const clone = document.body.cloneNode(true);
            clone.querySelectorAll('script, style, noscript, nav, footer, header').forEach(el => el.remove());
            let text = clone.innerText || clone.textContent || '';
            text = text.replace(/\\s+/g, ' ').trim();
            if (text.length > 16000) text = text.substring(0, 16000) + '...';
            return { title: document.title, url: window.location.href, content: text, length: text.length };
        })();
        """

        let result = try await webView.evaluateJavaScript(script)
        if let dict = result as? [String: Any] {
            let title = dict["title"] as? String ?? ""
            let url = dict["url"] as? String ?? ""
            let content = dict["content"] as? String ?? ""
            return "Title: \(title)\nURL: \(url)\n\n\(content)"
        }

        return "Failed to read page"
    }

    private func executeSearchInPage(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let query = args["query"] as? String else {
            return "Missing query parameter"
        }

        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let queryJSON = jsStringLiteral(query)
        let script = """
        (function() {
            const text = document.body.innerText;
            const query = \(queryJSON).toLowerCase();
            const matches = [];
            let idx = text.toLowerCase().indexOf(query);
            while (idx !== -1 && matches.length < 10) {
                const start = Math.max(0, idx - 50);
                const end = Math.min(text.length, idx + query.length + 50);
                matches.push({ index: idx, context: text.substring(start, end) });
                idx = text.toLowerCase().indexOf(query, idx + 1);
            }
            return JSON.stringify({ count: matches.length, matches: matches });
        })();
        """

        let result = try await webView.evaluateJavaScript(script)
        return result as? String ?? "No matches found"
    }

    private func executeGetTabList(browserManager: BrowserManager, windowState: BrowserWindowState) -> String {
        guard let tabManager = windowState.tabManager,
              let space = windowState.currentSpace else {
            return "No tabs available"
        }

        let tabs = tabManager.tabs(in: space)
        var tabList: [[String: Any]] = []
        for (index, tab) in tabs.enumerated() {
            tabList.append([
                "index": index,
                "title": tab.name,
                "url": tab.url.absoluteString,
                "isActive": tab.id == windowState.currentTabId
            ])
        }

        let data = try? JSONSerialization.data(withJSONObject: tabList, options: .prettyPrinted)
        return String(data: data ?? Data(), encoding: .utf8) ?? "[]"
    }

    private func executeSwitchTab(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) throws -> String {
        guard let index = args["index"] as? Int else {
            return "Missing index parameter"
        }

        guard let tabManager = windowState.tabManager,
              let space = windowState.currentSpace else {
            return "No tabs available"
        }

        let tabs = tabManager.tabs(in: space)
        guard index >= 0, index < tabs.count else {
            return "Tab index \(index) out of range (0-\(tabs.count - 1))"
        }

        let tab = tabs[index]
        tabManager.setActiveTab(tab)
        return "Switched to tab: \(tab.name)"
    }

    private func executeCreateTab(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) throws -> String {
        browserManager.createNewTab(in: windowState)

        if let urlString = args["url"] as? String,
           let url = URL(string: urlString) {
            // Load URL in the new tab after a brief delay for initialization
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let webView = self.getWebView(browserManager: browserManager, windowState: windowState) {
                    webView.load(URLRequest(url: url))
                }
            }
            return "Created new tab with URL: \(urlString)"
        }

        return "Created new empty tab"
    }

    private func executeGetSelectedText(browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let script = "window.getSelection().toString();"
        let result = try await webView.evaluateJavaScript(script)
        let text = result as? String ?? ""
        return text.isEmpty ? "No text selected" : text
    }

    private func executeJavaScript(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let code = args["code"] as? String else {
            return "Missing code parameter"
        }

        guard let webView = getWebView(browserManager: browserManager, windowState: windowState) else {
            return "No active tab"
        }

        let result = try await webView.evaluateJavaScript(code)
        if let result = result {
            return String(describing: result)
        }
        return "JavaScript executed (no return value)"
    }
}

// MARK: - OpenHive workflow replay (shared with AI chat browser tools)

extension BrowserToolExecutor {
    private static let genericSelectors: Set<String> = [
        "", "button", "#button", "#search", "input", "#input", "#submit", "a",
        "#search-button-narrow", "#video-title", "#media-container-link", "#thumbnail",
    ]

    /// Run a recorded OpenHive action on a specific web view (EngineBridge replay path).
    static func performWorkflowAction(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        guard let type = action["type"] as? String else {
            return (false, "Missing action type")
        }

        switch type {
        case "navigate":
            guard let urlString = action["url"] as? String,
                  !urlString.isEmpty,
                  urlString != "about:blank",
                  urlString != "about:newtab",
                  let url = URL(string: urlString) else {
                return (true, "Skipped navigate")
            }
            if let current = webView.url, current.absoluteString == urlString || current.host == url.host && current.path == url.path {
                return (true, "Already on page")
            }
            webView.load(URLRequest(url: url))
            return (true, "Navigated to \(urlString)")

        case "click":
            do {
                let detail = try await clickElement(args: action, on: webView)
                let ok = detail.hasPrefix("Clicked") || detail.hasPrefix("Focused")
                return (ok, detail)
            } catch {
                return (false, error.localizedDescription)
            }

        case "fill", "type":
            do {
                let detail = try await typeIntoElement(args: action, on: webView)
                let ok = detail.hasPrefix("Typed")
                return (ok, detail)
            } catch {
                return (false, error.localizedDescription)
            }

        default:
            return (false, "Unknown action type: \(type)")
        }
    }

    /// Interactive element snapshot — same selectors as getInteractiveElements tool.
    static func interactiveElements(from webView: WKWebView, limit: Int = 60) async -> [[String: Any]] {
        let script = """
        (function() {
            const limit = \(limit);
            const selectors = 'a[href], button, input, select, textarea, [role="button"], [role="link"], [role="menuitem"], [role="searchbox"], [onclick], [tabindex]';
            const elements = document.querySelectorAll(selectors);
            const results = [];
            for (const el of elements) {
                if (results.length >= limit) break;
                if (el.offsetParent === null && el.style.display !== 'contents' && !el.closest('label')) continue;
                const tag = el.tagName.toLowerCase();
                const type = el.getAttribute('type') || '';
                const text = (el.textContent || '').trim().substring(0, 80);
                const value = el.value || '';
                const ariaLabel = el.getAttribute('aria-label') || '';
                const placeholder = el.getAttribute('placeholder') || '';
                const name = el.getAttribute('name') || '';
                const id = el.id || '';
                const label = text || ariaLabel || placeholder || value || name;
                if (!label && tag === 'input' && type === 'hidden') continue;
                let selector = '';
                if (id) selector = '#' + CSS.escape(id);
                else if (name) selector = tag + '[name="' + name.replace(/"/g, '\\\\"') + '"]';
                else if (ariaLabel) selector = tag + '[aria-label="' + ariaLabel.replace(/"/g, '\\\\"') + '"]';
                else if (placeholder) selector = tag + '[placeholder="' + placeholder.replace(/"/g, '\\\\"') + '"]';
                results.push({ tag, text: label.substring(0, 60), role: el.getAttribute('role') || '', name, selector });
            }
            return results;
        })();
        """
        do {
            let result = try await webView.evaluateJavaScript(script)
            return result as? [[String: Any]] ?? []
        } catch {
            return []
        }
    }

    private static func clickElement(args: [String: Any], on webView: WKWebView) async throws -> String {
        let selector = (args["selector"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let genericName = Set(["button", "input", "a"])
        let lowerText = text.lowercased()
        let lowerSelector = selector.lowercased()
        let lowerName = name.lowercased()

        if lowerName == "search_query" || lowerSelector.contains("search_query") {
            if let result = try await focusSearchInput(on: webView) {
                return result
            }
        }

        let isSearchChrome = lowerText == "search"
            || lowerName == "search-button-narrow"
            || lowerSelector.contains("search-button")
            || lowerSelector.contains("search-icon")
            || selector == "#search-button-narrow"
        if isSearchChrome, let result = try await clickYouTubeSearch(on: webView) {
            return result
        }

        let preferText = !text.isEmpty && (
            selector.isEmpty
            || genericSelectors.contains(selector.lowercased())
            || (text.count >= 3 && !genericName.contains(text.lowercased()))
        )

        if preferText, let result = try await clickByText(text, on: webView) {
            return result
        }

        if !selector.isEmpty, !genericSelectors.contains(selector.lowercased()),
           let result = try await clickBySelector(selector, textHint: text, on: webView) {
            return result
        }

        if !text.isEmpty, text.count > 40, let result = try await clickSearchResult(text, on: webView) {
            return result
        }

        if !text.isEmpty, let result = try await clickByText(text, on: webView) {
            return result
        }

        if !name.isEmpty, !genericName.contains(name.lowercased()),
           let result = try await clickByName(name, on: webView) {
            return result
        }

        if !selector.isEmpty, let result = try await clickBySelector(selector, textHint: text, on: webView) {
            return result
        }

        if isSearchChrome, let result = try await focusSearchInput(on: webView) {
            return result
        }

        return "Provide selector, text, or name to click"
    }

    private static func focusSearchInput(on webView: WKWebView) async throws -> String? {
        let script = """
        (function() {
            const selectors = [
                'ytd-searchbox input[name="search_query"]',
                'input#search',
                'input[name="search_query"]',
                '#search-input input',
                'input[type="search"]',
                '[role="searchbox"]',
            ];
            for (const sel of selectors) {
                const el = document.querySelector(sel);
                if (!el) continue;
                el.scrollIntoView({block: 'center'});
                el.focus();
                el.click();
                return 'Focused search input';
            }
            return null;
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    private static func clickYouTubeSearch(on webView: WKWebView) async throws -> String? {
        let script = """
        (function() {
            const searchButtons = [
                'ytd-searchbox button[aria-label="Search"]',
                'button#search-icon-legacy',
                '#search-button-narrow',
                'yt-icon-button[aria-label="Search"]',
                'button[aria-label="Search"]',
                'tp-yt-paper-icon-button[aria-label="Search"]',
            ];
            for (const sel of searchButtons) {
                const btn = document.querySelector(sel);
                if (!btn) continue;
                btn.scrollIntoView({block: 'center'});
                btn.click();
                return 'Clicked Search';
            }
            const input = document.querySelector('ytd-searchbox input[name="search_query"], input[name="search_query"]');
            if (input) {
                input.scrollIntoView({block: 'center'});
                input.focus();
                input.click();
                return 'Focused search input';
            }
            return null;
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    private static func clickBySelector(_ selector: String, textHint: String = "", on webView: WKWebView) async throws -> String? {
        let selectorJSON = jsStringLiteral(selector)
        let hintJSON = jsStringLiteral(textHint.replacingOccurrences(of: "\n", with: " "))
        let script = """
        (function() {
            const sel = \(selectorJSON);
            const hint = \(hintJSON).replace(/\\s+/g, ' ').trim().toLowerCase();
            const nodes = document.querySelectorAll(sel);
            if (!nodes.length) return null;
            let el = nodes[0];
            if (hint && nodes.length > 1) {
                const prefix = hint.slice(0, 50);
                for (const node of nodes) {
                    const label = (node.textContent || node.getAttribute('title') || node.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                    if (label === hint || label.startsWith(prefix) || (prefix.length > 10 && label.includes(prefix.slice(0, 24)))) {
                        el = node;
                        break;
                    }
                }
            }
            el.scrollIntoView({block: 'center'});
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.getAttribute('role') === 'searchbox') {
                el.focus();
                el.click();
                return 'Focused search input';
            }
            el.click();
            return 'Clicked element: ' + (el.textContent || el.getAttribute('title') || '').substring(0, 100).trim();
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    private static func clickByName(_ name: String, on webView: WKWebView) async throws -> String? {
        let nameJSON = jsStringLiteral(name)
        let script = """
        (function() {
            const el = document.querySelector('[name="' + \(nameJSON) + '"], #' + CSS.escape(\(nameJSON)));
            if (!el) return null;
            el.scrollIntoView({block: 'center'});
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                el.focus();
                el.click();
                return 'Focused search input';
            }
            el.click();
            return 'Clicked: ' + (el.textContent || el.value || '').substring(0, 100).trim();
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    private static func clickSearchResult(_ text: String, on webView: WKWebView) async throws -> String? {
        let textJSON = jsStringLiteral(text.replacingOccurrences(of: "\n", with: " "))
        let script = """
        (function() {
            const raw = \(textJSON).replace(/\\s+/g, ' ').trim();
            const q = raw.toLowerCase();
            const prefix = q.slice(0, 50);
            const pools = [
                ...document.querySelectorAll('ytd-video-renderer a#video-title'),
                ...document.querySelectorAll('ytd-video-renderer h3 a'),
                ...document.querySelectorAll('ytd-item-section-renderer a#video-title'),
                ...document.querySelectorAll('#contents a[href*="/watch"]'),
            ];
            for (const el of pools) {
                const label = (el.textContent || el.getAttribute('title') || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                if (!label) continue;
                if (label === q || label.startsWith(prefix) || (prefix.length > 12 && label.includes(prefix.slice(0, 24)))) {
                    el.scrollIntoView({block: 'center'});
                    el.click();
                    return 'Clicked: ' + (el.textContent || '').replace(/\\s+/g, ' ').trim().substring(0, 100);
                }
            }
            return null;
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    private static func clickByText(_ text: String, on webView: WKWebView) async throws -> String? {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let textJSON = jsStringLiteral(normalized)
        let script = """
        (function() {
            const query = \(textJSON).replace(/\\s+/g, ' ').trim().toLowerCase();
            if (!query) return null;
            const prefix = query.slice(0, 48);
            const candidates = document.querySelectorAll(
                'a, button, input[type="submit"], input[type="button"], [role="button"], [role="link"], [role="tab"], label, ytd-button-renderer button, tp-yt-paper-button, [onclick], [tabindex]'
            );
            let best = null;
            let bestScore = -1;
            for (const el of candidates) {
                if (el.offsetParent === null && el.style.display !== 'contents') continue;
                const label = (el.textContent || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '').replace(/\\s+/g, ' ').trim();
                if (!label) continue;
                const lower = label.toLowerCase();
                let score = -1;
                if (lower === query) score = 100;
                else if (lower.startsWith(prefix)) score = 80;
                else if (prefix.length > 10 && lower.includes(prefix.slice(0, 24))) score = 60;
                else if (lower.includes(query)) score = 40;
                if (score > bestScore) {
                    best = el;
                    bestScore = score;
                }
            }
            if (!best || bestScore < 0) return null;
            best.scrollIntoView({block: 'center'});
            best.click();
            return 'Clicked: ' + (best.textContent || best.value || best.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').substring(0, 100).trim();
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    private static func isSearchField(selector: String, name: String) -> Bool {
        let s = selector.lowercased()
        let n = name.lowercased()
        return s.contains("search") || n.contains("search") || n == "q"
            || s.contains("[name=\"q\"]") || s.contains("search_query")
    }

    private static func submitSearch(on webView: WKWebView) async throws {
        let script = """
        (function() {
            let el = document.activeElement;
            if (!el || el === document.body) {
                el = document.querySelector('input[name="search_query"], input[name="q"], input[type="search"], [role="searchbox"]');
            }
            if (el) {
                el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
                if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
            }
            const btn = document.querySelector('#search-icon-legacy, button#search, #search-button-narrow, ytd-searchbox button[aria-label="Search"], yt-icon-button[aria-label="Search"], [aria-label="Search"]');
            if (btn) btn.click();
            const form = document.querySelector('ytd-searchbox form, form#search-form');
            if (form && form.requestSubmit) form.requestSubmit();
            return true;
        })();
        """
        _ = try await webView.evaluateJavaScript(script)
    }

    private static func typeIntoElement(args: [String: Any], on webView: WKWebView) async throws -> String {
        let value = (args["value"] as? String ?? args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Empty type value" }

        let selector = (args["selector"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pressEnter = (args["submit"] as? Bool) ?? isSearchField(selector: selector, name: name)
        let selectorJSON = jsStringLiteral(selector)
        let nameJSON = jsStringLiteral(name)

        let focusScript = """
        (function() {
            const sel = \(selectorJSON);
            const name = \(nameJSON);
            let el = null;
            if (sel) el = document.querySelector(sel);
            if (!el && name) {
                el = document.querySelector('[name="' + name + '"], #' + CSS.escape(name) + ', [placeholder*="' + name + '"], [aria-label*="' + name + '"]');
            }
            if (!el) el = document.activeElement;
            if (!el || el === document.body) {
                el = document.querySelector('input[type="search"], input[name="q"], input[name="search_query"], textarea#search-input, ytd-searchbox input, [role="searchbox"], input:not([type="hidden"]), textarea, [contenteditable="true"]');
            }
            if (!el) return false;
            el.scrollIntoView({block: 'center'});
            el.focus();
            el.click();
            if (el.isContentEditable) el.textContent = '';
            else if ('value' in el) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                    || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                if (setter) setter.call(el, '');
                else el.value = '';
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            return true;
        })();
        """
        let focused = try await webView.evaluateJavaScript(focusScript) as? Bool ?? false
        guard focused else { return "No input found" }

        for char in value {
            let charJSON = jsStringLiteral(String(char))
            let charScript = """
            (function() {
                const ch = \(charJSON);
                let el = document.activeElement;
                if (!el || el === document.body) {
                    el = document.querySelector('input[type="search"], input[name="search_query"], input[name="q"], textarea, [role="searchbox"], input:not([type="hidden"])');
                }
                if (!el) return false;
                if (el.isContentEditable) {
                    el.textContent = (el.textContent || '') + ch;
                } else if ('value' in el) {
                    const next = (el.value || '') + ch;
                    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                        || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                    if (setter) setter.call(el, next);
                    else el.value = next;
                }
                el.dispatchEvent(new InputEvent('input', { bubbles: true, data: ch, inputType: 'insertText' }));
                return true;
            })();
            """
            _ = try await webView.evaluateJavaScript(charScript)
            try await Task.sleep(nanoseconds: 35_000_000)
        }

        if pressEnter {
            try await submitSearch(on: webView)
        } else {
            let changeScript = """
            (function() {
                const el = document.activeElement;
                if (el) el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            })();
            """
            _ = try await webView.evaluateJavaScript(changeScript)
        }

        return "Typed: \(value.prefix(60))"
    }
}
