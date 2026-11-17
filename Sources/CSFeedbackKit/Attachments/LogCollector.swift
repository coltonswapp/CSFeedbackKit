import Foundation
import OSLog

/// Recent `os_log` / `Logger` entries from this process. `print` output is not included.
enum LogCollector {
    /// Collects off the main thread. Returns UTF-8 text, newest lines kept when over `maxBytes`.
    static func collect(_ config: LogsConfig, endingAt end: Date, bundleId: String) async -> Data? {
        let subsystems = config.subsystems.isEmpty ? [bundleId] : config.subsystems
        let start = end.addingTimeInterval(-config.lastMinutes * 60)
        let maxBytes = config.maxBytes
        return await Task.detached(priority: .utility) {
            read(subsystems: subsystems, from: start, to: end, maxBytes: maxBytes)
        }.value
    }

    private static func read(subsystems: [String], from start: Date, to end: Date, maxBytes: Int) -> Data? {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: start)
            let predicate = NSPredicate(format: "subsystem IN %@", subsystems)
            let entries = try store.getEntries(at: position, matching: predicate)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                guard entry.date <= end else { break }
                lines.append(
                    "\(formatter.string(from: entry.date)) [\(entry.subsystem)/\(entry.category)] "
                        + "\(level(entry.level)): \(entry.composedMessage)"
                )
            }
            guard !lines.isEmpty else { return nil }
            return trimmed(lines, maxBytes: maxBytes)
        } catch {
            Log.general.error("Log collection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Keeps the newest lines that fit.
    private static func trimmed(_ lines: [String], maxBytes: Int) -> Data {
        var kept: [String] = []
        var size = 0
        for line in lines.reversed() {
            let lineSize = line.utf8.count + 1
            if size + lineSize > maxBytes { break }
            kept.append(line)
            size += lineSize
        }
        var text = kept.reversed().joined(separator: "\n")
        if kept.count < lines.count {
            text = "… \(lines.count - kept.count) older lines trimmed\n" + text
        }
        return Data(text.utf8)
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "log"
        @unknown default: return "log"
        }
    }
}
