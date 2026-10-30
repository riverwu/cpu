import AppKit
import AVFoundation
import CPUCore
import Foundation

/// Developer CLI: exercises the engine and the agent from a terminal. Permissions belong to
/// the terminal app here (Accessibility, Screen Recording), not to CPU.app.
let usage = """
usage:
  cpuctl windows                     list on-screen windows
  cpuctl observe [window-id] [--shot] print the outline of a window (default: front window)
  cpuctl run [--no-context] "<request>"  run the agent on a request ("a ++ b": b is a follow-up); --no-context shares no window titles
  cpuctl click <window-id> <x> <y>   click at window points (resolving covers), then restore moved windows
  cpuctl steps <window-id> '<json>'  observe, then run [{"method":…, …params}] in one process
  cpuctl act <window-id> '<json>'    observe, then run an act call ([{"do":…}]) as the model would; nothing goes to the model
  cpuctl speech-bench <audio>…       feed audio in real time to every speech engine, compare
  cpuctl code <language> '<code>' [--timeout N] [--files '<json>'] [--yes]   run code as the code tool does
  cpuctl read <window-id|url>         print the full text of a window, or of a web page opened in the background
  cpuctl read-file <path>             print the text of a file (text, rtf/doc/docx/odt/html, PDF)
  cpuctl say "<text>"                speak with the reply voice, report time to first audio
  cpuctl demo-test <name>            record a scripted Calculator demonstration (real clicks) and learn it as a skill
  cpuctl config                      print the effective configuration (no secrets)
"""

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--cpu-helper" {
    exit(CPUHelper.main(Array(CommandLine.arguments.dropFirst(2))))
}
setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
let wantsShot = arguments.contains("--shot")
arguments.removeAll { $0 == "--shot" }
guard let command = arguments.first else {
    print(usage)
    exit(2)
}

