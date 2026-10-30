import AppKit
import CPUCore
import SwiftUI

/// One exchange: the user's words on the right, then what CPU did (folded once done) and
/// its answer. The card shows a session as a column of these, and so does the history window.
struct TurnView: View {
    let turn: SessionTurn
    /// Off when the card's title already says the same thing.
    var showsPrompt = true
    /// Still working: the latest steps show what is happening instead of a folded list.
    var live = false
    @Binding var expanded: Bool
    var size: CGFloat = 14
    /// Pages and files shown before "还有 N 项"; nil shows them all.
    var resourceLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsPrompt, !turn.request.isEmpty {
                PromptBubble(text: turn.request, size: size)
            }
            if !turn.steps.isEmpty {
                if live {
                    liveSteps
                } else {
                    foldedSteps
                }
            }
            if !turn.reply.isEmpty {
                reply
            }
            if !live, !turn.resources.isEmpty {
                ResourceList(resources: turn.resources, limit: resourceLimit, size: size)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last few steps, one line each.
    private var liveSteps: some View {
        VStack(alignment: .leading, spacing: 5) {
            if turn.steps.count > 6 {
                Text("… 前面还有 \(turn.steps.count - 6) 步")
                    .font(.system(size: size - 3))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(turn.steps.suffix(6).enumerated()), id: \.offset) { _, step in
                StepLine(step: step, size: size, oneLine: true)
            }
        }
    }

    /// One line that opens on click, so the answer comes first.
    private var foldedSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary)
                }
                .font(.system(size: size - 2))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                        StepLine(step: step, size: size, oneLine: false)
                        if let detail = step.detail {
                            Text(detail)
                                .font(.system(size: size - 3, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                                .padding(.leading, 18)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private var summary: String {
        let actions = turn.steps.filter { !$0.fromUser }.count
        var parts = [actions == 0 ? "过程" : "做了 \(actions) 步操作"]
        if !turn.timing.isEmpty {
            parts.append(turn.timing)
        }
        return parts.joined(separator: " · ")
    }

    /// A turn that did not get there keeps its answer readable, marked by a bar at the side.
    @ViewBuilder
    private var reply: some View {
        if turn.failed {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.orange.opacity(0.8))
                    .frame(width: 3)
                MarkdownView(text: turn.reply, size: size)
            }
        } else {
            MarkdownView(text: turn.reply, size: size)
        }
    }
}

/// The pages and files a turn worked with: the page the user was looking at first, then what
/// CPU made, changed, read and opened. A page opens in the browser; a file CPU made opens in its
/// app; any other file is shown in Finder.
struct ResourceList: View {
    let resources: [SessionResource]
    var limit: Int?
    var size: CGFloat = 14

    var body: some View {
        let ordered = resources.enumerated()
            .sorted { ($0.element.use.order, $0.offset) < ($1.element.use.order, $1.offset) }
            .map(\.element)
        let shown = limit.map { Array(ordered.prefix($0)) } ?? ordered
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, resource in
                row(resource)
            }
            if shown.count < ordered.count {
                Text("还有 \(ordered.count - shown.count) 项，在历史记录里")
                    .font(.system(size: size - 3))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
        .padding(.top, 2)
    }

    private func row(_ resource: SessionResource) -> some View {
        let missing = resource.kind == .file && !FileManager.default.fileExists(atPath: resource.location)
        return Button {
            open(resource)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(resource))
                    .font(.system(size: size - 3))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(resource.title.isEmpty ? resource.location : resource.title)
                    .font(.system(size: size - 1.5))
                    .foregroundStyle(missing ? Color.secondary : Color.primary.opacity(0.85))
                    .strikethrough(missing)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(missing ? "已不在原处" : detail(resource))
                    .font(.system(size: size - 3))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(missing)
        .help(resource.location)
    }

    private func icon(_ resource: SessionResource) -> String {
        switch (resource.kind, resource.use) {
        case (.page, _):
            return "globe"
        case (.file, .created):
            return "doc.badge.plus"
        case (.file, .changed):
            return "square.and.pencil"
        case (.file, _):
            return "doc.text"
        }
    }

    /// What was done with it, and where it is: "生成 · ~/Desktop", "当时在看 · news.ycombinator.com".
    private func detail(_ resource: SessionResource) -> String {
        let place: String
        switch resource.kind {
        case .page:
            place = URL(string: resource.location)?.host ?? resource.location
        case .file:
            place = ((resource.location as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        }
        return "\(resource.use.words) · \(place)"
    }

    private func open(_ resource: SessionResource) {
        switch resource.kind {
        case .page:
            if let url = URL(string: resource.location) {
                NSWorkspace.shared.open(url)
            }
        case .file:
            let url = URL(fileURLWithPath: resource.location)
            if resource.use == .created {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

private extension SessionResource.Use {
    /// The page the user was looking at first, then what CPU made, changed, read, opened.
    var order: Int {
        switch self {
        case .context:
            return 0
        case .created:
            return 1
        case .changed:
            return 2
        case .read:
            return 3
        case .opened:
            return 4
        }
    }

    var words: String {
        switch self {
        case .context:
            return "当时在看"
        case .created:
            return "生成"
        case .changed:
            return "修改"
        case .read:
            return "读取"
        case .opened:
            return "打开"
        }
    }
}

/// What the user said, as a bubble at the right.
struct PromptBubble: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: size))
                .lineSpacing(size * 0.25)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// A step: CPU's action with a tick, or the user's words (an answer, an interjection).
private struct StepLine: View {
    let step: SessionStep
    let size: CGFloat
    let oneLine: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: step.fromUser ? "person.fill" : "checkmark")
                .font(.system(size: size - 5, weight: .semibold))
                .foregroundStyle(step.fromUser ? Color.accentColor : Color.secondary.opacity(0.7))
                .frame(width: 12)
            Text(step.text)
                .font(.system(size: size - 1))
                .foregroundStyle(step.fromUser ? Color.accentColor : Color.secondary)
                .lineLimit(oneLine ? 1 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: !oneLine)
        }
    }
}
