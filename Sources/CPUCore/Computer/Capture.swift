import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

public struct ScreenshotRecord {
    public let id: String
    public let windowId: CGWindowID
    /// Global (Quartz, top-left origin) position of the captured window in points.
    public let origin: CGPoint
    public let pointSize: CGSize
    public let pixelWidth: Int
    public let pixelHeight: Int

    var scaleX: CGFloat {
        return pointSize.width > 0 ? CGFloat(pixelWidth) / pointSize.width : 1
    }

    var scaleY: CGFloat {
        return pointSize.height > 0 ? CGFloat(pixelHeight) / pointSize.height : 1
    }

    func summary() -> [String: Any] {
        return [
            "id": id,
            "width": pixelWidth,
            "height": pixelHeight,
            "originX": roundedPoint(origin.x),
            "originY": roundedPoint(origin.y),
            "pointWidth": roundedPoint(pointSize.width),
            "pointHeight": roundedPoint(pointSize.height),
            "scaleX": (Double(scaleX) * 1000).rounded() / 1000,
            "scaleY": (Double(scaleY) * 1000).rounded() / 1000,
            "coordinateSpace": "screenshot_pixels"
        ]
    }

    func globalPoint(x: Double, y: Double) throws -> CGPoint {
        guard x >= 0, y >= 0, x <= Double(pixelWidth), y <= Double(pixelHeight) else {
            throw HelperError(
                "Coordinate (\(x), \(y)) is outside screenshot \(id) (\(pixelWidth)x\(pixelHeight) px). "
                + "Use pixel coordinates measured on that screenshot."
            )
        }
        return CGPoint(
            x: origin.x + CGFloat(x) / max(scaleX, 0.0001),
            y: origin.y + CGFloat(y) / max(scaleY, 0.0001)
        )
    }