/// The terminal app hosting this CLI (first GUI app up the parent-process chain); never
/// treat it as the target window.
func hostAppPid() -> pid_t? {
    var pid = getppid()
    while pid > 1 {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return pid
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

let terminalPid = hostAppPid()

func runAsync(_ body: @escaping () async -> Int32) -> Never {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task.detached {
        let code = await body()
        exit(code)
    }
    application.run()
    exit(0)
}

let engineQueue = DispatchQueue(label: "cpuctl.engine")

func onEngine<T>(_ body: @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        engineQueue.async {
            continuation.resume(returning: body())
        }
    }
}

switch command {
case "code":
    // cpuctl code <language> '<code>' [--timeout N] [--files '<json>'] [--yes]
    guard arguments.count >= 3, let language = CodeRunner.Language(rawValue: arguments[1]) else {
        print(usage)
        exit(2)
    }
    var timeout: TimeInterval = 60
    var files: [String: String] = [:]
    var approved = false
    var index = 3
    while index < arguments.count {
        switch arguments[index] {
        case "--timeout" where index + 1 < arguments.count:
            timeout = Double(arguments[index + 1]) ?? 60
            index += 1
        case "--files" where index + 1 < arguments.count:
            let object = try? JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any]
            files = (object ?? [:]).compactMapValues { $0 as? String }
            index += 1
        case "--yes":
            approved = true
        default:
            break
        }
        index += 1
    }
    let code = arguments[2]
    switch CodeSafety.check(language: language.rawValue, code: code + "\n" + files.values.joined(separator: "\n")) {
    case .refuse(let reason):
        print("refused: \(reason)")
        exit(1)
    case .confirm(let reasons) where !approved:
        print("needs confirmation (\(reasons.joined(separator: ", "))); pass --yes to run it")
        exit(1)
    default:
        break
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let runner = CodeRunner(task: "cpuctl-" + formatter.string(from: Date()))
    do {
        let result = try runner.run(CodeRunner.Request(language: language, code: code, files: files, timeout: timeout))
        print(result.report)
        for image in result.images {
            print("(image for the model: \(ImagePreview.jpeg(image)?.note ?? "no preview"))")
        }
        print("(workspace: \(runner.workspace.path))")
    } catch {
        print("error: \(error)")
        exit(1)
    }
    exit(0)
case "windows":
    let computer = Computer()
    for window in computer.windows() where window.onScreen {
        print("\(window.id)\t\(window.app)\t\(window.title)\t\(Int(window.bounds.width))x\(Int(window.bounds.height))\t\(window.dialog ?? "")")
    }
case "observe":
    runAsync {
        let computer = Computer()
        let started = Date()
        let window: WindowRecord? = await onEngine {
            if arguments.count > 1, let id = Int(arguments[1]) {
                return computer.window(id: id)
            }
            return computer.frontWindow(excluding: terminalPid)
        }
        guard let window else {
            print("no window")
            return 1
        }
        let observation = await onEngine { computer.observe(window, screenshot: wantsShot ? .always : .never) }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let shown = observation.window
        print("window \(shown.id) · \(shown.app) · \"\(shown.title)\"\(shown.dialog.map { " · \($0)" } ?? "") · state \(observation.stateId) · \(observation.elementCount) elements · \(elapsed)ms")
        if let focused = observation.focused {
            print("focused: \(focused)")
        }
        if let note = observation.note {
            print("note: \(note)")
        }
        if let shot = observation.screenshot {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(shot.record.id).jpg")
            try? shot.data.write(to: path)
            print("screenshot: \(shot.record.pixelWidth)x\(shot.record.pixelHeight) → \(path.path)")
        } else if let error = observation.screenshotError {
            print("screenshot error: \(error)")
        }
        print(observation.outline)
        return 0
    }
case "click":
    guard arguments.count == 4, let id = Int(arguments[1]), let x = Double(arguments[2]), let y = Double(arguments[3]) else {
        print(usage)
        exit(2)
    }
    runAsync {
        let computer = Computer()
        let result: Result<[String: Any], Error> = await onEngine {
            Result { try computer.handle(method: "click", params: ["window": ["id": id], "x": x, "y": y, "coordinate_space": "window_points"]) }
        }
        switch result {
        case .success(let value):
            print("ok: \(value["delivery"] ?? "-") · \(value["note"] ?? "")")
        case .failure(let error):
            print("error: \(error)")
        }
        await onEngine { Thread.sleep(forTimeInterval: 0.5); computer.restoreDisplacedWindows() }
        return 0
    }
case "read":
    guard arguments.count == 2 else {
        print(usage)
        exit(2)
    }
    let source = arguments[1]
    runAsync {
        let computer = Computer()
        let started = Date()
        let output: String = await onEngine {
            do {
                let window: WindowRecord
                if let id = Int(source) {
                    guard let found = computer.window(id: id) else {
                        return "no window \(id)"
                    }
                    window = found
                } else {
                    guard let opened = try computer.open(url: source, activate: false) else {
                        return "no window shows \(source)"
                    }
                    window = opened
                }
                let read = try computer.readText(window)
                let notes = read.notes.map { "note: \($0)\n" }.joined()
                return "\(read.method) · \(read.text.count) chars · \(Int(Date().timeIntervalSince(started) * 1000))ms\(read.document.map { " · file \($0)" } ?? "")\n\(notes)\(read.text)"
            } catch {
                return "error: \(error)"
            }
        }
        print(output)
        return 0
    }
case "read-file":
    guard arguments.count == 2 else {
        print(usage)
        exit(2)
    }
    let started = Date()
    do {
        let file = try DocumentText.read(URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath))
        print("\(file.kind) · \(file.text.count) chars · \(Int(Date().timeIntervalSince(started) * 1000))ms\n\(file.text)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
case "steps":
    guard arguments.count == 3, let id = Int(arguments[1]),
          let steps = (try? JSONSerialization.jsonObject(with: Data(arguments[2].utf8))) as? [[String: Any]] else {
        print(usage)
        exit(2)
    }
    runAsync {
        let computer = Computer()
        await onEngine {
            guard let window = computer.window(id: id) else {
                print("no window \(id)")
                return
            }
            let observation = computer.observe(window, screenshot: .never)
            print("observed \(observation.stateId) of window \(observation.window.id): \(observation.elementCount) elements")
            let batch = steps.map { step -> (method: String, params: [String: Any], label: String) in
                var params = step
                let method = params.removeValue(forKey: "method") as? String ?? ""
                params["window"] = ["id": id]
                return (method, params, method)
            }
            let result = computer.runBatch(window: window, steps: batch)
            result.lines.forEach { print($0) }
            print("next window: \(result.window.map { "\($0.id) \($0.title)" } ?? "-")")
            computer.restoreDisplacedWindows()
        }
        return 0
    }
case "act":
    guard arguments.count == 3, let id = Int(arguments[1]),
          let actions = (try? JSONSerialization.jsonObject(with: Data(arguments[2].utf8))) as? [[String: Any]] else {
        print(usage)
        exit(2)
    }
    runAsync {
        print(await Agent().actLocally(window: id, actions: actions))
        return 0
    }
case "run":
    guard arguments.count > 1 else {
        print(usage)
        exit(2)
    }
    // --no-context: the model sees app names only, no window titles or front-window content.
    let privateRun = arguments.contains("--no-context")
    let request = arguments.dropFirst().filter { $0 != "--no-context" }.joined(separator: " ")
    runAsync {
        let agent = Agent()
        if let terminalPid {
            agent.excludedPids = [terminalPid]
        }
        if privateRun {
            agent.includeContext = false
        }
        var inThinking = false
        agent.onEvent = { event in
            switch event {
            case .thinking(let text):
                if !inThinking {
                    inThinking = true
                    print("\u{1B}[2m", terminator: "")
                }
                print(text, terminator: "")
            case .text(let text):
                print(text, terminator: "")
            default:
                if inThinking {
                    inThinking = false
                    print("\u{1B}[0m")
                }
                switch event {
                case .status(let text):
                    print("… \(text)")
                case .step(let text):
                    print("▸ \(text)")
                case .metrics(let text):
                    print("\u{1B}[2m  \(text)\u{1B}[0m")
                case .goal(let title):
                    print("◆ \(title)")
                case .context(let summary):
                    print("📎 \(summary.app) · \(summary.title)\(summary.selectedText.map { " · 选中 \($0.count) 字" } ?? "")\(summary.selectedItems.isEmpty ? "" : " · 选中 \(summary.selectedItems.count) 项")")
                case .finished(let text):
                    print("\n✓ \(text)")
                case .failed(let text):
                    print("\n✗ \(text)")
                default:
                    break
                }
            }
        }
        agent.askUser = { request in
            switch request {
            case .question(let question, let options):
                print("\n? \(question)\(options.isEmpty ? "" : " [\(options.joined(separator: " / "))]")\n> ", terminator: "")
                return readLine().map { .text($0) }
            case .confirm(let action, let details):
                print("\n? 确认：\(action)\n\(details)\n[y = 确认 / n = 取消 / 其他 = 修改] > ", terminator: "")
                guard let line = readLine() else {
                    return nil
                }
                return line == "y" ? .confirmed : line == "n" ? .cancelled : .text(line)
            case .handOver(let instruction):
                print("\n✋ \(instruction)\n[回车 = 完成] > ", terminator: "")
                return readLine().map { $0.isEmpty ? .done : .text($0) }
            case .edits(let summary, let edits):
                print("\n✎ \(summary)")
                for (index, edit) in edits.enumerated() {
                    print("  \(index + 1). \(edit.original)\n     → \(edit.replacement)\(edit.reason.isEmpty ? "" : "（\(edit.reason)）")")
                }
                print("[回车 = 全部应用 / 1,3 = 只应用这几条 / n = 不改 / 其他 = 意见] > ", terminator: "")
                guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
                    return nil
                }
                if line.isEmpty || line == "all" {
                    return .accepted(Array(1...edits.count))
                }
                if line == "n" {
                    return .cancelled
                }
                let numbers = line.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "，" }).compactMap { Int($0) }
                return numbers.isEmpty ? .text(line) : .accepted(numbers)
            }
        }
        let started = Date()
        // CPU_TEST_INTERJECT="2.5|改成乘以 8": say something mid-task, as holding Fn would.
        if let spec = ProcessInfo.processInfo.environment["CPU_TEST_INTERJECT"],
           let bar = spec.firstIndex(of: "|"), let delay = Double(spec[..<bar]) {
            let words = String(spec[spec.index(after: bar)...])
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                print("\n🗣 \(words)")
                agent.interject(words)
            }
        }
        // CPU_TEST_STOP=3: press Escape that many seconds into the first part.
        if let delay = ProcessInfo.processInfo.environment["CPU_TEST_STOP"].flatMap(Double.init) {
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                print("\n⎋ stop")
                Interrupts.stop()
            }
        }
        // CPU_TEST_ATTACH="/path/a.txt:/path/b.pdf": files as if dragged onto the card.
        if let paths = ProcessInfo.processInfo.environment["CPU_TEST_ATTACH"] {
            agent.attach(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        agent.prepare()
        // "first ++ follow-up ++ …": later parts continue the same task.
        let parts = request.components(separatedBy: " ++ ")
        for (index, part) in parts.enumerated() {
            if index > 0 {
                print("\n↳ \(part)")
            }
            if index > 0, part == "撤销" {
                print("  (canUndo: \(agent.canUndo))")
                await agent.undo()
                continue
            }
            await agent.run(part, followUp: index > 0)
        }
        print(String(format: "total %.1fs · log %@", Date().timeIntervalSince(started), agent.lastLogPath ?? "-"))
        return 0
    }
case "speech-bench":
    let files = Array(arguments.dropFirst())
    runAsync {
        let config = Config.load()
        var engines: [(String, () async -> Transcriber?)] = [
            ("apple-dictation", { AppleDictationTranscriber(locale: Locale(identifier: config.locale)) })
        ]
        if #available(macOS 26.0, *) {
            engines.append(("apple-analyzer", { await AppleAnalyzerTranscriber.make(locale: Locale(identifier: config.locale)) }))
        }
        engines.append(("doubao", { DoubaoCredentials.load().map { _ in DoubaoTranscriber.make() } ?? nil }))
        for path in files {
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
                print("cannot read \(path)")
                continue
            }
            var chunks: [AVAudioPCMBuffer] = []
            while file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600) {
                try? file.read(into: buffer, frameCount: 1_600)
                chunks.append(buffer)
            }
            print(String(format: "== %@ (%.1fs)", (path as NSString).lastPathComponent, Double(file.length) / file.processingFormat.sampleRate))
            for (name, make) in engines {
                guard let engine = await make() else {
                    print("  \(name): unavailable")
                    continue
                }
                let started = Date()
                var firstPartial: Double?
                var lastPartial = ""
                var endpoints: [String] = []
                engine.onPartial = { text in
                    lastPartial = text
                    if firstPartial == nil {
                        firstPartial = Date().timeIntervalSince(started)
                    }
                }
                engine.onEndpoint = {
                    let verdict = Endpointing.endpointEnds(lastPartial) ? "ends" : "waits"
                    endpoints.append(String(format: "%.2fs \"%@\" → %@", Date().timeIntervalSince(started), lastPartial, verdict))
                }
                do {
                    try await engine.start(format: file.processingFormat)
                } catch {
                    print("  \(name): \(error)")
                    continue
                }
                // Real time, as from a microphone.
                for chunk in chunks {
                    engine.append(chunk)
                    try? await Task.sleep(nanoseconds: UInt64(Double(chunk.frameLength) / chunk.format.sampleRate * 1e9))
                }
                let spoken = Date()
                // A second of silence, as a microphone keeps sending after the speaker stops.
                if let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600) {
                    silence.frameLength = 1_600
                    for _ in 0..<Int(file.processingFormat.sampleRate / 1_600) {
                        engine.append(silence)
                        try? await Task.sleep(nanoseconds: UInt64(1_600 / file.processingFormat.sampleRate * 1e9))
                    }
                }
                let text = await engine.finish()
                print(String(format: "  %-16@ first partial %.2fs · final %.2fs after speech · %@", name, firstPartial ?? -1, Date().timeIntervalSince(spoken), text))
                if !endpoints.isEmpty {
                    print("  \(name) endpoints: \(endpoints.joined(separator: " · ")) (speech ended at \(String(format: "%.2fs", spoken.timeIntervalSince(started))))")
                }
            }
        }
        return 0
    }
