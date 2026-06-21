//
//  OpenHiveObservation.swift
//  OpenHive — passive page observation script
//

import Foundation
import WebKit

enum OpenHiveObservation {
    static let scriptSource = """
    (function() {
        if (window.__openhive_obs__) return;
        window.__openhive_obs__ = true;
        function send(payload) {
            if (window.webkit && window.webkit.messageHandlers.openhiveObserve) {
                window.webkit.messageHandlers.openhiveObserve.postMessage(payload);
            }
        }
        document.addEventListener('click', function(e) {
            var el = e.target;
            send({
                type: 'click',
                tag: el.tagName || '',
                text: (el.innerText || el.value || '').slice(0, 120),
                role: el.getAttribute('role') || '',
                name: el.getAttribute('name') || el.id || '',
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
                    url: location.href
                });
            }
        }, true);
        send({ type: 'navigate', url: location.href, title: document.title });
    })();
    """

    static func inject(into webView: WKWebView) {
        webView.evaluateJavaScript(scriptSource, completionHandler: nil)
    }

    static func accessibilitySnapshot(from webView: WKWebView) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                """
                (function() {
                    function walk(node, depth) {
                        if (!node || depth > 8) return null;
                        var o = {
                            role: node.role || node.tagName || '',
                            name: node.name || node.innerText || node.placeholder || '',
                            ref: node.id ? '@' + node.id : ''
                        };
                        if (node.children && node.children.length) {
                            o.children = Array.from(node.children).slice(0, 40).map(function(c) {
                                return walk(c, depth + 1);
                            }).filter(Boolean);
                        }
                        return o;
                    }
                    return walk(document.body, 0);
                })();
                """
            ) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }

    static func perform(action: [String: Any], on webView: WKWebView) async -> Bool {
        guard let type = action["type"] as? String else { return false }
        switch type {
        case "navigate":
            if let urlStr = action["url"] as? String, let url = URL(string: urlStr) {
                await MainActor.run { webView.load(URLRequest(url: url)) }
                return true
            }
        case "click", "fill", "type":
            let ref = action["ref"] as? String ?? ""
            let value = action["value"] as? String ?? action["text"] as? String ?? ""
            let js: String
            if type == "click" {
                js = """
                (function() {
                    var ref = '\(ref.replacingOccurrences(of: "'", with: "\\'"))';
                    var el = ref.startsWith('@') ? document.getElementById(ref.slice(1)) : null;
                    if (!el && ref) el = document.querySelector('[aria-label="'+ref+'"]');
                    if (!el) el = document.activeElement;
                    if (el) { el.click(); return true; }
                    return false;
                })();
                """
            } else {
                js = """
                (function() {
                    var el = document.activeElement || document.querySelector('input,textarea');
                    if (el) { el.value = '\(value.replacingOccurrences(of: "'", with: "\\'"))'; el.dispatchEvent(new Event('input', {bubbles:true})); return true; }
                    return false;
                })();
                """
            }
            return await withCheckedContinuation { cont in
                webView.evaluateJavaScript(js) { result, _ in
                    cont.resume(returning: (result as? Bool) ?? false)
                }
            }
        default:
            break
        }
        return false
    }
}
