import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Tag stamped on every synthesized event so our own Escape presses never stop a turn.
let syntheticEventTag: Int64 = 0x4C4F_4253

struct KeyChord {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let display: String
    /// The key without modifiers as typed ("p", "*", "return"), for matching menu shortcuts.
    let key: String

    var hasCommand: Bool {
        return flags.contains(.maskCommand)
    }

    var isSelectAll: Bool {
        return keyCode == 0 && flags == .maskCommand
    }

    /// Pressing it again after it was ignored cannot do it twice: a shortcut, not a key that
    /// edits text or moves the caret.
    var safeToResend: Bool {
        return !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }

    var isEscape: Bool {
        return keyCode == 53 && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    private static let modifierAliases: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand, "super": .maskCommand,
        "win": .maskCommand, "windows": .maskCommand, "⌘": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl, "ctl": .maskControl, "^": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate, "⌥": .maskAlternate,
        "shift": .maskShift, "⇧": .maskShift,
        "fn": .maskSecondaryFn, "function": .maskSecondaryFn
    ]

    private static let namedKeys: [String: CGKeyCode] = {
        var keys: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "`": 50,
            "return": 36, "enter": 36, "kp_enter": 76, "numpadenter": 76,
            "tab": 48, "space": 49, "spacebar": 49,
            "delete": 51, "backspace": 51, "back": 51,
            "forwarddelete": 117, "forward_delete": 117, "del": 117,
            "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "prior": 116, "next": 121,
            "help": 114, "insert": 114, "capslock": 57,
            "plus": 24, "minus": 27, "equal": 24, "equals": 24, "comma": 43, "period": 47,
            "slash": 44, "backslash": 42, "semicolon": 41, "quote": 39, "apostrophe": 39,
            "grave": 50, "backquote": 50, "bracketleft": 33, "bracketright": 30,
            "leftbracket": 33, "rightbracket": 30
        ]
        let functionKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (offset, code) in functionKeys.enumerated() {
            keys["f\(offset + 1)"] = code
        }
        return keys
    }()

    /// Symbols typed with Shift on the US layout, as (key code, shift).
    private static let shiftedSymbols: [Character: CGKeyCode] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28, "(": 25, ")": 29,
        "_": 27, "+": 24, "{": 33, "}": 30, "|": 42, ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44, "~": 50
    ]

    static var supportedKeyNames: String {
        return "letters, digits, punctuation, return/enter, tab, space, delete/backspace, forwarddelete, "
            + "escape, left/right/up/down, home/end, pageup/pagedown, f1-f20; modifiers cmd, ctrl, alt/option, shift, fn"
    }

    /// Parses chords like "cmd+shift+t", "Control_L+a", "Return", "alt+Left".
    static func parse(_ raw: String) throws -> KeyChord {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError("key must not be empty")
        }
        var tokens: [String] = []
        var current = ""
        for character in trimmed {
            if character == "+", !current.isEmpty {
                tokens.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        tokens.append(current)
        tokens = tokens.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let keyToken = tokens.last else {
            throw HelperError("key must not be empty")
        }
        var flags = CGEventFlags()
        for token in tokens.dropLast() {
            guard let flag = modifier(token) else {
                throw HelperError("Unsupported modifier \"\(token)\" in key \"\(raw)\". Supported: \(supportedKeyNames).")
            }
            flags.insert(flag)
        }
        if keyToken.count == 1, let symbol = keyToken.first, let code = shiftedSymbols[symbol] {
            flags.insert(.maskShift)
            return KeyChord(keyCode: code, flags: flags, display: trimmed, key: String(symbol))
        }
        let normalized = normalizeKey(keyToken)
        guard let code = namedKeys[normalized] else {
            if modifier(keyToken) != nil {
                throw HelperError("Key \"\(raw)\" only contains modifiers; add the key to press, e.g. cmd+c.")
            }
            throw HelperError("Unsupported key \"\(keyToken)\" in \"\(raw)\". Supported: \(supportedKeyNames).")
        }
        // "cmd+A" means the A key; shift is only added when explicitly requested.
        return KeyChord(keyCode: code, flags: flags, display: trimmed, key: normalized)
    }

    private static func modifier(_ token: String) -> CGEventFlags? {
        var key = token.lowercased()
        for suffix in ["_l", "_r", "left", "right"] where key.hasSuffix(suffix) && key.count > suffix.count {
            key = String(key.dropLast(suffix.count))
        }
        for prefix in ["left", "right", "l", "r"] where key.hasPrefix(prefix) && modifierAliases[String(key.dropFirst(prefix.count))] != nil {
            key = String(key.dropFirst(prefix.count))
        }
        return modifierAliases[key.trimmingCharacters(in: CharacterSet(charactersIn: "_"))]
    }

    private static func normalizeKey(_ token: String) -> String {
        if token.count == 1 {
            return token.lowercased()
        }
        let lowered = token.lowercased().replacingOccurrences(of: " ", with: "")
        let aliases: [String: String] = [
            "page_up": "pageup", "page_down": "pagedown", "kp_return": "kp_enter",
            "arrow_left": "left", "arrow_right": "right", "arrow_up": "up", "arrow_down": "down",
            "back_space": "backspace", "caps_lock": "capslock"
        ]
        return aliases[lowered] ?? lowered
    }
}

