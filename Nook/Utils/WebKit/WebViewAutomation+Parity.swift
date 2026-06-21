import WebKit

/// Playwright / browser-use parity — extended page actions for the in-tab agent.
extension WebViewAutomation {
    static func performExtended(_ type: String, _ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String)? {
        switch type {
        case "hover":
            return await hover(action, on: webView)
        case "check":
            return await setChecked(action, checked: true, on: webView)
        case "uncheck":
            return await setChecked(action, checked: false, on: webView)
        case "dblclick", "double_click":
            return await doubleClick(action, on: webView)
        case "wait", "wait_for":
            return await waitFor(action, on: webView)
        case "extract":
            return await extract(action, on: webView)
        case "evaluate", "eval":
            return await evaluate(action, on: webView)
        case "scroll_into_view", "scrollintoview":
            return await scrollIntoView(action, on: webView)
        case "click_option":
            return await clickOption(action, on: webView)
        case "upload":
            return await upload(action, on: webView)
        default:
            return nil
        }
    }

    static func hover(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        guard let elJS = elementResolverJS(action) else {
            return (false, "hover requires ref or selector")
        }
        let script = """
        (function() {
            const el = \(elJS);
            if (!el) return { ok: false, error: 'element not found' };
            el.scrollIntoView({ block: 'center', inline: 'center' });
            ['pointerover','mouseover','mouseenter'].forEach(t => {
                el.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window }));
            });
            return { ok: true, detail: 'Hovered element' };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Hover failed")
    }

    static func setChecked(_ action: [String: Any], checked: Bool, on webView: WKWebView) async -> (success: Bool, detail: String) {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        guard let elJS = elementResolverJS(action) else {
            return (false, "check requires ref or selector")
        }
        let script = """
        (function() {
            const el = \(elJS);
            if (!el) return { ok: false, error: 'element not found' };
            const tag = el.tagName.toLowerCase();
            const role = el.getAttribute('role') || '';
            if (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
                el.checked = \(checked ? "true" : "false");
            } else if (role === 'checkbox' || role === 'switch') {
                el.setAttribute('aria-checked', \(checked ? "'true'" : "'false'"));
                el.click();
            } else {
                el.click();
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, detail: '\(checked ? "Checked" : "Unchecked")' };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Check failed")
    }

    static func doubleClick(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        guard let elJS = elementResolverJS(action) else {
            return (false, "dblclick requires ref or selector")
        }
        let script = """
        (function() {
            const el = \(elJS);
            if (!el) return { ok: false, error: 'element not found' };
            el.scrollIntoView({ block: 'center', inline: 'center' });
            const rect = el.getBoundingClientRect();
            const opts = { bubbles: true, cancelable: true, view: window, clientX: rect.left + rect.width/2, clientY: rect.top + rect.height/2, detail: 2 };
            el.dispatchEvent(new MouseEvent('dblclick', opts));
            if (typeof el.click === 'function') { el.click(); el.click(); }
            return { ok: true, detail: 'Double-clicked' };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Double-click failed")
    }

    static func waitFor(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        let timeoutMs = (action["timeout"] as? Int) ?? Int(action["value"] as? String ?? "") ?? 8_000
        let pollMs: UInt64 = 150
        let maxAttempts = max(1, timeoutMs / Int(pollMs))

        for attempt in 0..<maxAttempts {
            if action["load"] as? String == "networkidle" || action["state"] as? String == "networkidle" {
                let ready = try? await webView.evaluateJavaScript("document.readyState") as? String
                if ready == "complete", attempt > 4 {
                    return (true, "Page ready")
                }
            } else if let text = action["text"] as? String, !text.isEmpty {
                let found = try? await webView.evaluateJavaScript(
                    "document.body && document.body.innerText.includes(\(jsStringLiteral(text)))"
                ) as? Bool
                if found == true { return (true, "Text appeared: \(text.prefix(40))") }
            } else if let ref = action["ref"] as? String, !ref.isEmpty {
                let visible = await elementVisible(ref: ref, on: webView)
                if visible { return (true, "Element visible: \(ref)") }
            } else if let selector = action["selector"] as? String, !selector.isEmpty {
                let selJSON = jsStringLiteral(selector)
                let found = try? await webView.evaluateJavaScript(
                    "(function(){ const el = document.querySelector(\(selJSON)); if (!el) return false; const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; })()"
                ) as? Bool
                if found == true { return (true, "Selector visible") }
            } else if let ms = Int(action["value"] as? String ?? ""), ms > 0 {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return (true, "Waited \(ms)ms")
            } else {
                let ready = try? await webView.evaluateJavaScript("document.readyState") as? String
                if ready == "complete" { return (true, "DOM complete") }
            }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
        return (false, "Wait timed out after \(timeoutMs)ms")
    }

    static func extract(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        if let ref = action["ref"] as? String, !ref.isEmpty {
            let refJSON = jsStringLiteral(ref)
            let script = """
            (function() {
                const el = window.__openhive_resolve_ref ? window.__openhive_resolve_ref(\(refJSON)) : null;
                if (!el) return { ok: false, error: 'ref not found' };
                const text = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim();
                return { ok: true, detail: text.substring(0, 2000) };
            })();
            """
            return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Extract failed")
        }
        let limit = action["limit"] as? Int ?? 5000
        let script = """
        (function() {
            const text = document.body ? document.body.innerText : '';
            return { ok: true, detail: text.substring(0, \(limit)) };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Extract failed")
    }

    static func evaluate(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        guard let code = action["value"] as? String ?? action["script"] as? String, !code.isEmpty else {
            return (false, "eval requires script in value")
        }
        // Agent-safe: block navigation / cookie theft patterns
        let lower = code.lowercased()
        let blocked = ["document.cookie", "localStorage.clear", "location.href", "window.open("]
        if blocked.contains(where: { lower.contains($0) }) {
            return (false, "eval blocked for security")
        }
        do {
            let result = try await webView.evaluateJavaScript(code)
            let detail: String
            if let s = result as? String {
                detail = String(s.prefix(2000))
            } else if let json = try? JSONSerialization.data(withJSONObject: result ?? NSNull(), options: []),
                      let str = String(data: json, encoding: .utf8) {
                detail = String(str.prefix(2000))
            } else {
                detail = String(describing: result ?? "null").prefix(2000).description
            }
            return (true, detail)
        } catch {
            return (false, "eval error: \(error.localizedDescription.prefix(120))")
        }
    }

    static func scrollIntoView(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        guard let elJS = elementResolverJS(action) else {
            return (false, "scroll_into_view requires ref or selector")
        }
        let script = """
        (function() {
            const el = \(elJS);
            if (!el) return { ok: false, error: 'element not found' };
            el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
            return { ok: true, detail: 'Scrolled into view' };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Scroll into view failed")
    }

    /// Click autocomplete / listbox option by visible text (Playwright getByRole('option')).
    static func clickOption(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        let text = (action["value"] as? String ?? action["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (false, "click_option requires value text") }
        let textJSON = jsStringLiteral(text)
        let script = """
        (function() {
            const needle = \(textJSON).toLowerCase();
            const options = [...document.querySelectorAll('[role=option], [role=listbox] *, li, .autocomplete *, [data-value]')]
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    const label = (el.innerText || el.getAttribute('aria-label') || el.textContent || '').trim().toLowerCase();
                    return r.width > 0 && r.height > 0 && label && (label.includes(needle) || needle.includes(label.slice(0, 20)));
                });
            const el = options.find(o => (o.innerText || '').trim().toLowerCase() === needle) || options[0];
            if (!el) return { ok: false, error: 'option not found: ' + needle };
            el.scrollIntoView({ block: 'center' });
            el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
            el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            if (typeof el.click === 'function') el.click();
            return { ok: true, detail: 'Selected option: ' + needle.substring(0, 60) };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "click_option failed")
    }

    static func upload(_ action: [String: Any], on webView: WKWebView) async -> (success: Bool, detail: String) {
        guard let path = action["value"] as? String ?? action["path"] as? String, !path.isEmpty else {
            return (false, "upload requires file path in value")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (false, "File not found: \(path)")
        }
        await OpenHiveObservation.installAgentAutomation(on: webView)
        let ref = action["ref"] as? String ?? ""
        let refJSON = jsStringLiteral(ref)
        // WKWebView file inputs need native bridge for full parity; mark input for agent follow-up
        let script = """
        (function() {
            let input = \(ref.isEmpty ? "document.querySelector('input[type=file]')" : "(window.__openhive_resolve_ref && window.__openhive_resolve_ref(\(refJSON)))");
            if (!input || input.tagName !== 'INPUT' || input.type !== 'file') {
                input = document.querySelector('input[type=file]');
            }
            if (!input) return { ok: false, error: 'no file input on page' };
            input.scrollIntoView({ block: 'center' });
            input.click();
            return { ok: true, detail: 'Opened file input — native upload bridge pending' };
        })();
        """
        return parseResult(try? await webView.evaluateJavaScript(script)) ?? (false, "Upload failed")
    }

    // MARK: - Helpers

    static func elementVisible(ref: String, on webView: WKWebView) async -> Bool {
        await OpenHiveObservation.installAgentAutomation(on: webView)
        let refJSON = jsStringLiteral(ref)
        let script = """
        (function() {
            const el = window.__openhive_resolve_ref ? window.__openhive_resolve_ref(\(refJSON)) : null;
            if (!el) return false;
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0 && !el.disabled;
        })();
        """
        return (try? await webView.evaluateJavaScript(script) as? Bool) ?? false
    }

    static func elementResolverJS(_ action: [String: Any]) -> String? {
        if let ref = action["ref"] as? String, !ref.isEmpty {
            return "window.__openhive_resolve_ref && window.__openhive_resolve_ref(\(jsStringLiteral(ref)))"
        }
        if let selector = action["selector"] as? String, !selector.isEmpty {
            return "document.querySelector(\(jsStringLiteral(selector)))"
        }
        return nil
    }
}
