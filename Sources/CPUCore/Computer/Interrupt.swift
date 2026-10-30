import AppKit
import Foundation

/// Stop signal for the running task. A physical Escape press (or the panel's stop
/// button) stops it; engine loops and the agent check `isStopped` between steps.
public enum Interrupts {
    static let stoppedMessage = "The user stopped the task (Escape). Do not perform further actions."

    private static let lock = NSLock()
    private static var stopped = false
    private static var running = false
    private static var monitor: Any?
    static var cursor: VirtualCursorOverlay?
    /// Called on the main queue when Escape stops a running task.
    public static var onStop: (() -> Void)?

    public static func begin() {
        lock.lock()
        stopped = false
        running = true
        lock.unlock()
        installMonitorIfPossible()
    }

    public static func end() {
        lock.lock()
        running = false
        lock.unlock()
        DispatchQueue.main.async {
            cursor?.hide()
        }
    }

    public static var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    public static var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public static func stop() {
        lock.lock()
        let wasRunning = running
        stopped = true
        lock.unlock()
        guard wasRunning else {
            return
        }
        helperLog(.info, "task stopped by user")
        DispatchQueue.main.async {
            cursor?.hide()
            onStop?()
        }
    }

    static func installMonitorIfPossible() {
        DispatchQueue.main.async {
            guard monitor == nil, Permissions.accessibilityGranted() else {
                return
            }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else {
                    return
                }
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventTag {
                    return
                }
                if isRunning {
                    stop()
                }
            }
            helperLog(.debug, "escape monitor installed=\(monitor != nil)")
        }
    }
}
