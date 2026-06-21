import Foundation
import WebKit

/// Sync Nook WKWebView state into browser-use (Playwright) sessions.
@MainActor
enum OpenHiveBrowserSync {
    private static let maxCookies = 120

    /// Playwright `storage_state` — only cookies relevant to the current page (keeps WS payload small).
    static func exportStorageState(from webView: WKWebView) async -> [String: Any] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookiesAsync()
        let host = webView.url?.host?.lowercased() ?? ""

        let relevant = cookies.filter { cookie in
            cookieMatchesPage(cookie: cookie, host: host)
        }
        let chosen = relevant.isEmpty ? Array(cookies.prefix(maxCookies)) : Array(relevant.prefix(maxCookies))

        let mapped = chosen.compactMap { cookie -> [String: Any]? in
            guard cookie.value.utf8.count <= 4096 else { return nil }
            var entry: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path.isEmpty ? "/" : cookie.path,
                "httpOnly": cookie.isHTTPOnly,
                "secure": cookie.isSecure,
            ]
            if let expires = cookie.expiresDate, expires.timeIntervalSince1970 > 0 {
                entry["expires"] = expires.timeIntervalSince1970
            }
            if let sameSite = cookie.sameSitePolicy?.rawValue {
                entry["sameSite"] = sameSite
            }
            return entry
        }
        return ["cookies": mapped, "origins": [] as [[String: Any]]]
    }

    private static func cookieMatchesPage(cookie: HTTPCookie, host: String) -> Bool {
        guard !host.isEmpty else { return true }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain
            || host.hasSuffix(".\(domain)")
            || domain.hasSuffix(host)
            || cookie.domain.lowercased() == ".\(host)"
    }

    /// Mirror agent URL into Nook only when it is a meaningful navigation (not every micro-step).
    static func mirrorURLIfNeeded(
        _ urlString: String,
        on webView: WKWebView,
        lastMirrored: inout String?,
        force: Bool = false
    ) {
        guard !urlString.isEmpty,
              urlString.hasPrefix("http"),
              let url = URL(string: urlString) else { return }

        if !force {
            guard shouldMirror(newURL: url, previous: lastMirrored, current: webView.url) else { return }
        }

        lastMirrored = urlString
        if webView.url?.absoluteString == urlString { return }
        webView.load(URLRequest(url: url))
    }

    private static func shouldMirror(newURL: URL, previous: String?, current: URL?) -> Bool {
        let path = newURL.path
        // Skip mirror on in-page hash/query-only churn during agent steps
        if let previous, let prevURL = URL(string: previous),
           prevURL.host == newURL.host,
           prevURL.path == newURL.path {
            return false
        }
        if let current, current.host == newURL.host, current.path == newURL.path {
            return false
        }
        // Always mirror when path changes (e.g. /flights → /flights/search)
        if path.contains("/search") || path.contains("/results") {
            return true
        }
        return previous == nil
    }
}
