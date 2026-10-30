import AppKit
import CoreGraphics
import Foundation

public struct WindowRecord {
    public let app: String
    public let bundleId: String?
    public let id: CGWindowID
    public let pid: pid_t
    public var title: String
    public let bounds: CGRect
    public let onScreen: Bool
    /// Window-server level: 0 for ordinary windows and sheets, `WindowCatalog.modalLevel`
    /// for app-modal dialogs (save and open panels, alerts).
    public var layer = 0
    /// For a dialog, how it sits over the app's windows ("sheet on window 123").
    public var dialog: String?

    public func summary() -> [String: Any] {
        var value: [String: Any] = [
            "app": app,
            "id": Int(id),
            "pid": Int(pid),
            "bounds": [
                "x": roundedPoint(bounds.origin.x),
                "y": roundedPoint(bounds.origin.y),
                "width": roundedPoint(bounds.width),
                "height": roundedPoint(bounds.height)
            ]
        ]
        if !title.isEmpty {
            value["title"] = title
        }
        if let bundleId {
            value["bundleId"] = bundleId
        }
        if !onScreen {
            value["onScreen"] = false
        }
        return value
    }
}

enum WindowCatalog {
    /// System surfaces that are never useful targets and only add noise.
    private static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "WindowManager", "Control Center", "控制中心",
        "Notification Center", "通知中心", "Spotlight", "SystemUIServer", "TextInputMenuAgent",
        "Wallpaper", "墙纸", "loginwindow", "screencaptureui"
    ]

    /// Level of app-modal panels; they float above the app's windows and take all its input.
    static let modalLevel = Int(CGWindowLevelForKey(.modalPanelWindow))

    static func list(includeOffscreen: Bool = true) -> [WindowRecord] {
        let options: CGWindowListOption = includeOffscreen
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var appCache: [pid_t: NSRunningApplication?] = [:]
        var onScreen: [WindowRecord] = []
        var offScreen: [WindowRecord] = []
        for item in raw {
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 || layer == modalLevel,
                  let idNumber = item[kCGWindowNumber as String] as? NSNumber,
                  let owner = item[kCGWindowOwnerName as String] as? String, !owner.isEmpty,
                  !ignoredOwners.contains(owner) else {
                continue
            }
            let pid = pid_t((item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            guard pid > 0, pid != ownPid else {
                continue
            }
            if let alpha = item[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
                continue
            }
            var bounds = CGRect.zero
            if let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: boundsDictionary) ?? .zero
            }
            guard bounds.width >= 40, bounds.height >= 40 else {
                continue
            }
            let isOnScreen = (item[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let title = item[kCGWindowName as String] as? String ?? ""
            let runningApp: NSRunningApplication?
            if let cached = appCache[pid] {
                runningApp = cached
            } else {
                runningApp = NSRunningApplication(processIdentifier: pid)
                appCache[pid] = runningApp
            }
            if !isOnScreen {
                guard layer == 0 else {
                    continue
                }
                // Off-screen windows (minimized, hidden, other Spaces) are only useful for
                // regular apps and when they carry a title the model can recognize.
                guard runningApp?.activationPolicy == .regular, !title.isEmpty else {
                    continue
                }
            }
            var record = WindowRecord(
                app: runningApp?.localizedName ?? owner,
                bundleId: runningApp?.bundleIdentifier,
                id: CGWindowID(idNumber.uint32Value),
                pid: pid,
                title: title,
                bounds: bounds,
                onScreen: isOnScreen
            )
            record.layer = layer
            if layer == modalLevel {
                record.dialog = "modal dialog"
            }
            if isOnScreen {
                onScreen.append(record)
            } else {
                offScreen.append(record)
            }
        }
        return includeOffscreen ? onScreen + offScreen : onScreen
    }

    static func find(id: Int) -> WindowRecord? {
        return list().first(where: { Int($0.id) == id })
    }

    static func windows(forPid pid: pid_t) -> [WindowRecord] {
        return list().filter { $0.pid == pid }
    }

    struct Hit {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
        let owner: String
        let title: String
    }

    /// Front-most visible window under a global point, any layer (menus, panels, the Dock
    /// count as covering), optionally only `owner`'s. Skips fully transparent windows,
    /// `ignoring`'s own windows, and raised windows that cover almost a whole display: those
    /// are click-through overlays (e.g. ChatGPT's), which would block the user too if they
    /// took clicks.
    static func topWindow(at point: CGPoint, ignoring ignoredPid: pid_t, owner: pid_t? = nil) -> Hit? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        func isOverlay(_ bounds: CGRect, layer: Int) -> Bool {
            guard layer > 0 else {
                return false
            }
            let display = displayBounds(containing: CGPoint(x: bounds.midX, y: bounds.midY))
            let overlap = display.intersection(bounds)
            return overlap.width * overlap.height >= display.width * display.height * 0.8
        }
        for item in raw {
            let pid = pid_t((item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            guard pid > 0, pid != ignoredPid, owner == nil || pid == owner,
                  (item[kCGWindowOwnerName as String] as? String) != "Window Server",
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.contains(point),
                  !isOverlay(bounds, layer: layer),
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
                continue
            }
            return Hit(
                id: CGWindowID(id),
                pid: pid,
                layer: layer,
                bounds: bounds,
                owner: item[kCGWindowOwnerName as String] as? String ?? "",
                title: item[kCGWindowName as String] as? String ?? ""
            )
        }
        return nil
    }

    /// Bounds (global, top-left origin) of the display containing `point`, else the main one.
    static func displayBounds(containing point: CGPoint) -> CGRect {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &displays, &count)
        let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        return bounds.first(where: { $0.contains(point) }) ?? CGDisplayBounds(CGMainDisplayID())
    }

    /// Current bounds of one window, read after a capture to avoid stale geometry.
    static func currentBounds(id: CGWindowID) -> CGRect? {
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let item = raw.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let dictionary = item[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary)
    }
}

