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
