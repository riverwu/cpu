import Foundation

/// Long text is never cut off silently. A text result shows the whole lines that fit its
/// budget; the whole text stays in a file, and the result says what it shows and how to read
/// on. Window reads, file reads, code output and long selections all work this way, so the
/// model handles every kind of long text alike.
enum LongText {
    /// Saves the text as texts/<name>.txt in the workspace (numbered if the name is taken)
    /// and returns that path relative to the workspace.
    static func save(_ text: String, name: String, in workspace: URL) -> String? {
        let folder = workspace.appendingPathComponent("texts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = slug(name)
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(candidate).txt").path) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        guard (try? text.write(to: folder.appendingPathComponent("\(candidate).txt"), atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return "texts/\(candidate).txt"
    }

    /// Letters and digits of a title (Chinese included), runs of anything else as one dash,
    /// at most 40 characters.
    static func slug(_ name: String) -> String {
        var result = ""
        var gap = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                gap = true
                continue
            }
            if gap, !result.isEmpty {
                result.append("-")
            }
            gap = false
            result.append(character)
            if result.count >= 40 {
                break
            }
        }
        return result.isEmpty ? "text" : result
    }

    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// The whole lines from line `from` (counting from 1) that fit `budget` characters, at
    /// most `count` of them. Unless that is the whole text, a note says which lines these are
    /// and, when more follows, how to read on from `file`.
    static func excerpt(_ text: String, from: Int = 1, count: Int? = nil, budget: Int, file: String?) -> String {
        let all = LongText.lines(of: text)
        guard !text.isEmpty else {
            return ""
        }
        let total = all.count
        let first = max(1, min(from, total))
        var shown: [String] = []
        var used = 0
        var next = first - 1
        var longLine = false
        while next < total, count.map({ shown.count < $0 }) ?? true {
            let line = all[next]
            if used + line.count + 1 > budget {
                if shown.isEmpty {
                    // One line longer than the whole budget: its beginning.
                    shown.append(String(line.prefix(budget)))
                    used = budget
                    longLine = true
                    next += 1
                }
                break
            }
            shown.append(line)
            used += line.count + 1
            next += 1
        }
        let body = shown.joined(separator: "\n")
        if first == 1, next >= total, !longLine {
            return body
        }
        var note = first == 1
            ? "[Lines 1–\(next) of \(total) shown (\(min(used, text.count)) of \(text.count) characters)."
            : "[Lines \(first)–\(next) of \(total)."
        if longLine {
            note += " Line \(first) alone is \(all[first - 1].count) characters; this is its beginning: take the rest of it with code (cut -c, python)."
        }
        if next < total {
            if let file {
                note += " Read on: read_file {\"path\": \"\(file)\", \"from_line\": \(next + 1)}, or search the whole text with code (grep -n)."
            } else {
                note += " The rest could not be saved; read again in parts."
            }
        } else {
            note += " That is the end."
        }
        return body + "\n" + note + "]"
    }
}