enum EventPoster {
    static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = syntheticEventTag
        return source
    }()

    static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
    }

    static func keyEvents(code: CGKeyCode, flags: CGEventFlags) -> (CGEvent, CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return nil
        }
        down.flags = flags
        up.flags = flags
        tag(down)
        tag(up)
        return (down, up)
    }

    static func postKey(_ chord: KeyChord, pid: pid_t, hid: Bool) throws {
        guard let (down, up) = keyEvents(code: chord.keyCode, flags: chord.flags) else {
            throw HelperError("Unable to create key event for \(chord.display)")
        }
        post(down, pid: pid, hid: hid)
        usleep(8_000)
        post(up, pid: pid, hid: hid)
    }

    static func post(_ event: CGEvent, pid: pid_t, hid: Bool) {
        if hid {
            event.post(tap: .cghidEventTap)
        } else {
            event.postToPid(pid)
        }
    }

    /// Types text with keyboard events, one grapheme cluster per event pair.
    static func typeText(_ text: String, pid: pid_t, hid: Bool, shouldStop: () -> Bool) throws {
        for character in text {
            if shouldStop() {
                throw HelperError(Interrupts.stoppedMessage)
            }
            switch character {
            case "\n", "\r\n", "\r":
                // A line break inside the text, not "send": plain Return sends in chat apps.
                // Submitting is the model's own key press.
                try postKey(KeyChord(keyCode: 36, flags: .maskShift, display: "shift+return", key: "return"), pid: pid, hid: hid)
            case "\t":
                try postKey(KeyChord(keyCode: 48, flags: [], display: "tab", key: "tab"), pid: pid, hid: hid)
            default:
                var units = Array(String(character).utf16)
                guard let (down, up) = keyEvents(code: 0, flags: []) else {
                    continue
                }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                post(down, pid: pid, hid: hid)
                post(up, pid: pid, hid: hid)
            }
            usleep(2_500)
        }
    }

    static func mouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return nil
        }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        tag(event)
        return event
    }
}

/// Temporarily switches away from CJK/IME input methods while typing key events,
/// so "hello" is not captured into a pinyin composition.
final class InputSourceGuard {
    private var previous: TISInputSource?

    init() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return
        }
        guard let typeRef = TISGetInputSourceProperty(current, kTISPropertyInputSourceType) else {
            return
        }
        let type = Unmanaged<CFString>.fromOpaque(typeRef).takeUnretainedValue() as String
        guard type != (kTISTypeKeyboardLayout as String) else {
            return
        }
        guard let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return
        }
        if TISSelectInputSource(ascii) == noErr {
            previous = current
            usleep(30_000)
        }
    }

    var switched: Bool {
        return previous != nil
    }

    func restore() {
        if let previous {
            TISSelectInputSource(previous)
            self.previous = nil
        }
    }

    deinit {
        restore()
    }
}

