import Foundation
import OSLog

enum AppLog {
    private static let logger = Logger(subsystem: "app.voicestick.mac", category: "VoiceStick")

    static var isDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "VoiceStickDebugLogging") ||
            ProcessInfo.processInfo.environment["VOICESTICK_DEBUG_LOGS"] == "1"
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        let text = message()
        logger.notice("VoiceStick: \(text, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("VoiceStick: \(text, privacy: .public)")
    }
}
