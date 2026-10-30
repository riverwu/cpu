import AppKit
import ApplicationServices

/// Input delivered to one app without the system pointer, the keyboard focus or app
/// activation, so CPU and the user can use the Mac at the same time. Each path reports
/// whether it applied; callers fall back to borrowing the foreground when it did not.
enum BackgroundInput {
    /// Private CoreGraphics function that sets a mouse event's window-relative location.
    /// AppKit routes a process-targeted mouse event only when it carries that location and
    /// the window number (event field 51). Resolved at runtime; absent → no background clicks.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetWindowLocation.self) }
    private static let windowNumberField = CGEventField(rawValue: 51)!

    // MARK: - Clicks

    /// Clicks global `point` inside `record`'s window, even when the window is covered or its
    /// app inactive. Native controls accept such clicks; web views in an inactive window
    /// ignore them (callers verify the effect).
    static func click(_ record: WindowRecord, at point: CGPoint, button: CGMouseButton, count: Int) -> Bool {
        guard let setWindowLocation, let frame = WindowCatalog.currentBounds(id: record.id) else {
            return false
        }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let (down, up): (CGEventType, CGEventType) = {
            switch button {
            case .right:
                return (.rightMouseDown, .rightMouseUp)
            case .center:
                return (.otherMouseDown, .otherMouseUp)
            default:
                return (.leftMouseDown, .leftMouseUp)
            }
        }()
        for click in 1...max(1, count) {
            for type in [down, up] {
                guard let event = CGEvent(mouseEventSource: EventPoster.source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
                    return false
                }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event.setIntegerValueField(windowNumberField, value: Int64(record.id))
                setWindowLocation(event, local)
                event.postToPid(record.pid)
                usleep(12_000)
            }
        }
        return true
    }

    // MARK: - Menu shortcuts

    /// Presses the menu item bound to `chord` (⌘-shortcuts) in a possibly inactive app,
    /// which macOS would otherwise only deliver to the frontmost app. Returns its title.
    static func pressMenuShortcut(_ chord: KeyChord, pid: pid_t) -> String? {
        guard let item = menuItem(pid: pid, key: chord.key, flags: chord.flags) else {
            return nil
        }
        guard AX.perform(item, kAXPressAction) == .success else {
            return nil
        }
        return AX.string(item, kAXTitleAttribute) ?? chord.display
    }

    /// AXMenuItemCmdModifiers: shift 1, option 2, control 4, "no command" 8.
    private static func menuModifiers(_ flags: CGEventFlags) -> Int {
        var value = 0
        if flags.contains(.maskShift) { value |= 1 }
        if flags.contains(.maskAlternate) { value |= 2 }
        if flags.contains(.maskControl) { value |= 4 }
        if !flags.contains(.maskCommand) { value |= 8 }
        return value
    }

