import AppKit
import ApplicationServices
import Carbon
import Foundation

/// One thing the user did while demonstrating a task.
public struct DemoStep: Codable {
    public enum Kind: String, Codable {
        case click, doubleClick, rightClick, type, key, open
    }

    public let kind: Kind
    public let app: String
    public let bundleId: String?
    /// The clicked element's label, or the on-screen text at the click.
    public var target: String?
    /// Typed text; nil when an input method composed it in a field CPU cannot read.
    public var text: String?
    /// Key chord such as "cmd+f" or "return".
    public var key: String?

    /// The step as the card shows it.
    public var words: String {
        let what = target.map { "「\(compactText($0, limit: 24))」" } ?? "界面上的一个位置"
        switch kind {
        case .click:
            return "\(app)：点击\(what)"
        case .doubleClick:
            return "\(app)：双击\(what)"
        case .rightClick:
            return "\(app)：右键点击\(what)"
        case .type:
            return "\(app)：输入" + (text.map { "“\(compactText($0, limit: 30))”" } ?? "一段文字（经输入法，内容未读到）")
        case .key:
            return "\(app)：按 \(key ?? "")"
        case .open:
            return "切换到 \(app)"
        }
    }
}

/// Watches the user perform a task (clicks, keys, typing, app switches) and describes each
/// action semantically, so it can become a skill. Clicks are named by the element's label
/// (accessibility) or by the text under the pointer (OCR) in custom-drawn apps. Needs
/// Accessibility (global event monitors); events in CPU's own windows are not seen.
public final class DemonstrationRecorder {
    public var onChange: ([DemoStep]) -> Void = { _ in }
    public private(set) var steps: [DemoStep] = []

    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private let describer = DispatchQueue(label: "cpu.demonstration")
    private var typed = ""
    private var typedApp: NSRunningApplication?
    private var lastApp: pid_t?

    public init() {}

