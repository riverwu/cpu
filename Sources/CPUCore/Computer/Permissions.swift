import AppKit
import ApplicationServices
import CoreGraphics

/// macOS privacy permissions. The helper inherits the TCC identity of the app that
/// launched it (CPU.app, or the terminal in CLI mode), so prompts and System Settings entries name that app.
enum Permissions {
    static let accessibilityPaneUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenCapturePaneUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    static func screenCaptureGranted() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    static func status() -> [String: Any] {
        let accessibility = accessibilityGranted()
        let screenCapture = screenCaptureGranted()
        var missing: [String] = []
        if !accessibility {
            missing.append("accessibility")
        }
        if !screenCapture {
            missing.append("screenCapture")
        }
        return [
            "accessibility": accessibility,
            "screenCapture": screenCapture,
            "missing": missing
        ]
    }

    /// Triggers the system prompts for missing permissions and opens the matching
    /// System Settings pane, so the host app shows up in the list ready to toggle.
    static func request(openSettings: Bool) -> [String: Any] {
        var opened: [String] = []
        if !accessibilityGranted(prompt: true), openSettings {
            open(accessibilityPaneUrl)
            opened.append("accessibility")
        }
        if !screenCaptureGranted() {
            // Registers the app in the Screen Recording list; the prompt only appears once.
            _ = CGRequestScreenCaptureAccess()
            if openSettings {
                open(screenCapturePaneUrl)
                opened.append("screenCapture")
            }
        }
        var result = status()
        result["openedSettings"] = opened
        return result
    }

    static func requireAccessibility(for action: String) throws {
        guard accessibilityGranted() else {
            throw HelperError(
                "Accessibility permission is required to \(action). "
                + "Ask the user to enable CPU in System Settings → Privacy & Security → Accessibility, then retry."
            )
        }
    }

    private static func open(_ url: String) {
        guard let target = URL(string: url) else {
            return
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(target)
        }
    }
}
