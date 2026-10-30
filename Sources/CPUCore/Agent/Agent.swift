import AppKit
import Foundation

public enum AgentEvent {
    /// Short state line ("思考中…").
    case status(String)
    case thinking(String)
    case text(String)
    /// The task card's title, rewritten from the request.
    case goal(String)
    /// What CPU sees when summoned: the user's front window and selection.
    case context(ContextSummary)
    /// An action about to run, in plain words.
    case step(String)
    /// More about the step just announced, shown when the steps are opened (the code it runs).
    case detail(String)
    /// A page or file the turn worked with (again when its use or title changes).
    case resource(SessionResource)
    /// Timing/token line for one model call.
    case metrics(String)
    case finished(String)
    case failed(String)
}

/// The context capsule: what "this" refers to and what will be shared with the model.
public struct ContextSummary {
    public let app: String
    public let title: String
    public let selectedText: String?
    public let selectedItems: [String]
}

/// Moments where the task needs the user.
public enum UserRequest {
    case question(String, options: [String])
    /// An outward or irreversible action, with the exact content, awaiting approval.
    case confirm(action: String, details: String)
    /// A step only the user can do (log in, scan, enter a code).
    case handOver(String)
    /// Suggested changes to the user's text; they pick which to apply.
    case edits(summary: String, edits: [ProposedEdit])
}

/// One suggested change: replace `original` (verbatim from the text) with `replacement`.
public struct ProposedEdit {
    public let original: String
    public let replacement: String
    public let reason: String

    public init(original: String, replacement: String, reason: String) {
        self.original = original
        self.replacement = replacement
        self.reason = reason
    }
}

public enum UserReply {
    case text(String)
    case confirmed
    case cancelled
    case done
    /// The suggested edits the user chose, numbered from 1.
    case accepted([Int])
}

/// Runs a task: model ⇄ tools until the model answers without a tool call. A task can take
/// follow-ups (`run(_:followUp:)`) until the user closes it (`endSession`).
public final class Agent {
    public let config: Config
    /// Called from background threads.
    public var onEvent: (AgentEvent) -> Void = { _ in }
    /// Answers questions, confirmations and hand-overs; nil means no answer.
    public var askUser: (UserRequest) async -> UserReply? = { _ in nil }
    /// Apps never treated as the user's "current window" (the CLI's own terminal).
    public var excludedPids: Set<pid_t> = []
    /// Everything the user said in this session, for checks that depend on what they asked.
    private var sessionWords = ""
    /// False when the user removed the context capsule: the front window is not shared.
    public var includeContext = true
    /// The window that shows the latest result, for the card's "open" button.
    public private(set) var resultWindow: WindowRecord?

    private let computer = Computer()
    private let engineQueue = DispatchQueue(label: "cpu.engine", qos: .userInitiated)
    private let apiKey: Task<String?, Never>
    /// What this Mac offers code (interpreters, tools, voices), found once at startup.
    private let codeEnvironment = Task.detached(priority: .utility) { CodeRunner.environmentFacts() }
    /// The task's workspace (code, saved texts), made when first needed.
    private var runner: CodeRunner?
    /// The user allowed copying to the clipboard in this session.
    private var clipboardAllowed = false
    /// A long selection already saved for the model: its text and where.
    private var savedSelection: (text: String, path: String)?
    /// Text taken out of rich files (PDF, Word…), saved for code: file and date → path.
    private var extractedTexts: [String: String] = [:]
    /// Pages and files this turn worked with, as last reported: location → (use, title).
    private var notedResources: [String: (use: SessionResource.Use, title: String)] = [:]
    /// Code results carrying image previews: (message, tool_result block). The model needs a
    /// preview for one step only; then it is dropped like an old screenshot.
    private var previewRefs: [(message: Int, block: Int)] = []
    private var client: AnthropicClient?
    private var prefetch: (task: Task<Observation?, Never>, at: Date)?

    // Per-run state.
    private var messages: [JSONObject] = []
    private var observationRefs: [ObservationRef] = []
    private var current: WindowRecord?
    /// An app just opened that shows no window: an act without a window goes to it (through
    /// its menus) instead of to the window CPU worked in before.
    private var windowless: (pid: pid_t, app: String, bundleId: String?)?
    private var latest: [CGWindowID: (stateId: String, outline: String, fingerprint: String)] = [:]
    private var indexes: [String: (window: CGWindowID, index: OutlineIndex)] = [:]
    /// Apps whose hints and menu shortcuts were already given to the model in this task.
    private var briefedPids = Set<pid_t>()
    /// Scenario guides already given in this session.
    private var givenGuides = Set<String>()
    /// Changes of this task that the text journal cannot restore (clicks, keys), in plain
    /// words, for 撤销 to hand to the model.
    private var changedSteps: [String] = []
    /// Text fields the engine can restore exactly (its undo journal), as of the last batch.
    private var journaledTexts = 0
    /// Calls of this turn that moved the task forward, for replaying the same request later.
    private var recording: [JSONObject] = []
    /// False once the turn did something a replay must not repeat blindly.
    private var recordable = true
    private var indexOrder: [String] = []
    private var callCounts: [String: Int] = [:]
    private var stalledSteps = 0
    /// Edits the user accepted, checked against the document before the task may finish.
    private var editCheck: (window: WindowRecord, edits: [(number: Int, edit: ProposedEdit)], attempts: Int)?
    private var recentSteps: [String] = []
    private var log: RunLog?
    /// Trajectory file of the latest run.
    public private(set) var lastLogPath: String?
    /// Files the user dragged onto the card, given to the model with the next request.
    private var attachments: [URL] = []
    /// What the user said while the task was running, not yet given to the model.
    private var notes: [String] = []
    private let notesLock = NSLock()

    private struct ObservationRef {
        let message: Int
        let block: Int
        /// True when `block` is a tool_result whose inner content holds the observation.
        let nested: Bool
        let label: String
    }

    private struct ToolOutput {
        var content: [JSONObject]
        var isError = false
        var observationLabel: String?
        /// False when the call failed or left the screen unchanged.
        var progressed = true
        /// The app the call worked in, for replays.
        var app: WindowRecord?
        /// Where the call's time went (ms), for the run log: actions, wait, settle, open,
        /// read, observe and the observation's own parts.
        var timing: [(String, Int)] = []
    }

    private struct Stopped: Error {}

    public init(config: Config = .load()) {
        self.config = config
        let config = config
        apiKey = Task.detached(priority: .userInitiated) { config.resolvedAPIKey() }
        if config.screenshotMode != .never {
            Computer.warmUpTextRecognition()
        }
    }

    // MARK: - Engine bridge

    /// Milliseconds since `start`.
    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// An observation's cost, for ToolOutput.timing.
    private static func observeTiming(_ total: Int, _ observation: Observation) -> [(String, Int)] {
        [("observe", total)] + ["ax", "screenshot", "ocr"].compactMap { key in observation.timing[key].map { (key, $0) } }
    }

