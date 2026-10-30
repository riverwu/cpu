import AppKit
import ApplicationServices
import Foundation

/// Thin, failure-tolerant wrappers over the AXUIElement C API.
enum AX {
    static let systemWide = AXUIElementCreateSystemWide()
    static let readTimeout: Float = 0.35
    static let actionTimeout: Float = 1.0

    static func configureGlobalTimeout() {
        // Setting the timeout on the system-wide element sets the process-wide default.
        AXUIElementSetMessagingTimeout(systemWide, readTimeout)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        return stringFromValue(attribute(element, name))
    }

    static func stringFromValue(_ value: CFTypeRef?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? "1" : "0"
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 1e12 {
                return String(Int64(double))
            }
            return String(format: "%.3g", double)
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        return nil
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else {
            return nil
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }

    static func point(_ element: AXUIElement, _ name: String = kAXPositionAttribute) -> CGPoint? {
        return pointFromValue(attribute(element, name))
    }

    static func size(_ element: AXUIElement, _ name: String = kAXSizeAttribute) -> CGSize? {
        return sizeFromValue(attribute(element, name))
    }

    static func pointFromValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    static func sizeFromValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element), let size = size(element) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    static func center(_ element: AXUIElement) -> CGPoint? {
        guard let frame = frame(element), frame.width > 0 || frame.height > 0 else {
            return nil
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }

    /// A custom action (a list row's "未读", "提醒我") comes as "Name:未读\nTarget:0x0\nSelector:(null)";
    /// its name is what the user sees.
    static func actionName(_ raw: String) -> String {
        guard raw.hasPrefix("Name:") else {
            return raw
        }
        return String(raw.dropFirst(5).prefix { $0 != "\n" })
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        return self.element(element, kAXParentAttribute)
    }

    static func role(_ element: AXUIElement) -> String {
        return string(element, kAXRoleAttribute) ?? ""
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementSetMessagingTimeout(element, actionTimeout)
        return AXUIElementPerformAction(element, action as CFString)
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetMessagingTimeout(element, actionTimeout)
        return AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    /// One IPC round trip for many attributes; missing ones are omitted from the result.
    static func multiple(_ element: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard status == .success, let array = values as? [AnyObject], array.count == names.count else {
            var fallback: [String: CFTypeRef] = [:]
            for name in names {
                if let value = attribute(element, name) {
                    fallback[name] = value
                }
            }
            return fallback
        }
        var result: [String: CFTypeRef] = [:]
        for (index, name) in names.enumerated() {
            let value = array[index] as CFTypeRef
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                continue
            }
            result[name] = value
        }
        return result
    }

    static func hitTest(_ point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else {
            return nil
        }
        return element
    }

    static func isDescendant(_ element: AXUIElement, of ancestor: AXUIElement, maxDepth: Int = 40) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < maxDepth {
            if CFEqual(candidate, ancestor) {
                return true
            }
            current = parent(candidate)
            depth += 1
        }
        return false
    }

    static func ancestor(of element: AXUIElement, maxDepth: Int = 12, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < maxDepth {
            if predicate(candidate) {
                return candidate
            }
            current = parent(candidate)
            depth += 1
        }
        return nil
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        return element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
    }

    static func windowElement(for record: WindowRecord) -> AXUIElement? {
        let app = AXUIElementCreateApplication(record.pid)
        let windows = elements(app, kAXWindowsAttribute)
        guard !windows.isEmpty else {
            return nil
        }
        let best = closest(to: record, among: windows)
        if best.delta <= 2 {
            return best.element
        }
        // Sheets are windows of their own on screen but children of their window in accessibility.
        let sheet = closest(to: record, among: windows.flatMap { self.sheets(in: $0) })
        return sheet.element != nil && sheet.delta <= 2 ? sheet.element : best.element
    }

    /// Sheets attached to a window or sheet, outermost first (a save sheet can sit on a print sheet).
    static func sheets(in element: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var current = element
        while found.count < 4, let sheet = elements(current, kAXChildrenAttribute).last(where: { role($0) == "AXSheet" }) {
            found.append(sheet)
            current = sheet
        }
        return found
    }

