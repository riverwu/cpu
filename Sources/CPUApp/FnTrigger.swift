import AppKit
import CPUCore

/// Double-tap Fn (🌐) to summon or close; hold Fn to talk while the panel is open.
///
/// Fn is a modifier, so Carbon hotkeys cannot bind it; this watches modifier changes with
/// global and local event monitors, which needs Accessibility permission (CPU requires it
/// anyway). The gesture rules live in `FnTapDetector`.
final class FnTrigger {
    var onDoubleTap: () -> Void = {}
    var onHoldStart: () -> Void = {}
    var onHoldEnd: () -> Void = {}
    /// Whether holding Fn should start push-to-talk at this moment.
    var holdEnabled: () -> Bool = { false }

    /// kVK_Function; some keyboards report the Globe key as 179.
    private static let fnKeyCodes: Set<UInt16> = [63, 179]

    private var detector = FnTapDetector()
    private var monitors: [Any] = []

    /// Installs the monitors once Accessibility is granted (it may be granted later).
    func start() {
        guard monitors.isEmpty else {
            return
        }
        guard AXIsProcessTrusted() else {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.start()
                }
            }
            return
        }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        // Keys other programs post are not the user's: they neither tap Fn nor make a chord.
        guard event.postingProcess == nil else {
            return
        }
        let input: FnTapDetector.Input
        if event.type == .flagsChanged, FnTrigger.fnKeyCodes.contains(event.keyCode) {
            input = event.modifierFlags.contains(.function) ? .fnDown : .fnUp
        } else {
            input = .otherKey
        }
        let now = ProcessInfo.processInfo.systemUptime
        emit(detector.handle(input, at: now, holdEnabled: holdEnabled()))
        if input == .fnDown {
            Timer.scheduledTimer(withTimeInterval: FnTapDetector.holdDelay, repeats: false) { [weak self] _ in
                guard let self else {
                    return
                }
                self.emit(self.detector.holdTimerFired(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func emit(_ gesture: FnTapDetector.Gesture?) {
        switch gesture {
        case .doubleTap:
            onDoubleTap()
        case .holdStart:
            onHoldStart()
        case .holdEnd:
            onHoldEnd()
        case nil:
            break
        }
    }
}

extension NSEvent {
    /// The other program that posted this event, or nil when it came from the keyboard
    /// (hardware events carry source pid 0) or from CPU itself.
    var postingProcess: pid_t? {
        guard let pid = cgEvent?.getIntegerValueField(.eventSourceUnixProcessID), pid != 0, pid != Int64(getpid()) else {
            return nil
        }
        return pid_t(pid)
    }
}
