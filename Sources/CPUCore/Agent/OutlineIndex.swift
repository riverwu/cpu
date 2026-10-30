import CoreGraphics
import Foundation

/// Parsed view of one observation, used to check that an element index the model chose
/// really is the element it meant (`target`), and to find elements or OCR text by label.
struct OutlineIndex {
    struct Entry {
        let index: Int
        let role: String
        let label: String
        let value: String
        let interactive: Bool

        var summary: String {
            label.isEmpty ? role : "\(role) \"\(label)\""
        }
    }

    struct TextItem {
        let text: String
        let x: Double
        let y: Double
        /// Boxes a substring of the line (from the live OCR result); nil when parsed from text.
        var locate: ((String) -> CGPoint?)?
    }

    private(set) var entries: [Int: Entry] = [:]
    private(set) var texts: [TextItem] = []

    private static let interactiveRoles: Set<String> = [
        "button", "link", "menuitem", "menubaritem", "textfield", "textarea", "searchfield", "securefield",
        "checkbox", "switch", "radio", "popup", "menubutton", "combobox", "tab", "row", "cell", "disclosure", "slider"
    ]

    /// Index of a live observation: OCR lines keep their recognizer result, so a target
    /// inside a long line resolves to the position of those characters.
    init(observation: Observation) {
        self.init(outline: observation.outline, screenText: nil)
        texts = observation.textItems.map { item in
            TextItem(text: item.text, x: Double(item.rect.midX.rounded()), y: Double(item.rect.midY.rounded()), locate: item.point(of:))
        }
    }

