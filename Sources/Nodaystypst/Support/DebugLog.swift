import Foundation

/// Lightweight file logger used during diagnostics. Writes append-only lines to
/// ~/Library/Logs/Nodaystypst/debug.log so the host can tail the file to see
/// why a prediction is failing in a particular app.
enum DebugLog {
    nonisolated static let isEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["NODAYSTYPST_DEBUG_LOG"] == "1"
    }()

    nonisolated static let url: URL = {
        let logs = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return logs
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Nodaystypst", isDirectory: true)
            .appendingPathComponent("debug.log")
    }()

    nonisolated static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(Self.timestamp())] \(message())"
        let path = url.path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? data.write(to: url)
            }
        } else {
            try? data.write(to: url)
        }
    }

    nonisolated private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
