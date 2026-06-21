//
//  OpenHiveObservation.swift
//  OpenHive — passive observation + browser action replay
//

import AppKit
import Foundation
import WebKit

@MainActor
enum OpenHiveObservation {
    static let scriptSource = """
    (function() {
        if (window.__openhive_obs__) return;
        window.__openhive_obs__ = true;

        function selectorFor(el) {
            if (!el || !el.tagName) return '';
            if (el.id) return '#' + CSS.escape(el.id);
            var name = el.getAttribute('name');
            if (name) return el.tagName.toLowerCase() + '[name="' + name.replace(/"/g, '\\\\"') + '"]';
            var aria = el.getAttribute('aria-label');
            if (aria) return el.tagName.toLowerCase() + '[aria-label="' + aria.replace(/"/g, '\\\\"') + '"]';
            var ph = el.getAttribute('placeholder');
            if (ph) return el.tagName.toLowerCase() + '[placeholder="' + ph.replace(/"/g, '\\\\"') + '"]';
            return '';
        }

        function send(payload) {
            if (window.webkit && window.webkit.messageHandlers.openhiveObserve) {
                window.webkit.messageHandlers.openhiveObserve.postMessage(payload);
            }
        }

        document.addEventListener('click', function(e) {
            var el = e.target;
            if (!el || !el.closest) return;
            var clickable = el.closest('a,button,input,[role="button"],[onclick]') || el;
            send({
                type: 'click',
                tag: clickable.tagName || '',
                text: (clickable.innerText || clickable.value || clickable.getAttribute('aria-label') || '').slice(0, 120).trim(),
                role: clickable.getAttribute('role') || '',
                name: clickable.getAttribute('name') || clickable.id || '',
                selector: selectorFor(clickable),
                url: location.href
            });
        }, true);

        document.addEventListener('change', function(e) {
            var el = e.target;
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
                send({
                    type: 'type',
                    name: el.name || el.id || el.placeholder || '',
                    value: el.value || '',
                    selector: selectorFor(el),
                    url: location.href
                });
            }
        }, true);

        document.addEventListener('input', function(e) {
            var el = e.target;
            if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA' && !el.isContentEditable)) return;
            send({
                type: 'type',
                name: el.name || el.id || el.getAttribute('aria-label') || el.placeholder || '',
                value: el.value || el.textContent || '',
                selector: selectorFor(el),
                url: location.href
            });
        }, true);

        document.addEventListener('keydown', function(e) {
            if (e.key !== 'Enter') return;
            var el = e.target;
            if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
            send({
                type: 'type',
                name: el.name || el.id || el.placeholder || '',
                value: el.value || '',
                selector: selectorFor(el),
                submit: true,
                url: location.href
            });
        }, true);

        send({ type: 'navigate', url: location.href, title: document.title });
    })();
    """

    static func inject(into webView: WKWebView) {
        OpenHiveLogger.log("Observation", "inject_script", data: ["url": webView.url?.absoluteString ?? ""])
        webView.evaluateJavaScript(scriptSource) { _, error in
            if let error {
                OpenHiveLogger.error("Observation", "inject_failed", data: ["error": error.localizedDescription])
            } else {
                OpenHiveLogger.log("Observation", "inject_ok")
            }
        }
    }

    /// Single source of truth for which elements are addressable + their order.
    /// BOTH the candidate snapshot (LLM @refs) and ref resolution (click/fill) MUST
    /// use this identical collector so that `e5` in the candidate list is the exact
    /// same DOM element as `e5` at resolution time. Any divergence makes every
    /// click/type by ref miss, leaving only `navigate` working.
    static let elementCollectorJS = """
    (function() {
        var SEL = 'input, textarea, select, button, [role=button], [role=option], [role=gridcell], [role=menuitem], [role=combobox], [role=searchbox], [role=link], [role=tab], [role=checkbox], [aria-label], a[href], [onclick], [contenteditable=true]';
        var seen = new Set();
        return [...document.querySelectorAll(SEL)].filter(function(el) {
            if (seen.has(el)) return false;
            seen.add(el);
            var rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) return false;
            if (el.disabled) return false;
            var style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none' || parseFloat(style.opacity || '1') === 0) return false;
            var tag = el.tagName;
            var text = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.textContent || '').trim();
            return !!(text || tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable);
        });
    })()
    """