    private static func closest(to record: WindowRecord, among windows: [AXUIElement]) -> (element: AXUIElement?, delta: CGFloat) {
        var best: AXUIElement?
        var bestDelta = CGFloat.infinity
        var bestScore = -Double.infinity
        for window in windows {
            var score = 0.0
            var delta = CGFloat.infinity
            if let frame = frame(window) {
                delta = abs(frame.minX - record.bounds.minX) + abs(frame.minY - record.bounds.minY)
                    + abs(frame.width - record.bounds.width) + abs(frame.height - record.bounds.height)
                score -= Double(delta)
            } else {
                score -= 10_000
            }
            if !record.title.isEmpty, string(window, kAXTitleAttribute) == record.title {
                score += 500
            }
            if score > bestScore {
                bestScore = score
                best = window
                bestDelta = delta
            }
        }
        return (best, bestDelta)
    }
}

enum AXRoles {
    static let textInputs: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField", "AXComboBox"
    ]
    static let rows: Set<String> = ["AXRow", "AXCell", "AXOutlineRow"]
    static let lists: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser"]
    static let controls: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox",
        "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField", "AXSlider", "AXIncrementor",
        "AXLink", "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle", "AXTab", "AXRow", "AXCell",
        "AXColorWell", "AXDateField", "AXStepper", "AXSwitch", "AXToggle", "AXRadioGroup", "AXTabGroup"
    ]
    static let containers: Set<String> = [
        "AXList", "AXTable", "AXOutline", "AXBrowser", "AXWebArea", "AXSheet", "AXDialog",
        "AXToolbar", "AXPopover", "AXMenu", "AXGrid", "AXCollection"
    ]
    /// Elements that never carry useful structure for the model.
    static let skippedSubtrees: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXValueIndicator", "AXMatte", "AXRuler", "AXRulerMarker"
    ]
    static let windowButtonLabels: [String: String] = [
        "AXCloseButton": "close window",
        "AXMinimizeButton": "minimize window",
        "AXZoomButton": "zoom window",
        "AXFullScreenButton": "full screen"
    ]
    static let meaningfulActions: Set<String> = [
        "AXPress", "AXConfirm", "AXPick", "AXOpen", "AXIncrement", "AXDecrement", "AXShowAlternateUI"
    ]

    static func shortName(role: String, subrole: String) -> String {
        if subrole == "AXOutlineRow" {
            return "row"
        }
        switch role {
        case "AXStaticText": return "text"
        case "AXTextField": return subrole == "AXSearchField" ? "searchfield" : "textfield"
        case "AXTextArea": return "textarea"
        case "AXSecureTextField": return "securefield"
        case "AXPopUpButton": return "popup"
        case "AXMenuButton": return "menubutton"
        case "AXCheckBox": return subrole == "AXSwitch" ? "switch" : "checkbox"
        case "AXRadioButton": return "radio"
        case "AXComboBox": return "combobox"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXScrollArea": return "scrollarea"
        case "AXWebArea": return "webarea"
        case "AXRadioGroup": return "radiogroup"
        case "AXTabGroup": return "tabgroup"
        case "AXMenuItem": return "menuitem"
        case "AXMenuBarItem": return "menubaritem"
        case "AXSplitGroup": return "splitgroup"
        case "AXValueIndicator": return "indicator"
        case "AXProgressIndicator": return "progress"
        case "AXBusyIndicator": return "busy"
        case "AXLevelIndicator": return "level"
        case "AXImage": return "image"
        case "AXHeading": return "heading"
        default:
            let trimmed = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            return trimmed.isEmpty ? "element" : trimmed.lowercased()
        }
    }
}

