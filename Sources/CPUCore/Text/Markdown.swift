import Foundation

/// The block structure of the Markdown models write in replies: headings, paragraphs, lists,
/// tables, code, quotes and rules. Inline syntax (bold, code, links) is left in the text for
/// `AttributedString(markdown:)` to handle.
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case code(String)
    case quote(String)
    case rule
}

public struct MarkdownListItem: Equatable {
    /// "•" for bullets, the number as written ("1.") for ordered items.
    public let marker: String
    public var text: String
    /// Nesting level from the indentation, 0 for top-level items.
    public let depth: Int
}

public enum MarkdownAlignment: Equatable {
    case leading, center, trailing
}

public enum Markdown {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, let alignments = separator(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                let width = max(header.count, alignments.count)
                blocks.append(.table(
                    header: pad(header, to: width),
                    alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count)),
                    rows: rows.map { pad($0, to: width) }
                ))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else {
                        break
                    }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = listItem(current) {
                        items.append(item)
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.hasPrefix(" ") || current.hasPrefix("\t"),
                              !items.isEmpty {
                        // An indented continuation line belongs to the item above.
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " else {
            return nil
        }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, text: text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    /// The `|---|:--:|` line under a table header, as column alignments.
    private static func separator(_ line: String) -> [MarkdownAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- ".contains($0) }) else {
            return nil
        }
        let columns = cells(trimmed)
        guard !columns.isEmpty, columns.allSatisfy({ $0.contains("-") }) else {
            return nil
        }
        return columns.map { column in
            switch (column.hasPrefix(":"), column.hasSuffix(":")) {
            case (true, true):
                return .center
            case (false, true):
                return .trailing
            default:
                return .leading
            }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") {
            body = body.dropFirst()
        }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") {
            body = body.dropLast()
        }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func pad(_ cells: [String], to width: Int) -> [String] {
        cells.count >= width ? Array(cells.prefix(width)) : cells + Array(repeating: "", count: width - cells.count)
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        let depth = min(indent / 2, 3)
        for bullet in ["- ", "* ", "+ ", "• "] where rest.hasPrefix(bullet) {
            return MarkdownListItem(marker: "•", text: String(rest.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces), depth: depth)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else {
            return nil
        }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" || delimiter == "、",
              afterDigits.dropFirst().first == " " || delimiter == "、" else {
            return nil
        }
        let text = afterDigits.dropFirst().trimmingCharacters(in: .whitespaces)
        return MarkdownListItem(marker: "\(digits).", text: text, depth: depth)
    }
}
