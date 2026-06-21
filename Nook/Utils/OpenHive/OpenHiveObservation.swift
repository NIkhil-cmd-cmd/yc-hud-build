//
//  OpenHiveObservation.swift
//  OpenHive — passive observation + browser action replay
//

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
