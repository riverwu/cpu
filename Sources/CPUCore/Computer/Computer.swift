import AppKit
import ApplicationServices
import Foundation

/// One observation of a window: an indexed accessibility outline, optionally with a
/// screenshot. Element indexes in `outline` are bound to `stateId`.
public struct Observation {
    public let stateId: String
    public let window: WindowRecord
    public let outline: String
    public let elementCount: Int
    public let truncated: Bool
    public let focused: String?
    public let selectedText: String?
    public let note: String?
    public let screenshot: CapturedScreenshot?
    public let screenshotError: String?
    /// OCR text with screenshot-pixel positions, for windows the outline cannot drive.
    public let screenText: String?
    /// The recognized lines behind `screenText`, able to box a substring for precise clicks.
    let textItems: [ScreenText.Item]
    /// Too few interactive elements for the outline alone to drive the window.
    public let sparse: Bool
    /// The file the window shows (a document's path), when the app reports it.
    public var document: String? = nil
    /// Where the observation's time went, in ms: "ax" (outline), "screenshot", "ocr".
    public var timing: [String: Int] = [:]
}

public enum ScreenshotMode: String {
    /// Never capture.
    case never
    /// Capture only when the outline is too thin to act on (canvas, games, custom UI).
    case auto
    /// Always capture.
    case always
}

/// In-process macOS computer-use engine: window catalog, accessibility outlines,
/// background-first input, screenshots. Every method blocks and must be called off the
/// main thread (overlays and input-source switching hop to main). Callers confine an
/// instance to one serial queue, which is what makes the unchecked Sendable sound.
public final class Computer: @unchecked Sendable {
    private let cursor = VirtualCursorOverlay()
    private let snapshots = SnapshotStore()
    private let screenshots = ScreenshotStore()

    /// Fewer interactive elements than this means the outline alone is unlikely to be enough.
    public var sparseOutlineThreshold = 6
    /// Apps whose last observed window was sparse; their next observation starts OCR early.
    private var sparseApps = Set<pid_t>()
    /// Consecutive background clicks that had no visible effect, per app.
    private var backgroundClickMisses: [pid_t: Int] = [:]
    /// Text values CPU replaced during the task (element, value before), so 撤销 can put
    /// them back exactly. The first value per element wins: that is what the user had.
    private var undoJournal: [(element: AXUIElement, previous: String)] = []

    private func journal(_ element: AXUIElement, previous: String?) {
        guard let previous, !undoJournal.contains(where: { CFEqual($0.element, element) }) else {
            return
        }
        undoJournal.append((element, previous))
    }

    /// Number of text changes 撤销 can restore exactly.
    public var undoableTextChanges: Int {
        undoJournal.count
    }

    /// Puts every journaled field back to its value before the task, newest first. Returns
    /// how many were restored.
    public func undoTextChanges() -> Int {
        var restored = 0
        for entry in undoJournal.reversed() where AX.set(entry.element, kAXValueAttribute, entry.previous as CFString) == .success {
            restored += 1
        }
        undoJournal = []
        return restored
    }

    public func forgetUndo() {
        undoJournal = []
    }

    /// Methods that change app state; refused once the user stopped the task.
    private static let actionMethods: Set<String> = [
        "launch_app", "activate_window", "click", "press_key", "type_text", "scroll", "drag",
        "set_value", "perform_secondary_action", "menu"
    ]

    /// Synthesized input and accessibility actions are silently dropped by macOS without
    /// Accessibility permission, so fail loudly instead of reporting a false success.
    private static let inputMethods: Set<String> = [
        "click", "press_key", "type_text", "scroll", "drag", "set_value", "perform_secondary_action", "menu"
    ]

    public init() {
        Interrupts.cursor = cursor
    }

    /// Low-level dispatch with the reference helper's parameter names
    /// (`window: {id}`, `element_index`, `state_id`, `x`/`y`, `key`, `text`, ...).
    public func handle(method: String, params: [String: Any]) throws -> [String: Any] {
        if Computer.actionMethods.contains(method), Interrupts.isStopped {
            throw HelperError(Interrupts.stoppedMessage)
        }
        if Computer.inputMethods.contains(method) {
            try Permissions.requireAccessibility(for: "operate apps")
        }
        switch method {
        case "launch_app":
            return try launchApp(params)
        case "activate_window":
            return try activateWindow(params)
        case "click":
            return try click(params)
        case "press_key":
            return try pressKey(params)
        case "type_text":
            return try typeText(params)
        case "scroll":
            return try scroll(params)
        case "drag":
            return try drag(params)
        case "set_value":
            return try setValue(params)
        case "perform_secondary_action":
            return try performSecondaryAction(params)
        case "menu":
            return try chooseMenu(params)
        default:
            throw HelperError("Unknown method: \(method)")
        }
    }

    // MARK: - Permissions

    public static var hasAccessibility: Bool {
        Permissions.accessibilityGranted()
    }

    public static var hasScreenRecording: Bool {
        Permissions.screenCaptureGranted()
    }

    /// Shows the system prompts for missing permissions and opens the matching settings pane.
    public static func requestPermissions() {
        _ = Permissions.request(openSettings: true)
    }

    /// Prompts for Accessibility (adds CPU to the list) and opens its settings pane.
    public static func requestAccessibility() {
        _ = Permissions.accessibilityGranted(prompt: true)
        NSWorkspace.shared.open(URL(string: Permissions.accessibilityPaneUrl)!)
    }