    private func engine<T>(_ body: @escaping (Computer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            engineQueue.async { [computer] in
                do {
                    continuation.resume(returning: try body(computer))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func ensureClient() async -> AnthropicClient? {
        if let client {
            return client
        }
        guard let key = await apiKey.value else {
            return nil
        }
        let created = AnthropicClient(config: config, apiKey: key)
        client = created
        return created
    }

    /// Call when the user starts speaking/typing: warms the connection and observes their
    /// current window in parallel, so the first model call can start right away. Reports what
    /// it sees as the context capsule.
    public func prepare() {
        let excluded = excludedPids
        let mode = config.screenshotMode
        includeContext = true
        prefetch = (Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                return nil
            }
            await self.ensureClient()?.warmUp()
            let observation = try? await self.engine { computer -> Observation? in
                guard let window = computer.frontWindow(excluding: excluded.first) else {
                    return nil
                }
                return computer.observe(window, screenshot: mode, maxNodes: 250)
            }
            if let observation {
                self.onEvent(.context(Agent.summary(of: observation)))
            }
            return observation
        }, Date())
    }

    /// Ends the task: the next `run` starts fresh.
    public func endSession() {
        messages = []
        observationRefs = []
        latest = [:]
        indexes = [:]
        indexOrder = []
        current = nil
        resultWindow = nil
        briefedPids = []
        givenGuides = []
        attachments = []
        changedSteps = []
        journaledTexts = 0
        sessionWords = ""
        editCheck = nil
        runner?.stopAll()
        runner = nil
        clipboardAllowed = false
        savedSelection = nil
        extractedTexts = [:]
        previewRefs = []
        engineQueue.async { [computer] in
            computer.forgetUndo()
        }
        _ = takeNotes()
    }

    /// Files dragged onto the card: part of the next request ("把这个文件发给…").
    public func attach(_ urls: [URL]) {
        attachments += urls.filter { url in !attachments.contains(url) }
    }

    public func detach(_ url: URL) {
        attachments.removeAll { $0 == url }
    }

    /// The attachments as the model reads them; consumed by the request they go with.
    private func takeAttachments() -> JSONObject? {
        guard !attachments.isEmpty else {
            return nil
        }
        let lines = attachments.map { url -> String in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let kind = values?.isDirectory == true ? "folder" : ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
            return "- \(url.path) (\(kind))"
        }
        attachments = []
        return Agent.text("The user attached these files to the request (dragged onto the card); \"this file\" means them. Take a file's text with read_file; show or edit it in its app with open; enter a path in a file dialog with ⌘⇧G:\n" + lines.joined(separator: "\n"))
    }

    /// Something the user said while the task runs; the model reads it at its next step.
    public func interject(_ text: String) {
        sessionWords += "\n" + text
        notesLock.lock()
        notes.append(text)
        notesLock.unlock()
    }

    private func takeNotes() -> [String] {
        notesLock.lock()
        defer { notesLock.unlock() }
        let taken = notes
        notes = []
        return taken
    }

    /// Brings the result window to the front for the user (the card's "open" button).
    public func reveal(_ window: WindowRecord) {
        engineQueue.async { [computer] in
            computer.bringToFront(window)
        }
    }

    // MARK: - Run

    /// Runs a new task, or with `followUp` continues the current one (the card is still open).
    @discardableResult
    public func run(_ request: String, followUp: Bool = false) async -> String {
        Interrupts.begin()
        defer {
            Interrupts.end()
        }
        let continuing = followUp && !messages.isEmpty
        if !continuing {
            // Files dropped before the first request belong to it.
            let dropped = attachments
            endSession()
            attachments = dropped
        }
        sessionWords += "\n" + request
        notedResources = [:]
        callCounts = [:]
        stalledSteps = 0
        recentSteps = []
        recording = []
        recordable = true
        let log = RunLog(request: continuing ? "（跟进）\(request)" : request, config: config)
        self.log = log
        lastLogPath = log.url.path
        let started = Date()
        func end(_ reply: String, failed: Bool = false) -> String {
            resultWindow = current
            if !failed, !continuing, !Interrupts.isStopped {
                saveTrajectory(for: request)
            }
            // Put back windows moved out of the way (on the engine queue, which owns AX work).
            let computer = self.computer
            engineQueue.async {
                computer.restoreDisplacedWindows()
            }
            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            log.write("\n## result (\(totalMs)ms)\n\n\(reply)")
            log.finish(totalMs: totalMs, outcome: Interrupts.isStopped ? "stopped" : (failed ? "failed" : "done"))
            onEvent(failed ? .failed(reply) : .finished(reply))
            return reply
        }
        do {
            if !continuing, config.fastPaths, let reply = try await fastPath(request) {
                return end(reply)
            }
            guard let client = await ensureClient() else {
                return end("没有找到模型 API Key：请设置环境变量 \(config.apiKeyEnv)，或在 \(Config.fileURL.path) 中填写 apiKey。", failed: true)
            }
            if !continuing {
                startGoal(request, client: client)
            }
            onEvent(.status("思考中…"))
            if continuing {
                try await continueConversation(request)
            } else {
                try await startConversation(request)
            }
            if !continuing, let trajectory = TaskStore.shared.trajectory(for: request),
               let calls = trajectory["calls"] as? [JSONObject], !calls.isEmpty {
                try await replay(calls, trajectory: trajectory, request: request)
            }
            if let opening = messages.last?["content"] as? [JSONObject] {
                log.toolResult(step: 0, name: continuing ? "follow-up context" : "initial context", content: opening, isError: false)
            }
            for step in 1...config.maxSteps {
                if Interrupts.isStopped {
                    throw Stopped()
                }
                let response = try await client.send(system: Prompt.system, tools: Prompt.tools, messages: messages) { [weak self] delta in
                    switch delta {
                    case .thinking(let text):
                        self?.onEvent(.thinking(text))
                    case .text(let text):
                        self?.onEvent(.text(text))
                    case .toolStart:
                        break
                    case .retry(let reason):
                        self?.onEvent(.status("模型响应慢，正在重试…"))
                        log.write("\n(step \(step): retrying model request — \(reason))")
                    }
                }
                log.response(step: step, response)
                onEvent(.metrics(String(
                    format: "step %d · first token %dms · %.1fs · in %d (cached %d) · out %d",
                    step, response.firstTokenMs, Double(response.totalMs) / 1000,
                    response.inputTokens, response.cacheReadTokens, response.outputTokens
                )))
                if Interrupts.isStopped {
                    throw Stopped()
                }
                messages.append(["role": "assistant", "content": response.content.map(Agent.sanitized)])
                let uses = response.toolUses
                if uses.isEmpty {
                    // Said while the model was answering: carry on with it instead of stopping.
                    let pending = takeNotes()
                    if !pending.isEmpty {
                        messages.append(["role": "user", "content": [Agent.text("The user adds: \(pending.joined(separator: "\n"))")]])
                        log.section("step \(step) · user adds", pending.joined(separator: "\n"))
                        onEvent(.status("思考中…"))
                        continue
                    }
                    var text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch await checkEdits() {
                    case .retry(let message):
                        messages.append(["role": "user", "content": [Agent.text(message)]])
                        log.section("step \(step) · edit check", message)
                        onEvent(.status("核对修改…"))
                        continue
                    case .unresolved(let note):
                        log.section("step \(step) · edit check", note)
                        text += "\n\n" + note
                    case .passed:
                        break
                    }
                    helperLog(.info, "done in \(step) steps, \(Int(Date().timeIntervalSince(started) * 1000))ms")
                    return end(text.isEmpty ? "完成。" : text)
                }
                var results: [JSONObject] = []
                var refs: [(block: Int, label: String)] = []
                var hints: [String] = []
                var progressed = false
                for use in uses {
                    let started = Date()
                    var output = await execute(use)
                    let elapsed = Agent.ms(since: started)
                    noteForReplay(use, output: output)
                    if let repeated = noteRepeat(use) {
                        output.content.append(Agent.text(repeated))
                    }
                    if ["act", "open"].contains(use["name"] as? String ?? ""), output.progressed {
                        // The screen changed: calling something again now is not a loop.
                        callCounts = [:]
                    }
                    progressed = progressed || output.progressed
                    log.toolResult(step: step, name: use["name"] as? String ?? "?", content: output.content, isError: output.isError, elapsedMs: elapsed, timing: output.timing)
                    var result: JSONObject = [
                        "type": "tool_result",
                        "tool_use_id": use["id"] as? String ?? "",
                        "content": output.content
                    ]
                    if output.isError {
                        result["is_error"] = true
                    }
                    results.append(result)
                    if let label = output.observationLabel {
                        refs.append((results.count - 1, label))
                    }
                    if Interrupts.isStopped {
                        throw Stopped()
                    }
                }
                stalledSteps = progressed ? 0 : stalledSteps + 1
                if stalledSteps >= 3 {
                    hints.append("The last \(stalledSteps) steps changed nothing on screen. Stop repeating that approach: try a different route (keyboard shortcut, menu, search), or if you cannot see or reach what you need, stop and tell the user what blocks you.")
                }
                let remaining = config.maxSteps - step
                if remaining == 5 {
                    hints.append("Only 5 steps left. Finish the essential part now, or stop and tell the user what blocks you.")
                } else if remaining == 1 {
                    hints.append("This is your last step. Reply to the user now without calling a tool: say what was done and what is left or blocking.")
                }
                if !hints.isEmpty {
                    let hint = hints.joined(separator: "\n")
                    results.append(Agent.text("[CPU] \(hint)"))
                    log.section("step \(step) · hint", hint)
                }
                for note in takeNotes() {
                    results.append(Agent.text("[The user, while you work] \(note)"))
                    log.section("step \(step) · user adds", note)
                }
                for ref in previewRefs where ref.message < messages.count {
                    dropImages(ObservationRef(message: ref.message, block: ref.block, nested: true, label: "preview"))
                }
                previewRefs = results.indices.compactMap { index in
                    let inner = results[index]["content"] as? [JSONObject] ?? []
                    return inner.contains { $0["type"] as? String == "image" } && results[index]["type"] as? String == "tool_result" ? (messages.count, index) : nil
                }
                messages.append(["role": "user", "content": results])
                for ref in refs {
                    observationRefs.append(ObservationRef(message: messages.count - 1, block: ref.block, nested: true, label: ref.label))
                }
                elideOldObservations()
                onEvent(.status("思考中…"))
            }
            let last = recentSteps.suffix(3).joined(separator: "；")
            return end("已达到步数上限（\(config.maxSteps) 步），任务未完成。最后在做：\(last.isEmpty ? "—" : last)。完整记录：\(log.url.path)", failed: true)
        } catch is Stopped {
            closeInterruptedStep()
            return end("已停止。")
        } catch {
            closeInterruptedStep()
            if Interrupts.isStopped {
                return end("已停止。")
            }
            return end("出错了：\(error)\n完整记录：\(log.url.path)", failed: true)
        }
    }

    private enum EditVerdict {
        case passed
        /// Some accepted edits are not in the document: the model gets another go.
        case retry(String)
        /// Still not there after that: the user is told.
        case unresolved(String)
    }

    /// Reads the document and checks that every accepted edit is in it.
    private func checkEdits() async -> EditVerdict {
        guard let check = editCheck else {
            return .passed
        }
        let window = check.window
        guard let read = try? await engine({ try $0.readText(window) }) else {
            log?.section("edit check", "could not read the document to check the edits")
            editCheck = nil
            return .passed
        }
        let outcome = EditCheck.verify(check.edits, in: read.text)
        log?.section("edit check", "applied \(outcome.applied) · missing \(outcome.missing) · unclear \(outcome.unclear)")
        guard !outcome.missing.isEmpty else {
            editCheck = nil
            return .passed
        }
        let numbers = outcome.missing.map(String.init).joined(separator: ", ")
        if check.attempts >= 1 {
            editCheck = nil
            return .unresolved("（核对：第 \(numbers) 处修改在文档里没有找到，原文还在。）")
        }
        editCheck?.attempts += 1
        let originals = check.edits.filter { outcome.missing.contains($0.number) }
            .map { "#\($0.number): \"\(compactText($0.edit.original, limit: 80))\" → \"\(compactText($0.edit.replacement, limit: 80))\"" }
            .joined(separator: "\n")
        return .retry(
            "[CPU check] Reading the document shows \(outcome.applied.count) of \(check.edits.count) accepted edits in place, "
                + "but these still have their original text and are not applied:\n\(originals)\n"
                + "Apply them now (check each one before moving on), then finish."
        )
    }

    /// A stop or error mid-step leaves the history open: tool calls without results (which
    /// the API rejects on the next request), or results the model never answered. Close it
    /// so a follow-up starts a clean user turn.
    private func closeInterruptedStep() {
        if Interrupts.isStopped {
            runner?.stopAll()
        }
        guard let last = messages.last else {
            return
        }
        if last["role"] as? String == "assistant" {
            let calls = (last["content"] as? [JSONObject] ?? []).filter { $0["type"] as? String == "tool_use" }
            guard !calls.isEmpty else {
                // A finished answer: nothing is open.
                return
            }
            messages.append(["role": "user", "content": calls.map { call -> JSONObject in
                [
                    "type": "tool_result",
                    "tool_use_id": call["id"] as? String ?? "",
                    "content": [Agent.text("Not done: the task was interrupted.")],
                    "is_error": true
                ]
            }])
        }
        let reason = Interrupts.isStopped ? "The user stopped the task here." : "The task ended here with an error."
        messages.append(["role": "assistant", "content": [Agent.text("(\(reason))")]])
    }

    // MARK: - Learning by demonstration

    private var recorder: DemonstrationRecorder?

    /// Starts watching the user do a task ("看我做一遍"); `onChange` gets the steps so far on
    /// the main queue. Call on the main thread.
    public func startDemonstration(onChange: @escaping ([DemoStep]) -> Void) {
        let recorder = DemonstrationRecorder()
        recorder.onChange = onChange
        recorder.start()
        self.recorder = recorder
    }

    public func stopDemonstration() async -> [DemoStep] {
        guard let recorder else {
            return []
        }
        self.recorder = nil
        return await recorder.stop()
    }

    /// Turns a demonstration into a skill: the model writes a reusable procedure with
    /// placeholders, and when every step is labeled the steps are also kept for exact replay,
    /// so saying the skill's name redoes it without the model.
    public func learnSkill(name: String, steps: [DemoStep]) async -> Skill? {
        let recorded = steps.map(\.words)
        var summary = "照你示范的步骤完成「\(name)」"
        var procedure = recorded.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if let client = await ensureClient(),
           let answer = try? await client.complete(
               system: Prompt.skillSystem,
               user: "Skill name: \(name)\nRecorded steps:\n" + recorded.map { "- \($0)" }.joined(separator: "\n"),
               maxTokens: 2_000
           ),
           let json = Agent.jsonObject(in: answer) {
            summary = (json["summary"] as? String) ?? summary
            procedure = (json["procedure"] as? String) ?? procedure
        }
        let skill = Skill(name: name, summary: summary, procedure: procedure, steps: recorded, createdAt: Date())
        TaskStore.shared.saveSkill(skill)
        if let calls = Agent.replayCalls(for: steps) {
            TaskStore.shared.saveTrajectory([
                "request": name, "calls": calls, "replays": 0,
                "savedAt": ISO8601DateFormatter().string(from: Date()), "demonstrated": true
            ], for: name)
        } else {
            TaskStore.shared.removeTrajectory(for: name)
        }
        return skill
    }

    /// The demonstration as replayable calls (open the app, then act on labeled targets);
    /// nil when a click had no label or typed text could not be read.
    static func replayCalls(for steps: [DemoStep]) -> [JSONObject]? {
        var calls: [JSONObject] = []
        var app: (name: String, bundle: String?)?
        var actions: [JSONObject] = []
        func flush() {
            if let app, !actions.isEmpty {
                calls.append(["tool": "act", "input": ["actions": actions], "app": app.name, "bundle": app.bundle ?? ""])
            }
            actions = []
        }
        for step in steps {
            if app?.name != step.app {
                flush()
                app = (step.app, step.bundleId)
                calls.append(["tool": "open", "input": ["app": step.bundleId ?? step.app], "app": step.app, "bundle": step.bundleId ?? ""])
            }
            switch step.kind {
            case .open:
                continue
            case .click, .doubleClick, .rightClick:
                guard let target = step.target else {
                    return nil
                }
                let kind = step.kind == .click ? "click" : (step.kind == .doubleClick ? "double_click" : "right_click")
                actions.append(["do": kind, "target": target])
            case .type:
                guard let text = step.text else {
                    return nil
                }
                actions.append(["do": "type", "text": text])
            case .key:
                actions.append(["do": "key", "key": step.key ?? ""])
            }
        }
        flush()
        return calls.isEmpty ? nil : calls
    }

    /// The first JSON object in a model reply (which may wrap it in a code fence).
    static func jsonObject(in text: String) -> JSONObject? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? JSONObject
    }

    // MARK: - Undo

    /// Whether 撤销 can do anything for this task.
    public var canUndo: Bool {
        !changedSteps.isEmpty || journaledTexts > 0 || runner?.hasUndoableFiles == true
    }

    /// Keeps what a batch changed beyond the text journal. Text edits count only when the
    /// journal could not record them (fields without accessibility, like WeChat's).
    private func noteChanges(_ actions: [JSONObject], shown: [String], journaled: Int) {
        var textActions = 0
        for (action, words) in zip(actions, shown) {
            switch stringValue(action["do"]) ?? "" {
            case "type", "set_value":
                textActions += 1
                if textActions > journaled {
                    changedSteps.append(words)
                }
            case "scroll", "wait":
                break
            default:
                changedSteps.append(words)
            }
        }
    }

    /// 撤销: restores journaled text exactly, then asks the model to revert the rest of the
    /// task's changes (⌘Z or the inverse action), or to say what cannot be undone.
    @discardableResult
    public func undo() async -> String {
        let restored = (try? await engine { $0.undoTextChanges() }) ?? 0
        let files = runner?.undoFiles()
        journaledTexts = 0
        let others = changedSteps
        changedSteps = []
        guard !others.isEmpty else {
            var done: [String] = []
            if restored > 0 {
                done.append("\(restored) 处文字恢复成了原来的内容")
            }
            if let files {
                done.append(files)
            }
            let reply = done.isEmpty ? "这个任务没有需要撤销的修改。" : "已撤销：\(done.joined(separator: "；"))。"
            onEvent(.finished(reply))
            return reply
        }
        var restoredNote = restored > 0 ? "CPU already restored \(restored) text field(s) to their earlier values. " : ""
        if let files {
            restoredNote += "CPU already undid the files the task's code changed (\(files)). "
        }
        let request = """
        The user pressed 撤销 (undo) for this task. \(restoredNote)Revert the other changes this task \
        made, using each app's Undo (⌘Z) or the inverse action, and touch nothing else; moving \
        around or opening things needs no undo. If something cannot be undone (a message already \
        sent, a submitted form, a payment), say so instead of trying. The task's steps, oldest first:
        \(others.map { "- \($0)" }.joined(separator: "\n"))
        """
        let reply = await run(request, followUp: true)
        // The undo itself is not undone by a second press.
        changedSteps = []
        journaledTexts = 0
        engineQueue.async { [computer] in
            computer.forgetUndo()
        }
        return reply
    }

    // MARK: - Replay

    /// Keeps the calls that moved this turn forward. Pointer actions must name their target:
    /// coordinates and element indexes do not survive a new layout, labels do.
    private func noteForReplay(_ use: JSONObject, output: ToolOutput) {
        let name = use["name"] as? String ?? ""
        switch name {
        case "ask_user", "confirm", "hand_over", "read_window", "read_file", "propose_edits", "code":
            // The answer may differ next time; a replay must not assume it.
            recordable = false
        case "act", "open":
            guard !output.isError, recordable else {
                return
            }
            var input = use["input"] as? JSONObject ?? [:]
            input.removeValue(forKey: "state_id")
            input.removeValue(forKey: "window_id")
            input.removeValue(forKey: "screenshot")
            if name == "act" {
                var actions: [JSONObject] = []
                for var action in input["actions"] as? [JSONObject] ?? [] {
                    let kind = stringValue(action["do"]) ?? ""
                    let pointed = action["element"] != nil || action["x"] != nil
                    if kind == "drag" || (pointed && stringValue(action["target"]) == nil) {
                        recordable = false
                        return
                    }
                    for key in ["element", "x", "y"] {
                        action.removeValue(forKey: key)
                    }
                    actions.append(action)
                }
                input["actions"] = actions
            }
            recording.append(["tool": name, "input": input, "app": output.app?.app ?? "", "bundle": output.app?.bundleId ?? ""])
        default:
            break
        }
    }

    /// Only requests that mean the same thing every time are replayed: none that point at the
    /// screen ("这封邮件") or at a moment ("明天"), whose steps would differ.
    static func isReplayable(_ request: String) -> Bool {
        let lowered = request.lowercased()
        let contextual = [
            "这", "那个", "那些", "此", "刚才", "上面", "下面", "选中", "当前", "今天", "明天", "昨天", "后天", "现在", "最近",
            "本周", "下周", "上周", "今晚", "今年", "明年", "本月", "下个月", "上个月", "this", "that", "these", "those",
            "selected", "current", "today", "tomorrow", "yesterday", "now", "tonight", "week", "month"
        ]
        return !contextual.contains { lowered.contains($0) }
    }

    private func saveTrajectory(for request: String) {
        guard recordable, !recording.isEmpty, recording.count <= 15, Agent.isReplayable(request) else {
            return
        }
        let previous = TaskStore.shared.trajectory(for: request)
        let replays = (previous?["replays"] as? Int ?? -1) + 1
        TaskStore.shared.saveTrajectory([
            "request": request,
            "calls": recording,
            "replays": replays,
            "savedAt": ISO8601DateFormatter().string(from: Date())
        ], for: request)
    }

    /// Replays what completed this request last time, then hands the model the result to
    /// check (one call instead of one per step). A step that no longer applies ends the
    /// replay and the model continues from there.
    private func replay(_ calls: [JSONObject], trajectory: JSONObject, request: String) async throws {
        onEvent(.status("按上次的做法执行…"))
        log?.section("replay", "\(calls.count) recorded calls")
        let before = recentSteps.count
        var failure: String?
        for call in calls {
            if Interrupts.isStopped {
                throw Stopped()
            }
            let tool = call["tool"] as? String ?? ""
            let input = call["input"] as? JSONObject ?? [:]
            do {
                if tool == "act" {
                    try await focusApp(bundle: call["bundle"] as? String, app: call["app"] as? String ?? "")
                }
                let output = tool == "act" ? try await act(input) : try await open(input)
                if output.isError {
                    failure = (output.content.first?["text"] as? String).map { compactText($0, limit: 300) } ?? "the step failed"
                    break
                }
                recording.append(call)
            } catch is Stopped {
                throw Stopped()
            } catch {
                failure = String(describing: error)
                break
            }
        }
        let done = recentSteps[before...].map { "- \($0)" }.joined(separator: "\n")
        var text: String
        if let failure {
            text = "CPU replayed part of the procedure that completed this request before:\n\(done)\nThe next step no longer applied (\(failure)). Continue from the current screen."
            let failures = (trajectory["failures"] as? Int ?? 0) + 1
            if failures >= 2 {
                TaskStore.shared.removeTrajectory(for: request)
            } else {
                var updated = trajectory
                updated["failures"] = failures
                TaskStore.shared.saveTrajectory(updated, for: request)
            }
        } else {
            text = "CPU replayed the steps that completed this same request before:\n\(done)\nCheck the current screen below: if the request is done, reply with the result, reading values from the screen (not from earlier runs). Otherwise continue from here."
        }
        log?.section("replay result", text)
        // The model's first look: the replay report and the screen as it is now.
        guard var content = messages.last?["content"] as? [JSONObject] else {
            return
        }
        content.append(Agent.text(text))
        if let window = current {
            let mode = config.screenshotMode
            let observation = try await engine { $0.observe(window, screenshot: mode) }
            remember(observation)
            observationRefs.append(ObservationRef(message: messages.count - 1, block: content.count, nested: false, label: "observation \(observation.stateId) of \(window.app)"))
            content += await observationBlocks(observation, header: "Current screen after the replay:")
        }
        messages[messages.count - 1]["content"] = content
    }

    /// Before replaying an action, make the current window one of the app it was recorded in.
    private func focusApp(bundle: String?, app: String) async throws {
        if let current, (bundle.map { !$0.isEmpty && $0 == current.bundleId } ?? false) || current.app == app {
            return
        }
        guard let window = try await engine({ computer in
            computer.windows().first { $0.onScreen && ((bundle != nil && !bundle!.isEmpty && $0.bundleId == bundle) || $0.app == app) }
        }) else {
            throw HelperError("\(app) has no open window")
        }
        let mode = config.screenshotMode
        let observation = try await engine { $0.observe(window, screenshot: mode) }
        current = observation.window
        remember(observation)
    }

    /// Asks for the card title alongside the first step; the request stands in until then.
    private func startGoal(_ request: String, client: AnthropicClient) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let title = try? await client.complete(system: Prompt.goalSystem, user: request, maxTokens: 600),
                  !title.isEmpty, title.count <= 40 else {
                return
            }
            self?.onEvent(.goal(title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」。.")).trimmingCharacters(in: .whitespaces)))
        }
    }

    /// Warns when the model issues the same call again (state ids aside).
    private func noteRepeat(_ use: JSONObject) -> String? {
        var input = use["input"] as? JSONObject ?? [:]
        input.removeValue(forKey: "state_id")
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        let signature = "\(use["name"] as? String ?? "")|\(String(data: data, encoding: .utf8) ?? "")"
        let count = (callCounts[signature] ?? 0) + 1
        callCounts[signature] = count
        guard count >= 3 else {
            return nil
        }
        return "[CPU] You have made this exact call \(count) times. It is not working; do something different or stop and tell the user."
    }

    private func startConversation(_ request: String) async throws {
        let excluded = excludedPids
        var observation: Observation?
        if let prefetch, Date().timeIntervalSince(prefetch.at) < 30 {
            observation = await prefetch.task.value
        }
        self.prefetch = nil
        let shareContext = includeContext
        if !shareContext {
            observation = nil
        } else if observation == nil {
            let mode = config.screenshotMode
            observation = try await engine { computer in
                computer.frontWindow(excluding: excluded.first).map { computer.observe($0, screenshot: mode, maxNodes: 250) }
            }
        }
        if let window = observation?.window, isPrivateTerminal(window) {
            // A terminal's scrollback is private and rarely what the request is about.
            observation = nil
        }
        let windows = try await engine { computer in computer.windows().filter { $0.onScreen && !excluded.contains($0.pid) } }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
        var context = "Time: \(formatter.string(from: Date()))\n\(Computer.homeFolders)\nFor code: \(await codeEnvironment.value)\nCPU's own commands for code (cpu help has details): `cpu tts <text|file> -o a.m4a` speaks a text into an audio file; `cpu page <url> --png a.png` (or --pdf a.pdf) saves a web page as one long image (or PDF), with --main just the article (title and body); `cpu page <url> --text` prints its text, --js <expr> evaluates JavaScript there (cpu page loads the page anew in a hidden browser, without the user's logins, in 5–20 s: for pages that are not open, or to save a page as an image or PDF; save its output to a file once); `cpu media <file>` gives length, tracks, pixels or pages; `cpu pdf <file> --text` a PDF's text.\nOn-screen windows, front to back:\n"
        // Without the user's context, window titles (mail subjects, document names) stay private.
        context += windows.prefix(15).map { shareContext ? Agent.windowLine($0) : "window \($0.id) · \($0.app)" }.joined(separator: "\n")
        var content: [JSONObject] = [["type": "text", "text": context]]
        if let observation {
            current = observation.window
            note(observation, use: .context)
            remember(observation)
            let label = "observation \(observation.stateId) of \(observation.window.app)"
            observationRefs.append(ObservationRef(message: 0, block: content.count, nested: false, label: label))
            content += await observationBlocks(observation, header: "Current window (the user's front window):")
        }
        if let files = takeAttachments() {
            content.append(files)
        }
        if let skills = Agent.skillNotes(for: request) {
            content.append(Agent.text(skills))
        }
        if let guide = guides(for: request) {
            content.append(Agent.text(guide))
        }
        content.append(["type": "text", "text": "User request: \(request)"])
        messages.append(["role": "user", "content": content])
    }

    /// Skills the user taught: a one-line index, with the full procedure of any skill the
    /// request names.
    static func skillNotes(for request: String) -> String? {
        let skills = TaskStore.shared.skills
        guard !skills.isEmpty else {
            return nil
        }
        let wanted = TaskStore.normalize(request)
        var lines = ["Skills the user taught you by demonstration. When the request matches one, follow its procedure and fill in the placeholders:"]
        for skill in skills.prefix(12) {
            if wanted.contains(TaskStore.normalize(skill.name)) {
                lines.append("- \(skill.name): \(skill.summary)\n\(skill.procedure)")
            } else {
                lines.append("- \(skill.name): \(skill.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// How this kind of work should go (expectations and the practiced path), once per session.
    private func guides(for request: String) -> String? {
        let found = Playbooks.guides(for: request, excluding: givenGuides)
        guard !found.isEmpty else {
            return nil
        }
        givenGuides.formUnion(found.map(\.id))
        log?.section("scenario guides", found.map(\.id).joined(separator: ", "))
        return "How the user expects this kind of work to go:\n\n" + found.map(\.text).joined(separator: "\n\n")
    }

    /// A follow-up: the current state of the window the task was working in, then the words.
    private func continueConversation(_ request: String) async throws {
        var content: [JSONObject] = []
        if let window = try? await targetWindow(nil), !isPrivateTerminal(window) {
            let mode = config.screenshotMode
            let observation = try await engine { $0.observe(window, screenshot: mode) }
            current = observation.window
            remember(observation)
            let label = "observation \(observation.stateId) of \(window.app)"
            observationRefs.append(ObservationRef(message: messages.count, block: content.count, nested: false, label: label))
            content += await observationBlocks(observation, header: "Current state:")
        }
        if let files = takeAttachments() {
            content.append(files)
        }
        if let guide = guides(for: request) {
            content.append(Agent.text(guide))
        }
        content.append(Agent.text("Follow-up request (same task): \(request)"))
        messages.append(["role": "user", "content": content])
    }

    /// What the context capsule shows: the window, and the selected text or items in it.
    static func summary(of observation: Observation) -> ContextSummary {
        var items: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"^\s*\[\d+\] \S+ "([^"]+)".*\(.*\bselected\b"#)
        for line in observation.outline.split(separator: "\n") {
            let text = String(line)
            if let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                items.append(String(text[range]))
            }
        }
        let selected = observation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContextSummary(
            app: observation.window.app,
            title: observation.window.title,
            selectedText: selected?.isEmpty == false ? selected : nil,
            selectedItems: items
        )
    }

    // MARK: - Fast path

    /// "打开微信" / "open Safari": an exact app name needs no model call.
    private func fastPath(_ request: String) async throws -> String? {
        let trimmed = request.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.!！?？")))
        let pattern = #"^(?:请|帮我|麻烦)?\s*(?:打开|启动|开启|切换到|open|launch|start|switch to)\s*(.{1,30})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        let name = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
        guard try await engine({ $0.isExactAppName(name) }) else {
            return nil
        }
        if isBlocked(app: name, bundleId: try? await engine({ try $0.resolveApp(name).bundleId })) {
            return nil
        }
        onEvent(.step("打开 \(name)"))
        // The user asked to see the app: this one comes to the front.
        let launched = try await engine { try $0.launch(app: name, activate: true) }
        return "已打开\(launched.name)。"
    }

    // MARK: - Tools

    private func execute(_ use: JSONObject) async -> ToolOutput {
        let name = use["name"] as? String ?? ""
        let input = use["input"] as? JSONObject ?? [:]
        if use["_invalid_input"] != nil {
            return ToolOutput(content: [Agent.text("The tool input was not valid JSON. Call \(name) again with valid arguments.")], isError: true)
        }
        do {
            switch name {
            case "act":
                return try await act(input)
            case "open":
                return try await open(input)
            case "observe":
                return try await observe(input)
            case "windows":
                let list = try await engine { $0.windows().filter { $0.onScreen } }
                return ToolOutput(content: [Agent.text(list.prefix(30).map(Agent.windowLine).joined(separator: "\n"))])
            case "ask_user":
                let question = input["question"] as? String ?? ""
                let options = (input["options"] as? [Any])?.compactMap { $0 as? String } ?? []
                let reply = await askUser(.question(question, options: options))
                if Interrupts.isStopped {
                    throw Stopped()
                }
                switch reply {
                case .text(let answer):
                    return ToolOutput(content: [Agent.text("The user answered: \(answer)")])
                case .confirmed, .done, .accepted:
                    return ToolOutput(content: [Agent.text("The user answered: yes")])
                case .cancelled:
                    return ToolOutput(content: [Agent.text("The user declined to answer. Stop and say what is missing.")])
                case nil:
                    return ToolOutput(content: [Agent.text("The user did not answer.")])
                }
            case "confirm":
                let action = stringValue(input["action"]) ?? "继续"
                let details = input["details"] as? String ?? ""
                let reply = await askUser(.confirm(action: action, details: details))
                if Interrupts.isStopped {
                    throw Stopped()
                }
                switch reply {
                case .confirmed, .done, .accepted:
                    return ToolOutput(content: [Agent.text("The user confirmed. Do it now, exactly as shown.")])
                case .text(let answer):
                    return ToolOutput(content: [Agent.text("Instead of confirming, the user said: \(answer). Adjust; if the content changes, confirm again.")])
                case .cancelled, nil:
                    return ToolOutput(content: [Agent.text("The user did not approve. Do not do it; finish by saying it was not done.")])
                }
            case "read_window":
                return try await readWindow(input)
            case "read_file":
                return try await readFile(input)
            case "code":
                return try await runCode(input)
            case "propose_edits":
                let summary = stringValue(input["summary"]) ?? "修改建议"
                let edits = (input["edits"] as? [JSONObject] ?? []).compactMap { edit -> ProposedEdit? in
                    guard let original = stringValue(edit["original"]), let replacement = stringValue(edit["replacement"]),
                          !original.isEmpty, original != replacement else {
                        return nil
                    }
                    return ProposedEdit(original: original, replacement: replacement, reason: stringValue(edit["reason"]) ?? "")
                }
                guard !edits.isEmpty else {
                    throw HelperError("edits must list at least one change")
                }
                let reply = await askUser(.edits(summary: summary, edits: edits))
                if Interrupts.isStopped {
                    throw Stopped()
                }
                var chosen: [Int] = []
                switch reply {
                case .accepted(let numbers):
                    chosen = numbers.filter { (1...edits.count).contains($0) }
                case .confirmed, .done:
                    chosen = Array(1...edits.count)
                case .text(let answer):
                    return ToolOutput(content: [Agent.text("Instead of choosing, the user said: \(answer). Adjust; if the edits change, call propose_edits again.")])
                case .cancelled, nil:
                    break
                }
                guard !chosen.isEmpty else {
                    return ToolOutput(content: [Agent.text("The user applied none of the edits. Change nothing; finish by saying so.")])
                }
                if let window = current {
                    editCheck = (window, chosen.map { ($0, edits[$0 - 1]) }, 0)
                }
                let skipped = (1...edits.count).filter { !chosen.contains($0) }
                let list = chosen.map(String.init).joined(separator: ", ")
                return ToolOutput(content: [Agent.text(
                    "The user accepted edits \(list) of \(edits.count)"
                        + (skipped.isEmpty ? "" : " (not \(skipped.map(String.init).joined(separator: ", ")))")
                        + ". Apply exactly the accepted ones now, in place and visibly in the app: turn on its change tracking first if it has one (Word: Track Changes / 修订), then replace each original passage with its replacement (Find & Replace, or select the passage and type). Leave everything else, including formatting, as it is."
                )])
            case "hand_over":
                let instruction = stringValue(input["instruction"]) ?? "请完成这一步"
                let reply = await askUser(.handOver(instruction))
                if Interrupts.isStopped {
                    throw Stopped()
                }
                switch reply {
                case .done, .confirmed, .accepted:
                    return ToolOutput(content: [Agent.text("The user says they finished: \(instruction). Observe the current screen and continue.")])
                case .text(let answer):
                    return ToolOutput(content: [Agent.text("The user replied: \(answer)")])
                case .cancelled, nil:
                    return ToolOutput(content: [Agent.text("The user did not do it. Stop and say what is left.")])
                }
            default:
                return ToolOutput(content: [Agent.text("Unknown tool \(name).")], isError: true)
            }
        } catch is Stopped {
            return ToolOutput(content: [Agent.text(Interrupts.stoppedMessage)], isError: true, progressed: false)
        } catch {
            return ToolOutput(content: [Agent.text("Error: \(error)")], isError: true, progressed: false)
        }
    }

    /// The task's workspace: where code runs and long texts are saved.
    private func workspace() -> CodeRunner {
        let runner = self.runner ?? CodeRunner(task: log?.stem ?? UUID().uuidString)
        self.runner = runner
        return runner
    }

    /// Every text result shows this much at most; the rest is read on from its file.
    static let textBudget = 60_000

    /// What a window shows, in full; saved in the workspace for read_file and code.
    private func readWindow(_ input: JSONObject) async throws -> ToolOutput {
        let started = Date()
        let record = try await targetWindow(input["window_id"])
        try checkAllowed(record)
        let read = try await engine { try $0.readText(record) }
        current = read.window
        let words = "读取全文（约 \(read.text.count) 字）"
        onEvent(.step(words))
        recentSteps.append(words)
        let window = read.window
        if let page = read.page {
            noteResource(.page, .read, title: Agent.pageTitle(window), location: page)
        } else if let document = read.document {
            noteResource(.file, .read, title: (document as NSString).lastPathComponent, location: document)
        }
        let saved = LongText.save(read.text, name: window.title.isEmpty ? window.app : window.title, in: workspace().workspace)
        var header = "Text of window \(window.id) (\(window.app)\(window.title.isEmpty ? "" : ", \"\(window.title)\"")): \(LongText.lines(of: read.text).count) lines, \(read.text.count) characters"
        switch read.method {
        case "app_script":
            header += ", given by \(window.app) itself (its document body keeps the text from accessibility)"
        case "saved_file":
            header += ", from its saved file"
        default:
            break
        }
        if let document = read.document {
            header += ". The window shows the file \(document)"
        }
        if let saved {
            header += ". Saved as \(saved) in the workspace (for read_file and code)"
        }
        var text = header + "."
        for note in read.notes {
            text += "\nNote: " + note
        }
        text += "\n\n" + LongText.excerpt(read.text, budget: Agent.textBudget, file: saved)
        var output = ToolOutput(content: [Agent.text(text)])
        output.timing = [("read", Agent.ms(since: started))]
        return output
    }

    /// A file's text, any kind, from a given line: also how long results are read on.
    private func readFile(_ input: JSONObject) async throws -> ToolOutput {
        guard let path = stringValue(input["path"])?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw HelperError("read_file needs a path")
        }
        let started = Date()
        let workspace = workspace().workspace
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if path.hasPrefix("~") {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            url = workspace.appendingPathComponent(path)
        }
        if let secret = Agent.secretPlace(url) {
            throw HelperError("\(secret) holds credentials; CPU does not send them to the model.")
        }
        let document = try await Agent.offEngine { try DocumentText.read(url) }
        noteResource(.file, .read, title: url.lastPathComponent, location: url.standardizedFileURL.path)
        let from = intValue(input["from_line"]) ?? 1
        if from <= 1 {
            let words = "读取文件 \(url.lastPathComponent)"
            onEvent(.step(words))
            recentSteps.append(words)
        }
        let lines = LongText.lines(of: document.text).count
        var header = "Text of \(url.path) (\(document.kind)): \(lines) lines, \(document.text.count) characters"
        // Text taken out of a PDF or Word file is saved too, so that code can search it.
        let plain = document.kind.hasSuffix(" text") || document.kind == "text"
        if !plain {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            let key = "\(url.path)#\(modified)"
            if extractedTexts[key] == nil {
                extractedTexts[key] = LongText.save(document.text, name: url.deletingPathExtension().lastPathComponent, in: workspace)
            }
            if let saved = extractedTexts[key] {
                header += ". Its text is saved as \(saved) in the workspace (for code)"
            }
        }
        let body = LongText.excerpt(document.text, from: from, count: intValue(input["lines"]), budget: Agent.textBudget, file: path)
        var output = ToolOutput(content: [Agent.text(header + ".\n\n" + body)])
        output.timing = [("read", Agent.ms(since: started))]
        return output
    }

    /// Places that keep passwords and keys: their files stay on the Mac.
    static func secretPlace(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in [".ssh", ".gnupg", ".aws", "Library/Keychains", ".config/gh", ".docker"] where path.hasPrefix("\(home)/\(folder)/") || path == "\(home)/\(folder)" {
            return "~/\(folder)"
        }
        let name = url.lastPathComponent
        if [".netrc", ".npmrc", ".pypirc", ".git-credentials"].contains(name) || name == ".env" || name.hasPrefix(".env.") || url.pathExtension == "keychain-db" {
            return name
        }
        return nil
    }

    /// Runs the model's code in the task's workspace, after the user's OK when it is risky.
    private func runCode(_ input: JSONObject) async throws -> ToolOutput {
        let runner = workspace()
        let timeout = max(1, min(600, doubleValue(input["timeout"]) ?? 60))
        let started = Date()
        if let job = intValue(input["job"]) {
            let stop = boolValue(input["stop"]) ?? false
            onEvent(.status(stop ? "停止后台任务…" : "等待后台任务…"))
            let report = await Agent.offEngine { runner.wait(job: job, timeout: timeout, stop: stop) }
            var output = ToolOutput(content: [Agent.text(report)])
            output.timing = [("run", Agent.ms(since: started))]
            return output
        }
        guard var code = input["code"] as? String, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelperError("code needs code (or job)")
        }
        var files = (input["files"] as? JSONObject ?? [:]).compactMapValues { $0 as? String }
        let purpose = stringValue(input["purpose"]) ?? "运行代码"
        let requested = (stringValue(input["language"]) ?? "shell").lowercased()
        let shown = code
        if requested == "page" {
            // JavaScript in the browser tab CPU works in, through the browser's own scripting.
            if let refusal = CodeSafety.pageRefusal(code) {
                throw HelperError("Not run: \(refusal)")
            }
            let tab = try await browserTab()
            files[".cpu-page.js"] = CodeSafety.pageScript(code)
            code = CodeSafety.browserScript(bundleId: tab.bundleId, title: tab.title, scriptFile: ".cpu-page.js")
        }
        guard let language = requested == "page" ? .applescript : CodeRunner.Language(rawValue: requested) else {
            throw HelperError("language must be one of: \(CodeRunner.Language.allCases.map(\.rawValue).joined(separator: ", ")), page")
        }
        switch requested == "page" ? .run : CodeSafety.check(language: language.rawValue, code: code + "\n" + files.values.joined(separator: "\n")) {
        case .refuse(let reason):
            throw HelperError("Not run: \(reason)")
        case .confirm(let reasons):
            let details = "其中会：\(reasons.joined(separator: "、"))\n\n" + Agent.codePreview(code)
            let reply = await askUser(.confirm(action: "运行代码：\(purpose)", details: details))
            if Interrupts.isStopped {
                throw Stopped()
            }
            switch reply {
            case .confirmed, .done, .accepted:
                break
            case .text(let answer):
                return ToolOutput(content: [Agent.text("Not run. Instead of approving, the user said: \(answer)")], isError: true, progressed: false)
            case .cancelled, nil:
                return ToolOutput(content: [Agent.text("Not run: the user did not approve this code (\(reasons.joined(separator: ", "))). Do not do it another way; say it was not done.")], isError: true, progressed: false)
            }
        case .run:
            break
        }
        let words = "运行代码：\(purpose)"
        onEvent(.step(words))
        onEvent(.detail(Agent.codePreview(shown)))
        recentSteps.append(words)
        onEvent(.status("代码运行中…"))
        let request = CodeRunner.Request(language: language, code: code, files: files, timeout: timeout)
        let report: String
        var content: [JSONObject] = []
        if boolValue(input["background"]) == true {
            report = try await Agent.offEngine { try runner.startInBackground(request).note }
            content.append(Agent.text(report))
        } else {
            let result = try await Agent.offEngine { try runner.run(request) }
            report = result.report
            content.append(Agent.text(report))
            for path in result.created {
                noteResource(.file, .created, title: (path as NSString).lastPathComponent, location: path)
            }
            for path in result.changed {
                noteResource(.file, .changed, title: (path as NSString).lastPathComponent, location: path)
            }
            if config.vision {
                // The model can look at the images its code made instead of trusting sizes.
                for image in result.images.prefix(2) {
                    guard let preview = await Agent.offEngine({ ImagePreview.jpeg(image) }) else {
                        continue
                    }
                    content.append(Agent.text("Preview of \(preview.note):"))
                    content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": preview.data.base64EncodedString()]])
                }
            }
        }
        var output = ToolOutput(content: content)
        output.isError = report.contains(": exit ") && !report.contains("exit 0 (success)") || report.hasPrefix("Stopped")
        output.timing = [("run", Agent.ms(since: started))]
        return output
    }

    /// The browser window CPU is working in (else the front browser window): its app and the
    /// title of the tab it shows.
    private func browserTab() async throws -> (bundleId: String, title: String) {
        let browsers = CodeSafety.browsers
        if let window = current, let bundle = window.bundleId, browsers.contains(bundle) {
            return (bundle, window.title)
        }
        guard let window = try await engine({ computer in computer.windows().first { $0.onScreen && browsers.contains($0.bundleId ?? "") } }),
              let bundle = window.bundleId else {
            throw HelperError("No Chrome or Safari window is open; open the page first.")
        }
        return (bundle, window.title)
    }

    /// Runs blocking work (a process) off both the main thread and the engine queue, which
    /// the code must not hold up.
    private static func offEngine<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private static func offEngine<T>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }

    /// The code as the card and the confirmation show it: the first 40 lines.
    static func codePreview(_ code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        let shown = lines.prefix(40).map { compactText($0, limit: 160) }.joined(separator: "\n")
        return lines.count > 40 ? shown + "\n… 另有 \(lines.count - 40) 行" : shown
    }

    private func act(_ input: JSONObject) async throws -> ToolOutput {
        let first = try await actWindow(input)
        try checkAllowed(first)
        guard let actions = input["actions"] as? [JSONObject], !actions.isEmpty else {
            throw HelperError("actions must be a non-empty array")
        }
        // The clipboard is the user's: copying over what they copied needs their say.
        if !clipboardAllowed, let copying = Agent.clipboardWrite(in: actions) {
            let reply = await askUser(.confirm(action: "使用剪贴板", details: "这一步要\(copying)，会替换你剪贴板里现在的内容。"))
            if Interrupts.isStopped {
                throw Stopped()
            }
            switch reply {
            case .confirmed, .done, .accepted:
                clipboardAllowed = true
            case .text(let answer):
                return ToolOutput(content: [Agent.text("Nothing was done. Instead of allowing the clipboard, the user said: \(answer)")], isError: true)
            case .cancelled, nil:
                return ToolOutput(content: [Agent.text("Nothing was done: the user keeps their clipboard as it is. Move text by reading it (read_window, read_file) and typing it (type), not by copying.")], isError: true)
            }
        }
        var record = first
        var stateId = stringValue(input["state_id"]) ?? latest[record.id]?.stateId
        var queued: [(method: String, params: [String: Any], label: String)] = []
        var queuedWords: [String] = []
        var allWords: [String] = []
        var lines: [String] = []
        var ran = 0
        var failed: String?
        var settleMs = 0
        var waitMs = 0
        var actionsMs = 0
        var lookMs = 0
        var resultWindow: WindowRecord?
        var midwayChange = false
        let journaledBefore = try await engine { $0.undoableTextChanges }

        // Runs what is queued on the current window; false when an action failed.
        func runQueued() async throws -> Bool {
            guard !queued.isEmpty else {
                return true
            }
            for line in queuedWords {
                onEvent(.step(line))
            }
            recentSteps += queuedWords
            allWords += queuedWords
            let steps = queued
            let target = record
            let from = ran + 1
            queued = []
            queuedWords = []
            let started = Date()
            let batch = try await engine { $0.runBatch(window: target, steps: steps, numberFrom: from) }
            actionsMs += Agent.ms(since: started)
            lines += batch.lines
            for file in batch.files {
                noteWritten(file, since: started)
            }
            ran += batch.completed
            settleMs += batch.settleMs
            waitMs += batch.waitMs
            resultWindow = batch.window
            if Interrupts.isStopped {
                throw Stopped()
            }
            failed = batch.failed
            return batch.failed == nil
        }

        // Looks at what the window (or the dialog or menu it opened) shows now.
        func lookAgain() async throws {
            var view = resultWindow ?? record
            if isPrivateTerminal(view) {
                view = record
            }
            let started = Date()
            let observation = try await engine { $0.observe(view, screenshot: .never) }
            lookMs += Agent.ms(since: started)
            midwayChange = remember(observation) || midwayChange || observation.window.id != record.id
            if observation.window.id != record.id {
                try checkAllowed(observation.window)
                lines.append("(the next actions run in window \(observation.window.id), \(observation.window.app))")
            }
            current = observation.window
            record = observation.window
            stateId = observation.stateId
        }

        actionLoop: for action in actions {
            let kind = stringValue(action["do"]) ?? ""
            // A name without an index points at what the earlier actions bring up (a menu item,
            // a button of the dialog that appears): look it up once they have run.
            let later = !queued.isEmpty && action["element"] == nil && action["target"] != nil && !["key", "wait", "drag", "menu"].contains(kind)
            var made: [(method: String, params: [String: Any], label: String)]?
            var lastError: Error?
            for attempt in 0..<3 {
                if later || attempt > 0 {
                    guard try await runQueued() else {
                        break actionLoop
                    }
                    if attempt == 2 {
                        // Some apps take a moment to show a menu or dialog.
                        try await Task.sleep(nanoseconds: 400_000_000)
                    }
                    try await lookAgain()
                }
                do {
                    made = try makeSteps(action, record: record, stateId: stateId)
                    break
                } catch let missing as OutlineIndex.TargetNotFound where ran > 0 || !queued.isEmpty {
                    lastError = missing
                } catch where ran > 0 {
                    lastError = error
                    break
                }
            }
            guard let made else {
                let error = lastError.map { String(describing: $0) } ?? "not found"
                failed = error
                lines.append("\(ran + 1). \(plainWords(action, record: record, stateId: stateId)): FAILED — \(error)")
                break
            }
            queued += made
            queuedWords.append(plainWords(action, record: record, stateId: stateId))
        }
        if failed == nil {
            _ = try await runQueued()
        }
        journaledTexts = try await engine { $0.undoableTextChanges }
        noteChanges(actions, shown: allWords, journaled: journaledTexts - journaledBefore)
        var next = resultWindow ?? record
        if isPrivateTerminal(next) {
            // The action brought a terminal forward: stay on the window that was acted on.
            next = record
        }
        if next.id == 0 {
            let pid = next.pid
            guard let shown = try await engine({ computer in computer.windows().first { $0.pid == pid && $0.onScreen } }) else {
                var output = ToolOutput(content: [Agent.text((["Ran \(ran) action(s) in \(first.app):"] + lines + ["\(first.app) still shows no window."]).joined(separator: "\n"))])
                output.isError = failed != nil
                return output
            }
            windowless = nil
            next = shown
        }
        let mode = screenshotMode(input["screenshot"])
        let observed = Date()
        let observation = try await engine { $0.observe(next, screenshot: mode) }
        let observeMs = Agent.ms(since: observed)
        // The observation may be of a dialog in front of `next`: further actions go there.
        current = observation.window
        let changed = remember(observation) || midwayChange
        var header = ["Ran \(ran) action(s) on window \(first.id) (\(first.app)); UI settled in \(settleMs)ms:"]
        header += lines
        if observation.window.id != first.id {
            header.append("The result is shown in another window, observed below.")
        } else if !changed {
            header.append("No visible change: the window looks exactly as before these actions.")
        }
        var output = ToolOutput(content: await observationBlocks(observation, header: header.joined(separator: "\n")))
        output.app = first
        output.isError = failed != nil
        output.progressed = failed == nil && (changed || observation.window.id != first.id)
        output.observationLabel = "observation \(observation.stateId) of \(next.app)"
        output.timing = [("actions", actionsMs), ("wait", waitMs), ("settle", settleMs)]
            + (lookMs > 0 ? [("look again", lookMs)] : [])
            + Agent.observeTiming(observeMs, observation)
        return output
    }

    /// Runs one `act` call on a window the way the model's call would run and returns its
    /// text (development: `cpuctl act`). Nothing goes to the model.
    public func actLocally(window id: Int, actions: [JSONObject]) async -> String {
        do {
            guard let window = try await engine({ $0.window(id: id) }) else {
                return "no window \(id)"
            }
            let observation = try await engine { $0.observe(window, screenshot: .never) }
            current = observation.window
            remember(observation)
            let output = try await act(["window_id": Int(observation.window.id), "actions": actions])
            try? await engine { $0.restoreDisplacedWindows() }
            return output.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } catch {
            return "error: \(error)"
        }
    }

    /// The window an act targets: as given, else the window its state_id was observed in,
    /// else the current one.
    private func actWindow(_ input: JSONObject) async throws -> WindowRecord {
        if let app = windowless, input["window_id"] == nil, input["state_id"] == nil {
            if let window = try await engine({ computer in computer.windows().first { $0.pid == app.pid && $0.onScreen } }) {
                windowless = nil
                return window
            }
            // Stands for the app itself: its menus work without a window.
            return WindowRecord(app: app.app, bundleId: app.bundleId, id: 0, pid: app.pid, title: "", bounds: .zero, onScreen: false)
        }
        windowless = nil
        if input["window_id"] == nil, let id = stringValue(input["state_id"]), let entry = indexes[id], entry.window != current?.id,
           let window = try await engine({ $0.window(id: Int(entry.window)) }) {
            return window
        }
        return try await targetWindow(input["window_id"])
    }

    private func open(_ input: JSONObject) async throws -> ToolOutput {
        let app = stringValue(input["app"])
        let url = stringValue(input["url"])
        guard app != nil || url != nil else {
            throw HelperError("Pass app, url, or both.")
        }
        var appName = app ?? ""
        if let app {
            let resolved = try await engine { try $0.resolveApp(app) }
            if isBlocked(app: resolved.name, bundleId: resolved.bundleId) {
                throw HelperError("\(resolved.name) is on the blocked list; do not operate it.")
            }
            appName = resolved.name
        }
        let opening = url.map { target -> String in
            if target.hasPrefix("/") || target.hasPrefix("~") {
                return "打开「\((target as NSString).lastPathComponent)」"
            }
            return "打开 \(URL(string: target)?.host ?? target)"
        } ?? "打开 \(appName)"
        onEvent(.step(opening))
        recentSteps.append(opening)
        let show = boolValue(input["show"]) ?? false
        let window: WindowRecord?
        windowless = nil
        let opened = Date()
        if let url {
            window = try await engine { try $0.open(url: url, app: app, activate: show) }
        } else {
            let launched = try await engine { try $0.launch(app: app!, activate: show) }
            window = launched.windows.first(where: { $0.onScreen })
            if window == nil, launched.pid > 0 {
                let pid = launched.pid
                let menus = (try? await engine { $0.menuTitles(pid: pid) }) ?? []
                windowless = (pid, launched.name, launched.windows.first?.bundleId)
                let listed = menus.isEmpty ? "" : " Its menus: \(menus.joined(separator: " · "))."
                return ToolOutput(content: [Agent.text("\(launched.name) is running but shows no window. An act without window_id now goes to \(launched.name): use a menu command or its shortcut to open or create a document (e.g. {\"do\":\"menu\",\"path\":\"文件 ▸ 新建\"}).\(listed)")])
            }
        }
        if let url, url.hasPrefix("/") || url.hasPrefix("~") || url.hasPrefix("file:") {
            let path = url.hasPrefix("file:") ? (URL(string: url)?.path ?? url) : (url as NSString).expandingTildeInPath
            noteResource(.file, .opened, title: (path as NSString).lastPathComponent, location: path)
        }
        guard let window else {
            return ToolOutput(content: [Agent.text("Opened, but no window is showing yet (the app may still be starting or lives in the menu bar). Call windows or observe shortly.")])
        }
        try checkAllowed(window)
        let openMs = Agent.ms(since: opened)
        let mode = screenshotMode(input["screenshot"])
        let observed = Date()
        let observation = try await engine { $0.observe(window, screenshot: mode) }
        current = observation.window
        remember(observation)
        var output = ToolOutput(content: await observationBlocks(observation, header: "Opened; now showing:"))
        output.timing = [("open", openMs)] + Agent.observeTiming(Agent.ms(since: observed), observation)
        output.app = window
        output.observationLabel = "observation \(observation.stateId) of \(window.app)"
        return output
    }

    private func observe(_ input: JSONObject) async throws -> ToolOutput {
        let record = try await targetWindow(input["window_id"])
        try checkAllowed(record)
        let mode = screenshotMode(input["screenshot"])
        let observed = Date()
        let observation = try await engine { $0.observe(record, screenshot: mode) }
        current = observation.window
        remember(observation)
        var output = ToolOutput(content: await observationBlocks(observation, header: "Observed:"))
        output.timing = Agent.observeTiming(Agent.ms(since: observed), observation)
        output.observationLabel = "observation \(observation.stateId) of \(record.app)"
        return output
    }

    private func targetWindow(_ raw: Any?) async throws -> WindowRecord {
        if let id = intValue(raw) {
            guard let window = try await engine({ $0.window(id: id) }) else {
                throw HelperError("Window \(id) no longer exists. Call windows to list current windows.")
            }
            return window
        }
        if let current {
            // A closed dialog hands over to its app's front window, not to whatever app is in front.
            let pid = current.pid
            if let fresh = try await engine({ computer in
                computer.window(id: Int(current.id)) ?? computer.windows().first { $0.pid == pid && $0.onScreen }
            }) {
                return fresh
            }
        }
        let excluded = excludedPids
        guard let front = try await engine({ $0.frontWindow(excluding: excluded.first) }) else {
            throw HelperError("There is no window to operate. Use open to launch an app.")
        }
        return front
    }

    /// One action as the card shows it: "点击「发送」", "输入“hello”", "按 ⌘L".
    private func plainWords(_ action: JSONObject, record: WindowRecord, stateId: String?) -> String {
        func what() -> String {
            if let target = stringValue(action["target"]) {
                return "「\(compactText(target, limit: 24))」"
            }
            if let element = intValue(action["element"]), let entry = observationIndex(stateId, window: record.id)?.entries[element] {
                let text = entry.label.isEmpty ? entry.value : entry.label
                return text.isEmpty ? (Agent.roleNames[entry.role] ?? "界面元素") : "「\(compactText(text, limit: 24))」"
            }
            return "界面上的一个位置"
        }
        let pointed = action["element"] != nil || action["target"] != nil || action["x"] != nil
        switch stringValue(action["do"]) ?? "" {
        case "click":
            return "点击\(what())"
        case "double_click":
            return "双击\(what())"
        case "right_click":
            return "右键点击\(what())"
        case "type":
            let text = "“\(compactText(action["text"] as? String ?? "", limit: 30))”"
            return pointed ? "在\(what())中输入\(text)" : "输入\(text)"
        case "key":
            let times = (intValue(action["repeat"]) ?? 1) > 1 ? " ×\(intValue(action["repeat"])!)" : ""
            return "按 \(Agent.keyWords(stringValue(action["key"]) ?? ""))\(times)"
        case "scroll":
            let direction = (doubleValue(action["dy"]) ?? 0) < 0 ? "向上滚动" : "向下滚动"
            return pointed ? "\(direction)\(what())" : direction
        case "set_value":
            return "把\(what())设为“\(compactText((action["value"] as? String) ?? "", limit: 24))”"
        case "secondary":
            return "对\(what())执行 \(stringValue(action["name"]) ?? "")"
        case "drag":
            return "拖动"
        case "menu":
            return "选择菜单「\(compactText(stringValue(action["path"]) ?? stringValue(action["target"]) ?? "", limit: 40))」"
        case "wait":
            switch stringValue(action["until"]) {
            case nil:
                return "等待片刻"
            case "change":
                return "等待界面变化"
            case "file":
                return "等待文件生成"
            case let text?:
                return boolValue(action["gone"]) == true ? "等待「\(compactText(text, limit: 20))」消失" : "等待「\(compactText(text, limit: 20))」出现"
            }
        default:
            return stringValue(action["do"]) ?? "操作"
        }
    }

    static let roleNames: [String: String] = [
        "button": "按钮", "textfield": "输入框", "textarea": "文本框", "searchfield": "搜索框", "checkbox": "复选框",
        "switch": "开关", "radio": "单选项", "popup": "下拉菜单", "menubutton": "菜单按钮", "combobox": "组合框",
        "link": "链接", "menuitem": "菜单项", "row": "列表项", "cell": "单元格", "tab": "标签页", "image": "图片",
        "slider": "滑块"
    ]

    /// "cmd+shift+t" → "⌘⇧T", "return" → "回车".
    static func keyWords(_ chord: String) -> String {
        chord.split(separator: "+").map { part -> String in
            switch part.lowercased() {
            case "cmd", "command": return "⌘"
            case "shift": return "⇧"
            case "alt", "option", "opt": return "⌥"
            case "ctrl", "control": return "⌃"
            case "return", "enter": return "回车"
            case "escape", "esc": return "Esc"
            case "tab": return "Tab"
            case "space": return "空格"
            case "delete", "backspace": return "删除"
            case "up": return "↑"
            case "down": return "↓"
            case "left": return "←"
            case "right": return "→"
            default: return part.count == 1 ? part.uppercased() : String(part)
            }
        }.joined()
    }

    /// Translates one model action into engine calls (a `type` with an element clicks it first).
    /// What in these actions would copy or cut to the clipboard, in words for the user; nil
    /// when nothing does.
    static func clipboardWrite(in actions: [JSONObject]) -> String? {
        for action in actions {
            switch stringValue(action["do"]) ?? "" {
            case "key":
                let keys = (stringValue(action["key"]) ?? "").lowercased().replacingOccurrences(of: "⌘", with: "cmd+")
                    .replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
                guard keys.count == 2, keys.contains("cmd") || keys.contains("command") else {
                    continue
                }
                if keys.contains("c") {
                    return "按 ⌘C 拷贝"
                }
                if keys.contains("x") {
                    return "按 ⌘X 剪切"
                }
            case "menu":
                let path = MenuBar.parts(stringValue(action["path"]) ?? "")
                // 文件 ▸ 复制 is Duplicate in Chinese menus, not Copy.
                if let item = path.last, path.count > 1, isCopyLabel(item), !(path.first ?? "").hasPrefix("文件"), path.first?.lowercased() != "file" {
                    return "选择菜单「\(item)」"
                }
            case "click", "double_click", "secondary":
                if let target = stringValue(action["target"]), isCopyLabel(target) {
                    return "点「\(target)」"
                }
            default:
                break
            }
        }
        return nil
    }

    /// Copy and cut commands and buttons: 拷贝, 复制链接, Copy Link, Cut…
    static func isCopyLabel(_ label: String) -> Bool {
        let text = MenuBar.normalize(label).lowercased().trimmingCharacters(in: .whitespaces)
        return ["拷贝", "复制", "剪切"].contains { text.hasPrefix($0) } || text.range(of: #"^(copy|cut)\b"#, options: .regularExpression) != nil
    }

    private func makeSteps(_ action: JSONObject, record: WindowRecord, stateId: String?) throws -> [(method: String, params: [String: Any], label: String)] {
        let kind = stringValue(action["do"]) ?? ""
        // Window 0 stands for an app without windows, reached through its menus.
        var params: [String: Any] = record.id == 0 ? ["pid": Int(record.pid)] : ["window": ["id": Int(record.id)]]
        if record.id == 0, !["menu", "key", "wait"].contains(kind) {
            throw HelperError("\(record.app) has no window yet: open or create one with a menu command or shortcut first.")
        }
        if let stateId {
            params["state_id"] = stateId
        }
        var element = intValue(action["element"])
        var x = doubleValue(action["x"])
        var y = doubleValue(action["y"])
        var correction: String?
        // Check the chosen element against the label the model meant (index slips are the most
        // common wrong click), or find it by label / on-screen text when no index was given.
        if let wanted = stringValue(action["target"]), !["key", "wait", "drag", "menu"].contains(kind),
           let index = observationIndex(stateId, window: record.id) {
            switch try index.resolve(target: wanted, element: element) {
            case .element(let resolved, let note):
                element = resolved
                correction = note
            case .point(let px, let py, let note):
                element = nil
                x = px
                y = py
                correction = note
            }
        }
        let target = element.map { describe(element: $0, window: record) } ?? (x != nil && y != nil ? "(\(Int(x!)),\(Int(y!)))" : "")

        func pointOrElement() throws {
            if let element {
                params["element_index"] = element
            } else if let x, let y {
                params["x"] = x
                params["y"] = y
            } else {
                throw HelperError("\(kind) needs element or x/y")
            }
        }

        switch kind {
        case "click", "double_click", "right_click":
            try pointOrElement()
            if kind == "double_click" {
                params["click_count"] = 2
            }
            if kind == "right_click" {
                params["mouse_button"] = "right"
            }
            let verb = ["click": "点击", "double_click": "双击", "right_click": "右键"][kind]!
            return [("click", params, noted("\(verb) \(target)", correction))]
        case "type":
            guard let text = action["text"] as? String else {
                throw HelperError("type needs text")
            }
            var steps: [(method: String, params: [String: Any], label: String)] = []
            if element != nil || (x != nil && y != nil) {
                var click = params
                if let element {
                    click["element_index"] = element
                } else {
                    click["x"] = x!
                    click["y"] = y!
                }
                steps.append(("click", click, noted("点击 \(target)", correction)))
            }
            params["text"] = text
            steps.append(("type_text", params, "输入 “\(compactText(text, limit: 40))”"))
            return steps
        case "key":
            // A literal " " is the space bar.
            guard let key = stringValue(action["key"]) ?? ((action["key"] as? String)?.isEmpty == false ? "space" : nil) else {
                throw HelperError("key needs key")
            }
            params["key"] = key
            if let count = intValue(action["repeat"]) {
                params["repeat"] = count
            }
            return [("press_key", params, "按键 \(key)")]
        case "scroll":
            if element != nil || (x != nil && y != nil) {
                try pointOrElement()
            } else {
                params["coordinate_space"] = "window_points"
                params["x"] = Double(record.bounds.width / 2)
                params["y"] = Double(record.bounds.height / 2)
            }
            let dy = doubleValue(action["dy"]) ?? 0
            let dx = doubleValue(action["dx"]) ?? 0
            params["scrollY"] = dy == 0 && dx == 0 ? 400 : dy
            params["scrollX"] = dx
            return [("scroll", params, noted("滚动 \(target.isEmpty ? record.app : target)", correction))]
        case "set_value":
            guard let element else {
                throw HelperError("set_value needs element")
            }
            params["element_index"] = element
            params["value"] = (action["value"] as? String) ?? (action["text"] as? String) ?? ""
            return [("set_value", params, noted("设置 \(target)", correction))]
        case "secondary":
            guard let element else {
                throw HelperError("secondary needs element")
            }
            guard let name = stringValue(action["name"]) else {
                // Without an action name the model means the context menu.
                params["element_index"] = element
                params["mouse_button"] = "right"
                return [("click", params, noted("右键 \(target)", correction))]
            }
            params["element_index"] = element
            params["action"] = name
            return [("perform_secondary_action", params, noted("\(name) \(target)", correction))]
        case "menu":
            guard let path = stringValue(action["path"]) ?? stringValue(action["target"]) else {
                throw HelperError("menu needs path, e.g. \"文件 ▸ 导出\"")
            }
            params["path"] = path
            return [("menu", params, "菜单 menuitem \"\(path)\"")]
        case "drag":
            guard let x, let y, let toX = doubleValue(action["to_x"]), let toY = doubleValue(action["to_y"]) else {
                throw HelperError("drag needs x, y, to_x, to_y")
            }
            params["from_x"] = x
            params["from_y"] = y
            params["to_x"] = toX
            params["to_y"] = toY
            return [("drag", params, "拖动 (\(Int(x)),\(Int(y))) → (\(Int(toX)),\(Int(toY)))")]
        case "wait":
            guard let until = stringValue(action["until"]) else {
                return [("wait", ["seconds": doubleValue(action["seconds"]) ?? 1], "等待")]
            }
            let gone = boolValue(action["gone"]) ?? false
            params["until"] = until
            params["gone"] = gone
            params["seconds"] = doubleValue(action["seconds"]) ?? 30
            return [("wait", params, "等待 until \(until == "change" || until == "file" ? until : "\"\(until)\"\(gone ? " gone" : "")")")]
        default:
            throw HelperError("Unknown action \"\(kind)\"")
        }
    }

    // MARK: - Observation formatting

    /// Records the observation; returns false when the window looks exactly as last observed.
    @discardableResult
    private func remember(_ observation: Observation) -> Bool {
        note(observation, use: .opened)
        indexes[observation.stateId] = (observation.window.id, OutlineIndex(observation: observation))
        indexOrder.append(observation.stateId)
        while indexOrder.count > 12 {
            indexes.removeValue(forKey: indexOrder.removeFirst())
        }
        let fingerprint = [observation.outline, observation.screenText ?? "", observation.focused ?? "", observation.selectedText ?? ""].joined(separator: "\n")
        let changed = latest[observation.window.id]?.fingerprint != fingerprint
        latest[observation.window.id] = (observation.stateId, observation.outline, fingerprint)
        return changed
    }

    /// The page or document file a window shows, as a resource of this turn.
    private func note(_ observation: Observation, use: SessionResource.Use) {
        if let page = observation.page {
            noteResource(.page, use, title: Agent.pageTitle(observation.window), location: page)
        } else if let document = observation.document {
            noteResource(.file, use, title: (document as NSString).lastPathComponent, location: document)
        }
    }

    /// Reports a page or file the turn worked with, once per location unless its use grows
    /// or its title changes (a page's title arrives as it loads). The workspace is CPU's own.
    private func noteResource(_ kind: SessionResource.Kind, _ use: SessionResource.Use, title: String, location: String) {
        if kind == .file, let workspace = runner?.workspace.path, location.hasPrefix(workspace + "/") {
            return
        }
        let known = notedResources[location]
        let keptUse = known.map { $0.use.weight >= use.weight ? $0.use : use } ?? use
        let keptTitle = title.isEmpty ? (known?.title ?? "") : title
        guard known?.use != keptUse || known?.title != keptTitle else {
            return
        }
        notedResources[location] = (keptUse, keptTitle)
        onEvent(.resource(SessionResource(kind: kind, use: keptUse, title: keptTitle, location: location)))
    }

    /// A browser window's title is its page's title, without the browser's name.
    static func pageTitle(_ window: WindowRecord) -> String {
        window.title.replacingOccurrences(of: #" [-–—] (Google Chrome|Microsoft Edge|Brave|Safari|Firefox|Arc)$"#, with: "", options: .regularExpression)
    }

    /// A file written while the turn ran: created if it is newer than the turn, else changed.
    private func noteWritten(_ path: String, since start: Date) {
        let made = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        noteResource(.file, made >= start.addingTimeInterval(-2) ? .created : .changed, title: (path as NSString).lastPathComponent, location: path)
    }

    private func observationIndex(_ stateId: String?, window: CGWindowID) -> OutlineIndex? {
        guard let id = stateId ?? latest[window]?.stateId, let entry = indexes[id], entry.window == window else {
            return nil
        }
        return entry.index
    }

    private func noted(_ label: String, _ correction: String?) -> String {
        correction.map { "\(label) (\($0))" } ?? label
    }

    /// Text of element `index` from the latest outline of the window, for progress display.
    private func describe(element index: Int, window: WindowRecord) -> String {
        guard let outline = latest[window.id]?.outline else {
            return "[\(index)]"
        }
        let prefix = "[\(index)] "
        for line in outline.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let withoutPosition = trimmed.replacingOccurrences(of: #" @\d+,\d+"#, with: "", options: .regularExpression)
                return compactText(withoutPosition, limit: 60)
            }
        }
        return "[\(index)]"
    }

    /// First block: header (kept forever). Then the outline and an optional screenshot,
    /// which are elided once newer observations exist.
    /// The selection as the model sees it: a long one in part, the whole of it saved.
    private func selectionLine(_ selected: String) -> String {
        let shown = 2_000
        guard selected.count > shown else {
            return "Selected text: \(selected)"
        }
        if savedSelection?.text != selected, let path = LongText.save(selected, name: "selection", in: workspace().workspace) {
            savedSelection = (selected, path)
        }
        let whole = savedSelection.map { "all of it is saved as \($0.path): read_file it or search it with code" } ?? "the rest could not be saved"
        return "Selected text (the first \(shown) of \(selected.count) characters; \(whole)): \(selected.prefix(shown))…"
    }

    private func observationBlocks(_ observation: Observation, header: String) async -> [JSONObject] {
        var header = header
        if let briefing = await briefing(for: observation.window) {
            header += "\n\n" + briefing
        }
        var lines = [Agent.windowLine(observation.window) + " · state_id \(observation.stateId)"]
        if let shot = observation.screenshot {
            lines.append(config.vision
                ? "Screenshot attached: \(shot.record.pixelWidth)x\(shot.record.pixelHeight) px; x/y coordinates are in these pixels."
                : "Positions (@x,y) are pixels of a \(shot.record.pixelWidth)x\(shot.record.pixelHeight) capture; pass them as x/y.")
        } else if let error = observation.screenshotError {
            lines.append("Screenshot unavailable: \(error)")
        }
        if let document = observation.document {
            lines.append("Document: \(document)")
        }
        if let focused = observation.focused {
            lines.append("Focused: \(focused)")
        }
        if let selected = observation.selectedText {
            lines.append(selectionLine(selected))
        }
        if let note = observation.note {
            lines.append("Note: \(note)")
        }
        lines.append(observation.outline.isEmpty ? "(empty outline)" : observation.outline)
        if let screenText = observation.screenText {
            lines.append("The outline is sparse; text recognized on screen (click it with x/y):")
            lines.append(screenText)
        } else if observation.sparse, observation.screenshot == nil {
            if Computer.hasScreenRecording {
                lines.append("WARNING: this window exposes almost nothing to accessibility and could not be captured (see above), so you cannot see its content. Do not click blindly: use keyboard shortcuts and menu commands, or open the app with show: true to see it.")
            } else {
                lines.append("WARNING: this window exposes almost nothing to accessibility and no screenshot could be taken, so you cannot see its content. Do not click blindly. Unless keyboard shortcuts alone can finish the task, stop and tell the user to allow CPU under System Settings → Privacy & Security → Screen Recording.")
            }
        }
        var blocks: [JSONObject] = [Agent.text(header), Agent.text(lines.joined(separator: "\n"))]
        if config.vision, let shot = observation.screenshot {
            blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": shot.mimeType, "data": shot.data.base64EncodedString()]
            ])
        }
        return blocks
    }

    /// Once per app and task: known conventions and the app's menu shortcuts. They go in the
    /// observation header, which stays in the history, so each app is briefed only once.
    private func briefing(for window: WindowRecord) async -> String? {
        guard !briefedPids.contains(window.pid) else {
            return nil
        }
        briefedPids.insert(window.pid)
        let pid = window.pid
        let commands = (try? await engine { _ in BackgroundInput.menuCommands(pid: pid) }) ?? []
        let tips = AppHints.tips(bundleId: window.bundleId)
        guard tips != nil || !commands.isEmpty else {
            return nil
        }
        var lines = ["About \(window.app):"]
        if let tips {
            lines.append(tips)
        }
        if !commands.isEmpty {
            lines.append("Menu shortcuts (they also work while the app stays in the background): " + commands.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the newest `keepObservations` observations verbatim and replaces older ones with
    /// a one-line placeholder. Only the newly stale observation changes each step, so the
    /// cached prefix before it stays valid.
    private func elideOldObservations() {
        while observationRefs.count > config.keepObservations {
            let ref = observationRefs.removeFirst()
            guard ref.message < messages.count, var content = messages[ref.message]["content"] as? [JSONObject],
                  ref.block < content.count else {
                continue
            }
            let placeholder = Agent.text("[\(ref.label) omitted — superseded by a newer observation; its element indexes are stale]")
            if ref.nested {
                var block = content[ref.block]
                if let inner = block["content"] as? [JSONObject], inner.count > 1 {
                    block["content"] = [inner[0], placeholder]
                    content[ref.block] = block
                }
            } else {
                // Inline observation: [header, outline, image?] starting at `block`.
                var end = ref.block + 2
                if end < content.count,
                   content[end]["type"] as? String == "image" || content[end]["text"] as? String == "[older screenshot omitted]" {
                    end += 1
                }
                content.replaceSubrange(ref.block..<min(end, content.count), with: [placeholder])
            }
            messages[ref.message]["content"] = content
        }
        // Screenshots are the heaviest part of a request; only the newest one is useful.
        for ref in observationRefs.dropLast() {
            dropImages(ref)
        }
    }

    private func dropImages(_ ref: ObservationRef) {
        guard ref.message < messages.count, var content = messages[ref.message]["content"] as? [JSONObject],
              ref.block < content.count else {
            return
        }
        let placeholder = Agent.text("[older screenshot omitted]")
        func strip(_ blocks: [JSONObject]) -> [JSONObject] {
            blocks.map { $0["type"] as? String == "image" ? placeholder : $0 }
        }
        if ref.nested {
            var block = content[ref.block]
            guard let inner = block["content"] as? [JSONObject], inner.contains(where: { $0["type"] as? String == "image" }) else {
                return
            }
            block["content"] = strip(inner)
            content[ref.block] = block
        } else {
            // Inline observation: [header, outline, image?] starting at `block`.
            let end = min(ref.block + 3, content.count)
            guard content[ref.block..<end].contains(where: { $0["type"] as? String == "image" }) else {
                return
            }
            content.replaceSubrange(ref.block..<end, with: strip(Array(content[ref.block..<end])))
        }
        messages[ref.message]["content"] = content
    }

    // MARK: - Helpers

    /// Without vision the capture is still useful: OCR turns it into clickable text.
    private func screenshotMode(_ requested: Any?) -> ScreenshotMode {
        if boolValue(requested) == true, config.vision {
            return .always
        }
        return config.screenshotMode
    }

    private func isBlocked(app: String, bundleId: String?) -> Bool {
        let blocked = Set(config.blockedApps.map { $0.lowercased() })
        return blocked.contains(app.lowercased()) || bundleId.map { blocked.contains($0.lowercased()) } == true
    }

    private func checkAllowed(_ record: WindowRecord) throws {
        if isBlocked(app: record.app, bundleId: record.bundleId) {
            throw HelperError("\(record.app) is on the blocked list; do not operate it.")
        }
        if isPrivateTerminal(record) {
            throw HelperError(
                "\(record.app) is a terminal: what is typed there runs as commands in the user's shell, and its contents are private. "
                + "Do not use it unless the user asks for the terminal; check the result another way (open the folder or file) or say what you could not verify."
            )
        }
    }

    /// Terminals run what is typed as shell commands: off limits unless the user asks for one.
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"
    ]

    /// A terminal the user did not ask about: neither read nor typed into.
    private func isPrivateTerminal(_ window: WindowRecord) -> Bool {
        Agent.terminalApps.contains(window.bundleId ?? "") && !Agent.mentionsTerminal(sessionWords, app: window.app)
    }

    static func mentionsTerminal(_ words: String, app: String) -> Bool {
        let words = words.lowercased()
        return (["终端", "命令行", "terminal", "shell", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm"] + [app.lowercased()])
            .contains { words.contains($0) }
    }

    static func windowLine(_ window: WindowRecord) -> String {
        var line = "window \(window.id) · \(window.app)"
        if !window.title.isEmpty {
            line += " · \"\(compactText(window.title, limit: 80))\""
        }
        line += " · \(Int(window.bounds.width))x\(Int(window.bounds.height))"
        if let dialog = window.dialog {
            line += " · \(dialog)"
        }
        return line
    }

    static func text(_ value: String) -> JSONObject {
        ["type": "text", "text": value]
    }

    /// Drops client-side bookkeeping keys before a block goes back to the API.
    static func sanitized(_ block: JSONObject) -> JSONObject {
        block.filter { !$0.key.hasPrefix("_") }
    }
}
