import WebKit

/// DOM-first browser automation (browser-use / Playwright style).
/// Uses in-page JavaScript — never CGEvent — so clicks stay in the current tab.
@MainActor
enum WebViewAutomation {
    private static let candidateSelector =
        "input, textarea, button, [role=button], [role=option], [role=gridcell], [role=menuitem], [role=combobox], [role=searchbox], [aria-label], li, span, div[jsaction], a"

    static func perform(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        guard let type = action["type"] as? String else {
            return (false, "Missing action type")
        }

        switch type {
        case "navigate":
            return await navigate(action, on: webView)
        case "search":
            return search(action, on: webView)
        case "click":
            return await click(action, on: webView)
        case "type", "fill":
            return await typeText(action, on: webView)
        case "press":
            return await pressKey(action, on: webView)
        case "scroll":
            return await scroll(action, on: webView)
        case "select":
            return await selectOption(action, on: webView)
        case "done":
            return (true, "Task complete")
        default:
            if let extended = await performExtended(type, action, on: webView) {
                return extended
            }
            return (false, "Unknown action type: \(type)")
        }
    }

    /// Exposed for page-level search routing.
    static func search(_ action: [String: Any], on webView: WKWebView) -> (success: Bool, detail: String) {
        let result = NookBrowserController.search(action, on: webView)
        return (result.success, result.detail)
    }