struct InstalledApp {
    let name: String
    let fileName: String
    public let bundleId: String?
    let path: String
    /// Localized and English display names plus the bundle file name, for matching.
    let names: [String]

    public func summary() -> [String: Any] {
        var value: [String: Any] = ["name": name, "path": path]
        if let bundleId {
            value["bundleId"] = bundleId
        }
        return value
    }
}

enum AppCatalog {
    private static var cachedInstalled: [InstalledApp] = []
    private static var cachedAt = Date.distantPast
    private static let lock = NSLock()

    static func installedApps() -> [InstalledApp] {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(cachedAt) < 300, !cachedInstalled.isEmpty {
            return cachedInstalled
        }
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications"
        ]
        for root in roots {
            for path in appBundles(in: root, depth: root == "/Applications" ? 2 : 1) {
                let resolved = (path as NSString).resolvingSymlinksInPath
                guard seen.insert(resolved).inserted else {
                    continue
                }
                let bundle = Bundle(path: path)
                let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let names = displayNames(bundle: bundle, path: path, fileName: fileName)
                apps.append(InstalledApp(
                    name: names.first ?? fileName,
                    fileName: fileName,
                    bundleId: bundle?.bundleIdentifier,
                    path: path,
                    names: names
                ))
            }
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedInstalled = apps
        cachedAt = Date()
        return apps
    }

    /// A CLI helper has no localizations of its own, so Foundation would report English
    /// names; read the bundle's localized InfoPlist for the user's languages instead.
    static func displayNames(bundle: Bundle?, path: String, fileName: String) -> [String] {
        var names: [String] = []
        func add(_ value: Any?) {
            guard let string = value as? String else {
                return
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !names.contains(trimmed) {
                names.append(trimmed)
            }
        }
        if let bundle {
            let resources = (path as NSString).appendingPathComponent("Contents/Resources")
            let preferred = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages)
            let loctable = NSDictionary(contentsOfFile: (resources as NSString).appendingPathComponent("InfoPlist.loctable")) as? [String: Any]
            for localization in preferred where localization != "en" && localization != "Base" {
                for key in localizationKeys(localization) {
                    if let table = loctable?[key] as? [String: Any] {
                        add(table["CFBundleDisplayName"])
                        add(table["CFBundleName"])
                    }
                    let strings = (resources as NSString).appendingPathComponent("\(key).lproj/InfoPlist.strings")
                    if let table = NSDictionary(contentsOfFile: strings) as? [String: Any] {
                        add(table["CFBundleDisplayName"])
                        add(table["CFBundleName"])
                    }
                }
            }
            add(bundle.infoDictionary?["CFBundleDisplayName"])
            add(bundle.infoDictionary?["CFBundleName"])
        }
        add(fileName)
        return names
    }