/// Chromium/Electron apps only expose their web content tree once an assistive
/// client asks for it; ask once per process and give the tree time to appear.
enum AXEnhancer {
    private static var enabledPids = Set<pid_t>()
    private static let lock = NSLock()
    private static let browserBundleIds: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"
    ]

    static func isChromium(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        if let bundleId = app.bundleIdentifier, browserBundleIds.contains(bundleId) {
            return true
        }
        guard let url = app.bundleURL else {
            return false
        }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let electron = frameworks.appendingPathComponent("Electron Framework.framework").path
        let chromium = frameworks.appendingPathComponent("Chromium Embedded Framework.framework").path
        return FileManager.default.fileExists(atPath: electron) || FileManager.default.fileExists(atPath: chromium)
    }

    /// Returns true when the tree was just enabled, so callers can wait for it to populate.
    @discardableResult
    static func ensure(pid: pid_t, window: AXUIElement?) -> Bool {
        lock.lock()
        let inserted = enabledPids.insert(pid).inserted
        lock.unlock()
        guard inserted else {
            return false
        }
        let app = AXUIElementCreateApplication(pid)
        let manual = AX.set(app, "AXManualAccessibility", kCFBooleanTrue)
        var enabled = manual == .success
        if !enabled, let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           browserBundleIds.contains(bundleId) {
            enabled = AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) == .success
        }
        guard enabled, isChromium(pid: pid), let window else {
            return false
        }
        // Web content materializes asynchronously after the toggle (about 1-3s on a cold renderer).
        let initial = probe(window, limit: 400)
        let started = Date()
        var last = initial
        while Date().timeIntervalSince(started) < 3.5, !Interrupts.isStopped {
            Thread.sleep(forTimeInterval: 0.15)
            last = probe(window, limit: 400)
            if last.webContent || last.count >= initial.count + 8 {
                Thread.sleep(forTimeInterval: 0.25)
                break
            }
        }
        helperLog(.debug, "enabled web accessibility pid=\(pid) nodes \(initial.count)->\(last.count) web=\(last.webContent) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return true
    }

    /// Counts nodes and reports whether a web area already has rendered children.
    private static func probe(_ root: AXUIElement, limit: Int) -> (count: Int, webContent: Bool) {
        var count = 0
        var webContent = false
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast(), count < limit {
            count += 1
            let children = AX.elements(element, kAXChildrenAttribute)
            if !webContent, AX.role(element) == "AXWebArea", children.count > 0 {
                webContent = true
            }
            guard depth < 40 else {
                continue
            }
            for child in children.reversed() {
                stack.append((child, depth + 1))
            }
        }
        return (count, webContent)
    }
}

struct SnapshotOptions {
    var maxNodes = 350
    var maxVisited = 5000
    var maxDepth = 48
    var timeBudget: TimeInterval = 2.0
    var valueLimit = 160
    var textLimit = 6000
    /// Maps a global screen rect to screenshot pixels, when a screenshot accompanies the tree.
    var toScreenshot: ((CGRect) -> CGRect)?
}

/// Indexed, state-scoped accessibility outline of one window.
final class AXSnapshot {
    let stateId: String
    let windowId: CGWindowID
    let pid: pid_t
    private(set) var elements: [AXUIElement] = []
    private(set) var lines: [String] = []
    private var texts: [String] = []
    private var textChars = 0
    private(set) var truncated = false
    /// Rendered elements the model can act on (controls and anything with a press action).
    private(set) var interactiveCount = 0
    /// The text field with keyboard focus in this window, if any.
    private(set) var focusedInput: Int?
    private var renderedFocusedInput = false
    private var visited = 0

    init(stateId: String, windowId: CGWindowID, pid: pid_t) {
        self.stateId = stateId
        self.windowId = windowId
        self.pid = pid
    }

    func element(at index: Int) -> AXUIElement? {
        guard index >= 0, index < elements.count else {
            return nil
        }
        return elements[index]
    }

    func index(of element: AXUIElement) -> Int? {
        return elements.firstIndex(where: { CFEqual($0, element) })
    }

    var tree: String {
        return lines.joined(separator: "\n")
    }

    func documentText(limit: Int) -> String {
        return truncateText(texts.joined(separator: "\n"), limit: limit)
    }

