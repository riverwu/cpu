import ApplicationServices
import Foundation

/// The app's menu bar as a person uses it: a path of titles ("邮件 ▸ 标记 ▸ 标记为已读") chooses
/// that command, and a path that ends at a menu lists what is in it. Read through
/// accessibility, so it works while the app stays in the background and without the menu
/// ever showing.
enum MenuBar {
    struct Item {
        let element: AXUIElement
        let title: String
        let enabled: Bool
        let shortcut: String?
        let submenu: AXUIElement?

        var words: String {
            var text = title
            if submenu != nil {
                text += " ▸"
            }
            if let shortcut {
                text += " \(shortcut)"
            }
            if !enabled {
                text += " (dimmed)"
            }
            return text
        }
    }

    enum Outcome {
        case chose(path: String, item: Item)
        case listed(path: String, items: [Item])
    }

    static func parts(_ path: String) -> [String] {
        path.components(separatedBy: CharacterSet(charactersIn: "▸>›→"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Case- and space-insensitive, without the ellipsis and an access key such as "(M)".
    static func normalize(_ title: String) -> String {
        var text = title.lowercased()
        text = text.replacingOccurrences(of: #"\s*\([a-z0-9]\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(…|\.\.\.)$"#, with: "", options: .regularExpression)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "⇧⌘U" for an item with a keyboard shortcut.
    static func shortcut(_ element: AXUIElement) -> String? {
        guard let key = AX.string(element, "AXMenuItemCmdChar"), !key.isEmpty,
              let modifiers = intValue(AX.attribute(element, "AXMenuItemCmdModifiers")) else {
            return nil
        }
        var chord = ""
        if modifiers & 4 != 0 { chord += "⌃" }
        if modifiers & 2 != 0 { chord += "⌥" }
        if modifiers & 1 != 0 { chord += "⇧" }
        if modifiers & 8 == 0 { chord += "⌘" }
        return chord + key.uppercased()
    }

    /// The menu bar's own menus, without the Apple menu (it belongs to the system).
    static func topLevel(pid: pid_t) -> [Item] {
        guard let bar = AX.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else {
            return []
        }
        return AX.elements(bar, kAXChildrenAttribute).dropFirst().compactMap(item)
    }

    static func items(of menu: AXUIElement) -> [Item] {
        AX.elements(menu, kAXChildrenAttribute).compactMap(item)
    }

    private static func item(_ element: AXUIElement) -> Item? {
        let title = (AX.string(element, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            // Separators and custom views.
            return nil
        }
        return Item(
            element: element,
            title: title,
            enabled: AX.bool(element, kAXEnabledAttribute) != false,
            shortcut: shortcut(element),
            submenu: AX.elements(element, kAXChildrenAttribute).first { AX.role($0) == "AXMenu" }
        )
    }

    static func describe(_ items: [Item], limit: Int = 40) -> String {
        let shown = items.prefix(limit).map(\.words).joined(separator: " · ")
        return items.count > limit ? shown + " · …" : shown
    }

    /// Finds the item a path names. Each title may be shortened to its start, and an
    /// intermediate submenu may be left out ("邮件 ▸ 标记为已读" finds 邮件 ▸ 标记 ▸ 标记为已读).
    static func resolve(pid: pid_t, path: String) throws -> Outcome {
        let wanted = parts(path)
        let top = topLevel(pid: pid)
        guard !top.isEmpty else {
            throw HelperError("This app exposes no menu bar to accessibility.")
        }
        guard let first = wanted.first else {
            return .listed(path: "menu bar", items: top)
        }
        var trail: [String] = []
        var candidates = top
        var found: Item?
        for (index, part) in wanted.enumerated() {
            let here = trail.isEmpty ? "the menu bar" : trail.joined(separator: " ▸ ")
            guard let match = pick(part, in: candidates) ?? (index > 0 ? deepPick(part, in: candidates, trail: &trail) : nil) else {
                let options = describe(candidates)
                throw HelperError("No menu item \"\(part)\" in \(here). It has: \(options)")
            }
            trail.append(match.title)
            found = match
            if index + 1 < wanted.count {
                guard let submenu = match.submenu else {
                    throw HelperError("\(trail.joined(separator: " ▸ ")) is a command, not a menu; nothing is under it.")
                }
                candidates = items(of: submenu)
            }
        }
        guard let item = found else {
            throw HelperError("No menu item \"\(first)\".")
        }
        let full = trail.joined(separator: " ▸ ")
        if let submenu = item.submenu {
            return .listed(path: full, items: items(of: submenu))
        }
        return .chose(path: full, item: item)
    }

    private static func pick(_ part: String, in items: [Item]) -> Item? {
        let wanted = normalize(part)
        if let exact = items.first(where: { normalize($0.title) == wanted }) {
            return exact
        }
        let starting = items.filter { normalize($0.title).hasPrefix(wanted) }
        return starting.count == 1 ? starting[0] : nil
    }

    /// One level down: the item is in a submenu the path skipped.
    private static func deepPick(_ part: String, in items: [Item], trail: inout [String]) -> Item? {
        let wanted = normalize(part)
        var hits: [(menu: Item, item: Item)] = []
        for menu in items {
            guard let submenu = menu.submenu else {
                continue
            }
            for item in self.items(of: submenu) where normalize(item.title) == wanted {
                hits.append((menu, item))
            }
        }
        guard hits.count == 1 else {
            return nil
        }
        trail.append(hits[0].menu.title)
        return hits[0].item
    }
}
