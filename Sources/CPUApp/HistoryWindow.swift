import AppKit
import CPUCore
import SwiftUI

/// Past sessions in a window of their own: the list by day on the left, the chosen session's
/// whole transcript on the right. Opened from the card's clock button or the menu bar.
final class HistoryWindow: NSObject, NSWindowDelegate {
    /// "再做一次": run a session's first request on the card.
    var onRerun: (String) -> Void = { _ in }
    let model = HistoryModel()
    private var window: NSWindow?
    /// CPU has no Dock icon: when the window closes, the keyboard goes back to this app.
    private var previousApp: NSRunningApplication?

    func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// A session was saved: show it at once if the window is open.
    func saved(_ session: SessionRecord) {
        if window?.isVisible == true {
            model.upsert(session)
        }
    }

    func windowWillClose(_ notification: Notification) {
        previousApp?.activate()
        previousApp = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CPU 历史记录"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.contentViewController = NSHostingController(rootView: HistoryView(model: model, rerun: { [weak self] request in
            self?.onRerun(request)
        }))
        window.center()
        window.setFrameAutosaveName("CPUHistory")
        window.delegate = self
        return window
    }
}

final class HistoryModel: ObservableObject {
    @Published var sessions: [SessionRecord] = []
    @Published var selection: String?
    @Published var query = ""
    /// Opened steps, as "session id#turn".
    @Published var openTurns: Set<String> = []

    struct Day {
        let title: String
        let sessions: [SessionRecord]
    }

    func reload() {
        sessions = TaskStore.shared.sessions()
        if selection == nil || !sessions.contains(where: { $0.id == selection }) {
            selection = sessions.first?.id
        }
    }

    func upsert(_ session: SessionRecord) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    var selected: SessionRecord? {
        sessions.first { $0.id == selection }
    }

    /// The sessions that match the search, by day, newest first.
    var days: [Day] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = words.isEmpty ? sessions : sessions.filter { HistoryModel.text(of: $0).contains(words) }
        var days: [Day] = []
        for session in shown {
            let title = HistoryModel.dayTitle(session.started)
            if let last = days.last, last.title == title {
                days[days.count - 1] = Day(title: title, sessions: last.sessions + [session])
            } else {
                days.append(Day(title: title, sessions: [session]))
            }
        }
        return days
    }

    private static func text(of session: SessionRecord) -> String {
        ([session.title] + session.turns.flatMap { [$0.request, $0.reply] }).joined(separator: "\n").lowercased()
    }

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return format(date, sameYear ? "M月d日 EEEE" : "yyyy年M月d日 EEEE")
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    let rerun: (String) -> Void

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $model.query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)
            List(selection: $model.selection) {
                ForEach(model.days, id: \.title) { day in
                    Section(day.title) {
                        ForEach(day.sessions) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.sessions.isEmpty {
                    Text("还没有历史记录")
                        .foregroundStyle(.secondary)
                } else if model.days.isEmpty {
                    Text("没有找到")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.selected {
            SessionDetail(session: session, model: model, rerun: rerun)
                .id(session.id)
        } else {
            Text("选择左侧的一条记录")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SessionRow: View {
    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(HistoryModel.format(session.started, "HH:mm"))
                if session.turns.count > 1 {
                    Text("· \(session.turns.count) 轮")
                }
                if session.turns.contains(where: \.failed) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// One session, read like the card showed it, in a comfortable column.
private struct SessionDetail: View {
    let session: SessionRecord
    @ObservedObject var model: HistoryModel
    let rerun: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title)
                            .font(.system(size: 20, weight: .semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let first = session.turns.first?.request, !first.isEmpty {
                        Button {
                            rerun(first)
                        } label: {
                            Label("再做一次", systemImage: "arrow.clockwise")
                        }
                        .help(first)
                    }
                }
                ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                    if index > 0 {
                        Divider()
                    }
                    TurnView(turn: turn, showsPrompt: true, expanded: open(index), size: 14)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        let day = HistoryModel.format(session.started, "yyyy年M月d日 EEEE HH:mm")
        return session.turns.count > 1 ? "\(day) · \(session.turns.count) 轮" : day
    }

    private func open(_ index: Int) -> Binding<Bool> {
        let key = "\(session.id)#\(index)"
        return Binding(
            get: { model.openTurns.contains(key) },
            set: { open in
                if open {
                    model.openTurns.insert(key)
                } else {
                    model.openTurns.remove(key)
                }
            }
        )
    }
}
