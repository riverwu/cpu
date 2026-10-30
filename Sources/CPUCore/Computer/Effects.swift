import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Open menus of an app: a pop-up button's list, a context menu, a menu bar menu. A menu runs
/// its own event loop while it is open, so opening one through accessibility can return
/// "cannot complete" although it opened; whether it opened is checked here instead.
enum Menus {
    static let windowLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Whether a menu is showing. Save and open panels of sandboxed apps run in a helper
    /// process that owns their menus, so any menu but CPU's own counts.
    static func isOpen(pid: pid_t) -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let own = ProcessInfo.processInfo.processIdentifier
        return raw.contains { item in
            (item[kCGWindowLayer as String] as? NSNumber)?.intValue == windowLevel
                && (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != own
        }
    }

    /// A pop-up button keeps its menu as a child while closed; it shows when its items have
    /// a size on screen.
    static func isShowing(_ menu: AXUIElement) -> Bool {
        guard let item = AX.elements(menu, kAXChildrenAttribute).first, let frame = AX.frame(item) else {
            return false
        }
        return frame.width > 0 && frame.height > 0
    }

    /// The open menu's element: under `element` (a pop-up button shows its list as a child),
    /// at the top of the app (context menus), or around the focused item.
    static func openMenu(pid: pid_t, near element: AXUIElement? = nil) -> AXUIElement? {
        if let element, let menu = AX.elements(element, kAXChildrenAttribute).first(where: { AX.role($0) == "AXMenu" && isShowing($0) }) {
            return menu
        }
        let app = AXUIElementCreateApplication(pid)
        if let menu = AX.elements(app, kAXChildrenAttribute).first(where: { AX.role($0) == "AXMenu" }) {
            return menu
        }
        if let focused = AX.focusedElement(pid: pid), ["AXMenu", "AXMenuItem"].contains(AX.role(focused)) {
            return AX.ancestor(of: focused, maxDepth: 3) { AX.role($0) == "AXMenu" }
        }
        return nil
    }

    /// Waits briefly for a menu to appear after an action; returns its element when found.
    static func waitForOpen(pid: pid_t, near element: AXUIElement?, timeout: TimeInterval = 0.6) -> (open: Bool, menu: AXUIElement?) {
        var open = false
        _ = waitUntil(timeout: timeout, interval: 0.05) {
            open = isOpen(pid: pid)
            return open
        }
        guard open else {
            return (false, nil)
        }
        return (true, openMenu(pid: pid, near: element))
    }

    /// "6 items: 所有标记 · 简单标记 · 无标记 · …", for telling the model what opened.
    static func describe(_ menu: AXUIElement?, limit: Int = 12) -> String {
        guard let menu else {
            return "a menu"
        }
        let titles = AX.elements(menu, kAXChildrenAttribute).compactMap { item -> String? in
            let title = (AX.string(item, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        guard !titles.isEmpty else {
            return "a menu"
        }
        let shown = titles.prefix(limit).joined(separator: " · ")
        return "a menu with \(titles.count) items: \(shown)\(titles.count > limit ? " · …" : "")"
    }
}

/// Cheap accessibility facts about an app, read before and after each action so its result
/// can say what it visibly did: a menu or window opened or closed, focus moved, a value changed.
struct UIProbe {
    /// On-screen windows by id, with their titles.
    let windows: [CGWindowID: String]
    /// Every window of the app, also minimized or on another Space: one coming into view
    /// was not opened.
    let known: Set<CGWindowID>
    let menuOpen: Bool
    let focus: AXUIElement?
    let focusLabel: String?
    let focusValue: String?
    let selection: Selection?

    /// What is selected in the focused element: rows of a list, or a range of text.
    enum Selection: Equatable {
        /// How many rows, and the name of the first.
        case rows(Int, first: String?)
        case text(length: Int, of: Int)

        static func read(_ element: AXUIElement) -> Selection? {
            if AXRoles.lists.contains(AX.role(element)) {
                let rows = AX.elements(element, kAXSelectedRowsAttribute)
                return .rows(rows.count, first: rows.first.flatMap(rowName))
            }
            guard let raw = AX.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
                return nil
            }
            var range = CFRange()
            guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else {
                return nil
            }
            let total = AX.attribute(element, kAXNumberOfCharactersAttribute).flatMap { intValue($0) }
                ?? ((AX.string(element, kAXValueAttribute) ?? "") as NSString).length
            return .text(length: range.length, of: total)
        }

        /// A row's name: the first text in it (a file name, a sender).
        private static func rowName(_ row: AXUIElement) -> String? {
            var queue = AX.elements(row, kAXChildrenAttribute)
            var looked = 0
            while !queue.isEmpty, looked < 12 {
                let element = queue.removeFirst()
                looked += 1
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = AX.string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        return compactText(text, limit: 40)
                    }
                }
                queue += AX.elements(element, kAXChildrenAttribute)
            }
            return nil
        }

        /// "7 rows selected", "all 1,204 characters selected"; nil for a bare caret.
        var words: String? {
            switch self {
            case .rows(let count, let first):
                let name = first.map { " \"\($0)\"" } ?? ""
                return count == 1 ? "selected row\(name)" : (count == 0 ? "no row selected" : "\(count) rows selected, first\(name)")
            case .text(let length, let total):
                guard length > 0 else {
                    return nil
                }
                return length >= total ? "all \(total) characters selected" : "\(length) characters selected"
            }
        }
    }

