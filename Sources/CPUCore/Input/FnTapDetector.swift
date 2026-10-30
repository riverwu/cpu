import Foundation

/// Gesture logic for the Fn (🌐) key, separate from event monitoring so it can be tested:
/// two quick taps → `doubleTap`; a press held past `holdDelay` (when allowed) → `holdStart`,
/// released → `holdEnd`. A press that overlaps another key is a chord and counts as neither.
public struct FnTapDetector {
    public enum Input {
        case fnDown
        case fnUp
        /// Any other key or modifier.
        case otherKey
    }

    public enum Gesture: Equatable {
        case doubleTap
        case holdStart
        case holdEnd
    }

    public static let tapMaxDuration: TimeInterval = 0.3
    public static let doubleTapGap: TimeInterval = 0.45
    public static let holdDelay: TimeInterval = 0.35

    private var downAt: TimeInterval?
    private var chorded = false
    private var holdArmed = false
    private var holding = false
    private var lastTapUpAt: TimeInterval?

    public init() {}

    /// Feeds one key event; `holdEnabled` says whether a long press should talk right now.
    public mutating func handle(_ input: Input, at time: TimeInterval, holdEnabled: Bool) -> Gesture? {
        switch input {
        case .otherKey:
            guard downAt != nil else {
                return nil
            }
            chorded = true
            holdArmed = false
            if holding {
                holding = false
                return .holdEnd
            }
            return nil
        case .fnDown:
            downAt = time
            chorded = false
            holdArmed = holdEnabled
            return nil
        case .fnUp:
            guard let pressedAt = downAt else {
                return nil
            }
            downAt = nil
            holdArmed = false
            if holding {
                holding = false
                lastTapUpAt = nil
                return .holdEnd
            }
            guard !chorded, time - pressedAt <= FnTapDetector.tapMaxDuration else {
                lastTapUpAt = nil
                return nil
            }
            if let previous = lastTapUpAt, pressedAt - previous <= FnTapDetector.doubleTapGap {
                lastTapUpAt = nil
                return .doubleTap
            }
            lastTapUpAt = time
            return nil
        }
    }

    /// Call `holdDelay` after an `fnDown` (from a timer) to start push-to-talk.
    public mutating func holdTimerFired(at time: TimeInterval) -> Gesture? {
        guard holdArmed, !holding, !chorded, let downAt, time - downAt >= FnTapDetector.holdDelay - 0.01 else {
            return nil
        }
        holding = true
        return .holdStart
    }
}
