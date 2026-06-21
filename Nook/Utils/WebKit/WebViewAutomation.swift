import WebKit

/// DOM-first browser automation (browser-use / Playwright style).
/// Uses in-page JavaScript — never CGEvent — so clicks stay in the current tab.
@MainActor
enum WebViewAutomation {
    private static let candidateSelector =
        "input, textarea, button, [role=button], [role=option], [role=gridcell], [role=menuitem], [aria-label], a"

    static func perform(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        guard let type = action["type"] as? String else {
            return (false, "Missing action type")
        }

        switch type {
        case "navigate":
            return await navigate(action, on: webView)
        case "click":
            return await click(action, on: webView)
        case "type", "fill":
            return await typeText(action, on: webView)
        case "press":
            return await pressKey(action, on: webView)
        case "done":
            return (true, "Task complete")
        default:
            return (false, "Unknown action type: \(type)")
        }
    }

    static func waitForSettle(on webView: WKWebView, actionType: String) async {
        let minMs: UInt64 = actionType == "navigate" ? 1_200 : 500
        try? await Task.sleep(nanoseconds: minMs * 1_000_000)

        for _ in 0..<25 {
            let ready = try? await webView.evaluateJavaScript("document.readyState") as? String
            if ready == "complete" { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // Let SPAs finish rendering overlays (Google Flights, etc.)
        let extraMs: UInt64 = actionType == "navigate" ? 800 : 350
        try? await Task.sleep(nanoseconds: extraMs * 1_000_000)
    }

    // MARK: - Actions

    private static func navigate(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        guard let urlString = action["url"] as? String,
              !urlString.isEmpty,
              urlString != "about:blank",
              urlString != "about:newtab",
              let url = URL(string: urlString) else {
            return (true, "Skipped navigate")
        }

        if let current = webView.url,
           current.absoluteString == urlString || (current.host == url.host && current.path == url.path) {
            return (true, "Already on page")
        }

        webView.load(URLRequest(url: url))
        return (true, "Navigated to \(urlString)")
    }

    private static func click(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        if let ref = action["ref"] as? String, !ref.isEmpty,
           let result = await clickByRef(ref, on: webView) {
            return result
        }

        if let x = action["x"] as? Double, let y = action["y"] as? Double,
           let result = await clickAtPoint(x: x, y: y, on: webView) {
            return result
        }

        let text = (action["text"] as? String ?? action["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let result = await clickByLabel(text, on: webView) {
            return result
        }

        let selector = (action["selector"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !selector.isEmpty, let result = await clickBySelector(selector, hint: text, on: webView) {
            return result
        }

        return (false, "No clickable element found")
    }

    private static func typeText(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        let value = (action["value"] as? String ?? action["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (false, "Empty type value") }

        if let ref = action["ref"] as? String, !ref.isEmpty,
           let result = await fillRef(ref, value: value, on: webView) {
            return result
        }

        let label = (action["text"] as? String ?? action["placeholder"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, let result = await fillByLabel(label, value: value, on: webView) {
            return result
        }

        if let x = action["x"] as? Double, let y = action["y"] as? Double,
           let result = await fillAtPoint(x: x, y: y, value: value, on: webView) {
            return result
        }

        return (false, "No input found")
    }

    private static func pressKey(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        let key = (action["value"] as? String ?? "Enter").trimmingCharacters(in: .whitespacesAndNewlines)
        let keyJSON = jsStringLiteral(key)
        let script = """
        (function() {
            const key = \(keyJSON);
            const el = document.activeElement || document.body;
            const codes = { Enter: 13, Escape: 27, Tab: 9, ArrowDown: 40, ArrowUp: 38 };
            const keyCode = codes[key] || 13;
            ['keydown', 'keypress', 'keyup'].forEach(type => {
                el.dispatchEvent(new KeyboardEvent(type, {
                    key,
                    code: key,
                    keyCode,
                    which: keyCode,
                    bubbles: true,
                    cancelable: true
                }));
            });
            return { ok: true, detail: 'Pressed ' + key };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Press failed")
    }

    // MARK: - DOM helpers

    private static func clickByRef(_ ref: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let refJSON = jsStringLiteral(ref)
        let script = """
        (function() {
            const ref = \(refJSON);
            const els = [...document.querySelectorAll('\(candidateSelector)')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    const t = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.textContent || '').trim();
                    return r.width > 0 && r.height > 0 && !el.disabled && (t || el.tagName === 'INPUT' || el.tagName === 'TEXTAREA');
                });
            const idx = parseInt(ref.replace(/^e/, ''), 10);
            const el = els[idx];
            if (!el) return { ok: false, error: 'ref not found: ' + ref };
            el.scrollIntoView({ block: 'center', inline: 'center' });
            el.focus({ preventScroll: true });
            const tag = el.tagName.toLowerCase();
            const role = el.getAttribute('role') || '';
            if (tag === 'input' || tag === 'textarea' || role === 'searchbox' || role === 'combobox' || el.isContentEditable) {
                el.click();
                return { ok: true, detail: 'Focused ' + ref };
            }
            el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
            el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            if (typeof el.click === 'function') el.click();
            const label = (el.innerText || el.getAttribute('aria-label') || el.textContent || '').trim().substring(0, 80);
            return { ok: true, detail: 'Clicked ' + ref + (label ? ': ' + label : '') };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func clickAtPoint(x: Double, y: Double, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let script = """
        (function() {
            const el = document.elementFromPoint(\(x), \(y));
            if (!el) return { ok: false, error: 'No element at point' };
            const target = el.closest('a, button, input, textarea, [role=button], [role=option], [role=gridcell], [role=menuitem], [tabindex]') || el;
            target.scrollIntoView({ block: 'center', inline: 'center' });
            target.focus({ preventScroll: true });
            target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            if (typeof target.click === 'function') target.click();
            const label = (target.innerText || target.getAttribute('aria-label') || '').trim().substring(0, 80);
            return { ok: true, detail: 'Clicked at (' + Math.round(\(x)) + ',' + Math.round(\(y)) + ')' + (label ? ': ' + label : '') };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func clickByLabel(_ text: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let textJSON = jsStringLiteral(text)
        let script = """
        (function() {
            const query = \(textJSON).replace(/\\s+/g, ' ').trim().toLowerCase();
            if (!query) return { ok: false, error: 'empty label' };
            const els = [...document.querySelectorAll('\(candidateSelector)')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && !el.disabled;
                });
            let best = null, bestScore = -1;
            for (const el of els) {
                const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                if (!label) continue;
                let score = -1;
                if (label === query) score = 100;
                else if (label.startsWith(query.slice(0, 48))) score = 80;
                else if (query.length > 8 && label.includes(query.slice(0, 20))) score = 60;
                else if (label.includes(query)) score = 40;
                if (score > bestScore) { best = el; bestScore = score; }
            }
            if (!best || bestScore < 0) return { ok: false, error: 'label not found' };
            best.scrollIntoView({ block: 'center', inline: 'center' });
            best.focus({ preventScroll: true });
            best.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            if (typeof best.click === 'function') best.click();
            return { ok: true, detail: 'Clicked: ' + query.substring(0, 60) };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func clickBySelector(_ selector: String, hint: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let selJSON = jsStringLiteral(selector)
        let hintJSON = jsStringLiteral(hint)
        let script = """
        (function() {
            const el = document.querySelector(\(selJSON));
            if (!el) return { ok: false, error: 'selector not found' };
            el.scrollIntoView({ block: 'center', inline: 'center' });
            el.focus({ preventScroll: true });
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            if (typeof el.click === 'function') el.click();
            return { ok: true, detail: 'Clicked selector' };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func fillRef(_ ref: String, value: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let refJSON = jsStringLiteral(ref)
        let valueJSON = jsStringLiteral(value)
        let script = """
        (function() {
            const els = [...document.querySelectorAll('\(candidateSelector)')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && !el.disabled;
                });
            const idx = parseInt(\(refJSON).replace(/^e/, ''), 10);
            const el = els[idx];
            if (!el) return { ok: false, error: 'ref not found' };
            return fillElement(el, \(valueJSON));
        })();

        function fillElement(el, text) {
            el.scrollIntoView({ block: 'center', inline: 'center' });
            el.focus({ preventScroll: true });
            el.click();
            if (el.isContentEditable) {
                el.textContent = text;
            } else if ('value' in el) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                    || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                if (setter) setter.call(el, text);
                else el.value = text;
            } else {
                return { ok: false, error: 'not an input' };
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, detail: 'Typed into ' + \(refJSON) + ': ' + text.substring(0, 40) };
        }
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func fillByLabel(_ label: String, value: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let labelJSON = jsStringLiteral(label)
        let valueJSON = jsStringLiteral(value)
        let script = """
        (function() {
            const needle = \(labelJSON).toLowerCase();
            const inputs = [...document.querySelectorAll('input, textarea, [role=searchbox], [role=combobox], [contenteditable=true]')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && !el.disabled;
                });
            let best = null, bestScore = -1;
            for (const el of inputs) {
                const t = (el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || el.id || '').toLowerCase();
                let score = -1;
                if (t.includes(needle) || needle.includes(t)) score = 60;
                if (t.includes('from') && needle.includes('from')) score = 80;
                if (t.includes('to') && needle.includes('to')) score = 80;
                if (score > bestScore) { best = el; bestScore = score; }
            }
            if (!best) best = inputs[0];
            if (!best) return { ok: false, error: 'no input' };
            best.scrollIntoView({ block: 'center', inline: 'center' });
            best.focus({ preventScroll: true });
            best.click();
            const text = \(valueJSON);
            if (best.isContentEditable) best.textContent = text;
            else {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                    || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                if (setter) setter.call(best, text);
                else best.value = text;
            }
            best.dispatchEvent(new Event('input', { bubbles: true }));
            best.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, detail: 'Typed: ' + text.substring(0, 40) };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func fillAtPoint(x: Double, y: Double, value: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let valueJSON = jsStringLiteral(value)
        let script = """
        (function() {
            const el = document.elementFromPoint(\(x), \(y));
            if (!el) return { ok: false, error: 'No element at point' };
            const input = el.closest('input, textarea, [contenteditable=true], [role=searchbox], [role=combobox]') || el;
            input.scrollIntoView({ block: 'center', inline: 'center' });
            input.focus({ preventScroll: true });
            input.click();
            const text = \(valueJSON);
            if (input.isContentEditable) input.textContent = text;
            else if ('value' in input) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                    || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                if (setter) setter.call(input, text);
                else input.value = text;
            } else {
                return { ok: false, error: 'not an input at point' };
            }
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, detail: 'Typed at point: ' + text.substring(0, 40) };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func parseResult(_ raw: Any?) -> (success: Bool, detail: String)? {
        guard let dict = raw as? [String: Any] else { return nil }
        if dict["ok"] as? Bool == true {
            return (true, dict["detail"] as? String ?? "OK")
        }
        if let err = dict["error"] as? String {
            return (false, err)
        }
        return nil
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
