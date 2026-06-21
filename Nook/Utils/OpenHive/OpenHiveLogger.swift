//
//  OpenHiveLogger.swift
//  File logging for agent debugging (yc/logs/) — no WS relay on failure path
//

import Foundation
import OSLog

enum OpenHiveLogger {
    private static let osLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenHive",
        category: "OpenHive"
    )

    private static var logURLs: [URL] {
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenHive/logs/openhive-swift.log")
        let devMirror = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("yc/logs/openhive-swift.log")
        var urls = [appSupport]
        if fm.fileExists(atPath: devMirror.deletingLastPathComponent().path) {
            urls.append(devMirror)
        }
        return urls
    }

    static func log(_ component: String, _ message: String, data: [String: Any] = [:]) {
        write(component: component, message: message, data: data, level: "INFO", relay: shouldRelay(component: component, message: message))
    }

    static func error(_ component: String, _ message: String, data: [String: Any] = [:]) {
        var d = data
        d["level"] = "ERROR"
        write(component: component, message: message, data: d, level: "ERROR", relay: false)
    }

    private static func shouldRelay(component: String, message: String) -> Bool {
        if component == "EngineBridge" { return false }
        if component == "Tab" && message == "openhiveObserve" { return false }
        return true
    }

    private static func write(component: String, message: String, data: [String: Any], level: String, relay: Bool) {
        let ts = ISO8601DateFormatter().string(from: Date())
        var payload: [String: Any] = ["ts": ts, "component": component, "level": level, "msg": message]
        if !data.isEmpty { payload["data"] = data }

        let line: String
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: json, encoding: .utf8) {
            line = str + "\n"
        } else {
            line = "[\(ts)] \(component): \(message)\n"
        }

        osLog.info("[\(component)] \(message)")

        let fm = FileManager.default
        for url in logURLs {
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let d = line.data(using: .utf8) { handle.write(d) }
                try? handle.close()
            }
        }

        if relay {
            Task { @MainActor in
                if EngineBridge.shared.isConnected {
                    EngineBridge.shared.relayLog(component: component, message: message, data: data)
                }
            }
        }
    }
}
