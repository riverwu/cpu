import AppKit
import CPUCore
import SwiftUI

final class PanelModel: ObservableObject {
    enum Phase {
        case idle, listening, running, asking, finished, failed, onboarding, learning
    }

    struct Step: Identifiable {
        let id: Int
        let text: String
        /// Words the user added (follow-ups, answers, interjections).
        let fromUser: Bool
        /// The code a step ran, shown when the finished steps are opened.
        var detail: String?
    }

    struct Permission: Identifiable {
        let id: String
        let name: String
        let detail: String
        /// nil: cannot be checked, only advised.
        let granted: Bool?
        let action: String
    }

    @Published var phase: Phase = .idle
    @Published var input = ""
    /// The task card's title: the request at first, then the model's rewrite.
    @Published var title = ""
    @Published var context: ContextSummary?
    @Published var contextIncluded = true
    @Published var steps: [Step] = []
    @Published var status = ""
    @Published var reply = ""
    @Published var footer = ""
    @Published var level: Float = 0
    /// The microphone is open, whatever the phase (a follow-up, an answer, an interjection).
    @Published var listening = false
    /// The finished task's steps are folded into one line until the user opens them.
    @Published var stepsExpanded = false
    /// While a task runs the card shrinks to a pill, out of the way of the work.
    @Published var compact = false
    /// At the side of the screen (a task is underway or done) rather than in the middle for input.
    @Published var docked = false
    /// Tallest the result area grows before it scrolls (depends on the screen).
    @Published var resultMaxHeight: CGFloat = 340
    /// Which suggested edits are ticked, while the card shows a proposal.
    @Published var editChoices: [Bool] = []

    var isProposingEdits: Bool {
        if phase == .asking, case .edits = request {
            return true
        }
        return false
    }

    /// The ticked edits, numbered from 1.
    var chosenEdits: [Int] {
        editChoices.enumerated().filter(\.element).map { $0.offset + 1 }
    }
    /// Bumped to move keyboard focus into the visible text field.
    @Published var focusToken = 0
    @Published var request: UserRequest?
    /// App that shows the result, for the "open" button.
    @Published var resultApp: String?
    @Published var permissions: [Permission] = []
    /// Recent tasks and named shortcuts, offered on the empty card.
    @Published var recents: [TaskRecord] = []
    @Published var shortcuts: [Shortcut] = []
    /// Files dragged onto the card for the next request.
    @Published var attachments: [URL] = []
    /// The input names the finished task as a shortcut instead of continuing it.
    @Published var namingShortcut = false
    @Published var dropTargeted = false
    /// The finished task changed something 撤销 can revert.
    @Published var canUndo = false
    /// The input names the skill just demonstrated.
    @Published var namingSkill = false

    var hasTask: Bool {
        !title.isEmpty
    }

    func reset() {
        input = ""
        title = ""
        context = nil
        contextIncluded = true
        steps = []
        status = ""
        reply = ""
        footer = ""
        request = nil
        resultApp = nil
        attachments = []
        namingShortcut = false
        canUndo = false
        namingSkill = false
        stepsExpanded = false
    }

    func addStep(_ text: String, fromUser: Bool = false) {
        steps.append(Step(id: steps.count, text: text, fromUser: fromUser))
    }

    func addDetail(_ text: String) {
        guard !steps.isEmpty else {
            return
        }
        steps[steps.count - 1].detail = text
    }
}

/// What the card's buttons do; the controller fills these in.
struct PanelActions {
    var submit: () -> Void = {}
    var close: () -> Void = {}
    var reply: (UserReply) -> Void = { _ in }
    var openResult: () -> Void = {}
    var retry: () -> Void = {}
    var dropContext: () -> Void = {}
    var fixPermission: (String) -> Void = { _ in }
    /// Runs a recent task or a shortcut's request.
    var runRequest: (String) -> Void = { _ in }
    var nameShortcut: () -> Void = {}
    var dropFiles: ([URL]) -> Void = { _ in }
    var removeAttachment: (URL) -> Void = { _ in }
    var undo: () -> Void = {}
    var startLearning: () -> Void = {}
    var finishLearning: () -> Void = {}
    var cancelLearning: () -> Void = {}
    /// The card's frame in the hosting view, which decides where clicks fall through.
    var cardFrame: (CGRect) -> Void = { _ in }
    /// The mic button: start listening, or finish what is being said.
    var toggleListening: () -> Void = {}
    var stop: () -> Void = {}
    /// Pill ⇄ card while a task runs.
    var expand: () -> Void = {}
    var collapse: () -> Void = {}
}