    static func take(pid: pid_t) -> UIProbe {
        var windows: [CGWindowID: String] = [:]
        var known = Set<CGWindowID>()
        for window in WindowCatalog.windows(forPid: pid) {
            known.insert(window.id)
            if window.onScreen {
                windows[window.id] = window.title
            }
        }
        let focus = AX.focusedElement(pid: pid).flatMap { ["AXApplication", "AXUnknown", ""].contains(AX.role($0)) ? nil : $0 }
        return UIProbe(
            windows: windows,
            known: known,
            menuOpen: Menus.isOpen(pid: pid),
            focus: focus,
            focusLabel: focus.map(UIProbe.label),
            focusValue: focus.flatMap { AX.string($0, kAXValueAttribute) },
            selection: focus.flatMap(Selection.read)
        )
    }

    /// What changed between this probe and `after`, in a few words each.
    func effects(after: UIProbe, pid: pid_t) -> [String] {
        var effects: [String] = []
        for (id, title) in after.windows where windows[id] == nil && !known.contains(id) {
            effects.append(title.isEmpty ? "opened a new window (\(id))" : "opened window \"\(compactText(title, limit: 60))\" (\(id))")
        }
        for (id, title) in windows where after.windows[id] == nil {
            let name = title.isEmpty ? "a window" : "window \"\(compactText(title, limit: 60))\""
            effects.append(after.known.contains(id) ? "\(name) went out of view (minimized or another Space)" : "closed \(name)")
        }
        if !menuOpen, after.menuOpen {
            effects.append("opened \(Menus.describe(Menus.openMenu(pid: pid, near: nil)))")
        } else if menuOpen, !after.menuOpen {
            effects.append("closed the menu")
        }
        if let element = after.focus {
            let sameElement = focus.map { CFEqual($0, element) } ?? false
            if !sameElement, let label = after.focusLabel {
                let selected = after.selection?.words.map { " (\($0))" } ?? ""
                effects.append("focus moved to \(label)\(selected)")
            } else if sameElement {
                if after.focusValue != focusValue, let value = after.focusValue {
                    effects.append("its value is now \"\(compactText(value, limit: 60))\"")
                }
                if after.selection != selection, let words = after.selection?.words {
                    effects.append("\(words) in \(after.focusLabel ?? "the focused element")")
                }
            }
        }
        return effects
    }

    private static func label(_ element: AXUIElement) -> String {
        let role = AX.role(element).replacingOccurrences(of: "AX", with: "").lowercased()
        let name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .lazy.compactMap { AX.string(element, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return name.map { "\(role) \"\(compactText($0, limit: 40))\"" } ?? role
    }
}

/// Files written while CPU acted, looked up where files land: the folder of the document
/// being worked on, then 下载, 桌面 and 文稿. Each is reported with what tells whether it came
/// out right (size, and the length of a recording, the pixels of an image, the pages of a PDF).
enum RecentFiles {
    static func folders(document: String?) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders: [URL] = []
        if let document, let url = URL(string: document), url.isFileURL {
            folders.append(url.deletingLastPathComponent())
        }
        for name in ["Downloads", "Desktop", "Documents"] {
            let folder = home.appendingPathComponent(name)
            if !folders.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
                folders.append(folder)
            }
        }
        return folders
    }

    /// Files modified since `start`, with their description. Apps write a saved file after
    /// the dialog closes, so after a save this waits up to `timeout` for it.
    static func written(since start: Date, document: String?, timeout: TimeInterval = 0) -> [(url: URL, description: String)] {
        let folders = folders(document: document)
        var found: [(url: URL, size: Int)] = []
        _ = waitUntil(timeout: timeout, interval: 0.15) {
            found = scan(folders, since: start.addingTimeInterval(-1))
            return !found.isEmpty || Interrupts.isStopped
        }
        return found.prefix(3).map { ($0.url, describe($0.url, size: $0.size)) }
    }

    static func scan(_ folders: [URL], since: Date) -> [(url: URL, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var found: [(url: URL, size: Int, date: Date)] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for item in items where !item.lastPathComponent.hasPrefix("~$") {
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let date = values.contentModificationDate, date >= since, let size = values.fileSize, size > 0 else {
                    continue
                }
                found.append((item, size, date))
            }
        }
        return found.sorted { $0.date > $1.date }.map { ($0.url, $0.size) }
    }

    /// "/Users/me/Desktop/a.m4a (6.1 MB, 27 min 40 s)".
    static func describe(_ url: URL, size: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var facts = [formatter.string(fromByteCount: Int64(size))]
        if let more = details(url) {
            facts.append(more)
        }
        return "\(url.path) (\(facts.joined(separator: ", ")))"
    }

    private static func details(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp3", "wav", "aif", "aiff", "caf", "aac", "flac":
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
                return "not a readable audio file"
            }
            let seconds = Int((Double(file.length) / file.processingFormat.sampleRate).rounded())
            return seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp":
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                return "not a readable image"
            }
            return "\(width)x\(height) px"
        case "pdf":
            guard let document = CGPDFDocument(url as CFURL) else {
                return "not a readable PDF"
            }
            return document.numberOfPages == 1 ? "1 page" : "\(document.numberOfPages) pages"
        default:
            return nil
        }
    }
}
