import CPUCore
import Testing

struct FnTapDetectorTests {
    /// Plays (input, time) pairs; returns the gestures in order.
    private func play(_ steps: [(FnTapDetector.Input, Double)], holdEnabled: Bool = false, holdTimers: [Double] = []) -> [FnTapDetector.Gesture] {
        var detector = FnTapDetector()
        var gestures: [FnTapDetector.Gesture] = []
        var timers = holdTimers
        for (input, time) in steps {
            while let next = timers.first, next <= time {
                timers.removeFirst()
                if let gesture = detector.holdTimerFired(at: next) { gestures.append(gesture) }
            }
            if let gesture = detector.handle(input, at: time, holdEnabled: holdEnabled) { gestures.append(gesture) }
        }
        return gestures
    }

    @Test func twoQuickTapsAreADoubleTap() {
        #expect(play([(.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4)]) == [.doubleTap])
    }

    @Test func tapsTooFarApartAreNot() {
        #expect(play([(.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.8), (.fnUp, 0.9)]).isEmpty)
    }

    @Test func slowPressIsNotATap() {
        #expect(play([(.fnDown, 0), (.fnUp, 0.5), (.fnDown, 0.6), (.fnUp, 0.7)]).isEmpty)
    }

    @Test func fnShortcutIsNotATap() {
        // Fn+Delete, then a tap: only one clean tap, no double.
        #expect(play([(.fnDown, 0), (.otherKey, 0.05), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4)]).isEmpty)
    }

    @Test func tripleTapFiresOnce() {
        #expect(play([(.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.25), (.fnUp, 0.35), (.fnDown, 0.5), (.fnUp, 0.6)]) == [.doubleTap])
    }

    @Test func holdTalksWhenEnabled() {
        #expect(play([(.fnDown, 0), (.fnUp, 1.2)], holdEnabled: true, holdTimers: [0.35]) == [.holdStart, .holdEnd])
    }

    @Test func holdDoesNothingWhenDisabled() {
        #expect(play([(.fnDown, 0), (.fnUp, 1.2)], holdEnabled: false, holdTimers: [0.35]).isEmpty)
    }

    @Test func quickTapDoesNotStartHold() {
        #expect(play([(.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4)], holdEnabled: true, holdTimers: [0.35, 0.65]) == [.doubleTap])
    }

    @Test func otherKeyDuringHoldEndsIt() {
        #expect(play([(.fnDown, 0), (.otherKey, 0.8), (.fnUp, 1.0)], holdEnabled: true, holdTimers: [0.35]) == [.holdStart, .holdEnd])
    }
}
