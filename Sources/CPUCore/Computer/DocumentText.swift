import Foundation
import PDFKit

/// The text of a file on disk, whatever its kind: plain text and code in the common
/// encodings, rich documents (rtf, doc, docx, odt, html, webarchive) through textutil, and
/// PDFs page by page. Nothing is opened in an app and nothing touches the clipboard.
public enum DocumentText {
    public struct Result {
        public let text: String
        /// What the file is, for the result's header ("PDF, 12 pages").
        public let kind: String
    }

    static let richKinds: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "wordml"]
    static let maxBytes = 200 * 1024 * 1024

    public static func read(_ url: URL) throws -> Result {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw HelperError("No file at \(url.path).")
        }
        let kind = url.pathExtension.lowercased()
        // An .rtfd is a folder; other packages and folders have no text of their own.
        if isFolder.boolValue, kind != "rtfd" {
            if ["pages", "numbers", "key"].contains(kind) {
                throw HelperError("\(url.lastPathComponent) is an iWork document: open it in its app, then read_window.")
            }
            throw HelperError("\(url.path) is a folder; list it with code (ls).")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            throw HelperError("\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); work on it with code instead.")
        }
        if kind == "pdf" {
            return try pdf(url)
        }
        if richKinds.contains(kind) {
            return Result(text: try textutil(url), kind: "\(kind.uppercased()) document")
        }
        if ["xlsx", "xls", "pptx", "ppt", "key", "numbers", "pages"].contains(kind) {
            throw HelperError("\(url.lastPathComponent) is a spreadsheet or presentation: open it in its app and read_window, or convert it with code.")
        }
        let data = try Data(contentsOf: url)
        guard let text = plainText(data) else {
            throw HelperError("\(url.lastPathComponent) is not text (\(kind.isEmpty ? "binary" : kind) data); look into it with code.")
        }
        return Result(text: text, kind: kind.isEmpty ? "text" : "\(kind) text")
    }

    /// Text in UTF-8, UTF-16 (with its byte order mark) or GB 18030; nil for binary data.
    static func plainText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        // A NUL byte early on means binary data, not text.
        if data.prefix(8192).contains(0) {
            return nil
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gb18030)
    }

    private static func pdf(_ url: URL) throws -> Result {
        guard let document = PDFDocument(url: url) else {
            throw HelperError("\(url.lastPathComponent) is not a readable PDF.")
        }
        if document.isLocked {
            throw HelperError("\(url.lastPathComponent) is password-protected.")
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pages.append("[page \(index + 1)]\n\(text)")
        }
        let text = pages.joined(separator: "\n\n")
        // Only page markers: scanned pages without a text layer.
        if text.count < document.pageCount * 12 + 10 {
            throw HelperError("\(url.lastPathComponent) has no text layer (\(document.pageCount) scanned pages); open it and read it from screenshots, or recognize its text with code.")
        }
        return Result(text: text, kind: "PDF, \(document.pageCount) pages")
    }

    private static func textutil(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw HelperError("Could not take the text out of \(url.lastPathComponent).")
        }
        return text
    }
}

/// Apps whose document body keeps its text from accessibility but hands it to AppleScript.
/// Asking the app this way changes neither the selection nor the clipboard.
enum DocumentScripts {
    /// The script that returns the text of the document whose name the window title shows
    /// (else the front document), by bundle id.
    static func script(bundleId: String, title: String) -> String? {
        let name = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let choose = """
          repeat with d in documents
            set n to name of d as text
            if "\(name)" starts with n or n starts with "\(name)" then set target to d
          end repeat
        """
        switch bundleId {
        case "com.microsoft.Word":
            return """
            tell application id "com.microsoft.Word"
              set target to active document
            \(choose)
              return content of text object of target
            end tell
            """
        case "com.apple.iWork.Pages":
            return """
            tell application id "com.apple.iWork.Pages"
              set target to front document
            \(choose)
              return body text of target
            end tell
            """
        default:
            return nil
        }
    }

    /// The document's text, or why the app would not give it.
    static func text(bundleId: String, title: String) -> Result<String, HelperError>? {
        guard let source = script(bundleId: bundleId, title: title) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(HelperError("osascript did not start: \(error)"))
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        // A document can be long: read while it writes, so the pipe does not fill up.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let problem = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if problem.contains("-1743") {
                return .failure(HelperError("CPU is not allowed to ask this app for its text (系统设置 → 隐私与安全性 → 自动化)"))
            }
            return .failure(HelperError(problem.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        // Word separates paragraphs with carriage returns.
        let text = (String(data: data, encoding: .utf8) ?? "").replacingOccurrences(of: "\r", with: "\n")
        return .success(text.hasSuffix("\n") ? String(text.dropLast()) : text)
    }
}