    /// Maps a global rect (points) into this screenshot's pixel space.
    func pixelRect(_ rect: CGRect) -> CGRect {
        return CGRect(
            x: (rect.origin.x - origin.x) * scaleX,
            y: (rect.origin.y - origin.y) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}

public struct CapturedScreenshot {
    public let data: Data
    public let mimeType: String
    public let record: ScreenshotRecord
    /// The full-resolution capture (before downscaling), kept for on-device text recognition.
    let sourceImage: CGImage
}

final class ScreenshotStore {
    private var byId: [String: ScreenshotRecord] = [:]
    private var order: [String] = []
    private let capacity = 32

    func store(_ record: ScreenshotRecord) {
        byId[record.id] = record
        order.append(record.id)
        while order.count > capacity {
            byId.removeValue(forKey: order.removeFirst())
        }
    }

    func get(_ id: String) -> ScreenshotRecord? {
        return byId[id]
    }

    func latest(windowId: CGWindowID) -> ScreenshotRecord? {
        for id in order.reversed() {
            if let record = byId[id], record.windowId == windowId {
                return record
            }
        }
        return nil
    }
}

enum WindowCapture {
    /// Matches OpenClaw's 1200px history image limit, so replayed screenshots are not
    /// re-encoded on later turns (which changes their bytes and misses the prompt cache).
    static let maxDimension = 1200
    static let minScale = 0.1
    static let jpegQuality: CGFloat = 0.82

    private static var requestedScreenCapture = false

    /// `scale` (0.1...1) shrinks the screenshot below `maxDimension`; 0.5 halves both sides.
    /// The record keeps the output pixel size, so coordinates on it still map to points.
    static func capture(_ record: WindowRecord, format: String, scale: Double = 1) throws -> CapturedScreenshot {
        if !Permissions.screenCaptureGranted(), !requestedScreenCapture {
            // Shows the system prompt once and adds CPU to the Screen Recording list.
            requestedScreenCapture = true
            _ = CGRequestScreenCaptureAccess()
        }
        guard Permissions.screenCaptureGranted() else {
            throw HelperError(
                "Screen Recording permission is required for screenshots. Ask the user to enable CPU in "
                + "System Settings → Privacy & Security → Screen Recording "
                + "The accessibility outline still works without it."
            )
        }
        guard record.onScreen else {
            throw HelperError("Window \(record.id) is minimized, hidden, or on another Space, so it cannot be captured (Screen Recording permission is fine). Its accessibility outline and keyboard shortcuts still work; open it with show: true only if you must see it.")
        }
        var failures: [String] = []
        var captured: (image: CGImage, frame: CGRect)?
        // In-process ScreenCaptureKit avoids spawning screencapture (~150ms) on every step.
        if #available(macOS 14.0, *) {
            do {
                captured = try screenCaptureKitCapture(record)
            } catch {
                failures.append("ScreenCaptureKit: \(error)")
            }
        }
        if captured == nil {
            do {
                captured = try systemCapture(record)
            } catch {
                failures.append("screencapture: \(error)")
            }
        }
        guard let captured else {
            throw HelperError("Window screenshot failed. \(failures.joined(separator: "; "))")
        }
        let output = downscaled(captured.image, maxDimension: outputMaxDimension(for: captured.image, scale: scale))
            ?? captured.image
        let useJpeg = format.lowercased() != "png"
        let data = try encode(output, jpeg: useJpeg)
        let screenshot = ScreenshotRecord(
            id: "shot-\(record.id)-\(UUID().uuidString.prefix(8).lowercased())",
            windowId: record.id,
            origin: captured.frame.origin,
            pointSize: captured.frame.size,
            pixelWidth: output.width,
            pixelHeight: output.height
        )
        return CapturedScreenshot(data: data, mimeType: useJpeg ? "image/jpeg" : "image/png", record: screenshot, sourceImage: captured.image)
    }

    /// Frame for an image captured at native resolution: origin from the live window
    /// list (read after the capture), size from the pixels and the display scale.
    private static func frame(for record: WindowRecord, image: CGImage) -> CGRect {
        let bounds = WindowCatalog.currentBounds(id: record.id) ?? record.bounds
        let scale = displayScale(for: bounds)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if abs(size.width - bounds.width) <= 2, abs(size.height - bounds.height) <= 2 {
            return bounds
        }
        return CGRect(origin: bounds.origin, size: size)
    }

    private static func systemCapture(_ record: WindowRecord) throws -> (image: CGImage, frame: CGRect) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-shot-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(record.id), url.path]
        try process.run()
        let finished = waitUntil(timeout: 6, interval: 0.03) { !process.isRunning }
        if !finished {
            process.terminate()
            throw HelperError("timed out")
        }
        guard process.terminationStatus == 0 else {
            throw HelperError("exit status \(process.terminationStatus)")
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HelperError("no image produced")
        }
        return (image, frame(for: record, image: image))
    }

    @available(macOS 14.0, *)
    private static func screenCaptureKitCapture(_ record: WindowRecord) throws -> (image: CGImage, frame: CGRect) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(CGImage, CGRect), Error>?
        let task = Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == record.id }) else {
                    throw HelperError("window \(record.id) is not shareable")
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                let scale = displayScale(for: window.frame)
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                result = .success((image, window.frame))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            task.cancel()
            throw HelperError("timed out")
        }
        switch result {
        case .success(let value):
            return (value.0, value.1)
        case .failure(let error):
            throw error
        case .none:
            throw HelperError("no result")
        }
    }

    /// A 160px-wide grayscale thumbnail of the window, for telling whether an action changed
    /// anything. Nil without Screen Recording permission.
    static func fingerprint(_ record: WindowRecord) -> [UInt8]? {
        guard Permissions.screenCaptureGranted(), #available(macOS 14.0, *),
              let image = try? screenCaptureKitCapture(record).image else {
            return nil
        }
        let width = 160
        let height = max(1, Int(Double(image.height) * Double(width) / Double(max(1, image.width))))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Full-resolution grayscale pixels of the window around global `point`, for telling
    /// whether a click there changed anything: a caret or a highlight is enough to show.
    static func regionFingerprint(_ record: WindowRecord, around point: CGPoint, radius: CGFloat = 90) -> [UInt8]? {
        guard Permissions.screenCaptureGranted(), #available(macOS 14.0, *),
              let captured = try? screenCaptureKitCapture(record), captured.frame.width > 0, captured.frame.height > 0 else {
            return nil
        }
        let image = captured.image
        let scaleX = CGFloat(image.width) / captured.frame.width
        let scaleY = CGFloat(image.height) / captured.frame.height
        let region = CGRect(
            x: (point.x - captured.frame.minX - radius) * scaleX,
            y: (point.y - captured.frame.minY - radius) * scaleY,
            width: radius * 2 * scaleX,
            height: radius * 2 * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !region.isEmpty, let crop = image.cropping(to: region) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// True when two fingerprints differ in more than a couple of pixels (a caret blink or
    /// antialiasing noise stays below that).
    static func changed(_ before: [UInt8], _ after: [UInt8]) -> Bool {
        guard before.count == after.count else {
            return true
        }
        var differing = 0
        for index in before.indices where abs(Int(before[index]) - Int(after[index])) > 16 {
            differing += 1
            if differing >= 4 {
                return true
            }
        }
        return false
    }

    static func displayScale(for frame: CGRect) -> CGFloat {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return NSScreen.main?.backingScaleFactor ?? 2
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return NSScreen.main?.backingScaleFactor ?? 2
        }
        var best: CGDirectDisplayID?
        var bestArea: CGFloat = -1
        for display in displays {
            let overlap = CGDisplayBounds(display).intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        guard let display = best, let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else {
            return NSScreen.main?.backingScaleFactor ?? 2
        }
        let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        return scale > 0 ? scale : 1
    }

    private static func outputMaxDimension(for image: CGImage, scale: Double) -> Int {
        let longEdge = min(max(image.width, image.height), maxDimension)
        let clampedScale = scale.isFinite ? min(max(scale, minScale), 1) : 1
        return max(1, Int((Double(longEdge) * clampedScale).rounded()))
    }

    private static func downscaled(_ image: CGImage, maxDimension: Int) -> CGImage? {
        guard max(image.width, image.height) > maxDimension else {
            return nil
        }
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, jpeg: Bool) throws -> Data {
        let data = NSMutableData()
        let type = (jpeg ? "public.jpeg" : "public.png") as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw HelperError("Unable to create image encoder.")
        }
        let properties: CFDictionary? = jpeg
            ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, jpeg ? (flattened(image) ?? image) : image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw HelperError("Unable to encode screenshot.")
        }
        return data as Data
    }

    /// JPEG has no alpha; composite transparent window corners onto white.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else {
            return nil
        }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
