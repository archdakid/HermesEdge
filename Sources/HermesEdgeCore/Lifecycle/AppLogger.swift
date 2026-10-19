import Foundation
import Combine

/// Real-time on-device logger and crash diagnostics recorder.
/// Writes all application logs and fatal exceptions to `Documents/debug.log` and `Documents/crash.log`.
@MainActor
public final class AppLogger: ObservableObject {
    public static let shared = AppLogger()

    @Published public private(set) var recentLogs: [String] = []

    private var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("debug.log")
    }

    private var crashFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("crash.log")
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public init() {
        // Ensure Documents directory exists
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        installCrashHandler()
        checkPreviousCrash()
        log("HermesEdge diagnostics initialized.")
    }

    /// Logs a formatted message to console, memory buffer, and Documents/debug.log.
    public func log(_ message: String, tag: String = "SYSTEM") {
        let timestamp = dateFormatter.string(from: Date())
        let formatted = "[\(timestamp)][\(tag)] \(message)"
        
        print(formatted)
        recentLogs.append(formatted)
        if recentLogs.count > 300 {
            recentLogs.removeFirst(50)
        }

        // Append to Documents/debug.log
        appendToFile(formatted + "\n", url: logFileURL)
    }

    /// Reads the entire debug log from disk.
    public func readLogFile() -> String {
        return (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? recentLogs.joined(separator: "\n")
    }

    /// Reads previous crash log if present.
    public func readCrashFile() -> String? {
        guard FileManager.default.fileExists(atPath: crashFileURL.path) else { return nil }
        return try? String(contentsOf: crashFileURL, encoding: .utf8)
    }

    /// Clears the crash log.
    public func clearCrashFile() {
        try? FileManager.default.removeItem(at: crashFileURL)
    }

    /// Clears all logs.
    public func clearLogs() {
        recentLogs.removeAll()
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    private func checkPreviousCrash() {
        if let crash = readCrashFile() {
            log("⚠️ PREVIOUS UNCAUGHT CRASH DETECTED:\n\(crash)", tag: "CRASH")
        }
    }

    private func appendToFile(_ text: String, url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = text.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    /// Installs system-level NSException and POSIX signal handlers to record fatal crashes.
    public func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let crashURL = docs.appendingPathComponent("crash.log")
            let debugURL = docs.appendingPathComponent("debug.log")

            let crashReport = """
            ================================================================
            FATAL UNCAUGHT EXCEPTION: \(Date())
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "Unknown reason")
            Call Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            ================================================================
            """

            if let data = crashReport.data(using: .utf8) {
                try? data.write(to: crashURL, options: .atomic)
                if let handle = try? FileHandle(forWritingTo: debugURL) {
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                }
            }
        }
    }
}