case "say":
    let text = arguments.dropFirst().joined(separator: " ")
    runAsync {
        let speaker = Speaker(config: Config.load())
        let started = Date()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                speaker.speak(text) { continuation.resume() }
            }
        }
        print(String(format: "%@ · first audio %dms · done in %.1fs", speaker.engineName, speaker.lastFirstAudioMs ?? -1, Date().timeIntervalSince(started)))
        return 0
    }
case "demo-test":
    let name = arguments.count > 1 ? arguments[1] : "七乘八"
    runAsync {
        let agent = Agent()
        await MainActor.run {
            agent.startDemonstration { steps in
                if let last = steps.last {
                    print("  ● \(last.words)")
                }
            }
        }
        // Stand-in for the user: real (HID) clicks on Calculator's buttons, by label.
        let computer = Computer()
        let clicked: String = await onEngine {
            guard let window = computer.windows().first(where: { $0.bundleId == "com.apple.calculator" && $0.onScreen }) else {
                return "open Calculator first"
            }
            let observation = computer.observe(window, screenshot: .never)
            var done: [String] = []
            for label in ["全部清除", "7", "乘", "8", "等于"] {
                let pattern = "] button \"\(label)\""
                guard let line = observation.outline.split(separator: "\n").first(where: { $0.contains(pattern) }),
                      let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"),
                      let index = Int(line[line.index(after: open)..<close]) else {
                    continue
                }
                _ = try? computer.handle(method: "click", params: ["window": ["id": Int(window.id)], "element_index": index, "state_id": observation.stateId, "delivery": "foreground"])
                Thread.sleep(forTimeInterval: 0.25)
                done.append(label)
            }
            computer.restoreDisplacedWindows()
            return done.joined(separator: " ")
        }
        print("scripted clicks: \(clicked)")
        let steps = await agent.stopDemonstration()
        print("recorded \(steps.count) steps")
        guard let skill = await agent.learnSkill(name: name, steps: steps) else {
            print("learning failed")
            return 1
        }
        print("summary: \(skill.summary)\nprocedure:\n\(skill.procedure)")
        return 0
    }
case "config":
    let config = Config.load()
    print("endpoint: \(config.baseURL)\nmodel: \(config.model)\neffort: \(config.effort ?? "default")\nvision: \(config.vision) screenshots: \(config.screenshots)\nkey: \(config.resolvedAPIKey() == nil ? "MISSING (\(config.apiKeyEnv))" : "found (\(config.apiKey != nil ? "config file" : config.apiKeyEnv))")\nconfig file: \(Config.fileURL.path)")
default:
    print(usage)
    exit(2)
}