    static func waitForSettle(on webView: WKWebView, actionType: String) async {
        // Small floor, then poll readyState and bail the instant the doc is ready.
        let minMs: UInt64 = actionType == "navigate" ? 250 : 60
        try? await Task.sleep(nanoseconds: minMs * 1_000_000)

        let maxPolls = actionType == "navigate" ? 20 : 5
        for _ in 0..<maxPolls {
            let ready = try? await webView.evaluateJavaScript("document.readyState") as? String
            if ready == "complete" { break }
            try? await Task.sleep(nanoseconds: 90_000_000)
        }

        // Brief tail for SPAs to render overlays (Google Flights, etc.)
        let extraMs: UInt64 = actionType == "navigate" ? 220 : 100
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
        await OpenHiveObservation.installAgentAutomation(on: webView)
        // Cascade through strategies: a strategy only "wins" if it actually
        // succeeded. A failed ref/label/selector lookup must fall through to the
        // next strategy instead of short-circuiting the whole click.
        var lastDetail = "No clickable element found"

        if action["partial"] as? Bool == true,
           let text = action["text"] as? String, !text.isEmpty,
           let result = await clickByPartial(text, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        if let ref = action["ref"] as? String, !ref.isEmpty,
           let result = await clickByRef(ref, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        if let x = action["x"] as? Double, let y = action["y"] as? Double,
           let result = await clickAtPoint(x: x, y: y, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        let text = (action["text"] as? String ?? action["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let result = await clickByLabel(text, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        let selector = (action["selector"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !selector.isEmpty, let result = await clickBySelector(selector, hint: text, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        return (false, lastDetail)
    }

    private static func typeText(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        await OpenHiveObservation.installAgentAutomation(on: webView)

        let value = (action["value"] as? String ?? action["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (false, "Empty type value") }
        var lastDetail = "No input found"

        if let ref = action["ref"] as? String, !ref.isEmpty,
           let result = await fillRef(ref, value: value, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        let label = (action["text"] as? String ?? action["placeholder"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, let result = await fillByLabel(label, value: value, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        if let x = action["x"] as? Double, let y = action["y"] as? Double,
           let result = await fillAtPoint(x: x, y: y, value: value, on: webView) {
            if result.success { return result }
            lastDetail = result.detail
        }

        return (false, lastDetail)
    }

    private static func pressKey(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        let key = (action["value"] as? String ?? "Enter").trimmingCharacters(in: .whitespacesAndNewlines)
        let keyJSON = jsStringLiteral(key)
        let script = """
        (function() {
            const key = \(keyJSON);
            const el = document.activeElement || document.body;
            if (key === 'Meta+a' || key === 'Control+a' || key === 'SelectAll') {
                if (el.select) { el.select(); return { ok: true, detail: 'Selected all' }; }
                document.execCommand && document.execCommand('selectAll');
                return { ok: true, detail: 'Selected all' };
            }
            const codes = {
                Enter: 13, Escape: 27, Tab: 9,
                ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39,
                Backspace: 8, Delete: 46, Space: 32
            };
            const keyCode = codes[key] || 13;
            ['keydown', 'keypress', 'keyup'].forEach(type => {
                el.dispatchEvent(new KeyboardEvent(type, {
                    key,
                    code: key.startsWith('Arrow') ? key : key,
                    keyCode,
                    which: keyCode,
                    bubbles: true,
                    cancelable: true
                }));
            });
            if (key === 'Enter') {
                const form = el.form || el.closest('form');
                if (form && typeof form.requestSubmit === 'function') {
                    form.requestSubmit();
                    return { ok: true, detail: 'Submitted form with Enter' };
                }
            }
            if (key === 'Escape') {
                el.blur && el.blur();
            }
            return { ok: true, detail: 'Pressed ' + key };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Press failed")
    }

    private static func scroll(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        let direction = (action["value"] as? String ?? action["direction"] as? String ?? "down").lowercased()
        let amount = action["amount"] as? Int ?? 500
        let script = """
        (function() {
            const dir = \(jsStringLiteral(direction));
            const px = \(amount);
            if (dir === 'up') window.scrollBy(0, -px);
            else if (dir === 'down') window.scrollBy(0, px);
            else if (dir === 'top') window.scrollTo(0, 0);
            else if (dir === 'bottom') window.scrollTo(0, document.body.scrollHeight);
            else window.scrollBy(0, px);
            return { ok: true, detail: 'Scrolled ' + dir };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Scroll failed")
    }

    private static func selectOption(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        let value = (action["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = action["ref"] as? String ?? ""
        await OpenHiveObservation.installAgentAutomation(on: webView)
        let refJSON = jsStringLiteral(ref)
        let valueJSON = jsStringLiteral(value)
        let script = """
        (function() {
            let el = \(ref.isEmpty ? "null" : "window.__openhive_resolve_ref(\(refJSON))");
            if (!el) el = document.querySelector('select');
            if (!el || el.tagName !== 'SELECT') return { ok: false, error: 'no select element' };
            el.value = \(valueJSON);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, detail: 'Selected ' + \(valueJSON) };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Select failed")
    }

    // MARK: - DOM helpers

    private static func clickByRef(_ ref: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        let refJSON = jsStringLiteral(ref)
        let script = """
        (function() {
            const ref = \(refJSON);
            const el = window.__openhive_resolve_ref ? window.__openhive_resolve_ref(ref) : null;
            if (!el) return { ok: false, error: 'ref not found: ' + ref };
            return openhiveClick(el);

            function openhiveClick(el) {
                el.scrollIntoView({ block: 'center', inline: 'center' });
                el.focus({ preventScroll: true });
                const rect = el.getBoundingClientRect();
                const cx = rect.left + rect.width / 2;
                const cy = rect.top + rect.height / 2;
                const opts = { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy };
                ['pointerover','mouseover','mousemove','pointerdown','mousedown','pointerup','mouseup','click'].forEach(t => {
                    try { el.dispatchEvent(new MouseEvent(t, opts)); } catch (_) {}
                });
                if (typeof el.click === 'function') el.click();
                const tag = el.tagName.toLowerCase();
                const role = el.getAttribute('role') || '';
                const label = (el.innerText || el.getAttribute('aria-label') || el.textContent || '').trim().substring(0, 80);
                if (tag === 'input' || tag === 'textarea' || role === 'searchbox' || role === 'combobox' || el.isContentEditable) {
                    return { ok: true, detail: 'Focused ' + ref + (label ? ': ' + label : '') };
                }
                return { ok: true, detail: 'Clicked ' + ref + (label ? ': ' + label : '') };
            }
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

            function labelOf(el) {
                return (el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.innerText || el.value || el.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            }

            function clickEl(el) {
                const input = el.matches('input, textarea') ? el : el.querySelector('input, textarea, [contenteditable=true]');
                const target = input || el;
                target.scrollIntoView({ block: 'center', inline: 'center' });
                target.focus({ preventScroll: true });
                ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(t => {
                    try { target.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window })); } catch (_) {}
                });
                if (typeof target.click === 'function') target.click();
                return target;
            }

            const combos = [...document.querySelectorAll('[role=combobox], [role=searchbox]')];
            for (const el of combos) {
                const label = labelOf(el);
                if (label.includes(query) || query.includes(label)) {
                    clickEl(el);
                    return { ok: true, detail: 'Focused combobox: ' + query };
                }
            }

            const els = [...document.querySelectorAll('\(candidateSelector)')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && !el.disabled;
                });
            let best = null, bestScore = -1;
            for (const el of els) {
                const label = labelOf(el);
                if (!label) continue;
                let score = -1;
                if (label === query) score = 100;
                else if (label.startsWith(query)) score = 85;
                else if (label.includes(query)) score = 60;
                else if (query.includes(label) && label.length > 2) score = 50;
                if (score > bestScore) { best = el; bestScore = score; }
            }
            if (!best || bestScore < 0) return { ok: false, error: 'label not found: ' + query };
            clickEl(best);
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
        await OpenHiveObservation.installAgentAutomation(on: webView)
        let refJSON = jsStringLiteral(ref)
        let valueJSON = jsStringLiteral(value)
        let script = """
        (function() {
            const el = window.__openhive_resolve_ref ? window.__openhive_resolve_ref(\(refJSON)) : null;
            if (!el) return { ok: false, error: 'ref not found' };
            return fillElement(el, \(valueJSON));

            function fillElement(el, text) {
                el.scrollIntoView({ block: 'center', inline: 'center' });
                el.focus({ preventScroll: true });
                el.click();
                if (el.isContentEditable) {
                    el.textContent = '';
                    for (const ch of text) {
                        el.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: ch, bubbles: true, cancelable: true }));
                        el.textContent += ch;
                        el.dispatchEvent(new InputEvent('input', { inputType: 'insertText', data: ch, bubbles: true }));
                    }
                } else if ('value' in el) {
                    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                        || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                    el.value = '';
                    for (const ch of text) {
                        const next = el.value + ch;
                        if (setter) setter.call(el, next);
                        else el.value = next;
                        el.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: ch, bubbles: true, cancelable: true }));
                        el.dispatchEvent(new InputEvent('input', { inputType: 'insertText', data: ch, bubbles: true }));
                    }
                } else {
                    return { ok: false, error: 'not an input' };
                }
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return { ok: true, detail: 'Typed into ' + \(refJSON) + ': ' + text.substring(0, 40) };
            }
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func fillByLabel(_ label: String, value: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let labelJSON = jsStringLiteral(label)
        let valueJSON = jsStringLiteral(value)
        let script = """
        (function() {
            const needle = \(labelJSON).toLowerCase();
            const inputs = [...document.querySelectorAll('input, textarea, [role=searchbox], [role=combobox] input, [contenteditable=true]')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && !el.disabled;
                });
            let best = null, bestScore = -1;
            for (const el of inputs) {
                const t = (el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || el.id || '').toLowerCase();
                let score = -1;
                if (t.includes(needle) || needle.includes(t)) score = 60;
                if (t.includes('from') && needle.includes('from')) score = 90;
                if (t.includes('to') && needle.includes('to')) score = 90;
                if (score > bestScore) { best = el; bestScore = score; }
            }
            if (!best) return { ok: false, error: 'no input for ' + needle };
            best.scrollIntoView({ block: 'center', inline: 'center' });
            best.focus({ preventScroll: true });
            best.click();
            try { document.execCommand('selectAll'); } catch (e) {}
            try { document.execCommand('delete'); } catch (e) {}
            const text = \(valueJSON);
            if (best.isContentEditable) {
                best.textContent = '';
                for (const ch of text) {
                    best.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: ch, bubbles: true, cancelable: true }));
                    best.textContent += ch;
                    best.dispatchEvent(new InputEvent('input', { inputType: 'insertText', data: ch, bubbles: true }));
                }
            } else if ('value' in best) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                    || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                for (const ch of text) {
                    const next = (best.value || '') + ch;
                    if (setter) setter.call(best, next);
                    else best.value = next;
                    best.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: ch, bubbles: true, cancelable: true }));
                    best.dispatchEvent(new InputEvent('input', { inputType: 'insertText', data: ch, bubbles: true }));
                }
            } else {
                return { ok: false, error: 'not an input' };
            }
            best.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, detail: 'Typed: ' + text.substring(0, 40) };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script))
    }

    private static func clickByPartial(_ text: String, on webView: WKWebView) async -> (success: Bool, detail: String)? {
        let textJSON = jsStringLiteral(text)
        let script = """
        (function() {
            const query = \(textJSON).replace(/\\s+/g, ' ').trim().toLowerCase();
            if (!query) return { ok: false, error: 'empty partial' };

            const isDay = /^\\d{1,2}$/.test(query);
            if (isDay) {
                const cells = [...document.querySelectorAll('[role=gridcell], button, div[role=button]')]
                    .filter(el => {
                        const r = el.getBoundingClientRect();
                        if (r.width <= 0 || r.height <= 0 || el.disabled) return false;
                        const label = (el.getAttribute('aria-label') || el.innerText || el.textContent || '')
                            .replace(/\\s+/g, ' ').trim().toLowerCase();
                        if (!label) return false;
                        return label === query || label.startsWith(query + ' ') || label.startsWith(query + '\\n');
                    })
                    .filter(el => el.getBoundingClientRect().y > 260);
                if (cells.length) {
                    const best = cells.sort((a, b) => b.getBoundingClientRect().x - a.getBoundingClientRect().x)[0];
                    best.scrollIntoView({ block: 'center', inline: 'center' });
                    best.focus({ preventScroll: true });
                    best.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
                    if (typeof best.click === 'function') best.click();
                    return { ok: true, detail: 'Clicked calendar day: ' + query };
                }
            }

            const els = [...document.querySelectorAll('\(candidateSelector), [role=option], [role=listbox] *')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && !el.disabled;
                });
            let best = null, bestScore = -1;
            for (const el of els) {
                const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                if (!label || label.length > 120) continue;
                let score = -1;
                if (label.includes(query)) score = 50 + query.length;
                if (label === query) score = 100;
                if (score > bestScore) { best = el; bestScore = score; }
            }
            if (!best || bestScore < 0) return { ok: false, error: 'partial not found: ' + query };
            best.scrollIntoView({ block: 'center', inline: 'center' });
            best.focus({ preventScroll: true });
            best.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            if (typeof best.click === 'function') best.click();
            return { ok: true, detail: 'Clicked partial: ' + query };
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

    static func parseResult(_ raw: Any?) -> (success: Bool, detail: String)? {
        guard let dict = raw as? [String: Any] else { return nil }
        if dict["ok"] as? Bool == true {
            return (true, dict["detail"] as? String ?? "OK")
        }
        if let err = dict["error"] as? String {
            return (false, err)
        }
        return nil
    }

    static func jsStringLiteral(_ value: String) -> String {
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
