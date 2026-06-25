import Foundation
import OSLog

enum AppTrace {
    private static let logger = Logger(subsystem: "com.tid.VoiceCalendarAssistant", category: "Trace")
    private static let fileQueue = DispatchQueue(label: "com.tid.VoiceCalendarAssistant.AppTrace")

    static func makeID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    static func point(_ name: String, fields: [String: String] = [:]) {
        #if DEBUG
        let message = "trace point \(name)\(fieldSuffix(fields))"
        logger.notice("\(message, privacy: .public)")
        append(message)
        #endif
    }

    static func measure<T>(
        _ name: String,
        fields: [String: String] = [:],
        operation: () throws -> T
    ) rethrows -> T {
        #if DEBUG
        let startedAt = Date()
        log("trace start \(name)\(fieldSuffix(fields))")
        defer {
            logEnd(name, fields: fields, startedAt: startedAt)
        }
        #endif

        return try operation()
    }

    static func measure<T>(
        _ name: String,
        fields: [String: String] = [:],
        operation: () async throws -> T
    ) async rethrows -> T {
        #if DEBUG
        let startedAt = Date()
        log("trace start \(name)\(fieldSuffix(fields))")
        defer {
            logEnd(name, fields: fields, startedAt: startedAt)
        }
        #endif

        return try await operation()
    }

    static func beginSpan(_ name: String, fields: [String: String] = [:]) -> Date {
        let startedAt = Date()
        #if DEBUG
        log("trace start \(name)\(fieldSuffix(fields))")
        #endif
        return startedAt
    }

    static func endSpan(_ name: String, startedAt: Date?, fields: [String: String] = [:]) {
        guard let startedAt else { return }
        #if DEBUG
        logEnd(name, fields: fields, startedAt: startedAt)
        #endif
    }

    static func elapsedMilliseconds(since startedAt: Date?) -> String? {
        guard let startedAt else { return nil }
        return String(format: "%.1f", Date().timeIntervalSince(startedAt) * 1000)
    }

    static var traceLogURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tid-trace.log")
    }

    static var failureBundlesDirectoryURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tid-failure-bundles", isDirectory: true)
    }

    static func recentLines(limit: Int = 180) -> [String] {
        fileQueue.sync {
            guard let traceLogURL,
                  let text = try? String(contentsOf: traceLogURL, encoding: .utf8) else {
                return []
            }

            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            return Array(lines.suffix(limit))
        }
    }

    static func clear() {
        fileQueue.sync {
            guard let traceLogURL else { return }
            try? FileManager.default.removeItem(at: traceLogURL)
        }
    }

    static func preserveFailureBundle(
        reason: String,
        fields: [String: String] = [:],
        recentLineLimit: Int = 260
    ) {
        #if DEBUG
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let bundleID = "\(createdAt)-\(makeID())"
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        var metadata = fields
        metadata["reason"] = reason
        metadata["created_at"] = createdAt
        metadata["bundle_id"] = bundleID
        metadata["recent_line_limit"] = "\(recentLineLimit)"

        point("AppTrace.failureBundleQueued", fields: metadata)

        fileQueue.async {
            guard let failureBundlesDirectoryURL else { return }

            let fileManager = FileManager.default
            let bundleURL = failureBundlesDirectoryURL.appendingPathComponent(bundleID, isDirectory: true)

            do {
                try fileManager.createDirectory(
                    at: bundleURL,
                    withIntermediateDirectories: true
                )

                let traceText: String
                if let traceLogURL,
                   let text = try? String(contentsOf: traceLogURL, encoding: .utf8) {
                    let lines = text
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map(String.init)
                    traceText = Array(lines.suffix(recentLineLimit)).joined(separator: "\n") + "\n"
                } else {
                    traceText = ""
                }

                try traceText.write(
                    to: bundleURL.appendingPathComponent("tid-trace-window.log"),
                    atomically: true,
                    encoding: .utf8
                )

                let metadataData = try JSONSerialization.data(
                    withJSONObject: metadata,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try metadataData.write(
                    to: bundleURL.appendingPathComponent("metadata.json"),
                    options: .atomic
                )

                let metadataText = metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "\n") + "\n"
                try metadataText.write(
                    to: bundleURL.appendingPathComponent("metadata.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                logger.error("failure bundle write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    private static func logEnd(_ name: String, fields: [String: String], startedAt: Date) {
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt) * 1000)
        var endFields = fields
        endFields["duration_ms"] = elapsed
        log("trace end \(name)\(fieldSuffix(endFields))")
    }

    private static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        append(message)
    }

    private static func append(_ message: String) {
        fileQueue.async {
            guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return
            }

            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            let fileURL = cachesURL.appendingPathComponent("tid-trace.log")

            guard let data = line.data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private static func fieldSuffix(_ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return "" }

        let body = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        return " \(body)"
    }
}
