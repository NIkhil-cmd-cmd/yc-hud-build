import AppKit
import CoreGraphics
import WebKit

/// Real mouse/keyboard events in the active Nook tab (no separate browser window).
@MainActor
enum WebViewNativeInput {
    struct ElementTarget {
        let x: Double
        let y: Double
        let label: String
        let isInput: Bool
    }

    static func click(args: [String: Any], in webView: WKWebView) async -> String? {
        guard let target = await resolveTarget(args: args, in: webView) else { return nil }
        activate(webView)
        guard click(at: target, in: webView) else { return nil }
        try? await Task.sleep(nanoseconds: 150_000_000)
        if target.isInput {
            return "Focused search input"
        }
        return "Clicked: \(target.label)"
    }

    static func typeText(_ value: String, args: [String: Any], in webView: WKWebView) async -> String? {
        guard !value.isEmpty else { return "Empty type value" }
        var clickArgs = args
        if (clickArgs["selector"] as? String)?.isEmpty != false,
           (clickArgs["name"] as? String)?.isEmpty != false,
           (clickArgs["text"] as? String)?.isEmpty != false {
            clickArgs["text"] = args["placeholder"] as? String ?? "search"
        }

        if let clickResult = await click(args: clickArgs, in: webView) {
            _ = clickResult
        } else if await resolveTarget(args: args, in: webView) == nil {
            return "No input found"
        }

        activate(webView)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await clearFocusedField()
        await postText(value)
        try? await Task.sleep(nanoseconds: 120_000_000)

        let submit = (args["submit"] as? Bool) ?? isSearchField(args: args)
        if submit {
            postKey(keyCode: 36)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return "Typed: \(value.prefix(60))"
    }

    // MARK: - Element resolution

    private static func resolveTarget(args: [String: Any], in webView: WKWebView) async -> ElementTarget? {
        if let x = args["x"] as? Double, let y = args["y"] as? Double {
            let label = (args["text"] as? String ?? args["value"] as? String ?? "element").trimmingCharacters(in: .whitespacesAndNewlines)
            return ElementTarget(x: x, y: y, label: label.isEmpty ? "element" : label, isInput: false)
        }

        let selector = jsStringLiteral((args["selector"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let text = jsStringLiteral((args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let name = jsStringLiteral((args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let script = """
        (function() {
            const selector = \(selector);
            const query = \(text).replace(/\\s+/g, ' ').trim();
            const nameHint = \(name);
            const generic = new Set(['', 'button', '#button', '#search', 'input', '#input', '#submit', 'a']);

            function visible(el) {
                if (!el) return false;
                const style = getComputedStyle(el);
                if (style.visibility === 'hidden' || style.display === 'none' || style.pointerEvents === 'none') return false;
                const r = el.getBoundingClientRect();
                return r.width > 1 && r.height > 1;
            }

            function pack(el) {
                el.scrollIntoView({ block: 'center', inline: 'center' });
                const r = el.getBoundingClientRect();
                const tag = el.tagName.toLowerCase();
                const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || '').replace(/\\s+/g, ' ').trim();
                const isInput = tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable || el.getAttribute('role') === 'searchbox' || el.getAttribute('role') === 'combobox';
                return {
                    found: true,
                    x: r.left + r.width / 2,
                    y: r.top + r.height / 2,
                    label: label.substring(0, 100),
                    isInput
                };
            }

            function scoreLabel(label, q) {
                if (!q) return -1;
                const lower = label.toLowerCase();
                const needle = q.toLowerCase();
                if (lower === needle) return 100;
                if (lower.startsWith(needle.slice(0, 48))) return 80;
                if (needle.length > 10 && lower.includes(needle.slice(0, 24))) return 60;
                if (lower.includes(needle)) return 40;
                return -1;
            }

            if (selector && !generic.has(selector.toLowerCase())) {
                const nodes = document.querySelectorAll(selector);
                for (const el of nodes) {
                    if (!visible(el)) continue;
                    if (query) {
                        const label = (el.innerText || el.getAttribute('aria-label') || el.getAttribute('title') || '').replace(/\\s+/g, ' ').trim();
                        if (scoreLabel(label, query) < 0) continue;
                    }
                    return pack(el);
                }
            }

            if (nameHint) {
                const named = document.querySelector('[name="' + nameHint + '"], #' + CSS.escape(nameHint) + ', [aria-label="' + nameHint + '"], [aria-label*="' + nameHint + '" i], [placeholder*="' + nameHint + '" i]');
                if (visible(named)) return pack(named);
            }

            if (query) {
                const candidates = document.querySelectorAll('a, button, input[type="submit"], input[type="button"], [role="button"], [role="link"], [role="tab"], label, summary, [onclick], [tabindex]');
                let best = null;
                let bestScore = -1;
                for (const el of candidates) {
                    if (!visible(el)) continue;
                    const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '').replace(/\\s+/g, ' ').trim();
                    if (!label) continue;
                    const score = scoreLabel(label, query);
                    if (score > bestScore) {
                        best = el;
                        bestScore = score;
                    }
                }
                if (best && bestScore >= 0) return pack(best);
            }

            if (selector) {
                const el = document.querySelector(selector);
                if (visible(el)) return pack(el);
            }

            const fallback = document.querySelector('input[type="search"], input[name="q"], input[name="search_query"], textarea, [role="searchbox"], input:not([type="hidden"]), [contenteditable="true"]');
            if (visible(fallback)) return pack(fallback);

            return { found: false };
        })();
        """

        do {
            guard let dict = try await webView.evaluateJavaScript(script) as? [String: Any],
                  dict["found"] as? Bool == true,
                  let x = dict["x"] as? Double,
                  let y = dict["y"] as? Double else {
                return nil
            }
            let label = dict["label"] as? String ?? ""
            let isInput = dict["isInput"] as? Bool ?? false
            return ElementTarget(x: x, y: y, label: label, isInput: isInput)
        } catch {
            return nil
        }
    }

    // MARK: - Native events

    private static func activate(_ webView: WKWebView) {
        webView.window?.makeKeyAndOrderFront(nil)
        if let focusable = webView as? FocusableWKWebView {
            focusable.owningTab?.activate()
        }
        webView.window?.makeFirstResponder(webView)
    }

    private static func click(at target: ElementTarget, in webView: WKWebView) -> Bool {
        guard let screenPoint = screenPoint(for: target, in: webView) else { return false }
        postMouseClick(at: screenPoint)
        return true
    }

    private static func screenPoint(for target: ElementTarget, in webView: WKWebView) -> NSPoint? {
        guard let window = webView.window else { return nil }
        let viewPoint = NSPoint(x: target.x, y: webView.bounds.height - target.y)
        let windowPoint = webView.convert(viewPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private static func postMouseClick(at screenPoint: NSPoint) {
        let location = CGPoint(x: screenPoint.x, y: screenPoint.y)
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func clearFocusedField() async {
        postKey(keyCode: 0, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 30_000_000)
        postKey(keyCode: 51)
    }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postText(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for character in text {
            var chars = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func isSearchField(args: [String: Any]) -> Bool {
        let selector = (args["selector"] as? String ?? "").lowercased()
        let name = (args["name"] as? String ?? "").lowercased()
        return selector.contains("search") || name.contains("search") || name == "q" || selector.contains("[name=\"q\"]")
    }

    private static func jsStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
