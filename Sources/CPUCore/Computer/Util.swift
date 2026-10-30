import Foundation

struct HelperError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

public enum LogLevel: Int {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    static let current: LogLevel = {
        switch (ProcessInfo.processInfo.environment["CPU_LOG_LEVEL"] ?? "info").lowercased() {
        case "debug":
            return .debug
        case "warn", "warning":
            return .warn
        case "error":
            return .error
        default:
            return .info
        }
    }()
}

/// Diagnostic logging goes to stderr; the Node client persists it to the daily helper log.
public func helperLog(_ level: LogLevel, _ message: @autoclosure () -> String) {
    guard level.rawValue >= LogLevel.current.rawValue else {
        return
    }
    let tag: String
    switch level {
    case .debug:
        tag = "debug"
    case .info:
        tag = "info"
    case .warn:
        tag = "warn"
    case .error:
        tag = "error"
    }
    FileHandle.standardError.write(Data("[\(tag)] \(message())\n".utf8))
}

func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String {
        return Int(string.trimmingCharacters(in: .whitespaces))
    }
    return nil
}

func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double {
        return double
    }
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let string = value as? String {
        return Double(string.trimmingCharacters(in: .whitespaces))
    }
    return nil
}

func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    if let string = value as? String {
        switch string.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }
    return nil
}

func stringValue(_ value: Any?) -> String? {
    guard let string = value as? String else {
        return nil
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func requireInt(_ value: Any?, _ name: String) throws -> Int {
    guard let int = intValue(value) else {
        throw HelperError("\(name) must be an integer")
    }
    return int
}

func requireDouble(_ value: Any?, _ name: String) throws -> Double {
    guard let double = doubleValue(value), double.isFinite else {
        throw HelperError("\(name) must be a number")
    }
    return double
}

func requireString(_ value: Any?, _ name: String) throws -> String {
    guard let string = value as? String, !string.isEmpty else {
        throw HelperError("\(name) must be a non-empty string")
    }
    return string
}

private let invisibleFormatScalars: Set<Unicode.Scalar> = [
    "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
    "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}"
]

/// Drops bidi/format marks (e.g. the LRM that Calculator wraps around digits).
func stripInvisibleMarks(_ value: String) -> String {
    guard value.unicodeScalars.contains(where: { invisibleFormatScalars.contains($0) }) else {
        return value
    }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: value.unicodeScalars.filter { !invisibleFormatScalars.contains($0) })
    return String(scalars)
}

/// Single-line, length-bounded rendering for values embedded in the accessibility outline.
func compactText(_ value: String, limit: Int) -> String {
    let collapsed = stripInvisibleMarks(value)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: " ")
    if collapsed.count <= limit {
        return collapsed
    }
    return String(collapsed.prefix(limit)) + "…(+\(collapsed.count - limit) chars)"
}

func truncateText(_ value: String, limit: Int) -> String {
    if value.count <= limit {
        return value
    }
    return String(value.prefix(limit)) + "\n[truncated \(value.count - limit) chars]"
}

func roundedPoint(_ value: CGFloat) -> Double {
    return (Double(value) * 10).rounded() / 10
}

func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}