/// Hosting view for a card floating in a larger transparent window: clicks on the card go
/// to SwiftUI, clicks around it fall through to the windows below.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// The card's frame in this view's top-left coordinates, reported by the view.
    var cardFrame: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI buttons and text are not views of their own: the hosting view answers for
        // them and for the transparent margin alike, so only the card's geometry tells them apart.
        var local = convert(point, from: superview)
        if !isFlipped {
            local.y = bounds.height - local.y
        }
        guard cardFrame.contains(local) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }

    // The panel does not activate CPU: a click on a button should act at once, not just focus the card.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Dragging the card anywhere outside its controls moves the window.
private struct WindowDragArea: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

/// The task card: one card, one focus. Its content follows the task's phase. While a task
/// runs it is a pill at the side of the screen; the window is sized to whichever is shown.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @FocusState private var fieldFocused: Bool

    /// Room around the card for its shadow; the window is the card plus this margin.
    static let margin: CGFloat = 20

    var body: some View {
        Group {
            if model.compact {
                pill
            } else {
                card
            }
        }
        .modifier(WindowDragArea())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actions.cardFrame($0) }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(PanelView.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.focusToken) { _, _ in
            fieldFocused = true
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.phase == .onboarding {
                Divider().opacity(0.5)
                onboarding
            } else if model.hasTask {
                Divider().opacity(0.5)
                taskBody
            } else {
                starter
            }
        }
        .frame(width: model.docked ? 460 : 640, alignment: .topLeading)
        // Its own height, whatever the window's: the window is resized to fit the card.
        .fixedSize(horizontal: false, vertical: true)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: model.dropTargeted ? 2 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            loadFiles(providers)
            return true
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    // MARK: - Pill

    /// A running task, small and to the side: what it is doing now, and a way to stop it.
    /// Click to see the whole card.
    private var pill: some View {
        HStack(spacing: 10) {
            PhaseIndicator(phase: model.phase, level: model.level, listening: model.listening)
                .scaleEffect(0.85)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title.isEmpty ? "CPU" : model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(pillDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(model.status.hasPrefix("你：") ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button(action: actions.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.07), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("停止（Esc）")
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: actions.expand)
        .help("点击查看过程")
    }

    /// The step just done, or what is happening when that says more (retrying, stopping, the
    /// user's words).
    private var pillDetail: String {
        let status = model.status
        if !status.isEmpty, status != "思考中…" || model.steps.isEmpty {
            return status
        }
        if let last = model.steps.last {
            return last.fromUser ? "你：\(last.text)" : "✓ \(last.text)"
        }
        return "思考中…"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PhaseIndicator(phase: model.phase, level: model.level, listening: model.listening)
            if model.phase == .onboarding {
                Text("欢迎使用 CPU")
                    .font(.system(size: 17, weight: .semibold))
            } else if model.hasTask {
                Text(model.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                inputField(model.listening ? "正在听…" : "说出你要的结果，或直接输入…", size: 20)
                micButton
            }
            Spacer(minLength: 0)
            if model.phase == .running {
                ProgressView().controlSize(.small)
                Button(action: actions.collapse) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起，只显示进度")
            } else {
                Button(action: actions.close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭（Fn Fn 或 Esc）")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Talk without holding Fn: tap to listen, tap again to finish.
    private var micButton: some View {
        Button(action: actions.toggleListening) {
            Image(systemName: model.listening ? "waveform" : "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.listening ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(model.listening ? 0.1 : 0.05), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.listening ? "说完了" : "点一下说话（也可以按住 Fn 说）")
    }

    private func inputField(_ placeholder: String, size: CGFloat) -> some View {
        TextField(placeholder, text: $model.input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .lineLimit(1...4)
            .focused($fieldFocused)
            .onSubmit(actions.submit)
    }

    /// The empty card: what CPU sees, attached files, shortcuts and recent tasks.
    @ViewBuilder
    private var starter: some View {
        let hasContext = model.context != nil && model.contextIncluded
        if hasContext || !model.attachments.isEmpty || !model.shortcuts.isEmpty || !model.recents.isEmpty || model.phase == .idle {
            VStack(alignment: .leading, spacing: 8) {
                if hasContext || !model.attachments.isEmpty {
                    HStack(spacing: 6) {
                        if let context = model.context, model.contextIncluded {
                            capsule(context)
                        }
                        attachmentChips
                    }
                }
                if !model.shortcuts.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                        ForEach(model.shortcuts.prefix(6), id: \.name) { shortcut in
                            Button(shortcut.name) { actions.runRequest(shortcut.request) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .help(shortcut.request)
                        }
                    }
                }
                Button(action: actions.startLearning) {
                    Label("看我做一遍：示范一个任务，教会 CPU", systemImage: "record.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if !model.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.recents.prefix(3).enumerated()), id: \.offset) { _, record in
                            Button {
                                actions.runRequest(record.request)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                                    Text(record.title.isEmpty ? record.request : record.title).lineLimit(1)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("再做一次：\(record.request)")
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var attachmentChips: some View {
        ForEach(model.attachments, id: \.self) { url in
            HStack(spacing: 4) {
                Image(systemName: "doc")
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Button {
                    actions.removeAttachment(url)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func loadFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else {
                    return
                }
                DispatchQueue.main.async {
                    actions.dropFiles([url])
                }
            }
        }
    }

    private func capsule(_ context: ContextSummary) -> some View {
        var text = context.app
        if !context.title.isEmpty {
            text += " ·「\(context.title)」"
        }
        if let selected = context.selectedText {
            text += " · 选中 \(selected.count) 字"
        }
        if !context.selectedItems.isEmpty {
            text += " · 选中 \(context.selectedItems.count) 项"
        }
        return HStack(spacing: 6) {
            Image(systemName: "paperclip")
            Text(text).lineLimit(1).truncationMode(.middle)
            Button(action: actions.dropContext) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("不要把这个窗口发给模型")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    // MARK: - Task

    private var taskBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.steps.isEmpty {
                if model.phase == .finished || model.phase == .failed || model.isProposingEdits {
                    foldedSteps
                } else {
                    // While it works, the latest steps show what is happening.
                    VStack(alignment: .leading, spacing: 4) {
                        if model.steps.count > 6 {
                            Text("… 前面还有 \(model.steps.count - 6) 步")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(model.steps.suffix(6)) { step in
                            stepLine(step)
                        }
                    }
                }
            }
            switch model.phase {
            case .running:
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text("Esc 停止 · Fn Fn 收起 · 按住 Fn 插话")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            case .asking:
                asking
            case .finished, .failed:
                result
            case .learning:
                HStack(spacing: 8) {
                    Button("学好了", action: actions.finishLearning)
                        .buttonStyle(.borderedProminent)
                    Button("取消", action: actions.cancelLearning)
                    Spacer()
                    Text("照常操作即可 · 做完连按两次 Fn")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func stepLine(_ step: PanelModel.Step) -> some View {
        Text(step.fromUser ? "你：\(step.text)" : "✓ \(step.text)")
            .font(.system(size: 13))
            .foregroundStyle(step.fromUser ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Done: the steps fold into one line that opens on click, so the result comes first.
    private var foldedSteps: some View {
        let actions = model.steps.filter { !$0.fromUser }.count
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    model.stepsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(model.stepsExpanded ? 90 : 0))
                    Text(actions == 0 ? "过程" : "做了 \(actions) 步操作")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.stepsExpanded {
                FitScroll(maxHeight: 240) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.steps) { step in
                            stepLine(step)
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var asking: some View {
        switch model.request {
        case .question(let question, let options):
            MarkdownView.inline(question)
                .font(.system(size: 15, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if !options.isEmpty {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button(option) { actions.reply(.text(option)) }
                    }
                }
            }
            inputField("说出或输入你的回答…", size: 15)
        case .confirm(let action, let details):
            Label(action, systemImage: "exclamationmark.bubble")
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                Text(details)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Button("确认") { actions.reply(.confirmed) }
                    .buttonStyle(.borderedProminent)
                Button("取消") { actions.reply(.cancelled) }
                Spacer()
                Text("回车确认 · 或说出修改")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            inputField("要修改什么？", size: 13)
        case .handOver(let instruction):
            Label(instruction, systemImage: "hand.raised")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("我已完成，继续") { actions.reply(.done) }
                    .buttonStyle(.borderedProminent)
                Button("不做了") { actions.reply(.cancelled) }
            }
        case .edits(let summary, let edits):
            editProposal(summary: summary, edits: edits)
        case nil:
            EmptyView()
        }
    }

    /// Suggested changes, each with a tick box: original struck through, the new text below.
    @ViewBuilder
    private func editProposal(summary: String, edits: [ProposedEdit]) -> some View {
        Label(summary, systemImage: "pencil.line")
            .font(.system(size: 15, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
        FitScroll(maxHeight: model.resultMaxHeight) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(edits.enumerated()), id: \.offset) { index, edit in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { index < model.editChoices.count && model.editChoices[index] },
                            set: { if index < model.editChoices.count { model.editChoices[index] = $0 } }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(edit.original)
                                .strikethrough(color: .red.opacity(0.6))
                                .foregroundStyle(.secondary)
                            Text(edit.replacement)
                            if !edit.reason.isEmpty {
                                Text(edit.reason)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(index < model.editChoices.count && model.editChoices[index] ? 1 : 0.45)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
        HStack(spacing: 8) {
            Button(model.chosenEdits.count == edits.count ? "全部应用" : "应用 \(model.chosenEdits.count) 处") {
                actions.reply(.accepted(model.chosenEdits))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.chosenEdits.isEmpty)
            Button("不改了") { actions.reply(.cancelled) }
            Spacer()
            Text("回车应用 · 或说出调整")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        inputField("要怎么调整？", size: 13)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Long replies (tables, lists) scroll inside the card instead of stretching it.
            FitScroll(maxHeight: model.resultMaxHeight) {
                MarkdownView(text: model.reply, size: 14, color: model.phase == .failed ? .red : .primary)
                    .padding(.trailing, 6)
            }
            HStack(spacing: 8) {
                if let app = model.resultApp {
                    Button("打开\(app)", action: actions.openResult)
                }
                if model.canUndo {
                    Button("撤销", action: actions.undo)
                        .help("把这个任务改动的内容恢复原样")
                }
                if model.phase == .failed {
                    Button("重试", action: actions.retry)
                } else if !model.namingShortcut, !model.namingSkill {
                    Button("存为快捷说法", action: actions.nameShortcut)
                        .help("给这个任务起个名字，以后说出名字就能再做一次")
                }
                Spacer()
                Text(model.footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if !model.attachments.isEmpty {
                HStack(spacing: 6) { attachmentChips }
            }
            HStack(spacing: 8) {
                inputField(
                    model.namingSkill ? "给这个技能起个名字，比如“发周报”，回车保存"
                        : model.namingShortcut ? "给它起个名字，比如“日报”，回车保存"
                        : model.listening ? "正在听…说完会自动继续" : "说话或输入，继续这个任务…",
                    size: 14
                )
                micButton
            }
        }
    }

    // MARK: - Onboarding

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CPU 需要这些权限，才能替你操作电脑：")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            ForEach(model.permissions) { permission in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: permission.granted == true ? "checkmark.circle.fill"
                        : permission.granted == false ? "exclamationmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(permission.granted == true ? Color.green : permission.granted == false ? Color.orange : Color.secondary)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.name).font(.system(size: 13, weight: .medium))
                        Text(permission.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if permission.granted != true {
                        Button(permission.action) { actions.fixPermission(permission.id) }
                    }
                }
            }
            Text("就绪后：连按两次 Fn 唤起，按住 Fn 说话，Esc 停止。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct PhaseIndicator: View {
    let phase: PanelModel.Phase
    let level: Float
    let listening: Bool

    var body: some View {
        ZStack {
            if listening {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 30, height: 30)
                    .scaleEffect(1 + CGFloat(level) * 0.6)
                    .animation(.easeOut(duration: 0.12), value: level)
            }
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 30, height: 30)
    }

    private var symbol: String {
        if listening {
            return "mic.fill"
        }
        switch phase {
        case .idle, .listening:
            return "mic.fill"
        case .running:
            return "cursorarrow.motionlines"
        case .asking:
            return "questionmark.bubble.fill"
        case .finished:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .onboarding:
            return "hand.wave.fill"
        case .learning:
            return "record.circle.fill"
        }
    }

    private var color: Color {
        if listening {
            return .accentColor
        }
        switch phase {
        case .listening, .asking, .onboarding:
            return .accentColor
        case .finished:
            return .green
        case .failed:
            return .orange
        case .learning:
            return .red
        default:
            return .secondary
        }
    }
}