enum DeliveryPolicy: String {
    /// Background semantic actions first; briefly take over the pointer/keyboard when required.
    case auto
    /// Never move the physical pointer or activate apps; fail instead.
    case background
    /// Always use real pointer/keyboard events on the activated target window.
    case foreground

    static let configuredDefault: DeliveryPolicy = {
        let raw = (ProcessInfo.processInfo.environment["CPU_FOREGROUND_FALLBACK"] ?? "auto").lowercased()
        return raw == "never" || raw == "background" || raw == "off" ? .background : .auto
    }()

    static func from(_ params: [String: Any]) -> DeliveryPolicy {
        switch stringValue(params["delivery"])?.lowercased() {
        case "background", "pid":
            return .background
        case "foreground", "hid":
            return .foreground
        case "auto":
            return .auto
        default:
            return configuredDefault
        }
    }
}

/// The app the user had in front when CPU borrowed the foreground. It gets the foreground
/// back when the batch of actions ends, unless the user has moved on to another app.
enum FocusLoan {
    private static let lock = NSLock()
    private static var lender: pid_t?
    private static var borrower: pid_t?

    static func borrow(from lenderPid: pid_t?, for target: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard lender == nil, let lenderPid, lenderPid != target, lenderPid != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        lender = lenderPid
        borrower = target
    }

    static func giveBack() {
        lock.lock()
        let lenderPid = lender
        let borrowerPid = borrower
        lender = nil
        borrower = nil
        lock.unlock()
        guard let lenderPid, NSWorkspace.shared.frontmostApplication?.processIdentifier == borrowerPid,
              NSRunningApplication(processIdentifier: lenderPid)?.isTerminated == false else {
            return
        }
        AX.set(AXUIElementCreateApplication(lenderPid), kAXFrontmostAttribute, kCFBooleanTrue)
    }
}

/// Windows moved out of the way during a task, with their original positions; they are put
/// back when the task ends so the user's layout survives.
enum WindowDisplacements {
    private static let lock = NSLock()
    private static var moved: [(window: AXUIElement, origin: CGPoint)] = []

    /// Moves a window, remembering where it was the first time. Returns false if it did not move.
    @discardableResult
    static func move(_ window: AXUIElement, to origin: CGPoint) -> Bool {
        guard let before = AX.frame(window)?.origin else {
            return false
        }
        var target = origin
        guard let value = AXValueCreate(.cgPoint, &target), AX.set(window, kAXPositionAttribute, value) == .success else {
            return false
        }
        lock.lock()
        if !moved.contains(where: { CFEqual($0.window, window) }) {
            moved.append((window, before))
        }
        lock.unlock()
        return AX.frame(window)?.origin != before
    }

    static func restoreAll() {
        lock.lock()
        let entries = moved
        moved = []
        lock.unlock()
        for entry in entries.reversed() {
            var origin = entry.origin
            if let value = AXValueCreate(.cgPoint, &origin) {
                AX.set(entry.window, kAXPositionAttribute, value)
            }
        }
    }
}

/// Brings a target window forward for real HID input and puts the user's pointer back afterwards.
/// CPU's own windows (the task card) float above everything, so a real click aimed at a
/// point they cover would land on them. The app makes them click-through while CPU drives
/// the pointer and takes the user's clicks the rest of the time.
public enum PointerGate {
    /// Called on the main queue: true before CPU posts pointer events, false after.
    public static var onChange: ((Bool) -> Void)?

    static func during<T>(_ body: () throws -> T) rethrows -> T {
        set(true)
        defer {
            set(false)
        }
        return try body()
    }

    private static func set(_ busy: Bool) {
        guard let onChange else {
            return
        }
        if Thread.isMainThread {
            onChange(busy)
            return
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            onChange(busy)
            done.signal()
        }
        // The window must be click-through before the first event; never wait long on a busy main thread.
        if busy {
            _ = done.wait(timeout: .now() + 0.25)
        }
    }
}