    /// Starts watching; call on the main thread.
    public func start() {
        steps = []
        lastApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.mouseDown(event)
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.keyDown(event)
        }
        monitors = [mouse, keys].compactMap { $0 }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.activated(app)
        }
    }

    /// Stops watching and returns the steps once pending descriptions are done.
    public func stop() async -> [DemoStep] {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        if let activation {
            NSWorkspace.shared.notificationCenter.removeObserver(activation)
        }
        activation = nil
        flushTyping()
        // Let the describer finish labeling the last clicks.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            describer.async {
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
        // Switching apps at the very end (back to where the user was, to call CPU) is not
        // part of the task.
        while steps.last?.kind == .open {
            steps.removeLast()
        }
        return steps
    }

    // MARK: - Events (main thread)

    private func activated(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.processIdentifier != lastApp else {
            return
        }
        flushTyping()
        lastApp = app.processIdentifier
        append(DemoStep(kind: .open, app: app.localizedName ?? app.bundleIdentifier ?? "应用", bundleId: app.bundleIdentifier))
    }

    private func mouseDown(_ event: NSEvent) {
        flushTyping()
        let appKitPoint = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
        let kind: DemoStep.Kind = event.type == .rightMouseDown ? .rightClick : (event.clickCount >= 2 ? .doubleClick : .click)
        let front = NSWorkspace.shared.frontmostApplication
        // A double click arrives as a second click: fold it into the step just recorded.
        if kind == .doubleClick, let last = steps.last, last.kind == .click {
            steps[steps.count - 1] = DemoStep(kind: .doubleClick, app: last.app, bundleId: last.bundleId, target: last.target)
            onChange(steps)
            return
        }
        let index = append(DemoStep(kind: kind, app: front?.localizedName ?? "应用", bundleId: front?.bundleIdentifier))
        describer.async { [weak self] in
            let described = DemonstrationRecorder.describe(at: point)
            DispatchQueue.main.async {
                guard let self, index < self.steps.count else {
                    return
                }
                var step = self.steps[index]
                step = DemoStep(kind: step.kind, app: described.app ?? step.app, bundleId: described.bundleId ?? step.bundleId, target: described.label)
                self.steps[index] = step
                self.onChange(self.steps)
            }
        }
    }

    private func keyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let special: [UInt16: String] = [
            36: "return", 76: "return", 48: "tab", 53: "escape", 117: "forwarddelete",
            123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown"
        ]
        let front = NSWorkspace.shared.frontmostApplication
        if flags.isEmpty, event.keyCode == 51 {
            // Backspace while typing edits the text rather than being a step of its own.
            if !typed.isEmpty {
                typed.removeLast()
                return
            }
        }
        if flags.isEmpty, special[event.keyCode] == nil, event.keyCode != 51,
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            if typedApp?.processIdentifier != front?.processIdentifier {
                flushTyping()
                typedApp = front
            }
            typed += characters
            return
        }
        flushTyping()
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if event.modifierFlags.contains(.shift), !flags.isEmpty { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        let key = special[event.keyCode] ?? (event.keyCode == 51 ? "delete" : (event.charactersIgnoringModifiers ?? "").lowercased())
        guard !key.isEmpty else {
            return
        }
        parts.append(key)
        append(DemoStep(kind: .key, app: front?.localizedName ?? "应用", bundleId: front?.bundleIdentifier, key: parts.joined(separator: "+")))
    }

    /// Ends a run of typing. Key characters are only the text when no input method composed
    /// it; otherwise the focused field's value is the text (when the app exposes it).
    private func flushTyping() {
        guard !typed.isEmpty, let app = typedApp else {
            typed = ""
            return
        }
        var text: String? = typed
        if DemonstrationRecorder.inputMethodActive() {
            let focused = AX.focusedElement(pid: app.processIdentifier)
            text = focused.flatMap { AX.string($0, kAXValueAttribute) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        append(DemoStep(kind: .type, app: app.localizedName ?? "应用", bundleId: app.bundleIdentifier, text: text))
        typed = ""
        typedApp = nil
    }

    @discardableResult
    private func append(_ step: DemoStep) -> Int {
        steps.append(step)
        onChange(steps)
        return steps.count - 1
    }

    // MARK: - Describing a click

    /// What is under a global point: the element's label, else the nearest recognized text.
    static func describe(at point: CGPoint) -> (app: String?, bundleId: String?, label: String?) {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let hit = AX.hitTest(point)
        let pid = hit.flatMap { AX.pid($0) } ?? WindowCatalog.topWindow(at: point, ignoring: ownPid)?.pid
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        if let hit, let label = label(of: hit) {
            return (app?.localizedName, app?.bundleIdentifier, label)
        }
        // Custom-drawn UI: read the text under the pointer.
        guard let pid, let window = WindowCatalog.windows(forPid: pid).first(where: { $0.onScreen && $0.bounds.contains(point) }),
              let shot = try? WindowCapture.capture(window, format: "jpeg") else {
            return (app?.localizedName, app?.bundleIdentifier, nil)
        }
        let size = CGSize(width: shot.record.pixelWidth, height: shot.record.pixelHeight)
        let pixel = shot.record.pixelRect(CGRect(origin: point, size: .zero)).origin
        let items = ScreenText.recognize(shot.sourceImage, outputSize: size)
        let nearest = items
            .map { item -> (ScreenText.Item, CGFloat) in
                let dx = max(item.rect.minX - pixel.x, 0, pixel.x - item.rect.maxX)
                let dy = max(item.rect.minY - pixel.y, 0, pixel.y - item.rect.maxY)
                return (item, hypot(dx, dy))
            }
            .min { $0.1 < $1.1 }
        // Within about a line of the click; farther text is probably something else.
        let label = nearest.flatMap { $0.1 <= 24 ? $0.0.text : nil }
        return (app?.localizedName, app?.bundleIdentifier, label)
    }

    private static func label(of element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<3 {
            guard let candidate = current else {
                break
            }
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let text = AX.string(candidate, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, text.count <= 60 {
                    return text
                }
            }
            current = AX.parent(candidate)
        }
        return nil
    }

    /// True when the current input source composes text (Pinyin, etc.), so key characters
    /// are not the text that lands in the field.
    static func inputMethodActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodWithoutModes as String)
    }
}
