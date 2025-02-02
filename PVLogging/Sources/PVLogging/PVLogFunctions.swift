//
//  PVLogFunctions.swift
//
//
//  Created by Joseph Mattiello on 1/17/23.
//

import OSLog

extension os.Logger: Sendable {
    /// Using your bundle identifier is a great way to ensure a unique identifier.
    private static let subsystem: String = Bundle.main.bundleIdentifier ?? ""

    /// Logs the view cycles like a view that appeared.
    @usableFromInline
    static let viewCycle = Logger(subsystem: subsystem, category: "viewcycle")

    /// All logs related to tracking and analytics.
    @usableFromInline
    static let statistics = Logger(subsystem: subsystem, category: "statistics")

    /// All logs related to tracking and analytics.
    @usableFromInline
    static let networking = Logger(subsystem: subsystem, category: "network")

    /// All logs related to video processing and rendering.
    @usableFromInline
    static let video = Logger(subsystem: subsystem, category: "video")

    /// All logs related to audio processing and rendering.
    @usableFromInline
    static let audio = Logger(subsystem: subsystem, category: "audio")

    /// All logs related to  libraries and databases.
    @usableFromInline
    static let database = Logger(subsystem: subsystem, category: "database")

    /// General logs
    @usableFromInline
    static let general = Logger(subsystem: subsystem, category: "general")
}

@inlinable
public func log(_ message: @autoclosure () -> String,
                level: OSLogType = .debug,
                category: Logger = .general,
                file: String = #file,
                function: String = #function,
                line: Int = #line) {
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let emoji: String
    switch level {
    case .debug:
        emoji = "🔍"
    case .info:
        emoji = "ℹ️"
    case .error:
        emoji = "❌"
    case .fault:
        emoji = "💥"
    default:
        emoji = "📝"
    }
    let logMessage = "\(emoji) \(fileName):\(line) - \(function): \(message())"

    switch level {
    case .debug:
        category.debug("\(logMessage, privacy: .public)")
    case .info:
        category.info("\(logMessage, privacy: .public)")
    case .error:
        category.error("\(logMessage, privacy: .public)")
    case .fault:
        category.fault("\(logMessage, privacy: .public)")
    default:
        category.log(level: level, "\(logMessage, privacy: .public)")
    }
}

// Update convenience functions to include emojis
@inlinable
public func DLOG(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    log(message(), level: .debug, file: file, function: function, line: line)
}

@inlinable
public func ILOG(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    log(message(), level: .info, file: file, function: function, line: line)
}

@inlinable
public func ELOG(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    log(message(), level: .error, file: file, function: function, line: line)
}

@inlinable
public func WLOG(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    let warningPrefix = "⚠️"
    log(warningPrefix + " " + message(), level: .info, file: file, function: function, line: line)
}

@inlinable
public func VLOG(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    #if DEBUG
    log("🔬 " + message(), level: .debug, file: file, function: function, line: line)
    #endif
}
