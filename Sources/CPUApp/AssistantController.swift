import AppKit
import AVFoundation
import CPUCore
import Speech
import SwiftUI

/// Borderless floating panel that can take keyboard focus without activating the app, so
/// the user's app stays frontmost (it is usually what the request is about).
final class CommandPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 688, height: 640),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    /// Off while a task runs: clicking the card (to move it) must not take the keyboard
    /// from the app CPU is typing into.
    var acceptsKey = true

    override var canBecomeKey: Bool { acceptsKey }

    // Only the card's shadow margin reaches under the menu bar; keep the card close to it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
    override var canBecomeMain: Bool { false }
}

/// Wires hotkey → speech → agent → task card. One card is one task: while it is open, new
/// words continue the task; closing it ends the task.
final class AssistantController {
    let model = PanelModel()
    private let config: Config
    private let agent: Agent
    private let speech: SpeechInput
    private let speaker: Speaker
    /// The current request came by voice: answer by voice too (config.speakReplies).
    private var spokenRequest = false
    private let panel = CommandPanel()
    private var hotKey: HotKey?
    private let fnTrigger = FnTrigger()
    private var keyMonitor: Any?
    /// Set by AppDelegate to reflect a running task in the menu bar.
    var onRunningChanged: (Bool) -> Void = { _ in }

    /// True while the user holds the hotkey to talk; silence must not end the utterance.
    private var pushToTalk = false
    private var chordPressedAt: Date?
    private var speechAuthorized: Bool?
    private var lastTranscriptChange = Date()
    private var silenceTimer: Timer?
    private var answer: CheckedContinuation<UserReply?, Never>?
    private var started = Date()
    /// The request that started the current task, for "retry".
    private var taskRequest = ""
    /// The history entry this card writes after each turn; nil until the first turn starts.
    private var sessionID: String?
    private var sessionStarted = Date()
    private let history = HistoryWindow()
    /// Time spent waiting for the user's answers this turn, left out of the card's timing.
    private var waited: TimeInterval = 0
    private var askedAt: Date?
    private var onboardingTimer: Timer?
    /// Steps of the demonstration waiting for a skill name.
    private var demonstration: [DemoStep] = []
    /// A spoken task just finished: listen for a follow-up once the result has been read out.
    private var followUpPending = false
    /// Ends a follow-up listen in which nothing was said.
    private var followUpTimer: Timer?
    private static let followUpListenSeconds: TimeInterval = 8
    /// Size of what the panel shows (card or pill), reported by the view.
    private var shownSize: CGSize = .zero
    /// The shown card's top edge, and its middle (centered) or right edge (docked), in screen
    /// coordinates; the panel is sized around the card from here.
    private var anchor: NSPoint?
    /// Set while CPU moves the panel, so that only the user's drags are remembered.
    private var placing = false
    private static let dockKey = "dockTopRight"

    init(config: Config) {
        self.config = config
        agent = Agent(config: config)
        speech = SpeechInput(config: config)
        speaker = Speaker(config: config)

        var actions = PanelActions()
        actions.submit = { [weak self] in self?.submit() }
        actions.close = { [weak self] in self?.close() }
        actions.reply = { [weak self] reply in self?.reply(reply) }
        actions.openResult = { [weak self] in self?.openResult() }
        actions.retry = { [weak self] in self?.retry() }
        actions.dropContext = { [weak self] in self?.dropContext() }
        actions.fixPermission = { [weak self] id in self?.fixPermission(id) }
        actions.runRequest = { [weak self] request in
            self?.spokenRequest = false
            self?.startTask(request)
        }
        actions.nameShortcut = { [weak self] in self?.beginNamingShortcut() }
        actions.dropFiles = { [weak self] urls in self?.attach(urls) }
        actions.removeAttachment = { [weak self] url in self?.detach(url) }
        actions.undo = { [weak self] in self?.undo() }
        actions.startLearning = { [weak self] in self?.startLearning() }
        actions.finishLearning = { [weak self] in self?.finishLearning() }
        actions.cancelLearning = { [weak self] in self?.cancelLearning() }
        actions.toggleListening = { [weak self] in self?.toggleListening() }
        actions.openHistory = { [weak self] in self?.showHistory() }
        actions.stop = { Interrupts.stop() }
        actions.expand = { [weak self] in self?.model.compact = false }
        actions.collapse = { [weak self] in self?.model.compact = true }
        actions.cardFrame = { [weak self] frame in
            guard let self else {
                return
            }
            (self.panel.contentView as? PassthroughHostingView<PanelView>)?.cardFrame = frame
            if frame.size != self.shownSize {
                self.shownSize = frame.size
                self.fit()
            }
        }
        panel.contentView = PassthroughHostingView(rootView: PanelView(model: model, actions: actions))
        // The card floats above everything: while CPU drives the real pointer, its clicks
        // must reach the app underneath, not the card.
        PointerGate.onChange = { [weak self] busy in self?.panel.ignoresMouseEvents = busy }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            self?.panelMoved()
        }