    /// Canonical candidate snapshot — same query/filter/index used for LLM refs and click/fill resolution.
    static let agentCandidateQueryJS = """
    (function(limit) {
        limit = limit || 120;
        var els = \(elementCollectorJS);
        return els.slice(0, limit).map(function(el, idx) {
            var rect = el.getBoundingClientRect();
            var text = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.textContent || '').trim();
            var tag = el.tagName.toLowerCase();
            var ariaLabel = el.getAttribute('aria-label') || '';
            var placeholder = el.getAttribute('placeholder') || '';
            var name = el.getAttribute('name') || el.id || '';
            var selector = '';
            if (el.id) selector = '#' + CSS.escape(el.id);
            else if (name) selector = tag + '[name="' + name.replace(/"/g, '\\\\"') + '"]';
            else if (ariaLabel) selector = tag + '[aria-label="' + ariaLabel.replace(/"/g, '\\\\"') + '"]';
            else if (placeholder) selector = tag + '[placeholder="' + placeholder.replace(/"/g, '\\\\"') + '"]';
            return {
                ref: 'e' + idx,
                tag: tag,
                role: el.getAttribute('role') || tag,
                text: text.slice(0, 200),
                ariaLabel: ariaLabel,
                placeholder: placeholder,
                name: name,
                selector: selector,
                bbox: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
                visible: true,
                enabled: !el.disabled
            };
        });
    })
    """

    static let agentAutomationBootstrapJS = """
    (function() {
        // Always (re)install so the resolver and query stay in lockstep, even if a
        // prior/older version installed a divergent resolver on this context.
        window.__openhive_agent_query = \(agentCandidateQueryJS);
        window.__openhive_resolve_ref = function(ref) {
            var idx = parseInt(String(ref).replace(/^@?e/i, ''), 10);
            if (isNaN(idx)) return null;
            var els = \(elementCollectorJS);
            return els[idx] || null;
        };
    })();
    """

    static func installAgentAutomation(on webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript(agentAutomationBootstrapJS)
    }

