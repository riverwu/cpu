import CoreGraphics
import Foundation
import Vision

/// On-device OCR for windows whose accessibility tree is too thin to act on (custom-drawn
/// UIs such as WeChat or games). Gives the model clickable text positions instead of
/// making it estimate coordinates from pixels.
enum ScreenText {
    /// One recognized line. Positions are in screenshot (output) pixels, top-left origin.
    final class Item {
        let text: String
        let rect: CGRect
        private let candidate: VNRecognizedText
        private let outputSize: CGSize

        init(text: String, rect: CGRect, candidate: VNRecognizedText, outputSize: CGSize) {
            self.text = text
            self.rect = rect
            self.candidate = candidate
            self.outputSize = outputSize
        }

        /// Center of `fragment` within the line, so a click lands on those characters rather
        /// than the middle of a long line. Nil when Vision cannot box the fragment.
        func point(of fragment: String) -> CGPoint? {
            let source = candidate.string
            guard let range = source.range(of: fragment, options: [.caseInsensitive, .widthInsensitive]),
                  let box = try? candidate.boundingBox(for: range)?.boundingBox else {
                return nil
            }
            return CGPoint(x: box.midX * outputSize.width, y: (1 - box.midY) * outputSize.height)
        }
    }

    /// Recognizes `image` (the full-resolution capture: small text survives, and Vision's
    /// cost barely depends on input size) and maps boxes into `outputSize` pixels.
    static func recognize(_ image: CGImage, outputSize: CGSize, languages: [String] = ["zh-Hans", "en-US"]) -> [Item] {
        let request = VNRecognizeTextRequest()
        // The fast recognizer does not support Chinese.
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            helperLog(.warn, "text recognition failed: \(error)")
            return []
        }
        let items = (request.results ?? []).compactMap { observation -> Item? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            let box = observation.boundingBox
            let rect = CGRect(
                x: box.minX * outputSize.width,
                y: (1 - box.maxY) * outputSize.height,
                width: box.width * outputSize.width,
                height: box.height * outputSize.height
            )
            return Item(text: text, rect: rect, candidate: candidate, outputSize: outputSize)
        }
        // Reading order: rows top to bottom (within half a line), then left to right.
        return items.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > min(lhs.rect.height, rhs.rect.height) / 2 {
                return lhs.rect.midY < rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    /// Loads the recognition models ahead of time. The first request in a process pays for
    /// it (0.7s warm, measured up to 13s cold from disk), which would otherwise land on the
    /// first step that meets a custom-drawn app.
    static func warmUp() {
        let size = 64
        guard let context = CGContext(
            data: nil, width: size * 4, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size * 4, height: size))
        guard let image = context.makeImage() else {
            return
        }
        let started = Date()
        _ = recognize(image, outputSize: CGSize(width: size * 4, height: size))
        helperLog(.debug, "text recognition warmed up in \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    /// Outline-style lines: `text "Send" @412,88`.
    static func lines(_ items: [Item], limit: Int = 200) -> String {
        var lines = items.prefix(limit).map { item in
            "text \"\(compactText(item.text, limit: 80))\" @\(Int(item.rect.midX.rounded())),\(Int(item.rect.midY.rounded()))"
        }
        if items.count > limit {
            lines.append("… \(items.count - limit) more text items")
        }
        return lines.joined(separator: "\n")
    }
}