final class ForegroundSession {
    let record: WindowRecord
    private let originalCursor: CGPoint
    private(set) var activated = false
    /// What was done to clear the target point, for the action result.
    private(set) var resolutions: [String] = []

    init(record: WindowRecord) {
        self.record = record
        originalCursor = CGEvent(source: nil)?.location ?? .zero
    }

    static func isFrontmost(pid: pid_t) -> Bool {
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Brings the target app and window to the front. Accessibility activation (AXFrontmost)
    /// comes first: since macOS 14, cooperative activation silently ignores
    /// NSRunningApplication.activate() from an app that is not itself active, and CPU never is.
    func activate() throws {
        if let window = AX.windowElement(for: record) {
            if AX.bool(window, kAXMinimizedAttribute) == true {
                AX.set(window, kAXMinimizedAttribute, kCFBooleanFalse)
            }
            AX.perform(window, kAXRaiseAction)
            AX.set(window, kAXMainAttribute, kCFBooleanTrue)
        }
        if !ForegroundSession.isFrontmost(pid: record.pid) {
            guard let app = NSRunningApplication(processIdentifier: record.pid) else {
                throw HelperError("\(record.app) is no longer running.")
            }
            // Borrow the foreground politely: wait for the user to pause, remember their app.
            BackgroundInput.waitForUserPause()
            FocusLoan.borrow(from: NSWorkspace.shared.frontmostApplication?.processIdentifier, for: record.pid)
            if app.isHidden {
                app.unhide()
            }
            AX.set(AXUIElementCreateApplication(record.pid), kAXFrontmostAttribute, kCFBooleanTrue)
            app.activate()
            activated = true
            guard waitUntil(timeout: 1.5, { ForegroundSession.isFrontmost(pid: self.record.pid) }) else {
                throw HelperError("macOS did not bring \(record.app) to the front, so the input was not sent. Ask the user to click the \(record.app) window once, then retry.")
            }
            usleep(60_000)
        }
    }

    /// Whatever would receive a click at `point` instead of the target window.
    struct Cover {
        let pid: pid_t
        let window: WindowCatalog.Hit?

        var app: String {
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? window?.owner ?? "another app"
        }

        /// Pop-up menus, context menus and their submenus (NSPopUpMenuWindowLevel = 101).
        var isMenu: Bool {
            (window?.layer ?? 0) == 101
        }

        var description: String {
            var text = app
            if let window {
                text = "window \(window.id) · \(text)"
                if !window.title.isEmpty {
                    text += " \"\(compactText(window.title, limit: 60))\""
                }
                if window.layer > 0 {
                    text += " (floating above normal windows)"
                }
            }
            return text
        }
    }

    func cover(at point: CGPoint) -> Cover? {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        if let hit = AX.hitTest(point), let pid = AX.pid(hit) {
            // Our cursor/HUD overlays and panel are click-through while acting.
            if pid == record.pid || pid == ownPid || isHelper(pid) {
                return nil
            }
            return Cover(pid: pid, window: WindowCatalog.topWindow(at: point, ignoring: ownPid, owner: pid))
        }
        // The app under the point does not implement accessibility hit-testing (custom-drawn
        // UIs such as WeChat); the window server's stacking order decides.
        guard let top = WindowCatalog.topWindow(at: point, ignoring: ownPid), top.pid != record.pid, !isHelper(top.pid) else {
            return nil
        }
        return Cover(pid: top.pid, window: top)
    }

    /// Helper processes inside the target's bundle (web content, renderers) are the target.
    private func isHelper(_ pid: pid_t) -> Bool {
        guard let target = NSRunningApplication(processIdentifier: record.pid)?.bundleURL?.path,
              let other = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path else {
            return false
        }
        return other.hasPrefix(target + "/")
    }

    /// Makes `point` reach the target window, resolving whatever covers it the way a person
    /// would: bring the window forward, close an open menu, move a floating window aside, or
    /// shift the target window clear of fixed system UI such as the Dock. Moved windows go
    /// back when the task ends (`WindowDisplacements.restoreAll`). Returns the point to use,
    /// which moves with the target window.
    func clearPath(to start: CGPoint) throws -> CGPoint {
        var point = start
        var tried = Set<String>()
        while let cover = cover(at: point) {
            if !tried.contains("front"), cover.window?.layer ?? 0 == 0 || !ForegroundSession.isFrontmost(pid: record.pid) {
                tried.insert("front")
                try activate()
                usleep(80_000)
            } else if !tried.contains("menu"), cover.isMenu {
                tried.insert("menu")
                if let escape = try? KeyChord.parse("escape") {
                    try? EventPoster.postKey(escape, pid: cover.pid, hid: true)
                }
                usleep(150_000)
                resolutions.append("closed an open \(cover.app) menu")
            } else if !tried.contains("aside") {
                tried.insert("aside")
                if moveAside(cover, from: point) {
                    resolutions.append("moved \(cover.app)'s window aside (it goes back when the task ends)")
                    usleep(80_000)
                }
            } else if !tried.contains("shift") {
                tried.insert("shift")
                if let shifted = shiftTarget(point, clearOf: cover) {
                    point = shifted
                    resolutions.append("moved the \(record.app) window clear of \(cover.app) (it goes back when the task ends)")
                    usleep(80_000)
                }
            } else {
                throw HelperError(
                    "The point is covered by \(cover.description), which could not be moved aside; the input was not sent. "
                    + "Resolve it first — dismiss or close it (observe that window and use its close/cancel button, or press escape), "
                    + "or scroll the target into a clear area — then retry."
                )
            }
        }
        return point
    }

    /// Moves the covering window so it no longer contains `point`.
    private func moveAside(_ cover: Cover, from point: CGPoint) -> Bool {
        let windows = AX.elements(AXUIElementCreateApplication(cover.pid), kAXWindowsAttribute)
        let bounds = cover.window?.bounds
        let match = windows.first(where: { window in
            guard let frame = AX.frame(window), let bounds else {
                return false
            }
            return abs(frame.minX - bounds.minX) < 4 && abs(frame.minY - bounds.minY) < 4
        }) ?? windows.first(where: { AX.frame($0)?.contains(point) == true })
        guard let window = match, AX.isSettable(window, kAXPositionAttribute), let frame = AX.frame(window) else {
            return false
        }
        let display = WindowCatalog.displayBounds(containing: point)
        // Beside the point on the roomier side; if the system clamps that, below or above it.
        let sideX = display.maxX - point.x >= point.x - display.minX ? point.x + 24 : point.x - frame.width - 24
        let sideY = display.maxY - point.y >= point.y - display.minY ? point.y + 24 : point.y - frame.height - 24
        for origin in [CGPoint(x: sideX, y: frame.minY), CGPoint(x: frame.minX, y: sideY)] {
            if WindowDisplacements.move(window, to: origin), AX.frame(window)?.contains(point) == false {
                return true
            }
        }
        WindowDisplacements.move(window, to: frame.origin)
        return false
    }

    /// Shifts the target window the shortest distance that takes `point` out of the cover
    /// while keeping it on the display (below the menu bar).
    private func shiftTarget(_ point: CGPoint, clearOf cover: Cover) -> CGPoint? {
        guard let bounds = cover.window?.bounds, let window = AX.windowElement(for: record),
              AX.isSettable(window, kAXPositionAttribute), let frame = AX.frame(window) else {
            return nil
        }
        let display = WindowCatalog.displayBounds(containing: point)
        let usable = CGRect(x: display.minX + 4, y: display.minY + 40, width: display.width - 8, height: display.height - 44)
        let candidates = [
            CGVector(dx: 0, dy: bounds.minY - 16 - point.y),
            CGVector(dx: 0, dy: bounds.maxY + 16 - point.y),
            CGVector(dx: bounds.minX - 16 - point.x, dy: 0),
            CGVector(dx: bounds.maxX + 16 - point.x, dy: 0)
        ]
        .filter { usable.contains(CGPoint(x: point.x + $0.dx, y: point.y + $0.dy)) }
        .sorted { abs($0.dx) + abs($0.dy) < abs($1.dx) + abs($1.dy) }
        for delta in candidates {
            let origin = CGPoint(x: frame.minX + delta.dx, y: frame.minY + delta.dy)
            if WindowDisplacements.move(window, to: origin), let moved = AX.frame(window) {
                return CGPoint(x: point.x + moved.minX - frame.minX, y: point.y + moved.minY - frame.minY)
            }
        }
        return nil
    }

    func click(at point: CGPoint, button: CGMouseButton, count: Int) throws {
        let (downType, upType): (CGEventType, CGEventType) = {
            switch button {
            case .right:
                return (.rightMouseDown, .rightMouseUp)
            case .center:
                return (.otherMouseDown, .otherMouseUp)
            default:
                return (.leftMouseDown, .leftMouseUp)
            }
        }()
        PointerGate.during {
            move(to: point)
            usleep(25_000)
            for index in 1...max(1, min(3, count)) {
                EventPoster.mouseEvent(downType, at: point, button: button, clickState: Int64(index))?.post(tap: .cghidEventTap)
                usleep(12_000)
                EventPoster.mouseEvent(upType, at: point, button: button, clickState: Int64(index))?.post(tap: .cghidEventTap)
                usleep(40_000)
            }
        }
    }

    func drag(from: CGPoint, to: CGPoint, steps: Int = 24) {
        PointerGate.during {
            move(to: from)
            usleep(30_000)
            EventPoster.mouseEvent(.leftMouseDown, at: from, button: .left, clickState: 1)?.post(tap: .cghidEventTap)
            usleep(60_000)
            for step in 1...steps {
                let ratio = CGFloat(step) / CGFloat(steps)
                let eased = ratio * ratio * (3 - 2 * ratio)
                let point = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
                EventPoster.mouseEvent(.leftMouseDragged, at: point, button: .left, clickState: 1)?.post(tap: .cghidEventTap)
                usleep(12_000)
            }
            usleep(40_000)
            EventPoster.mouseEvent(.leftMouseUp, at: to, button: .left, clickState: 1)?.post(tap: .cghidEventTap)
        }
    }

    func scroll(at point: CGPoint, dx: Int, dy: Int) {
        PointerGate.during {
            wheel(at: point, dx: dx, dy: dy)
        }
    }

    private func wheel(at point: CGPoint, dx: Int, dy: Int) {
        move(to: point)
        usleep(20_000)
        // Split into wheel-sized chunks so apps with momentum handling scroll smoothly.
        let steps = max(1, min(20, Int((Double(max(abs(dx), abs(dy))) / 80).rounded(.up))))
        for _ in 0..<steps {
            guard let event = CGEvent(
                scrollWheelEvent2Source: EventPoster.source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(-dy / steps),
                wheel2: Int32(-dx / steps),
                wheel3: 0
            ) else {
                continue
            }
            event.location = point
            EventPoster.tag(event)
            event.post(tap: .cghidEventTap)
            usleep(16_000)
        }
    }

    private func move(to point: CGPoint) {
        EventPoster.mouseEvent(.mouseMoved, at: point, button: .left, clickState: 0)?.post(tap: .cghidEventTap)
    }

    /// Puts the physical pointer back where the user left it.
    func restoreCursor() {
        usleep(30_000)
        CGWarpMouseCursorPosition(originalCursor)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

func mouseButton(_ value: Any?) -> CGMouseButton {
    switch (stringValue(value) ?? "left").lowercased() {
    case "right", "r":
        return .right
    case "middle", "m", "center":
        return .center
    default:
        return .left
    }
}

/// Global-hotkey parsing for the app ("alt+space", "cmd+shift+k"): virtual key code plus
/// Carbon modifier mask, as RegisterEventHotKey expects.
public func parseHotKey(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
    guard let chord = try? KeyChord.parse(spec) else {
        return nil
    }
    var modifiers: UInt32 = 0
    if chord.flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
    if chord.flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
    if chord.flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
    if chord.flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
    return (UInt32(chord.keyCode), modifiers)
}