    private static func localizationKeys(_ localization: String) -> [String] {
        var keys = [localization]
        let underscored = localization.replacingOccurrences(of: "-", with: "_")
        let aliases: [String: [String]] = [
            "zh_CN": ["zh-Hans", "zh_Hans", "zh_CN"],
            "zh-Hans": ["zh_CN", "zh-Hans", "zh_Hans"],
            "zh_TW": ["zh-Hant", "zh_Hant", "zh_TW"],
            "zh-Hant": ["zh_TW", "zh-Hant", "zh_Hant", "zh_HK"],
            "zh_HK": ["zh-Hant", "zh_HK", "zh_TW"]
        ]
        keys.append(underscored)
        keys.append(contentsOf: aliases[localization] ?? [])
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func appBundles(in root: String, depth: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        var result: [String] = []
        for entry in entries where !entry.hasPrefix(".") {
            let path = (root as NSString).appendingPathComponent(entry)
            if entry.hasSuffix(".app") {
                result.append(path)
            } else if depth > 1, entry != "Utilities" {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    result.append(contentsOf: appBundles(in: path, depth: depth - 1))
                }
            }
        }
        return result
    }

    static func runningApps() -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    enum Target {
        case running(NSRunningApplication)
        case bundle(URL)
    }

    /// Resolves bundle ids, .app paths, English or localized names, and unique partial names.
    static func resolve(_ query: String) throws -> Target {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || expanded.hasSuffix(".app") {
            let url = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw HelperError("App bundle does not exist: \(expanded)")
            }
            if let running = runningApps().first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
                return .running(running)
            }
            return .bundle(url)
        }

        let needle = normalize(trimmed)
        if let running = runningApps().first(where: { app in
            app.bundleIdentifier?.lowercased() == trimmed.lowercased()
                || normalize(app.localizedName ?? "") == needle
                || normalize(app.bundleURL?.deletingPathExtension().lastPathComponent ?? "") == needle
        }) {
            return .running(running)
        }
        if trimmed.contains("."), !trimmed.contains(" "),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return .bundle(url)
        }

        let installed = installedApps()
        if let exact = installed.first(where: { app in app.names.contains(where: { normalize($0) == needle }) }) {
            return .bundle(URL(fileURLWithPath: exact.path))
        }
        let partial = installed.filter { app in app.names.contains(where: { normalize($0).contains(needle) }) }
        if partial.count == 1 {
            return .bundle(URL(fileURLWithPath: partial[0].path))
        }
        if partial.count > 1 {
            let names = partial.prefix(8).map { "\($0.name) (\($0.bundleId ?? $0.fileName))" }.joined(separator: ", ")
            throw HelperError("App name \"\(trimmed)\" is ambiguous: \(names). Pass the exact name or bundleId.")
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return .bundle(url)
        }
        throw HelperError("No installed app matches \"\(trimmed)\". Call list_apps to see installed apps and their bundleIds.")
    }

    private static func normalize(_ value: String) -> String {
        return value.lowercased().replacingOccurrences(of: " ", with: "")
    }

    static func launch(url: URL, activate: Bool) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        let semaphore = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            launched = app
            launchError = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw HelperError("Timed out waiting for \(url.lastPathComponent) to launch.")
        }
        if let launchError {
            throw HelperError("Unable to launch \(url.lastPathComponent): \(launchError.localizedDescription)")
        }
        guard let launched else {
            throw HelperError("Launch of \(url.lastPathComponent) returned no running application.")
        }
        return launched
    }
}
