import AppKit
import AVFoundation
import Foundation
import PDFKit
import WebKit

/// `cpu …` inside the code tool's scripts: the things that are common but easy to get wrong,
/// done reliably and reported with the facts that show they came out right. The CPU app and
/// cpuctl answer it when started with `--cpu-helper`.
public enum CPUHelper {
    static let usage = """
    cpu help                                   this list
    cpu tts <text-file | "text"> -o <out.m4a|.wav|.aiff|.mp3> [--voice NAME] [--rate WORDS_PER_MIN]
                                               speak a text (or a text file) into an audio file (Chinese
                                               gets a Mandarin voice); prints its length and size
    cpu media <file>...                        length, tracks, size, pixels or pages of audio, video,
                                               images and PDFs
    cpu page <url> [--text] [--main] [--png out.png] [--pdf out.pdf] [--js 'expr'] [--width 1000] [--wait 1.5]
                                               load a web page in the background (no login, not the
                                               user's browser): --text prints its text, --png/--pdf
                                               save the whole page as one long image or page, --js
                                               prints what a JavaScript expression returns (JSON);
                                               --main keeps only the article (title and body)
    cpu pdf <file> [--text] [--pages 1-3]      page count, and the text of the given pages
    """

    /// Runs one command; the process exits with the returned status.
    public static func main(_ arguments: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let command = arguments.first else {
            print(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        if rest.contains("--help") || rest.contains("-h") {
            // The lines of this command only.
            let lines = usage.components(separatedBy: "\n")
            if let start = lines.firstIndex(where: { $0.hasPrefix("cpu \(command) ") }) {
                let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("cpu ") }) ?? lines.count
                print(lines[start..<end].joined(separator: "\n"))
                return 0
            }
        }
        do {
            switch command {
            case "help", "--help", "-h":
                print(usage)
                return 0
            case "tts":
                return try tts(rest)
            case "media":
                return media(rest)
            case "page":
                return try page(rest)
            case "pdf":
                return try pdf(rest)
            default:
                fail("unknown command \"\(command)\"\n\(usage)")
                return 2
            }
        } catch {
            fail("\(error)")
            return 1
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("cpu: " + message + "\n").utf8))
    }

    /// Flags with values ("-o out.m4a"), switches ("--text") and the other words, in order.
    private struct Options {
        var values: [String: String] = [:]
        var switches: Set<String> = []
        var words: [String] = []

        init(_ arguments: [String], valued: Set<String>) {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if valued.contains(argument), index + 1 < arguments.count {
                    values[argument] = arguments[index + 1]
                    index += 2
                    continue
                }
                if argument.hasPrefix("-"), argument.count > 1 {
                    switches.insert(argument)
                } else {
                    words.append(argument)
                }
                index += 1
            }
        }
    }

    // MARK: - tts

    private static func tts(_ arguments: [String]) throws -> Int32 {
        let options = Options(arguments, valued: ["-o", "--voice", "--rate"])
        guard var input = options.words.first, let output = options.values["-o"] else {
            fail("usage: cpu tts <text-file | \"text\"> -o <out.m4a> [--voice NAME] [--rate N]")
            return 2
        }
        let text: String
        if FileManager.default.fileExists(atPath: input) {
            text = try String(contentsOfFile: input, encoding: .utf8)
        } else {
            // The text itself rather than a file.
            text = options.words.joined(separator: " ")
            input = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-tts-\(UUID().uuidString).txt").path
            try text.write(toFile: input, atomically: true, encoding: .utf8)
        }
        var voice = options.values["--voice"]
        if voice == nil, text.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            voice = mandarinVoice()
        }
        let out = URL(fileURLWithPath: output)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-tts-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var say = ["/usr/bin/say", "-o", temporary.path, "-f", input]
        if let voice {
            say += ["-v", voice]
        }
        if let rate = options.values["--rate"] {
            say += ["-r", rate]
        }
        try runTool(say)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        switch out.pathExtension.lowercased() {
        case "aiff", "aif":
            try FileManager.default.copyItem(at: temporary, to: out)
        case "wav":
            try runTool(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16", temporary.path, out.path])
        case "mp3":
            guard let ffmpeg = tool("ffmpeg") else {
                fail("mp3 needs ffmpeg, which this Mac does not have; use .m4a")
                return 1
            }
            try runTool([ffmpeg, "-loglevel", "error", "-y", "-i", temporary.path, "-codec:a", "libmp3lame", "-q:a", "3", out.path])
        default:
            try runTool(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", temporary.path, out.path])
        }
        print("wrote \(describe(out))\(voice.map { ", voice \($0)" } ?? "")")
        return 0
    }

    /// Tingting when installed, else the first Mandarin voice.
    private static func mandarinVoice() -> String? {
        let list = output(["/usr/bin/say", "-v", "?"])
        var first: String?
        for line in list.split(separator: "\n") {
            guard let range = line.range(of: " zh_CN ") else {
                continue
            }
            let name = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("Tingting") {
                return "Tingting"
            }
            first = first ?? name
        }
        return first
    }

    // MARK: - media

    private static func media(_ arguments: [String]) -> Int32 {
        guard !arguments.isEmpty else {
            fail("usage: cpu media <file>...")
            return 2
        }
        var status: Int32 = 0
        for path in arguments {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                fail("\(path): no such file")
                status = 1
                continue
            }
            var line = describe(url)
            let asset = AVURLAsset(url: url)
            let semaphore = DispatchSemaphore(value: 0)
            var tracks: [String] = []
            Task {
                if let loaded = try? await asset.load(.tracks) {
                    for track in loaded {
                        if track.mediaType == .video, let size = try? await track.load(.naturalSize), let rate = try? await track.load(.nominalFrameRate) {
                            tracks.append("video \(Int(size.width))x\(Int(size.height)) \(String(format: "%.0f", rate)) fps")
                        } else if track.mediaType == .audio, let formats = try? await track.load(.formatDescriptions), let format = formats.first,
                                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                            tracks.append("audio \(Int(basic.mSampleRate)) Hz, \(basic.mChannelsPerFrame) ch")
                        }
                    }
                    if url.pathExtension.lowercased() != "pdf", let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0,
                       !line.contains(" s)"), !line.contains(" s,") {
                        tracks.insert(clock(duration.seconds), at: 0)
                    }
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10)
            if !tracks.isEmpty {
                line += " — " + tracks.joined(separator: ", ")
            }
            print(line)
        }
        return status
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    // MARK: - pdf

    private static func pdf(_ arguments: [String]) throws -> Int32 {
        let options = Options(arguments, valued: ["--pages"])
        guard let path = options.words.first, let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            fail("usage: cpu pdf <file> [--text] [--pages 1-3] (the file must be a readable PDF)")
            return 2
        }
        print("\(path): \(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
        if options.switches.contains("--text") || options.values["--pages"] != nil {
            var range = 1...max(1, document.pageCount)
            if let spec = options.values["--pages"] {
                let bounds = spec.split(separator: "-").compactMap { Int($0) }
                if let low = bounds.first {
                    range = max(1, low)...min(document.pageCount, max(low, bounds.last ?? low))
                }
            }
            for number in range {
                guard let page = document.page(at: number - 1) else {
                    continue
                }
                print("\n--- page \(number) ---\n\(page.string ?? "")")
            }
        }
        return 0
    }

    // MARK: - page

    private static func page(_ arguments: [String]) throws -> Int32 {
        let options = Options(arguments, valued: ["--png", "--pdf", "--width", "--wait", "--js"])
        guard let address = options.words.first, let url = URL(string: address.contains("://") ? address : "https://" + address) else {
            fail("usage: cpu page <url> [--text] [--main] [--png out.png] [--pdf out.pdf]")
            return 2
        }
        let width = Double(options.values["--width"] ?? "") ?? 1000
        let settle = Double(options.values["--wait"] ?? "") ?? 1.5
        let loader = PageLoader(width: width)
        try loader.load(url, settle: settle)
        let main = options.switches.contains("--main")
        if let script = options.values["--js"] {
            let value = try loader.run(script)
            if let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(value.map { "\($0)" } ?? "null")
            }
        }
        if options.values["--png"] == nil && options.values["--pdf"] == nil && options.values["--js"] == nil || options.switches.contains("--text") {
            let text = try loader.text(main: main)
            print("\(loader.title.isEmpty ? url.absoluteString : loader.title) — \(text.count) characters\n")
            print(text)
        }
        // What the image or PDF holds, since the code cannot look at it.
        let holds = (try? loader.summary(main: main)) ?? ""
        if let png = options.values["--png"] {
            let out = URL(fileURLWithPath: png)
            try loader.image(main: main, to: out)
            print("wrote \(describe(out)) — \(holds)")
        }
        if let pdf = options.values["--pdf"] {
            let out = URL(fileURLWithPath: pdf)
            try loader.pdf(main: main).write(to: out)
            print("wrote \(describe(out)) — \(holds)")
        }
        return 0
    }

    // MARK: - Shared

    private static func describe(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return RecentFiles.describe(url, size: size)
    }

    private static func tool(_ name: String) -> String? {
        CodeRunner.searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runTool(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperError("\((arguments[0] as NSString).lastPathComponent) failed (exit \(process.terminationStatus)): \(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func output(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A web page loaded in an off-screen window of the helper process (never the user's browser
/// and never shown), for its text, or as one long image or PDF page.
private final class PageLoader: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let web: WKWebView
    private var finished = false
    private var failure: Error?
    private(set) var title = ""

    init(width: Double) {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let frame = CGRect(x: -20_000, y: -20_000, width: width, height: 1200)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        web = WKWebView(frame: CGRect(origin: .zero, size: frame.size))
        super.init()
        web.navigationDelegate = self
        window.contentView = web
        window.orderBack(nil)
    }

    func load(_ url: URL, settle: TimeInterval) throws {
        web.load(URLRequest(url: url, timeoutInterval: 30))
        spin(until: Date().addingTimeInterval(30)) { self.finished || self.failure != nil }
        if let failure {
            throw HelperError("could not load \(url.absoluteString): \(failure.localizedDescription)")
        }
        guard finished else {
            throw HelperError("\(url.absoluteString) did not finish loading in 30 s")
        }
        // Scroll through once so lazily loaded images and text arrive, then back to the top.
        _ = try? evaluate("""
        (async () => { const step = innerHeight; for (let y = 0; y < document.body.scrollHeight; y += step) { scrollTo(0, y); await new Promise(r => setTimeout(r, 60)); } scrollTo(0, 0); return 1 })()
        """)
        spin(until: Date().addingTimeInterval(settle)) { false }
        title = (try? evaluate("document.title") as? String) ?? ""
    }

    /// The article: the block with the most paragraphs, widened to take in the title when
    /// that adds little else; <article>/<main> when no block has paragraphs.
    private static let mainElement = """
    (() => { let body = null, best = 0;
      for (const c of document.querySelectorAll('div,section,article,main,td')) { let n = 0;
        for (const ch of c.children) if (ch.tagName === 'P' && (ch.innerText || '').trim()) n++;
        if (n > best) { best = n; body = c } }
      if (!body || best < 3) body = document.querySelector('article') || document.querySelector('main') || document.body;
      const h1 = document.querySelector('h1');
      if (h1 && !body.contains(h1)) { let a = body.parentElement; while (a && !a.contains(h1)) a = a.parentElement;
        if (a && (a.innerText || '').length < 1.6 * (body.innerText || '').length + 400) body = a }
      return body })()
    """

    /// "the article only (title "…", 4,993 characters, from "…" to "…")" or "the whole page".
    func summary(main: Bool) throws -> String {
        let text = try self.text(main: main)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let first = lines.first.map { compactText($0, limit: 30) } ?? ""
        let last = lines.last.map { compactText($0, limit: 30) } ?? ""
        let heading = (try? evaluate("(document.querySelector('h1') || {}).innerText || ''") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let what = main ? "the article only" : "the whole page"
        let titled = heading.isEmpty || !text.contains(heading) ? "" : "title \"\(compactText(heading, limit: 40))\", "
        return "\(what) (\(titled)\(text.count) characters, from \"\(first)\" to \"\(last)\"; floating bars and buttons left out)"
    }

    func run(_ script: String) throws -> Any? {
        try evaluate(script)
    }

    func text(main: Bool) throws -> String {
        let script = main ? "\(PageLoader.mainElement).innerText" : "document.body.innerText"
        return (try evaluate(script) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pdf(main: Bool) throws -> Data {
        // Floating bars, app banners and side buttons would sit on top of the content.
        _ = try? evaluate("""
        (() => { for (const e of document.querySelectorAll('body *')) { const p = getComputedStyle(e).position; if (p === 'fixed' || p === 'sticky') e.style.setProperty('display', 'none', 'important') } return 1 })()
        """)
        let configuration = WKPDFConfiguration()
        if main, let rect = try mainRect() {
            configuration.rect = rect
        }
        var result: Result<Data, Error>?
        web.createPDF(configuration: configuration) { result = $0 }
        spin(until: Date().addingTimeInterval(60)) { result != nil }
        guard let result else {
            throw HelperError("making the PDF took too long")
        }
        return try result.get()
    }

    /// The page (or its article) as one PNG, rendered from the PDF so any length works.
    func image(main: Bool, to url: URL) throws {
        let data = try pdf(main: main)
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
            throw HelperError("could not render the page")
        }
        let box = page.getBoxRect(.mediaBox)
        // Sharp on a Retina screen, but at most about 120 million pixels.
        let scale = min(2, sqrt(120_000_000 / max(1, box.width * box.height)))
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw HelperError("the image would be too large (\(width)x\(height))")
        }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw HelperError("could not write \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HelperError("could not write \(url.path)")
        }
    }

    private func mainRect() throws -> CGRect? {
        let script = "(() => { const r = \(PageLoader.mainElement).getBoundingClientRect(); return [r.left + scrollX, r.top + scrollY, r.width, r.height] })()"
        guard let values = try evaluate(script) as? [NSNumber], values.count == 4, values[2].doubleValue > 0, values[3].doubleValue > 0 else {
            return nil
        }
        return CGRect(x: values[0].doubleValue, y: values[1].doubleValue, width: values[2].doubleValue, height: values[3].doubleValue)
    }

    private func evaluate(_ script: String) throws -> Any? {
        var outcome: Result<Any?, Error>?
        if script.contains("async") {
            web.callAsyncJavaScript("return await \(script)", arguments: [:], in: nil, in: .page) { result in
                outcome = result.map { $0 as Any? }
            }
        } else {
            web.evaluateJavaScript(script) { value, error in
                outcome = error.map { .failure($0) } ?? .success(value)
            }
        }
        spin(until: Date().addingTimeInterval(20)) { outcome != nil }
        guard let outcome else {
            throw HelperError("the page did not answer")
        }
        return try outcome.get()
    }

    private func spin(until deadline: Date, _ done: () -> Bool) {
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error
    }
}