    static func menuItem(pid: pid_t, key: String, flags: CGEventFlags) -> AXUIElement? {
        guard key.count == 1, let bar = AX.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else {
            return nil
        }
        let wantedKey = key.uppercased()
        let wantedModifiers = menuModifiers(flags)
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            for child in AX.elements(element, kAXChildrenAttribute) {
                let role = AX.role(child)
                if role == "AXMenuItem",
                   (AX.string(child, "AXMenuItemCmdChar") ?? "").uppercased() == wantedKey,
                   (intValue(AX.attribute(child, "AXMenuItemCmdModifiers")) ?? 0) == wantedModifiers,
                   AX.bool(child, kAXEnabledAttribute) != false {
                    return child
                }
                if depth < 4, role == "AXMenuBarItem" || role == "AXMenu" || role == "AXMenuItem",
                   let found = search(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        // Skip the Apple menu: it belongs to the system, not the app.
        for item in AX.elements(bar, kAXChildrenAttribute).dropFirst() {
            if let found = search(item, depth: 1) {
                return found
            }
        }
        return nil
    }

    /// The app's own menu commands that have keyboard shortcuts, as "⌘F 编辑 ▸ 搜索", minus
    /// the ones every app has (copy, quit, …). Tells the model the fastest route in this app.
    static func menuCommands(pid: pid_t, limit: Int = 40) -> [String] {
        guard let bar = AX.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else {
            return []
        }
        var lines: [String] = []
        func walk(_ element: AXUIElement, path: String, depth: Int) {
            for child in AX.elements(element, kAXChildrenAttribute) where lines.count < limit {
                let role = AX.role(child)
                let title = AX.string(child, kAXTitleAttribute) ?? ""
                if role == "AXMenuItem", let key = AX.string(child, "AXMenuItemCmdChar"), !key.isEmpty,
                   let modifiers = intValue(AX.attribute(child, "AXMenuItemCmdModifiers")), modifiers & 8 == 0,
                   !title.isEmpty, !genericCommands.contains(where: { title.hasPrefix($0) }) {
                    var chord = ""
                    if modifiers & 4 != 0 { chord += "⌃" }
                    if modifiers & 2 != 0 { chord += "⌥" }
                    if modifiers & 1 != 0 { chord += "⇧" }
                    lines.append("\(chord)⌘\(key.uppercased()) \(path) ▸ \(title)")
                }
                if depth < 3, role == "AXMenuBarItem" || role == "AXMenu" || role == "AXMenuItem" {
                    walk(child, path: role == "AXMenuBarItem" ? title : path, depth: depth + 1)
                }
            }
        }
        for item in AX.elements(bar, kAXChildrenAttribute).dropFirst() {
            walk(item, path: AX.string(item, kAXTitleAttribute) ?? "", depth: 1)
        }
        return lines
    }

    /// Commands every Mac app shares; listing them would only cost tokens.
    private static let genericCommands = [
        "关于", "设置", "偏好设置", "隐藏", "退出", "关闭", "全选", "撤销", "重做", "剪切", "拷贝", "复制", "粘贴",
        "删除", "最小化", "缩放", "放大", "缩小", "进入全屏幕", "打印", "锁定", "About", "Settings", "Preferences",
        "Hide", "Quit", "Close", "Select All", "Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Minimize", "Zoom",
        "Print", "Enter Full Screen"
    ]

    // MARK: - Text

    /// Inserts text into the focused field of a possibly inactive app through its Edit ▸
    /// Paste menu item: no key events, so no input method in the way and nothing typed into
    /// the user's own app. The user's clipboard is put back afterwards.
    static func paste(_ text: String, pid: pid_t) -> Bool {
        guard let item = menuItem(pid: pid, key: "v", flags: .maskCommand) else {
            return false
        }
        let saved = DispatchQueue.main.sync { saveClipboard() }
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let pressed = AX.perform(item, kAXPressAction) == .success
        // Some apps (Chromium) read the clipboard asynchronously after the menu action.
        usleep(250_000)
        DispatchQueue.main.sync { restoreClipboard(saved) }
        return pressed
    }

    /// The focused document's whole text, taken the way a person hands text over: Select All
    /// and Copy (menu items, so the app may stay in the background). The user's clipboard is
    /// put back; the selection is left for the caller to collapse.
    static func copyAll(pid: pid_t) -> String? {
        guard let selectAll = menuItem(pid: pid, key: "a", flags: .maskCommand) else {
            return nil
        }
        let saved = DispatchQueue.main.sync { saveClipboard() }
        let before = DispatchQueue.main.sync { NSPasteboard.general.changeCount }
        defer {
            DispatchQueue.main.sync { restoreClipboard(saved) }
        }
        guard AX.perform(selectAll, kAXPressAction) == .success else {
            return nil
        }
        // Copy is enabled only once something is selected.
        var copy: AXUIElement?
        _ = waitUntil(timeout: 1.0, interval: 0.05) {
            copy = menuItem(pid: pid, key: "c", flags: .maskCommand)
            return copy != nil
        }
        guard let copy, AX.perform(copy, kAXPressAction) == .success else {
            return nil
        }
        _ = waitUntil(timeout: 2.0, interval: 0.05) {
            DispatchQueue.main.sync { NSPasteboard.general.changeCount != before }
        }
        return DispatchQueue.main.sync {
            NSPasteboard.general.changeCount != before ? NSPasteboard.general.string(forType: .string) : nil
        }
    }

    private static func saveClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private static func restoreClipboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        NSPasteboard.general.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            NSPasteboard.general.writeObjects(items)
        }
    }

    // MARK: - Sharing the machine

    /// Seconds since the user last touched a physical key, mouse or trackpad (synthetic
    /// events do not count).
    static var userIdleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Before borrowing the real pointer or keyboard, wait (briefly) until the user pauses.
    static func waitForUserPause(quiet: Double = 0.6, maximum: Double = 3) {
        let deadline = Date().addingTimeInterval(maximum)
        while userIdleSeconds < quiet, Date() < deadline, !Interrupts.isStopped {
            usleep(50_000)
        }
    }
}