    init(outline: String, screenText: String?) {
        let elementPattern = try! NSRegularExpression(pattern: #"^\s*\[(\d+)\]\s+(\S+)(?:\s+"(.*?)")?(?:\s+value="(.*?)")?"#)
        for line in outline.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = elementPattern.firstMatch(in: text, range: range),
                  let index = Int(OutlineIndex.group(match, 1, in: text)) else {
                continue
            }
            let role = OutlineIndex.group(match, 2, in: text)
            entries[index] = Entry(
                index: index,
                role: role,
                label: OutlineIndex.group(match, 3, in: text),
                value: OutlineIndex.group(match, 4, in: text),
                interactive: OutlineIndex.interactiveRoles.contains(role) || text.contains("clickable")
            )
        }
        let textPattern = try! NSRegularExpression(pattern: #"^text "(.*)" @(\d+),(\d+)$"#)
        for line in (screenText ?? "").split(separator: "\n") {
            let text = String(line)
            guard let match = textPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let x = Double(OutlineIndex.group(match, 2, in: text)),
                  let y = Double(OutlineIndex.group(match, 3, in: text)) else {
                continue
            }
            texts.append(TextItem(text: OutlineIndex.group(match, 1, in: text), x: x, y: y))
        }
    }

    /// Nothing in the observation carries the label; an earlier action may still bring it up.
    struct TargetNotFound: Error, CustomStringConvertible {
        let description: String
    }

    enum Resolution {
        case element(Int, note: String?)
        case point(x: Double, y: Double, note: String?)
    }

    /// Resolves `target` (a visible label), checking `element` when the model gave one.
    func resolve(target: String, element: Int?) throws -> Resolution {
        let wanted = OutlineIndex.normalize(target)
        if let element, let entry = entries[element],
           OutlineIndex.matches(entry, wanted, loosely: true) || wanted == OutlineIndex.normalize(entry.role) {
            // An unlabeled element can only be named by its kind ("scrollarea").
            return .element(element, note: nil)
        }
        if let element, let entry = entries[element],
           [entry.label, entry.value].contains(where: { OutlineIndex.oneSlip(OutlineIndex.normalize($0), wanted) }) {
            // The index is right and the label was copied with one character off (a look-alike
            // character): acting on it beats failing the whole batch.
            return .element(element, note: "\"\(target)\" taken as [\(element)] \(entry.summary)")
        }
        let all = entries.values.sorted { $0.index < $1.index }
        var found = all.filter { OutlineIndex.matches($0, wanted, loosely: false) }
        if found.isEmpty, wanted.count >= 2 {
            found = all.filter { OutlineIndex.matches($0, wanted, loosely: true) }
        }
        if found.count > 1 {
            let interactive = found.filter(\.interactive)
            if !interactive.isEmpty {
                found = interactive
            }
        }
        let given = element.map { index in "[\(index)] is \(entries[index]?.summary ?? "not in this observation")" }
        if found.count == 1 {
            var match = found[0]
            // A form label ("文件格式：") names the unlabeled control right after it.
            if !match.interactive, match.role == "text", let control = entries[match.index + 1], control.interactive, control.label.isEmpty {
                match = control
            }
            return .element(match.index, note: given.map { "\($0); used [\(match.index)] \(match.summary) instead" })
        }
        if found.isEmpty {
            var texts = self.texts.filter { OutlineIndex.normalize($0.text) == wanted }
            var partial = false
            if texts.isEmpty, wanted.count >= 2 {
                texts = self.texts.filter { OutlineIndex.normalize($0.text).contains(wanted) }
                partial = true
            }
            if texts.count == 1 {
                let item = texts[0]
                // Inside a longer line, aim at the matching characters, not the line's middle.
                let fragment = target.trimmingCharacters(in: .whitespacesAndNewlines)
                if partial, let point = item.locate?(fragment) {
                    let x = Double(point.x.rounded())
                    let y = Double(point.y.rounded())
                    return .point(x: x, y: y, note: "clicked \"\(fragment)\" inside the on-screen text \"\(item.text)\" at \(Int(x)),\(Int(y))")
                }
                return .point(x: item.x, y: item.y, note: "clicked the on-screen text \"\(item.text)\" at \(Int(item.x)),\(Int(item.y))")
            }
            if texts.count > 1 {
                let options = texts.prefix(6).map { "\"\($0.text)\" @\(Int($0.x)),\(Int($0.y))" }.joined(separator: ", ")
                throw HelperError("\"\(target)\" matches several on-screen texts: \(options). Pass x/y of the one you mean.")
            }
        }
        let prefix = given.map { "\($0), not \"\(target)\". " } ?? ""
        if found.isEmpty {
            throw TargetNotFound(description: "\(prefix)No element or on-screen text is labeled \"\(target)\". Check the latest observation.")
        }
        let options = found.prefix(8).map { "[\($0.index)] \($0.summary)" }.joined(separator: ", ")
        throw HelperError("\(prefix)\"\(target)\" matches several elements: \(options). Pass the element index of the one you mean together with its exact label.")
    }

    private static func matches(_ entry: Entry, _ wanted: String, loosely: Bool) -> Bool {
        for candidate in [entry.label, entry.value] where !candidate.isEmpty {
            let text = normalize(candidate)
            if text == wanted || (loosely && (extends(text, wanted) || describes(wanted, text))) {
                return true
            }
        }
        return false
    }

    /// The label says more than the wanted name ("导出为 PDF…" for "导出"), but not its
    /// opposite ("不保存" is not "保存").
    private static func extends(_ label: String, _ wanted: String) -> Bool {
        guard label.contains(wanted) else {
            return false
        }
        return !negations.contains { label.hasPrefix($0) && !wanted.hasPrefix($0) }
    }

    /// The wanted name is the label plus the kind of control ("发送按钮", "search field").
    /// Anything else around it ("显示以供审阅" around "审阅") names a different control,
    /// possibly one that is not on screen yet.
    private static func describes(_ wanted: String, _ label: String) -> Bool {
        guard label.count >= 2, let range = wanted.range(of: label) else {
            return false
        }
        let rest = (String(wanted[..<range.lowerBound]) + String(wanted[range.upperBound...]))
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return rest.isEmpty || kindWords.contains(rest)
    }

    /// Same length give or take one, at most one character different, and long enough that
    /// one character does not change what it names.
    static func oneSlip(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard min(x.count, y.count) >= 4, abs(x.count - y.count) <= 1, a != b else {
            return false
        }
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] {
            i += 1
        }
        // After the first difference the rest must line up: substitution, insertion or deletion.
        return x.dropFirst(i + 1) == y.dropFirst(i + 1) || x.dropFirst(i) == y.dropFirst(i + 1) || x.dropFirst(i + 1) == y.dropFirst(i)
    }

    private static let negations = ["不", "取消", "非", "don't", "don’t", "do not", "not "]

    private static let kindWords: Set<String> = [
        "按钮", "按键", "框", "输入框", "搜索框", "文本框", "字段", "栏", "菜单", "菜单项", "选项", "选项卡", "标签", "标签页",
        "图标", "链接", "开关", "复选框", "弹出菜单", "button", "field", "box", "menu", "menu item", "item", "tab", "link",
        "icon", "checkbox", "the", "the button"
    ]

    /// Case- and space-insensitive; drops the outline's truncation marker and wrapping quotes.
    static func normalize(_ value: String) -> String {
        var text = value
        if let marker = text.range(of: #"…\(\+\d+ chars\)$"#, options: .regularExpression) {
            text.removeSubrange(marker)
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        return text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else {
            return ""
        }
        return String(text[range])
    }
}
