import Foundation
import os

struct AppLog {
    let logger: Logger
    let tag: String

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        Swift.print("[\(timestamp)] [\(tag)] \(message)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Swift.print("[\(timestamp)] [\(tag) ERR] \(message)")
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    /// Logs a line that may contain user content — transcript text, prompts,
    /// model output. Compiled to a no-op in release builds, so meeting content
    /// never reaches the unified log or stdout; full detail in DEBUG only. The
    /// `@autoclosure` means the message (and any `prefix`/interpolation it does)
    /// isn't even built in release.
    func sensitive(_ message: @autoclosure () -> String) {
        #if DEBUG
            let text = message()
            logger.debug("\(text, privacy: .public)")
            Swift.print("[\(timestamp)] [\(tag)] \(text)")
        #endif
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

enum Log {
    private static let subsystem = "com.example.nod"
    static let ui    = AppLog(logger: Logger(subsystem: subsystem, category: "UI"),    tag: "UI")
    static let audio = AppLog(logger: Logger(subsystem: subsystem, category: "Audio"), tag: "AUDIO")
    static let stt   = AppLog(logger: Logger(subsystem: subsystem, category: "STT"),   tag: "STT")
    static let llm   = AppLog(logger: Logger(subsystem: subsystem, category: "LLM"),   tag: "LLM")
    static let auth  = AppLog(logger: Logger(subsystem: subsystem, category: "Auth"),  tag: "AUTH")
    static let screen = AppLog(logger: Logger(subsystem: subsystem, category: "Screen"), tag: "SCREEN")
}
