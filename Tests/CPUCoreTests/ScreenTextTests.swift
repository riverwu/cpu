import AppKit
@testable import CPUCore
import Testing

struct ScreenTextTests {
    /// A 2x "Retina" capture with one chat line drawn at a known place.
    private static func retinaImage() -> CGImage {
        let width = 1600, height = 400
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // AppKit origin is bottom-left: y=250 puts the line in the upper half of the image.
        ("王宁：明天下午三点开会，记得带电脑" as NSString)
            .draw(at: NSPoint(x: 100, y: 250), withAttributes: [.font: NSFont.systemFont(ofSize: 40)])
        NSGraphicsContext.current = nil
        return context.makeImage()!
    }

    @Test func recognizesAtFullResolutionInScreenshotPixels() throws {
        // The screenshot sent to the model is half the capture's size.
        let items = ScreenText.recognize(Self.retinaImage(), outputSize: CGSize(width: 800, height: 200))
        let line = try #require(items.first { $0.text.contains("开会") })
        #expect(line.rect.minX > 40 && line.rect.minX < 60, "x is mapped into 800px output space")
        #expect(line.rect.midY < 100, "the line is in the upper half (top-left origin)")
    }

    @Test func substringPointLandsOnItsCharacters() throws {
        let items = ScreenText.recognize(Self.retinaImage(), outputSize: CGSize(width: 800, height: 200))
        let line = try #require(items.first { $0.text.contains("开会") })
        let name = try #require(line.point(of: "王宁"))
        let laptop = try #require(line.point(of: "电脑"))
        #expect(name.x < line.rect.midX && laptop.x > line.rect.midX)
        #expect(name.x > line.rect.minX && laptop.x < line.rect.maxX)
    }

    @Test func outlineIndexUsesSubstringPosition() throws {
        let items = ScreenText.recognize(Self.retinaImage(), outputSize: CGSize(width: 800, height: 200))
        let line = try #require(items.first { $0.text.contains("开会") })
        let window = WindowRecord(app: "微信", bundleId: nil, id: 1, pid: 1, title: "", bounds: .zero, onScreen: true)
        let observation = Observation(
            stateId: "s-test", window: window, outline: "[0] window \"微信\"", elementCount: 1, truncated: false,
            focused: nil, selectedText: nil, note: nil, screenshot: nil, screenshotError: nil,
            screenText: ScreenText.lines(items), textItems: items, sparse: true
        )
        // A target inside a long line resolves to those characters, not the line's middle…
        guard case .point(let x, _, _) = try OutlineIndex(observation: observation).resolve(target: "王宁", element: nil) else {
            Issue.record("expected a point")
            return
        }
        let name = try #require(line.point(of: "王宁"))
        #expect(Int(x) == Int(name.x.rounded()))
        #expect(x < Double(line.rect.midX) - 100)
        // …while an index parsed from text alone can only use the line center.
        let parsed = OutlineIndex(outline: "", screenText: ScreenText.lines(items))
        guard case .point(let centerX, _, _) = try parsed.resolve(target: "王宁", element: nil) else {
            Issue.record("expected a point")
            return
        }
        #expect(Int(centerX) == Int(line.rect.midX.rounded()))
    }

    @Test func warmUpRuns() {
        ScreenText.warmUp()
    }
}