    /// Registers CPU for Screen Recording and opens its settings pane.
    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: Permissions.screenCapturePaneUrl)!)
    }

    // MARK: - Discovery

    public func windows() -> [WindowRecord] {
        return describeSheets(WindowCatalog.list())
    }

    /// The whole text of a window's page or document, including what is scrolled out of view,
    /// as a screen reader reads it. Apps that keep their document text from accessibility
    /// (Word) are read the way a person hands text over: Select All, Copy; then the selection
    /// collapses and the clipboard is put back. `method` says which happened.
    public func readText(_ requested: WindowRecord, limit: Int = 60_000) throws -> (text: String, method: String, window: WindowRecord) {
        let record = frontSurface(of: requested) ?? requested
        guard let window = AX.windowElement(for: record) else {
            throw HelperError("\(record.app) does not expose this window to accessibility; read it from screenshots instead.")
        }
        let found = FullText.collect(from: window, limit: limit)
        if found.text.count >= 200 || !found.opaqueDocument {
            return (found.text, "accessibility", record)
        }
        // Select All in a search or name field would take only that field: give the document
        // body keyboard focus first.
        let singleLine: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField"]
        var field = AX.focusedElement(pid: record.pid).flatMap { singleLine.contains(AX.role($0)) ? $0 : nil }
        if field != nil, let body = found.body {
            AX.set(body, kAXFocusedAttribute, kCFBooleanTrue)
            usleep(80_000)
            field = AX.focusedElement(pid: record.pid).flatMap { singleLine.contains(AX.role($0)) ? $0 : nil }
        }
        if let field {
            let name = [kAXTitleAttribute, kAXDescriptionAttribute].lazy.compactMap { AX.string(field, $0) }.first { !$0.isEmpty } ?? AX.role(field)
            throw HelperError("Keyboard focus is in the field \"\(name)\", so Select All would copy only that field. Click into the document body, then read again.")
        }
        guard let copied = BackgroundInput.copyAll(pid: record.pid), !copied.isEmpty else {
            throw HelperError("Could not read the document text of \(record.app). Scroll through it and read the screenshots instead.")
        }
        // Collapse the selection so that nothing typed later replaces the whole document.
        _ = try? handle(method: "press_key", params: ["window": ["id": Int(record.id)], "key": "left"])
        return (truncateText(copied, limit: limit), "select_all_copy", record)
    }

    /// What takes input in front of `record`: an app-modal dialog (save and open panels,
    /// alerts) or the innermost sheet attached to it. Nil when nothing covers it.
    /// Reads a web page that was just opened: waits for the browser to finish loading it
    /// (and for script-built pages to fill in) before taking the text.
    public func readPage(_ record: WindowRecord, limit: Int = 60_000, timeout: TimeInterval = 10) throws -> (text: String, method: String, window: WindowRecord) {
        let deadline = Date().addingTimeInterval(timeout)
        var current = record
        while true {
            current = WindowCatalog.find(id: Int(record.id)) ?? current
            let loading = AX.windowElement(for: current).flatMap(Computer.webArea).map { AX.bool($0, "AXLoaded") == false } ?? false
            if !loading, let read = try? readText(current, limit: limit), read.text.count >= 300 || Date() >= deadline {
                return read
            }
            if Date() >= deadline || Interrupts.isStopped {
                return try readText(current, limit: limit)
            }
            Thread.sleep(forTimeInterval: loading ? 0.3 : 0.8)
        }
    }

    private static func webArea(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let element = queue.removeFirst()
            visited += 1
            if AX.role(element) == "AXWebArea" {
                return element
            }
            queue += AX.elements(element, kAXChildrenAttribute)
        }
        return nil
    }

    func frontSurface(of record: WindowRecord) -> WindowRecord? {
        let windows = WindowCatalog.windows(forPid: record.pid).filter { $0.onScreen }
        if record.layer != WindowCatalog.modalLevel, var modal = windows.first(where: { $0.layer == WindowCatalog.modalLevel }) {
            if modal.title.isEmpty, let element = AX.windowElement(for: modal) {
                modal.title = Computer.label(of: element)
            }
            modal.dialog = "modal dialog in front of window \(record.id)"
            return modal
        }
        guard let element = AX.windowElement(for: record), let sheet = AX.sheets(in: element).last, let frame = AX.frame(sheet),
              var front = windows.first(where: { $0.id != record.id && Computer.sameFrame($0.bounds, frame) }) else {
            return nil
        }
        front.title = Computer.label(of: sheet)
        front.dialog = "sheet in front of window \(record.id)"
        return front
    }

    /// Sheets are untitled windows on screen: name them and say which window they belong to.
    private func describeSheets(_ list: [WindowRecord]) -> [WindowRecord] {
        var list = list
        let pids = Set(list.filter { $0.onScreen && $0.title.isEmpty && $0.layer == 0 }.map { $0.pid })
        for pid in pids {
            for window in AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute) {
                var parent = window
                for sheet in AX.sheets(in: window) {
                    defer {
                        parent = sheet
                    }
                    guard let frame = AX.frame(sheet),
                          let index = list.firstIndex(where: { $0.pid == pid && $0.title.isEmpty && Computer.sameFrame($0.bounds, frame) }) else {
                        continue
                    }
                    list[index].title = Computer.label(of: sheet)
                    let owner = AX.frame(parent).flatMap { frame in list.first { $0.pid == pid && Computer.sameFrame($0.bounds, frame) } }
                    list[index].dialog = owner.map { "sheet on window \($0.id)" } ?? "sheet"
                }
            }
        }
        return list
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height) <= 4
    }

    private static func label(of element: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = AX.string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return ""
    }

    public func window(id: Int) -> WindowRecord? {
        return WindowCatalog.find(id: id)
    }

    /// Front-most on-screen window of the front-most regular app other than `excluding`.
    public func frontWindow(excluding excludedPid: pid_t? = nil) -> WindowRecord? {
        let all = WindowCatalog.list(includeOffscreen: false)
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != excludedPid,
           let window = all.first(where: { $0.pid == front }) {
            return window
        }
        return all.first(where: { $0.pid != excludedPid })
    }

    /// Resolves an app query without launching it (English/localized name, bundle id, path).
    public func resolveApp(_ query: String) throws -> (name: String, bundleId: String?, running: Bool) {
        switch try AppCatalog.resolve(query) {
        case .running(let app):
            return (app.localizedName ?? query, app.bundleIdentifier, true)
        case .bundle(let url):
            let bundle = Bundle(url: url)
            let fileName = url.deletingPathExtension().lastPathComponent
            let name = AppCatalog.displayNames(bundle: bundle, path: url.path, fileName: fileName).first ?? fileName
            return (name, bundle?.bundleIdentifier, false)
        }
    }

    /// True when `query` names an app exactly (not a partial match), so it can be opened
    /// without asking the model.
    public func isExactAppName(_ query: String) -> Bool {
        func normalize(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: " ", with: "")
        }
        let needle = normalize(query)
        guard !needle.isEmpty else {
            return false
        }
        if AppCatalog.runningApps().contains(where: { app in
            normalize(app.localizedName ?? "") == needle
                || normalize(app.bundleURL?.deletingPathExtension().lastPathComponent ?? "") == needle
        }) {
            return true
        }
        return AppCatalog.installedApps().contains { app in app.names.contains { normalize($0) == needle } }
    }

    /// Where the user's files are, for the model (it cannot guess the account name).
    public static var homeFolders: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "The home folder is \(home): 下载 = \(home)/Downloads, 桌面 = \(home)/Desktop, 文稿 = \(home)/Documents."
    }

    /// Opens a URL (web page, file, or app scheme), optionally in a specific app, and
    /// returns the window that shows it.
    /// `activate: false` keeps the user's app in front; CPU works on the new window behind it.
    public func open(url raw: String, app: String? = nil, activate: Bool = false, waitMs: Int = 8_000) throws -> WindowRecord? {
        if Interrupts.isStopped {
            throw HelperError(Interrupts.stoppedMessage)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file://") {
            let path = trimmed.hasPrefix("file://") ? (URL(string: trimmed)?.path ?? trimmed) : (trimmed as NSString).expandingTildeInPath
            // Opening a missing file makes macOS show an alert that then has to be dismissed.
            guard FileManager.default.fileExists(atPath: path) else {
                throw HelperError("No such file or folder: \(path). \(Computer.homeFolders)")
            }
            url = URL(fileURLWithPath: path)
        } else if let parsed = URL(string: trimmed), parsed.scheme != nil {
            url = parsed
        } else if let parsed = URL(string: "https://\(trimmed)") {
            url = parsed
        } else {
            throw HelperError("Not a valid URL or path: \(trimmed)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        let semaphore = DispatchSemaphore(value: 0)
        var opened: NSRunningApplication?
        var openError: Error?
        let completion: (NSRunningApplication?, Error?) -> Void = { app, error in
            opened = app
            openError = error
            semaphore.signal()
        }
        if let app {
            let appURL: URL
            switch try AppCatalog.resolve(app) {
            case .running(let running):
                guard let bundleURL = running.bundleURL else {
                    throw HelperError("Cannot locate the bundle of \(app).")
                }
                appURL = bundleURL
            case .bundle(let bundleURL):
                appURL = bundleURL
            }
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(url, configuration: configuration, completionHandler: completion)
        }
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw HelperError("Timed out opening \(url.absoluteString).")
        }
        if let openError {
            throw HelperError("Unable to open \(url.absoluteString): \(openError.localizedDescription)")
        }
        guard let pid = opened?.processIdentifier else {
            return frontWindow()
        }
        var window: WindowRecord?
        _ = waitUntil(timeout: TimeInterval(waitMs) / 1000, interval: 0.1) {
            window = WindowCatalog.windows(forPid: pid).first(where: { $0.onScreen })
            return window != nil || Interrupts.isStopped
        }
        if window != nil {
            SettleWaiter(pid: pid)?.wait(minimum: 0.3, quiet: 0.3, maximum: 2.5)
            window = WindowCatalog.windows(forPid: pid).first(where: { $0.onScreen }) ?? window
        }
        return window
    }

    // MARK: - Observation

    public func observe(_ requested: WindowRecord, screenshot mode: ScreenshotMode, maxNodes: Int? = nil) -> Observation {
        // A dialog in front takes the window's input: show the dialog, not the controls behind it.
        let front = frontSurface(of: requested)
        let record = front ?? requested
        let stateId = "s-\(UUID().uuidString.prefix(6).lowercased())"
        var capture: CapturedScreenshot?
        var captureError: String?
        var timing: [String: Int] = [:]
        func measure<T>(_ key: String, _ body: () -> T) -> T {
            let started = Date()
            defer { timing[key, default: 0] += Int(Date().timeIntervalSince(started) * 1000) }
            return body()
        }
        func takeScreenshot() {
            measure("screenshot") { takeScreenshotNow() }
        }
        func takeScreenshotNow() {
            do {
                let shot = try WindowCapture.capture(record, format: "jpeg")
                screenshots.store(shot.record)
                capture = shot
            } catch {
                captureError = String(describing: error)
            }
        }
        // Text recognition runs on its own queue so it overlaps the accessibility walk.
        var recognition: (group: DispatchGroup, result: RecognitionResult)?
        func startRecognition() {
            guard recognition == nil, let capture else {
                return
            }
            let group = DispatchGroup()
            let result = RecognitionResult()
            let image = capture.sourceImage
            let size = CGSize(width: capture.record.pixelWidth, height: capture.record.pixelHeight)
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                result.items = ScreenText.recognize(image, outputSize: size)
            }
            recognition = (group, result)
        }
        func recognizedItems() -> [ScreenText.Item] {
            guard let recognition else {
                return []
            }
            measure("ocr") { _ = recognition.group.wait(timeout: .distantFuture) }
            return recognition.result.items
        }

        // An app that was sparse last time most likely still is: capture and start OCR now,
        // in parallel with the accessibility walk, instead of after it.
        let expectSparse = mode != .never && sparseApps.contains(record.pid)
        if mode == .always || expectSparse {
            takeScreenshot()
        }
        if expectSparse {
            startRecognition()
        }
        guard Permissions.accessibilityGranted(prompt: true) else {
            if mode == .auto {
                takeScreenshot()
            }
            startRecognition()
            let items = recognizedItems()
            return Observation(
                stateId: stateId, window: record, outline: "", elementCount: 0, truncated: false, focused: nil,
                selectedText: nil,
                note: "Accessibility permission is missing, so the window outline is unavailable. Ask the user to enable CPU in System Settings → Privacy & Security → Accessibility.",
                screenshot: capture, screenshotError: captureError,
                screenText: items.isEmpty ? nil : ScreenText.lines(items), textItems: items, sparse: true
            )
        }
        var window = AX.windowElement(for: record)
        if window == nil {
            // Just launched or activated: the window reaches accessibility a moment after it
            // appears on screen.
            _ = waitUntil(timeout: 1.0, interval: 0.05) {
                window = AX.windowElement(for: record)
                return window != nil || Interrupts.isStopped
            }
        }
        AXEnhancer.ensure(pid: record.pid, window: window)
        let root = window ?? AXUIElementCreateApplication(record.pid)
        var options = SnapshotOptions()
        if let maxNodes {
            options.maxNodes = max(20, min(1500, maxNodes))
        }
        if let shot = capture?.record {
            options.toScreenshot = { shot.pixelRect($0) }
        }
        var snapshot = measure("ax") { AXSnapshot.build(stateId: stateId, record: record, root: root, options: options) }
        let sparse = snapshot.interactiveCount < sparseOutlineThreshold
        if sparse, mode == .auto, capture == nil {
            // The outline cannot drive this window; rebuild with pixel positions next to a screenshot.
            takeScreenshot()
            if let shot = capture?.record {
                options.toScreenshot = { shot.pixelRect($0) }
                snapshot = measure("ax") { AXSnapshot.build(stateId: stateId, record: record, root: root, options: options) }
            }
        }
        if Menus.isOpen(pid: record.pid), let menu = Menus.openMenu(pid: record.pid) {
            snapshot.appendMenu(menu, record: record, options: options)
        }
        snapshots.store(snapshot)
        if sparse {
            sparseApps.insert(record.pid)
        } else {
            // A speculative recognition for a window that turned out rich finishes unused.
            sparseApps.remove(record.pid)
        }
        var items: [ScreenText.Item] = []
        if sparse {
            startRecognition()
            items = recognizedItems()
        }

        var focusedText: String?
        var selected: String?
        if let focused = AX.focusedElement(pid: record.pid), !["AXUnknown", "AXApplication", ""].contains(AX.role(focused)) {
            if snapshot.index(of: focused) == nil, let index = snapshot.focusedInput, let field = snapshot.element(at: index) {
                // The app reports focus elsewhere (Chrome does while its save panel is up), but a
                // field here has keyboard focus: that is where typing goes.
                focusedText = describe(field, in: snapshot)
            } else if snapshot.index(of: focused) == nil, let window, let focusWindow = AX.element(focused, kAXWindowAttribute),
               !CFEqual(focusWindow, window) {
                let title = AX.string(focusWindow, kAXTitleAttribute) ?? ""
                focusedText = "keyboard focus is in another \(record.app) window\(title.isEmpty ? "" : " (\"\(title)\")"); click a field in this window before typing"
            } else {
                focusedText = describe(focused, in: snapshot)
            }
            if let text = AX.string(focused, kAXSelectedTextAttribute), !text.isEmpty {
                selected = truncateText(text, limit: 2000)
            }
        }
        var notes: [String] = []
        if front != nil {
            notes.append("Window \(requested.id) is behind this dialog and takes no input until the dialog is finished or cancelled.")
        }
        if window == nil {
            notes.append("The app did not expose this window to accessibility; the outline covers the whole app.")
        }
        return Observation(
            stateId: stateId,
            window: record,
            outline: snapshot.tree,
            elementCount: snapshot.elements.count,
            truncated: snapshot.truncated,
            focused: focusedText,
            selectedText: selected,
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            screenshot: capture,
            screenshotError: captureError,
            screenText: items.isEmpty ? nil : ScreenText.lines(items),
            textItems: items,
            sparse: sparse,
            document: window.flatMap { AX.string($0, "AXDocument") }.flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil },
            timing: timing
        )
    }

    /// Hand-off box for a background recognition; read only after its group finished.
    private final class RecognitionResult {
        var items: [ScreenText.Item] = []
    }

    /// Loads the OCR models in the background so the first custom-drawn window is not slow.
    public static func warmUpTextRecognition() {
        DispatchQueue.global(qos: .utility).async {
            ScreenText.warmUp()
        }
    }

    // MARK: - Batched actions

    public struct BatchResult {
        public var lines: [String] = []
        public var completed = 0
        public var failed: String?
        /// The window that most likely shows the outcome (a new dialog/window, or another app).
        public var window: WindowRecord?
        public var settleMs = 0
        /// Time spent in `wait` actions.
        public var waitMs = 0
    }

    /// Runs `steps` (each a `handle` method + params) against one window, stopping at the first
    /// failure, then waits for the UI to settle and picks the window to observe next.
    public func runBatch(window record: WindowRecord, steps: [(method: String, params: [String: Any], label: String)], numberFrom: Int = 1) -> BatchResult {
        var result = BatchResult()
        if let front = frontSurface(of: record),
           steps.contains(where: { $0.params["element_index"] != nil || $0.params["x"] != nil }) {
            // Accessibility would press a control behind the dialog as if the dialog were not there.
            result.failed = "window \(record.id) is behind a dialog"
            let name = front.title.isEmpty ? "" : " \"\(front.title)\""
            result.lines.append("Not run: window \(record.id) is behind the dialog\(name) (window \(front.id)), which takes all input until it is finished or cancelled. Act in the dialog, observed below.")
            result.window = front
            return result
        }
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowsBefore = Set(WindowCatalog.windows(forPid: record.pid).map { $0.id })
        let batchStarted = Date()
        let waiter = SettleWaiter(pid: record.pid)
        var settled = false
        func settle() {
            let started = Date()
            if let waiter {
                waiter.wait()
            } else {
                Thread.sleep(forTimeInterval: 0.35)
            }
            result.settleMs = Int(Date().timeIntervalSince(started) * 1000)
            settled = true
        }
        var lastEffects: [String] = []
        for (index, step) in steps.enumerated() {
            if Interrupts.isStopped {
                result.failed = Interrupts.stoppedMessage
                break
            }
            let number = numberFrom + index
            do {
                if step.method == "wait", let until = stringValue(step.params["until"]) {
                    let limit = max(0.5, min(120, doubleValue(step.params["seconds"]) ?? 30))
                    let started = Date()
                    let seen = waitFor(until, gone: boolValue(step.params["gone"]) ?? false, record: record, filesSince: batchStarted, limit: limit)
                    result.waitMs += Int(Date().timeIntervalSince(started) * 1000)
                    let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                    guard let seen else {
                        throw HelperError(Interrupts.isStopped ? Interrupts.stoppedMessage : "not seen within \(Int(limit))s")
                    }
                    result.lines.append("\(number). \(step.label): happened after \(elapsed)s\(seen.isEmpty ? "" : " — \(seen)")")
                } else if step.method == "wait" {
                    let seconds = max(0.05, min(10, doubleValue(step.params["seconds"]) ?? 1))
                    _ = waitUntil(timeout: seconds, interval: 0.05) { Interrupts.isStopped }
                    result.waitMs += Int(seconds * 1000)
                    result.lines.append("\(number). \(step.label): ok")
                } else {
                    let before = UIProbe.take(pid: record.pid)
                    let value = try handle(method: step.method, params: step.params)
                    if before.menuOpen, step.label.contains("menuitem") {
                        // Choosing an item closes the menu a moment later.
                        _ = waitUntil(timeout: 0.4, interval: 0.04) { !Menus.isOpen(pid: record.pid) }
                    }
                    if index + 1 < steps.count {
                        // Let each step land before the next one (menus, focus changes).
                        waiter?.wait(minimum: 0.05, quiet: 0.1, maximum: 0.8)
                    } else {
                        settle()
                    }
                    lastEffects = before.effects(after: UIProbe.take(pid: record.pid), pid: record.pid)
                    result.lines.append("\(number). \(step.label): \(Computer.summarize(value, effects: lastEffects))")
                }
                result.completed += 1
            } catch {
                result.failed = String(describing: error)
                result.lines.append("\(number). \(step.label): FAILED — \(error)")
                if index + 1 < steps.count {
                    result.lines.append("(skipped the remaining \(steps.count - index - 1) action(s))")
                }
                break
            }
        }
        if !settled {
            settle()
        }
        if result.failed == nil, lastEffects.isEmpty, let last = steps.last, Computer.opensDialog(last.label) {
            // "Name…" opens a dialog, and some apps take a moment to show it.
            _ = waitUntil(timeout: 1.5, interval: 0.1) {
                WindowCatalog.windows(forPid: record.pid).contains { $0.onScreen && !windowsBefore.contains($0.id) }
            }
        }
        // Whatever wrote a file (a save, an export, a script, a download) says so, with the
        // facts that tell whether it came out right.
        let saved = result.failed == nil && steps.contains(where: { Computer.saves($0.label) })
        let document = AX.windowElement(for: record).flatMap { AX.string($0, "AXDocument") }
        let earlier = result.lines
        for file in RecentFiles.written(since: batchStarted, document: document, timeout: saved ? 2.5 : 0) where !earlier.contains(where: { $0.contains(file) }) {
            result.lines.append("\(saved ? "Saved file" : "File written meanwhile"): \(file)")
        }
        result.window = followUpWindow(after: record, frontBefore: frontBefore, windowsBefore: windowsBefore)
        // Borrowed the foreground for real input: hand it back to the user's app, unless a
        // menu is open for the next action (switching apps would close it).
        if !Menus.isOpen(pid: record.pid) {
            FocusLoan.giveBack()
        }
        return result
    }

    /// Waits until `until` happens and says what was seen, or nil when it did not within
    /// `limit` seconds: "change" (the window's content, title or windows change), "file" (a
    /// file is written where files land, and has stopped growing), or a text that appears in
    /// the window (or disappears, with `gone`).
    private func waitFor(_ until: String, gone: Bool, record: WindowRecord, filesSince: Date, limit: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(limit)
        func poll(_ check: () -> String?) -> String? {
            while Date() < deadline, !Interrupts.isStopped {
                if let seen = check() {
                    return seen
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return nil
        }
        switch until.lowercased() {
        case "file":
            let document = AX.windowElement(for: record).flatMap { AX.string($0, "AXDocument") }
            let folders = RecentFiles.folders(document: document)
            var sizes: [URL: Int] = [:]
            return poll {
                let found = RecentFiles.scan(folders, since: filesSince.addingTimeInterval(-1))
                // A file still being written grows between looks.
                let settled = found.filter { sizes[$0.url] == $0.size }
                sizes = Dictionary(found.map { ($0.url, $0.size) }, uniquingKeysWith: { first, _ in first })
                guard !settled.isEmpty, settled.count == found.count else {
                    return nil
                }
                return settled.prefix(3).map { "file written: " + RecentFiles.describe($0.url, size: $0.size) }.joined(separator: "; ")
            }
        case "change":
            let before = windowText(record)
            return poll { windowText(record) != before ? "" : nil }
        default:
            let wanted = OutlineIndex.normalize(until)
            return poll {
                let present = OutlineIndex.normalize(windowText(record)).contains(wanted)
                return present != gone ? "" : nil
            }
        }
    }

    /// Everything the window says through accessibility, plus its title and its app's other
    /// windows (a dialog that appears), for waiting on a change.
    private func windowText(_ record: WindowRecord) -> String {
        let windows = WindowCatalog.windows(forPid: record.pid).filter(\.onScreen).map { "\($0.id) \($0.title)" }
        guard let element = AX.windowElement(for: record) else {
            return windows.joined(separator: "\n")
        }
        let snapshot = AXSnapshot.build(stateId: "wait", record: record, root: element, options: SnapshotOptions())
        return windows.joined(separator: "\n") + "\n" + snapshot.tree
    }

    /// A control whose title ends in an ellipsis opens a dialog (a macOS convention).
    static func opensDialog(_ label: String) -> Bool {
        label.range(of: #"(…|\.\.\.)(\([^)]*\))?""#, options: .regularExpression) != nil
    }

    /// The action presses a button that writes a file (save, export, overwrite).
    static func saves(_ label: String) -> Bool {
        label.range(of: #"(button|menuitem) "[^"]*(存储|保存|导出|替换|Save|Export|Replace)[^"]*""#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func followUpWindow(after record: WindowRecord, frontBefore: pid_t?, windowsBefore: Set<CGWindowID>) -> WindowRecord? {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        // Another app came to the front (e.g. a link opened the browser).
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != frontBefore,
           front != record.pid, front != ownPid,
           let window = WindowCatalog.windows(forPid: front).first(where: { $0.onScreen }) {
            return window
        }
        let current = WindowCatalog.windows(forPid: record.pid).filter { $0.onScreen }
        // A new window of the same app (dialog, new document, settings).
        if let fresh = current.first(where: { !windowsBefore.contains($0.id) }) {
            return fresh
        }
        return current.first(where: { $0.id == record.id }) ?? current.first
    }

    static func summarize(_ value: [String: Any], effects: [String] = []) -> String {
        var parts: [String] = []
        if var outcome = value["outcome"] as? String {
            if !effects.isEmpty, outcome == "unknown" || outcome == "no_visible_change" {
                outcome = "worked"
            }
            parts.append(outcome)
        }
        if let delivery = value["delivery"] as? String {
            parts.append("via \(delivery)")
        }
        let note = value["note"] as? String
        if let note {
            parts.append("— \(note)")
        }
        let seen = effects.filter { !($0.hasPrefix("opened a menu") && note?.hasPrefix("Opened") == true) }
        if !seen.isEmpty {
            parts.append("→ " + seen.joined(separator: "; "))
        }
        return parts.isEmpty ? "ok" : parts.joined(separator: " ")
    }

    // MARK: - App lifecycle

    private func launchApp(_ params: [String: Any]) throws -> [String: Any] {
        let query = try requireString(params["app"], "app")
        let activate = boolValue(params["activate"]) ?? true
        let waitMs = max(0, min(20_000, intValue(params["wait_ms"]) ?? 8_000))
        let target = try AppCatalog.resolve(query)
        let app: NSRunningApplication
        var alreadyRunning = false
        switch target {
        case .running(let running):
            app = running
            alreadyRunning = true
            if activate {
                if running.isHidden {
                    running.unhide()
                }
                running.activate(options: [.activateIgnoringOtherApps])
            }
        case .bundle(let url):
            app = try AppCatalog.launch(url: url, activate: activate)
        }
        var windows = WindowCatalog.windows(forPid: app.processIdentifier)
        let deadline = Date().addingTimeInterval(TimeInterval(waitMs) / 1000)
        while !windows.contains(where: { $0.onScreen }), Date() < deadline, !Interrupts.isStopped {
            Thread.sleep(forTimeInterval: 0.1)
            windows = WindowCatalog.windows(forPid: app.processIdentifier)
        }
        if !alreadyRunning, windows.contains(where: { $0.onScreen }) {
            // Freshly launched apps keep building their UI after the first window appears.
            SettleWaiter(pid: app.processIdentifier)?.wait(minimum: 0.2, quiet: 0.25, maximum: 2.0)
            windows = WindowCatalog.windows(forPid: app.processIdentifier)
        }
        noteActivity(near: windows.first?.bounds)
        return [
            "ok": true,
            "app": app.localizedName ?? query,
            "pid": Int(app.processIdentifier),
            "alreadyRunning": alreadyRunning,
            "windows": windows
        ]
    }

    private func activateWindow(_ params: [String: Any]) throws -> [String: Any] {
        let record = try requireWindow(params)
        let session = ForegroundSession(record: record)
        try session.activate()
        noteActivity(near: record.bounds)
        return ["ok": true, "outcome": "worked", "delivery": "activate"]
    }

    public func launch(app query: String, activate: Bool = false) throws -> (name: String, windows: [WindowRecord], alreadyRunning: Bool, pid: pid_t) {
        if Interrupts.isStopped {
            throw HelperError(Interrupts.stoppedMessage)
        }
        let value = try launchApp(["app": query, "activate": activate])
        return (
            value["app"] as? String ?? query,
            value["windows"] as? [WindowRecord] ?? [],
            value["alreadyRunning"] as? Bool ?? false,
            pid_t(intValue(value["pid"]) ?? 0)
        )
    }

    /// The titles of an app's menus, for an app that shows no window yet.
    public func menuTitles(pid: pid_t) -> [String] {
        MenuBar.topLevel(pid: pid).map(\.title)
    }

    private func describe(_ element: AXUIElement, in snapshot: AXSnapshot) -> String {
        let role = AX.role(element)
        let subrole = AX.string(element, kAXSubroleAttribute) ?? ""
        let label = [AX.string(element, kAXTitleAttribute), AX.string(element, kAXDescriptionAttribute)]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? ""
        var text = AXRoles.shortName(role: role, subrole: subrole)
        if let index = snapshot.index(of: element) {
            text = "[\(index)] \(text)"
        }
        if !label.isEmpty {
            text += " \"\(compactText(label, limit: 80))\""
        }
        if subrole != "AXSecureTextField", let value = AX.string(element, kAXValueAttribute), !value.isEmpty {
            text += " value=\"\(compactText(value, limit: 160))\""
        }
        return text
    }

    // MARK: - Pointer actions

    private func click(_ params: [String: Any]) throws -> [String: Any] {
        let record = try requireWindow(params)
        let policy = DeliveryPolicy.from(params)
        let button = mouseButton(params["mouse_button"])
        let count = max(1, min(3, intValue(params["click_count"]) ?? 1))
        noteActivity(near: record.bounds)
        if let index = intValue(params["element_index"]) {
            let element = try snapshots.element(index: index, stateId: stringValue(params["state_id"]), windowId: record.id)
            return try clickElement(element, record: record, button: button, count: count, policy: policy)
        }
        let point = try pointInWindow(params, record: record)
        return try clickPoint(point, record: record, button: button, count: count, policy: policy)
    }

    private func clickElement(_ element: AXUIElement, record: WindowRecord, button: CGMouseButton, count: Int, policy: DeliveryPolicy) throws -> [String: Any] {
        let role = AX.role(element)
        let actions = AX.actions(element)
        let center = AX.center(element)
        if role == "AXPopUpButton" || role == "AXMenuButton", button == .left, count == 1 {
            if policy != .foreground, let opened = openMenu(of: element, role: role, actions: actions, record: record) {
                return opened
            }
            if role == "AXPopUpButton", policy != .background, let center {
                // Its menu would not open from accessibility; a background click only
                // highlights it, so press it with the real pointer.
                var result = try foregroundClick(at: center, record: record, button: button, count: count, policy: .foreground, reason: "its menu did not open from accessibility")
                let menu = Menus.waitForOpen(pid: record.pid, near: element)
                if menu.open {
                    result["outcome"] = "worked"
                    result["note"] = "Opened \(Menus.describe(menu.menu)) (real click; the pointer was restored)."
                }
                return result
            }
        }
        if policy != .foreground {
            if button == .left, count == 1 {
                if AXRoles.textInputs.contains(role), AX.set(element, kAXFocusedAttribute, kCFBooleanTrue) == .success {
                    showCursor(center, record: record, click: true)
                    return ["ok": true, "delivery": "ax_focus", "outcome": "worked", "note": "Focused the field without moving the pointer; type_text now goes here."]
                }
                if actions.contains("AXPress") {
                    showCursor(center, record: record, click: true)
                    let windowsBefore = Set(WindowCatalog.windows(forPid: record.pid).map(\.id))
                    let status = AX.perform(element, "AXPress")
                    if status == .success {
                        return ["ok": true, "delivery": "ax_press", "outcome": "worked"]
                    }
                    if status == .cannotComplete {
                        // The app was busy opening a menu or a modal dialog, which blocks the call.
                        let menu = Menus.waitForOpen(pid: record.pid, near: element)
                        if menu.open {
                            return ["ok": true, "delivery": "ax_press", "outcome": "worked", "note": "Opened \(Menus.describe(menu.menu))."]
                        }
                        if WindowCatalog.windows(forPid: record.pid).contains(where: { !windowsBefore.contains($0.id) }) {
                            return ["ok": true, "delivery": "ax_press", "outcome": "worked"]
                        }
                    }
                    helperLog(.debug, "AXPress failed status=\(status.rawValue) role=\(role)")
                }
                if AXRoles.rows.contains(role), selectRow(element) {
                    showCursor(center, record: record, click: true)
                    return ["ok": true, "delivery": "ax_select", "outcome": "worked"]
                }
                for action in ["AXConfirm", "AXPick"] where actions.contains(action) {
                    if AX.perform(element, action) == .success {
                        showCursor(center, record: record, click: true)
                        return ["ok": true, "delivery": "ax_action", "action": action, "outcome": "worked"]
                    }
                }
            } else if button == .right, actions.contains("AXShowMenu"), [.success, .cannotComplete].contains(AX.perform(element, "AXShowMenu")) {
                showCursor(center, record: record, click: true)
                let menu = Menus.waitForOpen(pid: record.pid, near: element)
                return ["ok": true, "delivery": "ax_show_menu", "outcome": menu.open ? "worked" : "unknown", "note": menu.open ? "Opened \(Menus.describe(menu.menu))." : "Asked for its context menu."]
            } else if count == 2, actions.contains("AXOpen"), AX.perform(element, "AXOpen") == .success {
                showCursor(center, record: record, click: true)
                return ["ok": true, "delivery": "ax_open", "outcome": "worked"]
            }
        }
        guard let center else {
            throw HelperError("Element has no on-screen position, so it cannot be clicked. Scroll it into view or pick another element.")
        }
        return try foregroundClick(at: center, record: record, button: button, count: count, policy: policy, reason: "the element has no background accessibility action")
    }

    /// Opens a pop-up button's or menu button's menu through accessibility and says what it
    /// lists. Nil when no menu opened (a menu button may instead have run its command).
    private func openMenu(of element: AXUIElement, role: String, actions: [String], record: WindowRecord) -> [String: Any]? {
        let center = AX.center(element)
        for action in ["AXPress", "AXShowMenu"] where actions.contains(action) {
            let status = AX.perform(element, action)
            // An open menu runs its own loop, so the call may time out although it opened.
            guard status == .success || status == .cannotComplete else {
                continue
            }
            let menu = Menus.waitForOpen(pid: record.pid, near: element, timeout: status == .success ? 0.35 : 0.6)
            if menu.open {
                showCursor(center, record: record, click: true)
                return ["ok": true, "delivery": action == "AXPress" ? "ax_press" : "ax_show_menu", "outcome": "worked", "note": "Opened \(Menus.describe(menu.menu))."]
            }
            if role == "AXMenuButton", action == "AXPress", status == .success {
                // A split button (Word's 修订): pressing it runs its command.
                showCursor(center, record: record, click: true)
                return ["ok": true, "delivery": "ax_press", "outcome": "worked"]
            }
        }
        return nil
    }

    private func clickPoint(_ point: CGPoint, record: WindowRecord, button: CGMouseButton, count: Int, policy: DeliveryPolicy) throws -> [String: Any] {
        if policy != .foreground, button == .left, count == 1, let hit = AX.hitTest(point), AX.pid(hit) == record.pid {
            if AXRoles.textInputs.contains(AX.role(hit)), AX.set(hit, kAXFocusedAttribute, kCFBooleanTrue) == .success {
                showCursor(point, record: record, click: true)
                return ["ok": true, "delivery": "ax_focus", "outcome": "worked", "note": "Focused the field under the point without moving the pointer."]
            }
            if let target = pressableTarget(hit, point: point, windowBounds: record.bounds), AX.perform(target, "AXPress") == .success {
                showCursor(point, record: record, click: true)
                return ["ok": true, "delivery": "ax_position_press", "outcome": "worked"]
            }
        }
        return try foregroundClick(at: point, record: record, button: button, count: count, policy: policy, reason: "no background accessibility action matches that point")
    }

    private func foregroundClick(at point: CGPoint, record: WindowRecord, button: CGMouseButton, count: Int, policy: DeliveryPolicy, reason: String) throws -> [String: Any] {
        var reason = reason
        if policy != .foreground, let attempt = backgroundClick(at: point, record: record, button: button, count: count) {
            if attempt.worked != false {
                return attempt.result
            }
            guard policy != .background else {
                return attempt.result
            }
            reason = "a background click had no visible effect"
        }
        guard policy != .background else {
            throw HelperError(
                "This click needs real mouse input on macOS because \(reason), but delivery is \"background\". "
                + "Use an element index from the latest observation, or retry with delivery \"auto\" to briefly take over the pointer."
            )
        }
        let session = ForegroundSession(record: record)
        try session.activate()
        let point = try session.clearPath(to: point)
        showCursor(point, record: record, click: true)
        defer {
            session.restoreCursor()
        }
        try session.click(at: point, button: button, count: count)
        return [
            "ok": true,
            "delivery": "foreground_pointer",
            "outcome": "unknown",
            "note": Computer.note("\(record.app) was brought to the front for a real click; the pointer was restored.", session)
        ]
    }

    /// Clicks through the window's process without the real pointer, so the user keeps
    /// working undisturbed. `worked` is nil when the effect cannot be checked (no Screen
    /// Recording), false when the window did not change, which happens with web content in
    /// an inactive window; the caller then borrows the real pointer.
    private func backgroundClick(at point: CGPoint, record: WindowRecord, button: CGMouseButton, count: Int) -> (worked: Bool?, result: [String: Any])? {
        // An app that ignored background clicks twice in a row goes straight to the pointer.
        if (backgroundClickMisses[record.pid] ?? 0) >= 2 {
            return nil
        }
        let before = WindowCapture.regionFingerprint(record, around: point)
        guard BackgroundInput.click(record, at: point, button: button, count: count) else {
            return nil
        }
        showCursor(point, record: record, click: true)
        var worked: Bool?
        if let before {
            worked = false
            for _ in 0..<3 {
                usleep(80_000)
                if let after = WindowCapture.regionFingerprint(record, around: point), WindowCapture.changed(before, after) {
                    worked = true
                    break
                }
            }
            backgroundClickMisses[record.pid] = worked == true ? 0 : (backgroundClickMisses[record.pid] ?? 0) + 1
        }
        var result: [String: Any] = [
            "ok": true,
            "delivery": "background_pointer",
            "outcome": worked == true ? "worked" : (worked == false ? "no_visible_change" : "unknown")
        ]
        if worked == nil {
            result["note"] = "Clicked in the background (the pointer did not move); verify the result in the next observation."
        }
        return (worked, result)
    }

    /// Action note plus whatever was done to clear the target point.
    private static func note(_ base: String, _ session: ForegroundSession) -> String {
        guard !session.resolutions.isEmpty else {
            return base
        }
        return base + " To reach the point CPU " + session.resolutions.joined(separator: "; ") + "."
    }

    /// Shows a window to the user: unminimizes, raises and activates it. Unlike foreground
    /// borrowing, the user asked for this, so focus is not handed back afterwards.
    public func bringToFront(_ record: WindowRecord) {
        guard let current = WindowCatalog.find(id: Int(record.id)) ?? WindowCatalog.windows(forPid: record.pid).first else {
            NSRunningApplication(processIdentifier: record.pid)?.activate()
            return
        }
        if let window = AX.windowElement(for: current) {
            if AX.bool(window, kAXMinimizedAttribute) == true {
                AX.set(window, kAXMinimizedAttribute, kCFBooleanFalse)
            }
            AX.perform(window, kAXRaiseAction)
            AX.set(window, kAXMainAttribute, kCFBooleanTrue)
        }
        NSRunningApplication(processIdentifier: current.pid)?.unhide()
        AX.set(AXUIElementCreateApplication(current.pid), kAXFrontmostAttribute, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: current.pid)?.activate()
    }

    /// Puts back windows moved out of the way during the task.
    public func restoreDisplacedWindows() {
        WindowDisplacements.restoreAll()
        FocusLoan.giveBack()
    }

    private func pressableTarget(_ hit: AXUIElement, point: CGPoint, windowBounds: CGRect) -> AXUIElement? {
        // Only controls whose press does not depend on where inside them the click lands;
        // images, canvases, and generic groups need the real pointer position.
        let accepted: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox",
            "AXDisclosureTriangle", "AXMenuItem", "AXTab", "AXLink", "AXRow", "AXCell"
        ]
        return AX.ancestor(of: hit, maxDepth: 4) { candidate in
            let role = AX.role(candidate)
            guard accepted.contains(role), AX.actions(candidate).contains("AXPress"), let frame = AX.frame(candidate) else {
                return false
            }
            guard frame.insetBy(dx: -2, dy: -2).contains(point) else {
                return false
            }
            if frame.width >= windowBounds.width * 0.95, frame.height >= windowBounds.height * 0.2 {
                return false
            }
            return !((role == "AXRow" || role == "AXCell") && frame.height > 180)
        }
    }

    private func selectRow(_ element: AXUIElement) -> Bool {
        let row = AX.role(element) == "AXCell" ? (AX.ancestor(of: element, maxDepth: 3) { AX.role($0) == "AXRow" } ?? element) : element
        guard AX.isSettable(row, kAXSelectedAttribute), AX.set(row, kAXSelectedAttribute, kCFBooleanTrue) == .success else {
            return false
        }
        // A click on a row also gives its list the keyboard focus, so ⌘A, arrow keys and menu
        // commands then act on the list rather than on whatever had focus before.
        if let list = AX.ancestor(of: row, maxDepth: 3, where: { AXRoles.lists.contains(AX.role($0)) }),
           AX.bool(list, kAXFocusedAttribute) != true, AX.isSettable(list, kAXFocusedAttribute) {
            AX.set(list, kAXFocusedAttribute, kCFBooleanTrue)
        }
        return true
    }

    private func scroll(_ params: [String: Any]) throws -> [String: Any] {
        let record = try requireWindow(params)
        let policy = DeliveryPolicy.from(params)
        let dx = Int(doubleValue(params["scrollX"]) ?? 0)
        let dy = Int(doubleValue(params["scrollY"]) ?? 0)
        guard dx != 0 || dy != 0 else {
            throw HelperError("scrollX or scrollY must be non-zero (pixels; positive scrollY scrolls down).")
        }
        noteActivity(near: record.bounds)
        var point: CGPoint?
        var start: AXUIElement?
        if let index = intValue(params["element_index"]) {
            let element = try snapshots.element(index: index, stateId: stringValue(params["state_id"]), windowId: record.id)
            start = element
            point = AX.center(element)
        } else {
            let resolved = try pointInWindow(params, record: record)
            point = resolved
            start = AX.hitTest(resolved).flatMap { AX.pid($0) == record.pid ? $0 : nil }
        }
        if policy != .foreground, let start, let area = scrollArea(from: start),
           let outcome = semanticScroll(area, dx: dx, dy: dy) {
            showCursor(point, record: record, click: false)
            return outcome
        }
        guard policy != .background else {
            throw HelperError("This view has no accessibility scroll bar, so scrolling needs real wheel events, but delivery is \"background\". Retry with delivery \"auto\".")
        }
        guard let point else {
            throw HelperError("Scroll target has no on-screen position.")
        }
        let session = ForegroundSession(record: record)
        var target = point
        if session.cover(at: point) != nil {
            // Wheel events reach the window under the pointer even when its app is inactive,
            // so only an actual cover needs resolving.
            try session.activate()
            target = try session.clearPath(to: point)
        }
        showCursor(target, record: record, click: false)
        defer {
            session.restoreCursor()
        }
        session.scroll(at: target, dx: dx, dy: dy)
        return [
            "ok": true,
            "delivery": "foreground_wheel",
            "outcome": "unknown",
            "note": Computer.note("Sent wheel events under a briefly moved pointer (restored afterwards).", session)
        ]
    }

    private func scrollArea(from element: AXUIElement) -> AXUIElement? {
        return AX.ancestor(of: element, maxDepth: 10) { candidate in
            AX.role(candidate) == "AXScrollArea"
                && (AX.element(candidate, kAXVerticalScrollBarAttribute) != nil || AX.element(candidate, kAXHorizontalScrollBarAttribute) != nil)
        }
    }

    private func semanticScroll(_ area: AXUIElement, dx: Int, dy: Int) -> [String: Any]? {
        guard let areaFrame = AX.frame(area) else {
            return nil
        }
        let content = AX.elements(area, "AXContents").first
            ?? AX.elements(area, kAXChildrenAttribute).first(where: { AX.role($0) != "AXScrollBar" })
        let contentFrame = content.flatMap { AX.frame($0) }
        var positions: [String: Double] = [:]
        var moved = false
        var atEdge = false
        for (delta, vertical) in [(dy, true), (dx, false)] where delta != 0 {
            guard let bar = AX.element(area, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
                  AX.isSettable(bar, kAXValueAttribute),
                  let current = doubleValue(AX.attribute(bar, kAXValueAttribute)) else {
                return nil
            }
            let visible = Double(vertical ? areaFrame.height : areaFrame.width)
            let total = contentFrame.map { Double(vertical ? $0.height : $0.width) } ?? visible * 5
            let scrollable = max(1, total - visible)
            let next = min(1, max(0, current + Double(delta) / scrollable))
            if abs(next - current) < 0.0001 {
                atEdge = true
                positions[vertical ? "vertical" : "horizontal"] = current
                continue
            }
            guard AX.set(bar, kAXValueAttribute, NSNumber(value: next)) == .success else {
                return nil
            }
            let after = doubleValue(AX.attribute(bar, kAXValueAttribute)) ?? next
            if abs(after - current) < 0.0001 {
                return nil
            }
            moved = true
            positions[vertical ? "vertical" : "horizontal"] = (after * 1000).rounded() / 1000
        }
        guard moved || atEdge else {
            return nil
        }
        var result: [String: Any] = [
            "ok": true,
            "delivery": "ax_scroll_bar",
            "outcome": moved ? "worked" : "no_change",
            "scroll_position": positions
        ]
        if !moved {
            result["note"] = "Already at the end of the scrollable content in that direction."
        }
        return result
    }

    private func drag(_ params: [String: Any]) throws -> [String: Any] {
        let record = try requireWindow(params)
        let policy = DeliveryPolicy.from(params)
        guard policy != .background else {
            throw HelperError("Dragging needs real mouse input on macOS; retry with delivery \"auto\".")
        }
        let from = try pointInWindow(params, record: record, xKey: "from_x", yKey: "from_y")
        let to = try pointInWindow(params, record: record, xKey: "to_x", yKey: "to_y")
        noteActivity(near: record.bounds)
        let session = ForegroundSession(record: record)
        try session.activate()
        let start = try session.clearPath(to: from)
        // The target window may have been shifted to clear the start point; the end follows it.
        let end = CGPoint(x: to.x + start.x - from.x, y: to.y + start.y - from.y)
        showCursor(start, record: record, click: true)
        defer {
            session.restoreCursor()
        }
        session.drag(from: start, to: end)
        showCursor(end, record: record, click: false)
        return ["ok": true, "delivery": "foreground_pointer", "outcome": "unknown", "note": Computer.note("Dragged with the real pointer.", session)]
    }

    // MARK: - Keyboard and values

    private func pressKey(_ params: [String: Any]) throws -> [String: Any] {
        if params["window"] == nil, let pid = intValue(params["pid"]).map({ pid_t($0) }) {
            // The app has no window yet: only its menu shortcuts can reach it.
            let chord = try KeyChord.parse(try requireString(params["key"], "key"))
            guard chord.hasCommand, let title = BackgroundInput.pressMenuShortcut(chord, pid: pid) else {
                throw HelperError("The app has no window to type into; \(chord.display) is not one of its menu shortcuts.")
            }
            return ["ok": true, "delivery": "ax_menu", "outcome": "worked", "note": "Ran the menu command \"\(title)\"."]
        }
        let record = try requireWindow(params)
        let chord = try KeyChord.parse(try requireString(params["key"], "key"))
        let repeatCount = max(1, min(50, intValue(params["repeat"]) ?? 1))
        let policy = DeliveryPolicy.from(params)
        noteActivity(near: record.bounds)
        let keyTarget = try keyboardFocus(for: record)
        // A document body may be one of several text areas (Word has one per page), so its
        // Select All goes through the app's menu; a single field is selected directly.
        if chord.isSelectAll, policy != .foreground, let focused = keyTarget,
           AXRoles.textInputs.contains(AX.role(focused)),
           AX.role(focused) != "AXTextArea" || BackgroundInput.menuItem(pid: record.pid, key: "a", flags: .maskCommand) == nil,
           selectAllText(focused) {
            showCursor(AX.center(focused), record: record, click: false)
            return ["ok": true, "delivery": "ax_select_all", "outcome": "worked"]
        }
        // A shortcut that belongs to a menu command runs that command: the outcome is certain,
        // and the app may stay in the background.
        if chord.hasCommand, policy != .foreground, let title = BackgroundInput.pressMenuShortcut(chord, pid: record.pid) {
            for _ in 1..<repeatCount {
                usleep(25_000)
                _ = BackgroundInput.pressMenuShortcut(chord, pid: record.pid)
            }
            return ["ok": true, "delivery": "ax_menu", "outcome": "worked", "note": "Ran the menu command \"\(title)\"."]
        }
        let needsFront = policy == .foreground || (chord.hasCommand && !ForegroundSession.isFrontmost(pid: record.pid))
        var activated = false
        if needsFront {
            guard policy != .background else {
                throw HelperError("\(chord.display) is a menu shortcut and macOS only delivers it to the frontmost app, but delivery is \"background\". Retry with delivery \"auto\", or use an element action.")
            }
            let session = ForegroundSession(record: record)
            try session.activate()
            activated = session.activated
        }
        let before = repeatCount == 1 ? KeyEffect(record: record) : nil
        for index in 0..<repeatCount {
            if Interrupts.isStopped {
                throw HelperError(Interrupts.stoppedMessage)
            }
            try EventPoster.postKey(chord, pid: record.pid, hid: false)
            if index + 1 < repeatCount {
                usleep(25_000)
            }
        }
        var changed = before?.changed()
        var delivery = needsFront ? "foreground_key" : "background_key"
        var note = activated ? "\(record.app) was brought to the front because macOS only routes menu shortcuts to the active app." : nil
        // Escape is pressed again only to close a menu that is still open: in a text field
        // it would start completion.
        if changed == false, !needsFront, policy == .auto, chord.safeToResend || (chord.isEscape && Menus.isOpen(pid: record.pid)) {
            // Nothing at all changed: the app ignored a key sent while it was not active.
            // Press it for real with the app in front.
            let session = ForegroundSession(record: record)
            try session.activate()
            BackgroundInput.waitForUserPause()
            let retry = KeyEffect(record: record)
            try EventPoster.postKey(chord, pid: record.pid, hid: ForegroundSession.isFrontmost(pid: record.pid))
            changed = retry.changed()
            delivery = "foreground_key"
            note = "\(record.app) did not react to the key in the background, so it was brought to the front and the key pressed again."
        }
        var result: [String: Any] = [
            "ok": true,
            "delivery": delivery,
            "outcome": changed == true ? "worked" : (changed == false ? "no_visible_change" : "unknown")
        ]
        if let note {
            result["note"] = note
        }
        return result
    }

    /// Whether a posted key visibly did anything: the window's pixels or the focused field.
    private struct KeyEffect {
        let record: WindowRecord
        let pixels: [UInt8]?
        let focus: AXUIElement?
        let value: String?
        let selection: String?

        init(record: WindowRecord) {
            self.record = record
            pixels = WindowCapture.fingerprint(record)
            focus = AX.focusedElement(pid: record.pid)
            value = focus.flatMap { AX.string($0, kAXValueAttribute) }
            selection = focus.flatMap(KeyEffect.selection)
        }

        /// The caret or selection of a text field, which arrow keys move without changing text.
        static func selection(_ element: AXUIElement) -> String? {
            guard let raw = AX.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
                return nil
            }
            var range = CFRange()
            guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else {
                return nil
            }
            return "\(range.location):\(range.length)"
        }

        /// Nil when it cannot be told (no Screen Recording permission).
        func changed() -> Bool? {
            for _ in 0..<3 {
                usleep(80_000)
                let now = AX.focusedElement(pid: record.pid)
                let moved: Bool
                switch (focus, now) {
                case (nil, nil):
                    moved = false
                case let (before?, after?):
                    moved = !CFEqual(before, after)
                default:
                    moved = true
                }
                if moved || now.flatMap({ AX.string($0, kAXValueAttribute) }) != value || now.flatMap(KeyEffect.selection) != selection {
                    return true
                }
                if let pixels, let after = WindowCapture.fingerprint(record), WindowCapture.changed(pixels, after) {
                    return true
                }
            }
            return pixels == nil ? nil : false
        }
    }

    /// Keyboard input goes to the app's key window. Make the target window key (without
    /// activating the app) when focus sits in another window of the same app.
    private func keyboardFocus(for record: WindowRecord) throws -> AXUIElement? {
        guard let window = AX.windowElement(for: record) else {
            return AX.focusedElement(pid: record.pid)
        }
        func focusInTarget() -> AXUIElement?? {
            guard let focused = AX.focusedElement(pid: record.pid) else {
                return .some(nil)
            }
            guard let focusWindow = AX.element(focused, kAXWindowAttribute) else {
                return .some(focused)
            }
            return CFEqual(focusWindow, window) ? .some(focused) : nil
        }
        if let focused = focusInTarget() {
            return focused
        }
        AX.set(window, kAXMainAttribute, kCFBooleanTrue)
        AX.perform(window, kAXRaiseAction)
        for _ in 0..<6 {
            usleep(50_000)
            if let focused = focusInTarget() {
                return focused
            }
        }
        throw HelperError("Keyboard focus is in another \(record.app) window, so the input was not sent. Click the field you want in this window (element_index) first, then retry.")
    }

    private func selectAllText(_ element: AXUIElement) -> Bool {
        let length = ((AX.string(element, kAXValueAttribute) ?? "") as NSString).length
        var range = CFRange(location: 0, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else {
            return false
        }
        return AX.set(element, kAXSelectedTextRangeAttribute, value) == .success
    }

    private func typeText(_ params: [String: Any]) throws -> [String: Any] {
        let record = try requireWindow(params)
        guard let text = params["text"] as? String else {
            throw HelperError("text must be a string")
        }
        let policy = DeliveryPolicy.from(params)
        noteActivity(near: record.bounds)
        let focused = try keyboardFocus(for: record)
        let focusedRole = focused.map { AX.role($0) } ?? ""
        let isSecure = focused.map { AX.string($0, kAXSubroleAttribute) == "AXSecureTextField" } ?? false
        if policy != .foreground, let focused, !text.isEmpty, AXRoles.textInputs.contains(focusedRole), !isSecure,
           !AXEnhancer.isChromium(pid: record.pid), AX.isSettable(focused, kAXSelectedTextAttribute) {
            let before = AX.string(focused, kAXValueAttribute) ?? ""
            if AX.set(focused, kAXSelectedTextAttribute, text as CFString) == .success,
               (AX.string(focused, kAXValueAttribute) ?? "") != before {
                journal(focused, previous: before)
                showCursor(AX.center(focused), record: record, click: false)
                return ["ok": true, "delivery": "ax_insert", "outcome": "worked"]
            }
        }
        // Paste through the app's Edit menu: no key events, so the active input method and the
        // user's own typing stay out of it, and long text lands at once. Only where the field's
        // value shows whether it worked: an inactive app's Paste item can be stale and do nothing.
        if policy != .foreground, !text.isEmpty, !isSecure, let focused,
           let valueBefore = AX.string(focused, kAXValueAttribute),
           BackgroundInput.paste(text, pid: record.pid),
           let valueAfter = AX.string(focused, kAXValueAttribute), valueAfter != valueBefore {
            journal(focused, previous: valueBefore)
            showCursor(AX.center(focused), record: record, click: false)
            return ["ok": true, "delivery": "background_paste", "outcome": "worked"]
        }
        if policy == .foreground {
            try ForegroundSession(record: record).activate()
        }
        let before = focused.flatMap { AX.string($0, kAXValueAttribute) }
        // Typing may switch the system-wide input source for a moment: not while the user types.
        BackgroundInput.waitForUserPause()
        var switchedInput = false
        let guardBox: InputSourceGuard = DispatchQueue.main.sync {
            InputSourceGuard()
        }
        switchedInput = guardBox.switched
        defer {
            DispatchQueue.main.sync {
                guardBox.restore()
            }
        }
        showCursor(focused.flatMap { AX.center($0) }, record: record, click: false)
        try EventPoster.typeText(text, pid: record.pid, hid: false) { Interrupts.isStopped }
        usleep(40_000)
        var result: [String: Any] = ["ok": true, "delivery": "keyboard_events", "outcome": "unknown"]
        if let focused, let before {
            journal(focused, previous: before)
        }
        if let focused, let before, let after = AX.string(focused, kAXValueAttribute) {
            result["outcome"] = after != before ? "worked" : "no_visible_change"
            if after == before {
                result["note"] = "The focused element's value did not change. Make sure the right field is focused (click it first), then check the next observation."
            }
        } else if focused == nil {
            result["note"] = "No focused element was reported; verify the text landed where expected."
        }
        if switchedInput {
            result["input_source"] = "temporarily switched to an ASCII keyboard layout to avoid the active input method"
        }
        return result
    }

    private func setValue(_ params: [String: Any]) throws -> [String: Any] {
        let record = try requireWindow(params)
        try Permissions.requireAccessibility(for: "set values")
        let index = try requireInt(params["element_index"], "element_index")
        guard let raw = params["value"] as? String else {
            throw HelperError("value must be a string")
        }
        let element = try snapshots.element(index: index, stateId: stringValue(params["state_id"]), windowId: record.id)
        noteActivity(near: record.bounds)
        guard AX.isSettable(element, kAXValueAttribute) else {
            throw HelperError("Element \(index) (\(AXRoles.shortName(role: AX.role(element), subrole: ""))) is not directly editable. Click it and use type_text, or use perform_secondary_action.")
        }
        let current = AX.attribute(element, kAXValueAttribute)
        let newValue: CFTypeRef
        if let current, CFGetTypeID(current) == CFBooleanGetTypeID() || current is NSNumber {
            if let number = Double(raw) {
                newValue = NSNumber(value: number)
            } else if let bool = boolValue(raw) {
                newValue = NSNumber(value: bool ? 1 : 0)
            } else {
                throw HelperError("Element \(index) holds a number; pass a numeric value.")
            }
        } else {
            newValue = raw as CFString
        }
        let previous = AX.stringFromValue(current)
        let status = AX.set(element, kAXValueAttribute, newValue)
        guard status == .success else {
            throw HelperError("Unable to set the value of element \(index) (AX error \(status.rawValue)).")
        }
        journal(element, previous: previous)
        showCursor(AX.center(element), record: record, click: false)
        let after = AX.string(element, kAXValueAttribute)
        let verified = after == AX.stringFromValue(newValue)
        var result: [String: Any] = ["ok": true, "delivery": "ax_set_value", "outcome": verified ? "worked" : "unknown", "verified": verified]
        if !verified {
            result["note"] = "The app accepted the value but reports \"\(compactText(after ?? "", limit: 80))\". Web pages may ignore direct value writes; click the field and use type_text instead."
        }
        return result
    }

    private func performSecondaryAction(_ params: [String: Any]) throws -> [String: Any] {
        let record = try requireWindow(params)
        try Permissions.requireAccessibility(for: "perform accessibility actions")
        let index = try requireInt(params["element_index"], "element_index")
        let requested = try requireString(params["action"], "action")
        let element = try snapshots.element(index: index, stateId: stringValue(params["state_id"]), windowId: record.id)
        noteActivity(near: record.bounds)
        let available = AX.actions(element)
        let normalized = requested.hasPrefix("AX") ? requested : "AX" + requested.prefix(1).uppercased() + requested.dropFirst()
        let action = available.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame })
            ?? available.first(where: { AX.actionName($0).caseInsensitiveCompare(requested) == .orderedSame })
        guard let action else {
            let names = available.map(AX.actionName)
            throw HelperError("Element \(index) does not support \(requested). Available actions: \(names.isEmpty ? "none" : names.joined(separator: ", ")).")
        }
        let status = AX.perform(element, action)
        if status == .cannotComplete {
            // An open menu runs its own loop, so the call may time out although it opened.
            let menu = Menus.waitForOpen(pid: record.pid, near: element)
            if menu.open {
                showCursor(AX.center(element), record: record, click: true)
                return ["ok": true, "delivery": "ax_action", "action": AX.actionName(action), "outcome": "worked", "note": "Opened \(Menus.describe(menu.menu))."]
            }
        }
        guard status == .success else {
            throw HelperError("Accessibility action \(AX.actionName(action)) failed (AX error \(status.rawValue)).")
        }
        showCursor(AX.center(element), record: record, click: true)
        return ["ok": true, "delivery": "ax_action", "action": AX.actionName(action), "outcome": "worked"]
    }

    /// Chooses a menu bar command by its path, or lists the menu the path ends at. Needs a
    /// window (its document is what the command acts on), or just the app's pid when it has
    /// no window yet ("文件 ▸ 新建" makes one).
    private func chooseMenu(_ params: [String: Any]) throws -> [String: Any] {
        let path = try requireString(params["path"], "path")
        var record: WindowRecord?
        if params["window"] != nil {
            record = try requireWindow(params)
        }
        guard let pid = record?.pid ?? intValue(params["pid"]).map({ pid_t($0) }) else {
            throw HelperError("menu needs a window or an app.")
        }
        if let record {
            noteActivity(near: record.bounds)
            // Commands act on the app's main window: make it the one the model means.
            _ = try? keyboardFocus(for: record)
        }
        var outcome = try MenuBar.resolve(pid: pid, path: path)
        if case .listed(let full, let items) = outcome {
            var note = "\(full) has \(items.count) items: \(MenuBar.describe(items))"
            if items.contains(where: { !$0.enabled }), !ForegroundSession.isFrontmost(pid: pid) {
                note += ". (The app is in the background, where commands that act on a document show dimmed; choosing one brings it forward and checks again.)"
            }
            return ["ok": true, "delivery": "ax_menu", "outcome": "worked", "note": note]
        }
        var activated = false
        if case .chose(let full, let item) = outcome, !item.enabled, let record {
            // A menu says which commands are available as of its last check, and a background
            // app has no key window for document commands. Bring the app forward and open the
            // menu, as a person would: opening it checks its items again.
            if !ForegroundSession.isFrontmost(pid: pid) {
                let session = ForegroundSession(record: record)
                try session.activate()
                activated = session.activated
            }
            if let top = MenuBar.parts(full).first, let bar = MenuBar.topLevel(pid: pid).first(where: { $0.title == top }) {
                AX.perform(bar.element, kAXPressAction)
                _ = waitUntil(timeout: 0.6, interval: 0.05) { Menus.isOpen(pid: pid) }
                outcome = try MenuBar.resolve(pid: pid, path: full)
                if case .chose(_, let checked) = outcome, !checked.enabled, let menu = bar.submenu {
                    AX.perform(menu, kAXCancelAction)
                }
            }
        }
        guard case .chose(let full, let item) = outcome else {
            throw HelperError("\(path) is a menu, not a command.")
        }
        guard item.enabled else {
            throw HelperError("\(full) is dimmed: it needs something first (a selection, the right window or field in front, something copied).")
        }
        let status = AX.perform(item.element, kAXPressAction)
        // A command that opens a modal dialog can block the call although it ran.
        guard status == .success || status == .cannotComplete else {
            throw HelperError("Choosing \(full) failed (AX error \(status.rawValue)).")
        }
        // A menu opened above closes as the command runs; let it go before effects are read.
        _ = waitUntil(timeout: 0.5, interval: 0.04) { !Menus.isOpen(pid: pid) }
        var note = "Chose \(full)."
        if activated, let record {
            note += " \(record.app) was brought to the front: the command is dimmed while the app is in the background."
        }
        return ["ok": true, "delivery": activated ? "foreground_menu" : "ax_menu", "outcome": "worked", "note": note]
    }

    // MARK: - Helpers

    private func requireWindow(_ params: [String: Any]) throws -> WindowRecord {
        let window = params["window"] as? [String: Any] ?? params
        let id = try requireInt(window["id"], "window.id")
        if let record = WindowCatalog.find(id: id) {
            return record
        }
        throw HelperError("Window \(id) is no longer available (it was closed or recreated). Call list_windows to get a fresh window.")
    }

    private func pointInWindow(_ params: [String: Any], record: WindowRecord, xKey: String = "x", yKey: String = "y") throws -> CGPoint {
        let x = try requireDouble(params[xKey], xKey)
        let y = try requireDouble(params[yKey], yKey)
        let space = stringValue(params["coordinate_space"]) ?? stringValue(params["coordinateSpace"])
        let screenshotId = stringValue(params["screenshotId"]) ?? stringValue(params["screenshot_id"])
        if space == "window_points" {
            return CGPoint(x: record.bounds.minX + CGFloat(x), y: record.bounds.minY + CGFloat(y))
        }
        let screenshot: ScreenshotRecord
        if let screenshotId {
            guard let stored = screenshots.get(screenshotId) else {
                throw HelperError("Unknown or expired screenshotId \(screenshotId). Ask for a new screenshot.")
            }
            guard stored.windowId == record.id else {
                throw HelperError("screenshotId \(screenshotId) belongs to window \(stored.windowId), not \(record.id).")
            }
            screenshot = stored
        } else if let latest = screenshots.latest(windowId: record.id) {
            screenshot = latest
        } else {
            throw HelperError("Coordinates need a screenshot of this window: pass screenshot: true to get one.")
        }
        let global = try screenshot.globalPoint(x: x, y: y)
        // Follow the window if it moved since the screenshot was taken.
        return CGPoint(
            x: global.x + (record.bounds.minX - screenshot.origin.x),
            y: global.y + (record.bounds.minY - screenshot.origin.y)
        )
    }

    private func showCursor(_ point: CGPoint?, record: WindowRecord, click: Bool) {
        guard let point else {
            return
        }
        cursor.show(at: point, above: record.id, click: click)
    }

    private func noteActivity(near frame: CGRect?) {
        Interrupts.installMonitorIfPossible()
    }
}