    static func agentCandidates(from webView: WKWebView, limit: Int = 120) async -> [[String: Any]] {
        let script = "window.__openhive_agent_query ? window.__openhive_agent_query(\(limit)) : (\(agentCandidateQueryJS))(\(limit));"
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? [[String: Any]] ?? [])
            }
        }
    }

    static func interactiveSnapshot(from webView: WKWebView) async -> [[String: Any]] {
        let script = """
        (function() {
            var selectors = 'a[href], button, input, select, textarea, [role="button"], [role="link"], [onclick], [tabindex]';
            var elements = document.querySelectorAll(selectors);
            var results = [];
            var idx = 0;
            for (var el of elements) {
                if (results.length >= 60) break;
                if (el.offsetParent === null && el.style.display !== 'contents') continue;
                var tag = el.tagName.toLowerCase();
                var text = (el.innerText || el.value || '').trim().slice(0, 80);
                var aria = el.getAttribute('aria-label') || '';
                var placeholder = el.getAttribute('placeholder') || '';
                var name = el.getAttribute('name') || el.id || '';
                var label = text || aria || placeholder || name;
                if (!label && tag === 'input') continue;
                var selector = '';
                if (el.id) selector = '#' + CSS.escape(el.id);
                else if (el.getAttribute('name')) selector = tag + '[name="' + el.getAttribute('name').replace(/"/g, '\\\\"') + '"]';
                else if (aria) selector = tag + '[aria-label="' + aria.replace(/"/g, '\\\\"') + '"]';
                results.push({
                    ref: '@e' + idx,
                    tag: tag,
                    text: label.slice(0, 60),
                    role: el.getAttribute('role') || '',
                    name: name,
                    selector: selector
                });
                idx++;
            }
            return results;
        })();
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                if let arr = result as? [[String: Any]] {
                    continuation.resume(returning: arr)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    static func accessibilitySnapshot(from webView: WKWebView) async -> Any? {
        let elements = await interactiveSnapshot(from: webView)
        return ["elements": elements, "count": elements.count]
    }

    static func documentHTML(from webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    static func screenshotPath(from webView: WKWebView, identifier: String) async -> String? {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true

        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let pngData = bitmap.representation(using: .png, properties: [:])
                else {
                    if let error {
                        OpenHiveLogger.error("Observation", "snapshot_failed", data: ["error": error.localizedDescription])
                    }
                    continuation.resume(returning: nil)
                    return
                }

                let previewDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/OpenHive/harvest/previews", isDirectory: true)
                try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
                let fileName = "\(identifier)_\(Int(Date().timeIntervalSince1970)).png"
                let path = previewDir.appendingPathComponent(fileName)
                do {
                    try pngData.write(to: path)
                    continuation.resume(returning: path.path)
                } catch {
                    OpenHiveLogger.error("Observation", "snapshot_write_failed", data: ["error": error.localizedDescription])
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func perform(action: [String: Any], on webView: WKWebView) async -> Bool {
        guard let type = action["type"] as? String else { return false }

        switch type {
        case "navigate":
            if let urlStr = action["url"] as? String, let url = URL(string: urlStr) {
                webView.load(URLRequest(url: url))
                return true
            }
        case "click":
            return await performClick(action: action, on: webView)
        case "fill", "type":
            return await performType(action: action, on: webView)
        default:
            break
        }
        return false
    }

    private static func performClick(action: [String: Any], on webView: WKWebView) async -> Bool {
        if let selector = action["selector"] as? String, !selector.isEmpty {
            let selJSON = jsonString(selector)
            let script = """
            (function() {
                var el = document.querySelector(\(selJSON));
                if (!el) return false;
                el.scrollIntoView({block: 'center'});
                el.click();
                return true;
            })();
            """
            return await evalBool(script, on: webView)
        }

        if let text = action["text"] as? String, !text.isEmpty {
            let textJSON = jsonString(text)
            let script = """
            (function() {
                var query = \(textJSON).toLowerCase();
                var candidates = document.querySelectorAll('a, button, input[type="submit"], input[type="button"], [role="button"], [onclick], span, div');
                var best = null;
                var bestScore = Infinity;
                for (var el of candidates) {
                    if (el.offsetParent === null && el.style.display !== 'contents') continue;
                    var label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '').trim();
                    var lower = label.toLowerCase();
                    if (!label) continue;
                    if (lower === query) { best = el; break; }
                    if (lower.includes(query) && label.length < bestScore) {
                        best = el;
                        bestScore = label.length;
                    }
                }
                if (!best) return false;
                best.scrollIntoView({block: 'center'});
                best.click();
                return true;
            })();
            """
            return await evalBool(script, on: webView)
        }

        if let name = action["name"] as? String, !name.isEmpty {
            let nameJSON = jsonString(name)
            let script = """
            (function() {
                var el = document.querySelector('[name="' + \(nameJSON) + '"], #' + \(nameJSON));
                if (!el) return false;
                el.scrollIntoView({block: 'center'});
                el.click();
                return true;
            })();
            """
            return await evalBool(script, on: webView)
        }

        return false
    }

    private static func performType(action: [String: Any], on webView: WKWebView) async -> Bool {
        let value = action["value"] as? String ?? action["text"] as? String ?? ""
        let valueJSON = jsonString(value)

        if let selector = action["selector"] as? String, !selector.isEmpty {
            let selJSON = jsonString(selector)
            let script = """
            (function() {
                var el = document.querySelector(\(selJSON));
                if (!el) return false;
                el.focus();
                el.value = \(valueJSON);
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                return true;
            })();
            """
            return await evalBool(script, on: webView)
        }

        if let name = action["name"] as? String, !name.isEmpty {
            let nameJSON = jsonString(name)
            let script = """
            (function() {
                var el = document.querySelector('[name="' + \(nameJSON) + '"], #' + \(nameJSON) + ', [placeholder*="' + \(nameJSON) + '"]');
                if (!el) el = document.querySelector('input,textarea');
                if (!el) return false;
                el.focus();
                el.value = \(valueJSON);
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                return true;
            })();
            """
            return await evalBool(script, on: webView)
        }

        let script = """
        (function() {
            var el = document.activeElement || document.querySelector('input,textarea,[contenteditable="true"]');
            if (!el) return false;
            el.focus();
            if (el.isContentEditable) {
                el.textContent = \(valueJSON);
            } else {
                el.value = \(valueJSON);
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
        })();
        """
        return await evalBool(script, on: webView)
    }

    private static func evalBool(_ script: String, on webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: (result as? Bool) ?? false)
            }
        }
    }

    private static func jsonString(_ value: String) -> String {
        // JSONSerialization only accepts array/dict at top level — use JSONEncoder for strings.
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
}
