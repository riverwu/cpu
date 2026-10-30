import AppKit
import Foundation

enum ScreenGeometry {
    /// Quartz global coordinates have their origin at the top-left of the primary display.
    static func appKitPoint(fromQuartz point: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        return NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func appKitRect(fromQuartz rect: CGRect) -> NSRect {
        let origin = appKitPoint(fromQuartz: CGPoint(x: rect.minX, y: rect.maxY))
        return NSRect(origin: origin, size: rect.size)
    }

    static func screen(containing rect: CGRect?) -> NSScreen? {
        guard let rect else {
            return NSScreen.main ?? NSScreen.screens.first
        }
        let appKit = appKitRect(fromQuartz: rect)
        var best: NSScreen?
        var bestArea: CGFloat = -1
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(appKit)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? NSScreen.main ?? NSScreen.screens.first
    }
}

final class CursorView: NSView {
    /// Right half of the arrow in its own frame: tip (hotspot) at the origin, +y along the axis
    /// toward the tail, +x toward the arrow's right side. The left half is drawn as its mirror
    /// image, so both sides are symmetric by construction. Classic pointer proportions: 45° tip
    /// angle, wings swept back, tail centered on the axis.
    private static let arrowHalf: [CGPoint] = [
        CGPoint(x: 10.8, y: 26),  // wing tip
        CGPoint(x: 3, y: 22.7),   // notch where the wing meets the tail
        CGPoint(x: 3, y: 35.6),   // tail end
    ]
    /// Tilt of the arrow axis from vertical, toward the right. 30° keeps the familiar pointer
    /// pose with a nearly vertical left edge; the two sides stay symmetric about the axis at
    /// any tilt.
    private static let arrowTilt: CGFloat = .pi / 6

    private var pulseStartedAt: Date?

    override var isOpaque: Bool {
        false
    }

    func pulse() {
        pulseStartedAt = Date()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let bloom = NSColor(calibratedRed: 1, green: 0.47, blue: 0.09, alpha: 1)
        let glow = NSBezierPath(ovalIn: NSRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))
        NSGradient(colors: [
            bloom.withAlphaComponent(0.50),
            bloom.withAlphaComponent(0.14),
            bloom.withAlphaComponent(0)
        ])?.draw(in: glow, relativeCenterPosition: .zero)

        if let pulseStartedAt {
            let progress = min(1, max(0, Date().timeIntervalSince(pulseStartedAt) / 0.36))
            if progress < 1 {
                let radius = 12 + 18 * progress
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                bloom.withAlphaComponent(0.44 * (1 - progress)).setStroke()
                ring.lineWidth = 1.8
                ring.stroke()
            }
        }

        // Arrow axis (tip -> tail) and the arrow's right side, in this view's y-up coordinates.
        let axis = CGVector(dx: sin(CursorView.arrowTilt), dy: -cos(CursorView.arrowTilt))
        let side = CGVector(dx: cos(CursorView.arrowTilt), dy: sin(CursorView.arrowTilt))
        let rightHalf = CursorView.arrowHalf
        let leftHalf = rightHalf.reversed().map { CGPoint(x: -$0.x, y: $0.y) }
        let body = NSBezierPath()
        body.move(to: center)
        for point in rightHalf + leftHalf {
            body.line(to: NSPoint(
                x: center.x + point.x * side.dx + point.y * axis.dx,
                y: center.y + point.x * side.dy + point.y * axis.dy
            ))
        }
        body.close()

        // Shadow offset and gradient both run along the axis, so the shading stays symmetric too.
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: axis.dx * 2, height: axis.dy * 2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        NSGradient(colors: [
            NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.46, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.47, blue: 0.09, alpha: 1),
            NSColor(calibratedRed: 0.91, green: 0.29, blue: 0.05, alpha: 1)
        ])?.draw(in: body, angle: CursorView.arrowTilt * 180 / .pi - 90)
        NSColor.white.setStroke()
        body.lineWidth = 2.2
        body.lineJoinStyle = .round
        body.stroke()
    }
}

/// Click-through animated cursor that shows where the agent acts without moving the real pointer.
final class VirtualCursorOverlay {
    /// Centered on the hotspot; large enough for the arrow (~32pt below and ~23pt right of the
    /// hotspot), its stroke and drop shadow, and the 31pt click pulse ring without clipping.
    private let size = NSSize(width: 88, height: 88)
    private var panel: NSPanel?
    private var view: CursorView?
    private var animationTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var currentOrigin: NSPoint?

    func show(at point: CGPoint, above windowId: CGWindowID?, click: Bool = false) {
        DispatchQueue.main.async {
            self.animate(to: point, above: windowId, click: click)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.panel?.orderOut(nil)
            self.currentOrigin = nil
        }
    }

    private func ensurePanel() -> (NSPanel, CursorView) {
        if let panel, let view {
            return (panel, view)
        }
        let view = CursorView(frame: NSRect(origin: .zero, size: size))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary]
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setAccessibilityElement(false)
        self.panel = panel
        self.view = view
        return (panel, view)
    }

    private func animate(to quartzPoint: CGPoint, above windowId: CGWindowID?, click: Bool) {
        let (panel, view) = ensurePanel()
        let appKit = ScreenGeometry.appKitPoint(fromQuartz: quartzPoint)
        let target = NSPoint(x: appKit.x - size.width / 2, y: appKit.y - size.height / 2)
        let start = currentOrigin ?? NSPoint(x: target.x - 120, y: target.y - 90)
        currentOrigin = start
        panel.setFrameOrigin(start)
        if let windowId, windowExists(windowId) {
            // Stay directly above the target window: visible on it, but still behind
            // whatever the user has in front when the agent works in the background.
            panel.level = .normal
            panel.order(.above, relativeTo: Int(windowId))
        } else {
            panel.level = .floating
            panel.orderFrontRegardless()
        }
        if click {
            view.pulse()
        }
        let distance = hypot(target.x - start.x, target.y - start.y)
        let duration = max(0.16, min(0.6, TimeInterval(distance / 1300)))
        let dx = target.x - start.x
        let dy = target.y - start.y
        let length = max(1, hypot(dx, dy))
        let bend = min(100, max(20, length * 0.16))
        let midX: CGFloat = (start.x + target.x) / 2
        let midY: CGFloat = (start.y + target.y) / 2
        let control = NSPoint(x: midX - dy / length * bend, y: midY + dx / length * bend)
        let startedAt = Date()
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 90.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let raw: Double = min(1, Date().timeIntervalSince(startedAt) / duration)
            let origin = VirtualCursorOverlay.bezier(start: start, control: control, target: target, progress: raw)
            self.currentOrigin = origin
            panel.setFrameOrigin(origin)
            view.needsDisplay = true
            if raw >= 1 {
                timer.invalidate()
            }
        }
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.currentOrigin = nil
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    static func bezier(start: NSPoint, control: NSPoint, target: NSPoint, progress: Double) -> NSPoint {
        let eased: Double = progress * progress * (3 - 2 * progress)
        let t = CGFloat(eased)
        let inv: CGFloat = 1 - t
        let a: CGFloat = inv * inv
        let b: CGFloat = 2 * inv * t
        let c: CGFloat = t * t
        let x: CGFloat = a * start.x + b * control.x + c * target.x
        let y: CGFloat = a * start.y + b * control.y + c * target.y
        return NSPoint(x: x, y: y)
    }

    private func windowExists(_ windowId: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]] else {
            return false
        }
        return !info.isEmpty
    }
}
