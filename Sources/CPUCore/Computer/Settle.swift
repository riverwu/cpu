import ApplicationServices
import Foundation

/// Waits for an app's UI to settle after an action by listening to its accessibility
/// notifications, instead of sleeping a fixed time. Returns as soon as the app has been
/// quiet for `quiet` seconds (after at least `minimum`), or after `maximum`.
final class SettleWaiter {
    private static let notifications = [
        kAXFocusedUIElementChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification,
        kAXCreatedNotification, kAXLayoutChangedNotification, kAXWindowCreatedNotification,
        kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXSheetCreatedNotification,
        kAXMenuOpenedNotification, kAXMenuClosedNotification, "AXLoadComplete"
    ]

    private var observer: AXObserver?
    private let app: AXUIElement
    private let runLoop = CFRunLoopGetCurrent()
    private(set) var lastEvent = Date()
    private(set) var eventCount = 0

    /// Starts listening before the action runs so no notification is missed.
    init?(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else {
                return
            }
            let waiter = Unmanaged<SettleWaiter>.fromOpaque(refcon).takeUnretainedValue()
            waiter.lastEvent = Date()
            waiter.eventCount += 1
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            return nil
        }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in SettleWaiter.notifications {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(created), .defaultMode)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            for name in SettleWaiter.notifications {
                AXObserverRemoveNotification(observer, app, name as CFString)
            }
        }
    }

    /// Pumps this thread's run loop so observer callbacks fire while waiting.
    @discardableResult
    func wait(minimum: TimeInterval = 0.12, quiet: TimeInterval = 0.18, maximum: TimeInterval = 2.0) -> TimeInterval {
        let started = Date()
        lastEvent = started
        while !Interrupts.isStopped {
            CFRunLoopRunInMode(.defaultMode, 0.03, false)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= maximum {
                break
            }
            if elapsed >= minimum, Date().timeIntervalSince(lastEvent) >= quiet {
                break
            }
        }
        return Date().timeIntervalSince(started)
    }
}