    private static let attributeNames = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute, kAXEnabledAttribute,
        kAXFocusedAttribute, kAXSelectedAttribute, kAXExpandedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXChildrenAttribute
    ]

    static func build(
        stateId: String,
        record: WindowRecord,
        root: AXUIElement,
        options: SnapshotOptions
    ) -> AXSnapshot {
        let snapshot = AXSnapshot(stateId: stateId, windowId: record.id, pid: record.pid)
        let started = Date()
        snapshot.visit(root, depth: 0, outputDepth: 0, rowLabel: nil, clip: record.bounds.insetBy(dx: -1, dy: -1), options: options, started: started, windowBounds: record.bounds)
        if snapshot.truncated {
            snapshot.lines.append("… [outline truncated after \(snapshot.elements.count) elements; inspect a smaller window or pass max_nodes]")
        }
        return snapshot
    }

    /// Adds an open menu that is not part of the window's tree (a context menu belongs to the
    /// app), so its items can be targeted like the window's own elements.
    func appendMenu(_ menu: AXUIElement, record: WindowRecord, options: SnapshotOptions) {
        guard index(of: menu) == nil else {
            return
        }
        var options = options
        options.maxNodes = elements.count + 80
        truncated = false
        lines.append("Open menu:")
        visit(menu, depth: 1, outputDepth: 0, rowLabel: nil, clip: .infinite, options: options, started: Date(), windowBounds: record.bounds)
    }

    /// Containers whose bounds clip their content (scrolled-out children are not visible).
    private static let viewportRoles: Set<String> = [
        "AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline", "AXGrid", "AXCollection", "AXBrowser"
    ]

    enum Visibility: Equatable {
        /// Visible; carries hidden descendants not yet reported by a printed ancestor.
        case visible(pendingHidden: Int)
        /// Scrolled or clipped out of view; summarized as "N more items".
        case outside
        /// Empty or zero-size; skipped silently.
        case empty
    }

    @discardableResult
    private func visit(
        _ element: AXUIElement,
        depth: Int,
        outputDepth: Int,
        rowLabel: String?,
        clip: CGRect,
        options: SnapshotOptions,
        started: Date,
        windowBounds: CGRect
    ) -> Visibility {
        if truncated {
            return .visible(pendingHidden: 0)
        }
        if elements.count >= options.maxNodes || visited >= options.maxVisited
            || Date().timeIntervalSince(started) > options.timeBudget {
            truncated = true
            return .visible(pendingHidden: 0)
        }
        visited += 1
        let values = AX.multiple(element, AXSnapshot.attributeNames)
        let role = AX.stringFromValue(values[kAXRoleAttribute]) ?? ""
        if AXRoles.skippedSubtrees.contains(role) {
            return .empty
        }
        let frame = AXSnapshot.frame(from: values)
        let children = (values[kAXChildrenAttribute] as? [AXUIElement]) ?? []
        if depth > 0, let frame {
            if frame.width > 0, frame.height > 0, !frame.intersects(clip) {
                return .outside
            }
            if (frame.width <= 1.5 || frame.height <= 1.5), frame.origin != .zero, !AXSnapshot.hasVisibleChild(children) {
                // Chromium clamps scrolled-out elements to a 1pt sliver at the container edge.
                let edge: CGFloat = 1.5
                let onEdge = abs(frame.minY - clip.maxY) <= edge || abs(frame.maxY - clip.minY) <= edge
                    || abs(frame.minX - clip.maxX) <= edge || abs(frame.maxX - clip.minX) <= edge
                    || abs(frame.maxY - clip.maxY) <= edge || abs(frame.minY - clip.minY) <= edge
                return onEdge && clip.height < windowBounds.height - 4 ? .outside : .empty
            }
        }
        let subrole = AX.stringFromValue(values[kAXSubroleAttribute]) ?? ""
        renderedFocusedInput = false
        let rendered = render(element: element, role: role, subrole: subrole, values: values, frame: frame, children: children, rowLabel: rowLabel, options: options, windowBounds: windowBounds)

        var childOutputDepth = outputDepth
        var childRowLabel = rowLabel
        var ownIndex: Int?
        if let rendered {
            let index = elements.count
            ownIndex = index
            elements.append(element)
            if renderedFocusedInput {
                focusedInput = index
            }
            lines.append("\(String(repeating: "  ", count: outputDepth))[\(index)] \(rendered.line)")
            childOutputDepth = outputDepth + 1
            if rendered.foldsChildText, !rendered.label.isEmpty {
                childRowLabel = rendered.label
            }
        }
        guard depth < options.maxDepth else {
            return .visible(pendingHidden: 0)
        }
        var childClip = clip
        if role == "AXMenu" {
            // A menu draws over everything, beyond its window, and its items can be chosen
            // even when scrolled out of view: list them all.
            childClip = .infinite
        } else if let frame, frame.width > 0, frame.height > 0,
           AXSnapshot.viewportRoles.contains(role) || (role == "AXGroup" && children.count > 20) {
            childClip = clip.intersection(frame)
        }
        var hidden = 0
        for child in children {
            if truncated {
                break
            }
            switch visit(child, depth: depth + 1, outputDepth: childOutputDepth, rowLabel: childRowLabel, clip: childClip, options: options, started: started, windowBounds: windowBounds) {
            case .outside:
                hidden += 1
            case .visible(let pending):
                hidden += pending
            case .empty:
                break
            }
        }
        guard hidden > 0, !truncated else {
            return .visible(pendingHidden: 0)
        }
        guard let ownIndex else {
            // Not printed: let the nearest printed ancestor report these.
            return .visible(pendingHidden: hidden)
        }
        lines.append("\(String(repeating: "  ", count: childOutputDepth))… \(hidden) more item\(hidden == 1 ? "" : "s") outside the visible area of [\(ownIndex)] (scroll to reveal)")
        return .visible(pendingHidden: 0)
    }

    private static func hasVisibleChild(_ children: [AXUIElement]) -> Bool {
        for child in children.prefix(3) {
            if let frame = AX.frame(child), frame.width > 1.5, frame.height > 1.5 {
                return true
            }
        }
        return false
    }

    static func frame(from values: [String: CFTypeRef]) -> CGRect? {
        guard let origin = AX.pointFromValue(values[kAXPositionAttribute]),
              let size = AX.sizeFromValue(values[kAXSizeAttribute]) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func render(
        element: AXUIElement,
        role: String,
        subrole: String,
        values: [String: CFTypeRef],
        frame: CGRect?,
        children: [AXUIElement],
        rowLabel: String?,
        options: SnapshotOptions,
        windowBounds: CGRect
    ) -> (line: String, label: String, foldsChildText: Bool)? {
        let title = AX.stringFromValue(values[kAXTitleAttribute])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = AX.stringFromValue(values[kAXDescriptionAttribute])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawValue = AX.stringFromValue(values[kAXValueAttribute]) ?? ""
        let placeholder = AX.stringFromValue(values[kAXPlaceholderValueAttribute]) ?? ""
        let help = AX.stringFromValue(values[kAXHelpAttribute]) ?? ""
        let enabled = values[kAXEnabledAttribute].flatMap { AX.stringFromValue($0) } != "0"
        let focused = AX.stringFromValue(values[kAXFocusedAttribute]) == "1"
        let selected = AX.stringFromValue(values[kAXSelectedAttribute]) == "1"
        let expanded = AX.stringFromValue(values[kAXExpandedAttribute])

        var label = title.isEmpty ? description : title
        if label.isEmpty, let windowButton = AXRoles.windowButtonLabels[subrole] {
            label = windowButton
        }
        var valueText = ""
        let isText = role == "AXStaticText"
        let isTextInput = AXRoles.textInputs.contains(role)
        if isText {
            if label.isEmpty {
                label = rawValue
            } else if !rawValue.isEmpty, rawValue != label {
                // Labeled read-only displays (Calculator's result, status fields) keep the
                // content in the value.
                valueText = rawValue
                collectText(rawValue)
            }
            collectText(label)
        } else if isTextInput {
            valueText = rawValue
            if subrole != "AXSecureTextField", role != "AXSecureTextField" {
                collectText(rawValue)
            } else if !rawValue.isEmpty {
                valueText = "••••"
            }
        } else if !rawValue.isEmpty, role != "AXWindow", role != "AXScrollArea" {
            valueText = rawValue
        }
        let actions: [String]
        let isControl = AXRoles.controls.contains(role) || AXRoles.containers.contains(role)
        if isControl || isText || role == "AXGroup" || role == "AXImage" || role == "AXCell" || role.isEmpty || role == "AXUnknown" {
            actions = AX.actions(element)
        } else {
            actions = []
        }
        let meaningful = actions.filter { AXRoles.meaningfulActions.contains($0) }

        // Rows, cells, and clickable containers often carry their text in children.
        var foldsChildText = false
        let labelFromChildren = AXRoles.rows.contains(role)
            || (meaningful.contains("AXPress") && ["AXGroup", "AXButton", "AXLink", "AXImage", "AXUnknown", ""].contains(role))
        if label.isEmpty, labelFromChildren {
            label = synthesizedLabel(children: children)
            foldsChildText = !label.isEmpty
        } else if AXRoles.rows.contains(role), !label.isEmpty {
            foldsChildText = true
        }
        if label.isEmpty, role == "AXImage" || role == "AXGroup" || role == "AXButton" {
            if !help.isEmpty {
                label = help
            }
        }

        let interesting: Bool
        switch role {
        case "AXWindow", "AXScrollArea":
            interesting = true
        case "AXGroup", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXGenericElement", "":
            interesting = !label.isEmpty || !meaningful.isEmpty
        case "AXStaticText":
            // Row labels already include their cell text; avoid repeating it line by line.
            interesting = !label.isEmpty && !(rowLabel?.contains(label) ?? false)
        case "AXCell":
            // A cell that only repeats its row's label adds nothing; the row is the target.
            let repeatsRow = label.isEmpty || (rowLabel?.contains(label) ?? false)
            interesting = !repeatsRow || (label.isEmpty && !meaningful.isEmpty && rowLabel == nil)
        case "AXImage":
            let repeatsRow = !label.isEmpty && (rowLabel?.contains(label) ?? false)
            interesting = (!label.isEmpty && !repeatsRow) || (!meaningful.isEmpty && rowLabel == nil)
        default:
            interesting = isControl || !label.isEmpty || !valueText.isEmpty || !meaningful.isEmpty
        }
        guard interesting else {
            return nil
        }

        var parts = [AXRoles.shortName(role: role, subrole: subrole)]
        if !label.isEmpty {
            parts.append("\"\(compactText(label, limit: options.valueLimit))\"")
        }
        if !valueText.isEmpty, valueText != label {
            parts.append("value=\"\(compactText(valueText, limit: options.valueLimit))\"")
        }
        if isTextInput, valueText.isEmpty, !placeholder.isEmpty {
            parts.append("placeholder=\"\(compactText(placeholder, limit: 60))\"")
        }
        if role == "AXScrollArea" {
            if let bar = AX.element(element, kAXVerticalScrollBarAttribute), let position = AX.string(bar, kAXValueAttribute) {
                parts.append("scroll=\(position)")
            }
        }
        var flags: [String] = []
        if !enabled {
            flags.append("disabled")
        }
        if focused, isTextInput {
            // Keyboard focus matters for typing; other focus is reported via focused_element.
            flags.append("focused")
            renderedFocusedInput = true
        }
        if selected {
            flags.append("selected")
        }
        if expanded == "1" {
            flags.append("expanded")
        } else if expanded == "0", role == "AXDisclosureTriangle" || subrole == "AXOutlineRow" {
            // Chromium reports AXExpanded=0 on every element; only trust it where it means something.
            flags.append("collapsed")
        }
        let pressImplied: Set<String> = [
            "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
            "AXDisclosureTriangle", "AXTab", "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField",
            "AXComboBox", "AXWebArea", "AXWindow"
        ]
        if meaningful.contains("AXPress"), !pressImplied.contains(role) {
            flags.append("clickable")
        }
        if meaningful.contains("AXIncrement") || meaningful.contains("AXDecrement") {
            flags.append("adjustable")
        }
        if let frame, frame.width > 0, frame.height > 0 {
            if !frame.intersects(windowBounds.insetBy(dx: -2, dy: -2)) {
                flags.append("offscreen")
            } else if let toScreenshot = options.toScreenshot, role != "AXWindow" {
                let pixels = toScreenshot(frame)
                parts.append("@\(Int(pixels.midX.rounded())),\(Int(pixels.midY.rounded()))")
            }
        }
        if !flags.isEmpty {
            parts.append("(\(flags.joined(separator: ", ")))")
        }
        if (AXRoles.controls.contains(role) || !meaningful.isEmpty) && role != "AXWindow" {
            interactiveCount += 1
        }
        return (parts.joined(separator: " "), label, foldsChildText)
    }

    private func synthesizedLabel(children: [AXUIElement]) -> String {
        var pieces: [String] = []
        var stack = children.reversed().map { ($0, 0) }
        var budget = 24
        while let (element, depth) = stack.popLast(), budget > 0, pieces.count < 3 {
            budget -= 1
            let role = AX.role(element)
            if role == "AXStaticText" || AXRoles.textInputs.contains(role) {
                let text = (AX.string(element, kAXValueAttribute) ?? AX.string(element, kAXTitleAttribute) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    pieces.append(text)
                }
            } else if let title = AX.string(element, kAXTitleAttribute), !title.isEmpty, role != "AXGroup" {
                pieces.append(title)
            } else if let description = AX.string(element, kAXDescriptionAttribute), !description.isEmpty, role == "AXImage" {
                pieces.append(description)
            }
            if depth < 3 {
                for child in AX.elements(element, kAXChildrenAttribute).reversed() {
                    stack.append((child, depth + 1))
                }
            }
        }
        return pieces.joined(separator: " · ")
    }

    private func collectText(_ text: String) {
        let trimmed = stripInvisibleMarks(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, textChars < 200_000 else {
            return
        }
        if texts.last == trimmed {
            return
        }
        texts.append(trimmed)
        textChars += trimmed.count
    }
}

/// Keeps recent snapshots so element indexes stay bound to the observation they came from.
final class SnapshotStore {
    private var byState: [String: AXSnapshot] = [:]
    private var order: [String] = []
    private var latestByWindow: [CGWindowID: String] = [:]
    private let capacity = 24

    func store(_ snapshot: AXSnapshot) {
        byState[snapshot.stateId] = snapshot
        order.removeAll { $0 == snapshot.stateId }
        order.append(snapshot.stateId)
        latestByWindow[snapshot.windowId] = snapshot.stateId
        while order.count > capacity {
            let oldest = order.removeFirst()
            byState.removeValue(forKey: oldest)
        }
    }

    func snapshot(stateId: String?, windowId: CGWindowID) throws -> AXSnapshot {
        if let stateId {
            guard let snapshot = byState[stateId] else {
                throw HelperError("Unknown or expired state_id \(stateId). Use the state_id of the latest observation of this window.")
            }
            guard snapshot.windowId == windowId else {
                throw HelperError("state_id \(stateId) belongs to window \(snapshot.windowId), not window \(windowId).")
            }
            return snapshot
        }
        guard let latest = latestByWindow[windowId], let snapshot = byState[latest] else {
            throw HelperError("Window \(windowId) has not been observed yet, so its element indexes are unknown. Observe it first and use indexes from that observation.")
        }
        return snapshot
    }

    func element(index: Int, stateId: String?, windowId: CGWindowID) throws -> AXUIElement {
        let snapshot = try snapshot(stateId: stateId, windowId: windowId)
        guard let element = snapshot.element(at: index) else {
            throw HelperError("element_index \(index) is not in state \(snapshot.stateId) (0-\(max(0, snapshot.elements.count - 1))).")
        }
        if AX.role(element).isEmpty, AX.frame(element) == nil {
            throw HelperError("Element \(index) from state \(snapshot.stateId) no longer exists (the UI changed). Use the latest observation.")
        }
        return element
    }
}
