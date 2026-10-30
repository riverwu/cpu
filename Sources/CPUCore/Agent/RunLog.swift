import Foundation

/// Human-readable trajectory of one request: every model step (thinking, text, tool calls,
/// timing) and every tool result (outlines, OCR; screenshots saved next to it). Lives in
/// ~/Library/Logs/CPU/runs and is pruned after a week. It contains screen content, so it
/// stays on this Mac.
final class RunLog {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CPU/runs", isDirectory: true)
    }

    let url: URL
    private let handle: FileHandle?
    let stem: String
    private var imageCount = 0
    private var stats = Stats()

    /// Totals for the summary line at the end, the numbers to compare runs by.
    private struct Stats {
        var modelSteps = 0
        var modelMs = 0
        var firstTokenMs = 0
        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0
        var thinkingChars = 0
        var toolCalls: [String: Int] = [:]
        var toolMs: [String: Int] = [:]
        var parts: [String: Int] = [:]
        var errors = 0
        var unchanged = 0
        var resultChars = 0
    }

    init(request: String, config: Config) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        stem = formatter.string(from: Date())
        let directory = RunLog.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RunLog.prune(directory, olderThanDays: 7)
        url = directory.appendingPathComponent("\(stem).md")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try? FileHandle(forWritingTo: url)
        write("""
        # \(request)

        - time: \(Date())
        - model: \(config.model) @ \(config.baseURL) · effort \(config.effort ?? "default") · vision \(config.vision) · screenshots \(config.screenshots)
        - permissions: accessibility \(Computer.hasAccessibility) · screen recording \(Computer.hasScreenRecording)

        """)
    }

    deinit {
        try? handle?.close()
    }

    func write(_ text: String) {
        handle?.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }

    func section(_ title: String, _ body: String) {
        write("\n## \(title)\n\n```\n\(body)\n```")
    }

    func response(step: Int, _ response: LLMResponse) {
        var lines: [String] = []
        for block in response.content {
            switch block["type"] as? String {
            case "thinking":
                lines.append("[thinking] \(block["thinking"] as? String ?? "")")
            case "text":
                lines.append("[text] \(block["text"] as? String ?? "")")
            case "tool_use":
                let input = (block["input"] as? JSONObject).flatMap {
                    try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])
                }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                lines.append("[tool_use \(block["name"] as? String ?? "?")] \(input)")
                if let invalid = block["_invalid_input"] as? String {
                    lines.append("  (invalid JSON input: \(invalid))")
                }
            default:
                lines.append("[\(block["type"] as? String ?? "?")]")
            }
        }
        lines.append(String(
            format: "-- first token %dms · total %dms · in %d (cached %d) · out %d · stop %@",
            response.firstTokenMs, response.totalMs, response.inputTokens, response.cacheReadTokens,
            response.outputTokens, response.stopReason ?? "-"
        ))
        section("step \(step) · model", lines.joined(separator: "\n"))
        stats.modelSteps += 1
        stats.modelMs += response.totalMs
        stats.firstTokenMs += response.firstTokenMs
        stats.inputTokens += response.inputTokens
        stats.cachedTokens += response.cacheReadTokens
        stats.outputTokens += response.outputTokens
        stats.thinkingChars += response.content.reduce(0) { $0 + (($1["thinking"] as? String)?.count ?? 0) }
    }

    func toolResult(step: Int, name: String, content: [JSONObject], isError: Bool, elapsedMs: Int? = nil, timing: [(String, Int)] = []) {
        var lines: [String] = []
        for block in content {
            if block["type"] as? String == "image",
               let source = block["source"] as? JSONObject,
               let base64 = source["data"] as? String,
               let data = Data(base64Encoded: base64) {
                imageCount += 1
                let image = url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(imageCount).jpg")
                try? data.write(to: image)
                lines.append("[screenshot → \(image.lastPathComponent)]")
            } else if let text = block["text"] as? String {
                lines.append(text)
            }
        }
        let chars = lines.reduce(0) { $0 + $1.count }
        if let elapsedMs {
            // "-- took 1840ms · actions 520 · wait 0 · settle 215 · observe 410 · ax 300 · 6.2k chars"
            let parts = timing.filter { $0.1 > 0 || $0.0 == "actions" }.map { "\($0.0) \($0.1)" }
            lines.append((["-- took \(elapsedMs)ms"] + parts + [String(format: "%.1fk chars", Double(chars) / 1000)]).joined(separator: " · "))
            stats.toolCalls[name, default: 0] += 1
            stats.toolMs[name, default: 0] += elapsedMs
            for (part, ms) in timing {
                stats.parts[part, default: 0] += ms
            }
            stats.errors += isError ? 1 : 0
            stats.unchanged += content.contains { ($0["text"] as? String)?.contains("No visible change:") == true } ? 1 : 0
            stats.resultChars += chars
        }
        section("step \(step) · \(name)\(isError ? " (error)" : "")", lines.joined(separator: "\n"))
    }

    /// The run's totals as one JSON line, for scripts/runstats.py.
    func finish(totalMs: Int, outcome: String) {
        let summary: JSONObject = [
            "total_ms": totalMs,
            "outcome": outcome,
            "model_steps": stats.modelSteps,
            "model_ms": stats.modelMs,
            "first_token_ms": stats.firstTokenMs,
            "input_tokens": stats.inputTokens,
            "cached_tokens": stats.cachedTokens,
            "output_tokens": stats.outputTokens,
            "thinking_chars": stats.thinkingChars,
            "tool_calls": stats.toolCalls,
            "tool_ms": stats.toolMs,
            "tool_parts_ms": stats.parts,
            "errors": stats.errors,
            "unchanged": stats.unchanged,
            "result_chars": stats.resultChars
        ]
        let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data()
        write("\n## summary\n\n\(String(data: data, encoding: .utf8) ?? "{}")")
    }

    private static func prune(_ directory: URL, olderThanDays days: Double) {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