        speech.onPartial = { [weak self] text in
            guard let self else {
                return
            }
            self.lastTranscriptChange = Date()
            if self.model.phase == .running {
                // Talking over a running task: show the words, they become an interjection.
                self.model.status = "你：\(text)"
            } else if text != self.model.input {
                self.model.input = text
            }
        }
        speech.onLevel = { [weak self] level in
            self?.model.level = level
        }
        speech.onFinal = { [weak self] text in
            self?.speechEnded(text)
        }
        speech.onRunningChanged = { [weak self] running in
            self?.model.listening = running
            if !running {
                self?.model.level = 0
            }
        }
        speech.onEndpoint = { [weak self] in
            // The engine heard the sentence end: hands-free turns submit right away.
            guard let self, self.speech.isRunning, !self.pushToTalk else {
                return
            }
            // A pause mid-thought ("用它……", "…现金流的") is not the end: the silence timer
            // ends it if nothing follows. Short answers ("好", "取消") still end at once.
            let words = self.model.input
            let ends = self.model.phase == .asking ? !Endpointing.looksUnfinished(words) : Endpointing.endpointEnds(words)
            guard ends else {
                return
            }
            helperLog(.info, "endpoint after \"\(self.model.input)\"")
            self.speech.stop()
        }
        agent.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
        agent.askUser = { [weak self] request in
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.beginAsking(request, continuation)
                }
            }
        }
        Interrupts.onStop = { [weak self] in
            self?.model.status = "正在停止…"
            self?.resolveAnswer(nil)
        }
        history.onRerun = { [weak self] request in
            self?.run(request: request)
        }
        installKeyMonitor()
    }

    // MARK: - Hotkey

    /// "fn fn" (default): double-tap Fn opens and closes, holding Fn talks. Any other value
    /// is a Carbon chord such as "alt+space". Returns false when that chord is taken.
    func registerHotKey() -> Bool {
        if usesDoubleFn {
            fnTrigger.onDoubleTap = { [weak self] in self?.toggle() }
            fnTrigger.holdEnabled = { [weak self] in self?.canPushToTalk ?? false }
            fnTrigger.onHoldStart = { [weak self] in self?.pushToTalkStarted() }
            fnTrigger.onHoldEnd = { [weak self] in self?.pushToTalkEnded() }
            fnTrigger.start()
            return true
        }
        guard let spec = parseHotKey(config.hotkey) else {
            return false
        }
        hotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers, onPress: { [weak self] in
            self?.chordPressed()
        }, onRelease: { [weak self] in
            self?.chordReleased()
        })
        return hotKey != nil
    }

    var usesDoubleFn: Bool {
        ["fn fn", "fn-fn", "fnfn", "double-fn", "fn"].contains(config.hotkey.lowercased().trimmingCharacters(in: .whitespaces))
    }

    var hotKeyName: String {
        usesDoubleFn ? "Fn Fn" : config.hotkey
    }

    /// Opens or closes the card. Closing never stops a running task: it keeps going and its
    /// result card comes back when it finishes. Only the user dismisses a result.
    func toggle() {
        speaker.stop()
        if model.phase == .learning {
            finishLearning()
            return
        }
        if panel.isVisible {
            close()
        } else {
            open(voice: true)
        }
    }

    /// Menu bar "recent task": open the card and run it as a new task.
    func run(request: String) {
        guard model.phase != .running, model.phase != .asking else {
            return
        }
        if !panel.isVisible || model.phase == .onboarding {
            beginRequest(voice: false)
        }
        spokenRequest = false
        startTask(request)
    }

    /// Menu bar entry: same as the hotkey, but starts with the keyboard.
    func toggleFromMenu() {
        if panel.isVisible {
            close()
        } else {
            open(voice: false)
        }
    }

    private func open(voice: Bool) {
        switch model.phase {
        case .running:
            show(focus: false)
        case .asking:
            show(focus: true)
            if voice, !speech.isRunning {
                startListening()
            }
        case .onboarding:
            show(focus: true)
        default:
            beginRequest(voice: voice)
        }
    }

    private func close() {
        cancelFollowUp()
        speaker.stop()
        if speech.isRunning {
            speech.cancel()
        }
        stopSilenceTimer()
        model.level = 0
        panel.orderOut(nil)
        switch model.phase {
        case .running, .asking:
            // Still working: the card comes back with the result.
            break
        case .onboarding:
            onboardingTimer?.invalidate()
            onboardingTimer = nil
            UserDefaults.standard.set(true, forKey: "onboarded")
            model.phase = .idle
        case .learning:
            Task { [agent] in
                _ = await agent.stopDemonstration()
            }
            model.reset()
            model.phase = .idle
        default:
            model.reset()
            model.phase = .idle
            endSession()
        }
    }

    /// The card's conversation is over: the agent forgets it, and the next turn starts a new
    /// history entry.
    private func endSession() {
        agent.endSession()
        sessionID = nil
    }

    /// Writes this card's whole session (all its turns so far) for the history window.
    private func saveSession() {
        if sessionID == nil {
            sessionID = SessionRecord.id(for: started)
            sessionStarted = started
        }
        guard let sessionID else {
            return
        }
        let session = SessionRecord(id: sessionID, title: model.title, started: sessionStarted, turns: model.turns + [model.currentTurn])
        TaskStore.shared.saveSession(session)
        history.saved(session)
    }

    /// An empty card makes way for the history window; one with a task stays.
    func showHistory() {
        if panel.isVisible, !model.hasTask, model.phase == .idle || model.phase == .listening {
            close()
        }
        history.show()
    }

    /// Holding Fn talks whenever the open card can take words, including over a running task.
    private var canPushToTalk: Bool {
        panel.isVisible && [.idle, .listening, .finished, .failed, .asking, .running].contains(model.phase)
    }

    private func pushToTalkStarted() {
        cancelFollowUp()
        speaker.stop()
        pushToTalk = true
        show(focus: model.phase != .running)
        // Already listening hands-free (after opening or a result): keep the words, hold the end.
        if !speech.isRunning {
            startListening()
        }
    }

    /// The mic button: listen hands-free (it ends after a pause), or finish now.
    private func toggleListening() {
        if speech.isRunning {
            speech.stop()
            return
        }
        cancelFollowUp()
        speaker.stop()
        pushToTalk = false
        show(focus: true)
        startListening()
    }

    /// After a spoken task the card listens again, as it did when it opened: "再发给王宁"
    /// continues the task; silence leaves the card as it is.
    private func listenForFollowUp() {
        guard followUpPending else {
            return
        }
        followUpPending = false
        guard panel.isVisible, model.phase == .finished || model.phase == .failed, !speech.isRunning,
              !model.namingShortcut, !model.namingSkill else {
            return
        }
        pushToTalk = false
        startListening()
        followUpTimer?.invalidate()
        followUpTimer = Timer.scheduledTimer(withTimeInterval: AssistantController.followUpListenSeconds, repeats: false) { [weak self] _ in
            guard let self, self.speech.isRunning, !self.pushToTalk,
                  self.model.input.trimmingCharacters(in: .whitespaces).isEmpty else {
                return
            }
            self.speech.cancel()
            self.stopSilenceTimer()
        }
    }

    private func cancelFollowUp() {
        followUpPending = false
        followUpTimer?.invalidate()
        followUpTimer = nil
    }

    private func pushToTalkEnded() {
        pushToTalk = false
        if speech.isRunning {
            speech.stop()
        }
    }

    /// Carbon chord: press opens and listens (hold for push-to-talk); press again closes.
    private func chordPressed() {
        guard panel.isVisible else {
            chordPressedAt = Date()
            pushToTalk = true
            open(voice: true)
            return
        }
        if speech.isRunning {
            speech.stop()
        } else {
            close()
        }
    }

    private func chordReleased() {
        if let chordPressedAt, Date().timeIntervalSince(chordPressedAt) > 0.4, speech.isRunning {
            speech.stop()
        }
        chordPressedAt = nil
        pushToTalk = false
    }

    // MARK: - Panel

    private func beginRequest(voice: Bool) {
        model.reset()
        model.phase = .idle
        model.docked = false
        model.compact = false
        place()
        model.recents = Array(TaskStore.shared.history.prefix(3))
        model.shortcuts = TaskStore.shared.shortcuts
        endSession()
        // Observe the user's window and warm the connection while they speak.
        agent.prepare()
        show(focus: true)
        if voice {
            startListening()
        }
    }

    private func show(focus: Bool) {
        if !panel.isVisible {
            place()
        }
        panel.acceptsKey = model.phase != .running
        if focus {
            panel.makeKeyAndOrderFront(nil)
            model.focusToken += 1
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Placement

    /// A new request sits near the top in the middle, like Spotlight: the user is looking at
    /// it. Once the task runs, the card moves to the side (as a pill while it works), so the
    /// windows being worked on stay in view; questions and the result open there too.
    private func dock(compact: Bool) {
        model.compact = compact
        if !model.docked {
            model.docked = true
            place()
        }
    }

    /// Moves the card to the default spot for its mode on the current screen.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return
        }
        // A whole session reads in the card: up to most of the screen, leaving room for the
        // title above and the buttons and input below.
        model.resultMaxHeight = max(200, min(560, visible.height - 320))
        if !model.docked {
            anchor = NSPoint(x: visible.midX, y: visible.maxY - visible.height * 0.06)
        } else if let saved = UserDefaults.standard.string(forKey: AssistantController.dockKey).map(NSPointFromString),
                  visible.contains(NSPoint(x: saved.x - 40, y: saved.y - 20)) {
            // Where the user last dragged the docked card.
            anchor = saved
        } else {
            // Top right, under the menu bar, where the CPU menu-bar icon is.
            anchor = NSPoint(x: visible.maxX - 10, y: visible.maxY - 8)
        }
        fit()
    }

    /// Sizes the panel to what it shows (no invisible margin to block clicks), keeping the card
    /// pinned at its anchor.
    private func fit() {
        guard let anchor else {
            return
        }
        let margin = PanelView.margin
        let size = shownSize == .zero ? CGSize(width: model.docked ? PanelView.dockedWidth : 640, height: 80) : shownSize
        let width = size.width + 2 * margin
        let height = size.height + 2 * margin
        let x = model.docked ? anchor.x + margin - width : anchor.x - width / 2
        let frame = NSRect(x: x.rounded(), y: (anchor.y + margin - height).rounded(), width: width, height: height)
        guard frame != panel.frame else {
            return
        }
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
    }

    /// The user dragged the card: keep it there, and remember where they like the docked card.
    private func panelMoved() {
        guard !placing, panel.isVisible else {
            return
        }
        let margin = PanelView.margin
        let frame = panel.frame
        if model.docked {
            let point = NSPoint(x: frame.maxX - margin, y: frame.maxY - margin)
            anchor = point
            UserDefaults.standard.set(NSStringFromPoint(point), forKey: AssistantController.dockKey)
        } else {
            anchor = NSPoint(x: frame.midX, y: frame.maxY - margin)
        }
    }

    // MARK: - Speech

    private func startListening() {
        guard speechAuthorized != false else {
            model.status = "语音不可用，请直接输入。"
            return
        }
        guard speechAuthorized == true else {
            speech.authorize { [weak self] error in
                guard let self else {
                    return
                }
                self.speechAuthorized = error == nil
                if let error {
                    self.model.status = error
                    if self.model.phase == .listening {
                        self.model.phase = .idle
                    }
                } else {
                    self.startListening()
                }
            }
            return
        }
        do {
            try speech.start()
            helperLog(.info, "listening (\(pushToTalk ? "push-to-talk" : "hands-free"), \(model.phase))")
            if model.phase == .idle {
                model.phase = .listening
            }
            lastTranscriptChange = Date()
            startSilenceTimer()
        } catch {
            model.status = "无法启动语音识别：\(error.localizedDescription)"
            if model.phase == .listening {
                model.phase = .idle
            }
        }
    }

    /// Hands-free mode: submit after a pause once something was said.
    private func startSilenceTimer() {
        stopSilenceTimer()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.speech.isRunning, !self.pushToTalk else {
                return
            }
            let said = !self.model.input.trimmingCharacters(in: .whitespaces).isEmpty || self.model.status.hasPrefix("你：")
            let pause = Endpointing.pause(after: self.model.input, base: self.config.silenceSubmitSeconds)
            if said, Date().timeIntervalSince(self.lastTranscriptChange) > pause {
                helperLog(.info, "silence after \"\(self.model.input)\"")
                self.speech.stop()
            }
        }
    }

    private func stopSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func speechEnded(_ text: String) {
        stopSilenceTimer()
        model.level = 0
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        helperLog(.info, "heard \(words.count) characters (\(model.phase))")
        if model.phase == .running {
            model.status = ""
            if !words.isEmpty {
                interject(words)
            }
            return
        }
        if !words.isEmpty {
            model.input = words
        }
        if model.phase == .listening {
            model.phase = .idle
        }
        if !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submit(spoken: true)
        }
    }

    /// Typing while listening switches to keyboard input; Escape stops or closes.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else {
                return event
            }
            // While listening, a key another program posted is not the user typing: Gemini
            // answers the same Fn double-tap with one, which used to end listening at once.
            if self.speech.isRunning, let source = event.postingProcess {
                helperLog(.info, "dropped key \(event.keyCode) posted by pid \(source) while listening")
                return nil
            }
            if event.keyCode == 53 {
                self.escapePressed()
                return nil
            }
            if self.speech.isRunning, event.keyCode != 36 {
                helperLog(.info, "key \(event.keyCode) typed: listening ends")
                self.speech.cancel()
                self.stopSilenceTimer()
                self.model.level = 0
                if self.model.phase == .listening {
                    self.model.phase = .idle
                }
            }
            return event
        }
    }

    private func escapePressed() {
        if speaker.isSpeaking {
            cancelFollowUp()
            speaker.stop()
            return
        }
        if speech.isRunning, [.finished, .failed].contains(model.phase) {
            // Stop listening for a follow-up; the result stays.
            cancelFollowUp()
            speech.cancel()
            stopSilenceTimer()
            return
        }
        switch model.phase {
        case .running, .asking:
            Interrupts.stop()
        case .listening:
            speech.cancel()
            stopSilenceTimer()
            model.phase = .idle
        case .learning:
            cancelLearning()
        default:
            close()
        }
    }

    // MARK: - Tasks

    /// Enter or end of speech: a new task, a follow-up, or an answer, depending on the card.
    private func submit(spoken: Bool = false) {
        let text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelFollowUp()
        speaker.stop()
        if model.phase != .asking {
            spokenRequest = spoken
        }
        if speech.isRunning {
            speech.cancel()
        }
        stopSilenceTimer()
        switch model.phase {
        case .asking:
            answerWithWords(text)
        case .finished, .failed:
            guard !text.isEmpty else {
                return
            }
            model.input = ""
            if model.namingSkill {
                learnSkill(named: text)
                return
            }
            if model.namingShortcut {
                TaskStore.shared.saveShortcut(name: text, request: taskRequest)
                model.namingShortcut = false
                model.footer = "已存为快捷说法「\(text)」"
                return
            }
            model.beginTurn(text)
            run(text, followUp: true)
        case .idle, .listening:
            guard !text.isEmpty else {
                return
            }
            model.input = ""
            if AssistantController.matches(text, AssistantController.teachWords) {
                startLearning()
                return
            }
            startTask(text)
        case .running, .onboarding, .learning:
            break
        }
    }

    /// A new task on this card. A shortcut's name or "再做一次" stands for its full request.
    private func startTask(_ words: String) {
        if model.phase == .finished || model.phase == .failed {
            // Starting over from a finished card: a new task, not a follow-up.
            let files = model.attachments
            model.reset()
            endSession()
            attach(files)
        }
        let request = TaskStore.shared.expand(words) ?? words
        taskRequest = request
        model.title = request
        model.prompt = words
        sessionID = SessionRecord.id(for: Date())
        sessionStarted = Date()
        run(request, followUp: false)
    }

    private func beginNamingShortcut() {
        model.namingShortcut = true
        show(focus: true)
    }

    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        agent.attach(urls)
        model.attachments += urls.filter { !model.attachments.contains($0) }
        show(focus: true)
    }

    private func detach(_ url: URL) {
        agent.detach(url)
        model.attachments.removeAll { $0 == url }
    }

    private func run(_ text: String, followUp: Bool) {
        model.reply = ""
        model.stepsExpanded = false
        model.resultApp = nil
        model.attachments = []
        model.namingShortcut = false
        model.status = "思考中…"
        model.phase = .running
        panel.acceptsKey = false
        dock(compact: true)
        onRunningChanged(true)
        started = Date()
        waited = 0
        Task { [agent] in
            await agent.run(text, followUp: followUp)
        }
    }

    private func interject(_ words: String) {
        agent.interject(words)
        model.addStep(words, fromUser: true)
    }

    private func retry() {
        guard !taskRequest.isEmpty else {
            return
        }
        let request = taskRequest
        let title = model.title
        model.reset()
        model.title = title
        model.prompt = request
        endSession()
        run(request, followUp: false)
    }

    // MARK: - Learning by demonstration

    /// Menu bar entry.
    func teach() {
        if !panel.isVisible {
            beginRequest(voice: false)
        }
        startLearning()
    }

    /// "看我做一遍": watch the user do the task in their own apps, step by step on the card.
    private func startLearning() {
        guard model.phase != .running, model.phase != .asking, model.phase != .learning else {
            return
        }
        speaker.stop()
        if speech.isRunning {
            speech.cancel()
        }
        stopSilenceTimer()
        model.reset()
        endSession()
        model.title = "正在学习：请在你的应用里做一遍"
        model.phase = .learning
        // Give the keyboard back to the user's app: the card stays visible but not key.
        panel.orderOut(nil)
        model.docked = true
        model.compact = false
        place()
        panel.acceptsKey = true
        panel.orderFrontRegardless()
        agent.startDemonstration { [weak self] steps in
            self?.model.steps = steps.map { PanelModel.Step(text: $0.words) }
        }
    }

    private func finishLearning() {
        guard model.phase == .learning else {
            return
        }
        model.status = "整理中…"
        Task { [agent] in
            let steps = await agent.stopDemonstration()
            await MainActor.run {
                self.demonstration = steps
                self.model.status = ""
                if steps.isEmpty {
                    self.model.reply = "没有记录到操作。可以再说一次“看我做一遍”重新开始。"
                    self.model.phase = .failed
                } else {
                    self.model.title = "学会一个新技能"
                    self.model.reply = "记下了 \(steps.count) 步。给这个技能起个名字，以后说出名字我就照做；说“用它给…”还能换参数。"
                    self.model.namingSkill = true
                    self.model.phase = .finished
                }
                self.show(focus: true)
            }
        }
    }

    private func cancelLearning() {
        Task { [agent] in
            _ = await agent.stopDemonstration()
        }
        model.reset()
        model.phase = .idle
        close()
    }

    private func learnSkill(named name: String) {
        let steps = demonstration
        model.namingSkill = false
        model.reply = ""
        model.status = "正在整理成技能…"
        model.phase = .running
        Task { [agent] in
            let skill = await agent.learnSkill(name: name, steps: steps)
            await MainActor.run {
                self.model.status = ""
                self.model.title = "已学会「\(name)」"
                self.model.reply = skill.map { "\($0.summary)\n以后说「\(name)」就能照做。" } ?? "保存失败，请再试一次。"
                self.model.phase = skill == nil ? .failed : .finished
                self.demonstration = []
                self.model.shortcuts = TaskStore.shared.shortcuts
            }
        }
    }

    private func undo() {
        guard agent.canUndo, model.phase == .finished || model.phase == .failed else {
            return
        }
        speaker.stop()
        model.beginTurn("撤销")
        model.canUndo = false
        model.status = "正在撤销…"
        model.phase = .running
        panel.acceptsKey = false
        dock(compact: true)
        onRunningChanged(true)
        started = Date()
        waited = 0
        Task { [agent] in
            await agent.undo()
        }
    }

    private func openResult() {
        if let window = agent.resultWindow {
            agent.reveal(window)
        }
    }

    private func dropContext() {
        agent.includeContext = false
        model.contextIncluded = false
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .status(let text):
            if !model.status.hasPrefix("你：") {
                model.status = text
            }
        case .thinking, .text, .metrics:
            break
        case .goal(let title):
            if model.hasTask {
                model.title = title
            }
        case .context(let summary):
            if !model.hasTask {
                model.context = summary
            }
        case .detail(let text):
            model.addDetail(text)
        case .resource(let resource):
            SessionResource.merge(resource, into: &model.resources)
        case .step(let text):
            model.addStep(text)
            if !model.status.hasPrefix("你：") {
                model.status = ""
            }
        case .finished(let text), .failed(let text):
            let failed: Bool
            if case .failed = event {
                failed = true
            } else {
                failed = false
            }
            resolveAnswer(nil)
            model.request = nil
            model.reply = text
            model.status = ""
            model.input = ""
            model.timing = String(format: "%.1f 秒", Date().timeIntervalSince(started) - waited)
            model.footer = ""
            model.resultApp = agent.resultWindow?.app
            model.canUndo = agent.canUndo
            model.phase = failed ? .failed : .finished
            saveSession()
            dock(compact: false)
            if !taskRequest.isEmpty, text != "已停止。" {
                TaskStore.shared.record(TaskRecord(request: taskRequest, title: model.title, result: text, succeeded: !failed, date: Date()))
            }
            panel.acceptsKey = true
            onRunningChanged(false)
            // The result stays until the user closes it; if they hid the card while the task
            // ran, bring the result back without taking focus.
            let wasVisible = panel.isVisible
            if !panel.isVisible {
                show(focus: false)
            }
            // A spoken task: read the result, then listen for a follow-up as when the card opened
            // (not when the result popped up over whatever the user is doing now).
            followUpPending = config.listenAfterResult && spokenRequest && wasVisible && text != "已停止。"
            if shouldSpeak, text != "已停止。" {
                speaker.speak(text) { [weak self] in self?.listenForFollowUp() }
            } else {
                listenForFollowUp()
            }
        }
    }

    // MARK: - Questions, confirmations, hand-overs

    private func beginAsking(_ request: UserRequest, _ continuation: CheckedContinuation<UserReply?, Never>) {
        resolveAnswer(nil)
        answer = continuation
        askedAt = Date()
        model.request = request
        if case .edits(_, let edits) = request {
            model.editChoices = Array(repeating: true, count: edits.count)
        }
        model.input = ""
        model.status = ""
        model.phase = .asking
        panel.acceptsKey = true
        dock(compact: false)
        show(focus: true)
        guard shouldSpeak else {
            NSSound(named: "Tink")?.play()
            startListening()
            return
        }
        // Ask out loud, then listen: the microphone must not hear CPU's own voice.
        let prompt: String
        switch request {
        case .question(let question, _):
            prompt = question
        case .confirm(let action, let details):
            prompt = "\(action)：\(details)。确认吗？"
        case .handOver(let instruction):
            prompt = instruction
        case .edits(let summary, let edits):
            prompt = "我有 \(edits.count) 处修改建议：\(summary)。要应用吗？"
        }
        speaker.speak(prompt) { [weak self] in
            guard let self, self.model.phase == .asking, !self.speech.isRunning else {
                return
            }
            self.startListening()
        }
    }

    private var shouldSpeak: Bool {
        config.speakReplies == "always" || (config.speakReplies == "voice" && spokenRequest)
    }

    /// Typed or spoken answer: for a confirmation, "发吧/确认" approves and "取消/算了" declines;
    /// anything else goes to the model as a correction. An empty Enter approves or finishes.
    private func answerWithWords(_ text: String) {
        switch model.request {
        case .confirm:
            if text.isEmpty || AssistantController.matches(text, AssistantController.yesWords) {
                reply(.confirmed)
            } else if AssistantController.matches(text, AssistantController.noWords) {
                reply(.cancelled)
            } else {
                reply(.text(text))
            }
        case .handOver:
            if text.isEmpty || AssistantController.matches(text, AssistantController.doneWords) {
                reply(.done)
            } else if AssistantController.matches(text, AssistantController.noWords) {
                reply(.cancelled)
            } else {
                reply(.text(text))
            }
        case .question:
            if !text.isEmpty {
                reply(.text(text))
            }
        case .edits:
            if text.isEmpty || AssistantController.matches(text, AssistantController.yesWords) {
                reply(.accepted(model.chosenEdits))
            } else if AssistantController.matches(text, AssistantController.noWords) {
                reply(.cancelled)
            } else {
                reply(.text(text))
            }
        case nil:
            break
        }
    }

    private static let teachWords = ["看我做一遍", "看我做", "我来示范", "我示范一下", "示范一下", "学一下", "看我操作", "跟我学", "watchme", "learnthis"]
    private static let yesWords = ["确认", "确定", "发吧", "发送", "发", "好", "好的", "可以", "行", "是", "对", "没问题", "继续", "ok", "yes"]
    private static let noWords = ["取消", "不要", "不用", "算了", "别", "不", "不行", "no", "cancel"]
    private static let doneWords = ["好了", "完成", "完成了", "搞定", "继续", "已完成", "ok", "done"]

    private static func matches(_ text: String, _ words: [String]) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return words.contains(normalized) || words.contains(normalized.replacingOccurrences(of: " ", with: ""))
    }

    private func reply(_ reply: UserReply) {
        if speech.isRunning {
            speech.cancel()
        }
        stopSilenceTimer()
        switch reply {
        case .confirmed:
            model.addStep("确认", fromUser: true)
        case .cancelled:
            model.addStep("取消", fromUser: true)
        case .done:
            model.addStep("已完成", fromUser: true)
        case .text(let text):
            model.addStep(text, fromUser: true)
        case .accepted(let numbers):
            model.addStep(numbers.count == model.editChoices.count ? "全部应用" : "应用 \(numbers.count)/\(model.editChoices.count) 处修改", fromUser: true)
        }
        model.request = nil
        model.input = ""
        model.status = "思考中…"
        model.phase = .running
        panel.acceptsKey = false
        dock(compact: true)
        resolveAnswer(reply)
    }

    private func resolveAnswer(_ reply: UserReply?) {
        guard let continuation = answer else {
            return
        }
        answer = nil
        if let askedAt {
            waited += Date().timeIntervalSince(askedAt)
            self.askedAt = nil
        }
        continuation.resume(returning: reply)
    }

    // MARK: - Onboarding

    /// First launch, or a missing permission: show what CPU needs, live-updating.
    func showOnboardingIfNeeded() {
        refreshPermissions()
        let missing = model.permissions.contains { $0.granted == false && ($0.id == "accessibility" || $0.id == "screen") }
        guard missing || !UserDefaults.standard.bool(forKey: "onboarded") else {
            return
        }
        model.reset()
        model.phase = .onboarding
        model.docked = false
        model.compact = false
        place()
        show(focus: true)
        onboardingTimer?.invalidate()
        onboardingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }

    private func refreshPermissions() {
        let usesApple = DoubaoCredentials.load() == nil || config.voice == "apple"
        let speechGranted: Bool? = {
            // Doubao needs only the microphone; Apple's engine also needs speech recognition.
            let speech = usesApple ? SFSpeechRecognizer.authorizationStatus() : .authorized
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            if speech == .authorized, microphone == .authorized {
                return true
            }
            return speech == .notDetermined || microphone == .notDetermined ? nil : false
        }()
        // 0: the 🌐 key does nothing. Anything else (input source, emoji, dictation) fights Fn Fn.
        let fnUsage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        var permissions = [
            PanelModel.Permission(id: "accessibility", name: "辅助功能", detail: "读取界面、在后台操作应用。", granted: Computer.hasAccessibility, action: "去开启"),
            PanelModel.Permission(id: "screen", name: "屏幕录制", detail: "截图和识别文字，用于微信这类自绘界面。", granted: Computer.hasScreenRecording, action: "去开启"),
            PanelModel.Permission(
                id: "speech", name: DoubaoCredentials.load() == nil || config.voice == "apple" ? "麦克风与语音识别" : "麦克风",
                detail: DoubaoCredentials.load() == nil || config.voice == "apple" ? "用语音下达任务；识别在本机完成。" : "用语音下达任务（豆包语音识别）。",
                granted: speechGranted, action: "允许"
            )
        ]
        if usesDoubleFn {
            permissions.append(PanelModel.Permission(
                id: "fnkey", name: "Fn 键",
                detail: "「按下 🌐 键时」请设为「不执行任何操作」，听写快捷键不要用「按两下 🌐」，否则会和 Fn Fn 冲突。",
                granted: fnUsage == 0 ? true : (fnUsage == nil ? nil : false),
                action: "打开键盘设置"
            ))
        }
        model.permissions = permissions
    }

    private func fixPermission(_ id: String) {
        switch id {
        case "accessibility":
            Computer.requestAccessibility()
        case "screen":
            Computer.requestScreenRecording()
        case "speech":
            speech.authorize { [weak self] error in
                self?.speechAuthorized = error == nil
                self?.refreshPermissions()
            }
        case "fnkey":
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}
