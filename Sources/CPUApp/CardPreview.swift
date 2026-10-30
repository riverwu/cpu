import AppKit
import CPUCore
import SwiftUI

/// Development: `CPU --render-card reply.md out.png [expanded] [docked] [pill] [session]` lays
/// out a finished card with that reply (or, with `pill`, a running task; with `session`, after
/// an earlier turn) in an off-screen window and saves it, to check rendering and scrolling
/// without driving the real panel. `CPU --render-history reply.md out.png` does the same for
/// the history window, with made-up sessions.
enum CardPreview {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render-history"), arguments.count > flag + 2 {
            renderHistory(reply: arguments[flag + 1], to: arguments[flag + 2])
            return true
        }
        guard let flag = arguments.firstIndex(of: "--render-card"), arguments.count > flag + 2 else {
            return false
        }
        let model = PanelModel()
        let options = Set(arguments.dropFirst(flag + 3))
        model.title = "分析这几套配置的成本，给出选择建议"
        if options.contains("session") {
            model.title = "整理今天 Hacker News 的热门新闻"
            model.turns = [sampleTurn]
        }
        model.prompt = options.contains("session") ? "再把重点整理成表格，按热度排序" : model.title
        model.phase = .finished
        model.addStep("帮我分析一下这些不同配置的成本", fromUser: true)
        for index in 1...14 {
            model.addStep(index % 4 == 0 ? "向下滚动表格" : "读取第 \(index) 行")
        }
        model.reply = (try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8)) ?? ""
        model.timing = "52.8 秒"
        model.resources = sampleResources
        model.stepsExpanded = options.contains("expanded")
        model.docked = options.contains("docked") || options.contains("pill")
        if options.contains("edits") {
            model.phase = .asking
            model.request = .edits(summary: "修正拼写和语法，理顺两处句子", edits: [
                ProposedEdit(original: "Harry and Hermoine walked to the castel.", replacement: "Harry and Hermione walked to the castle.", reason: "拼写：Hermione、castle"),
                ProposedEdit(original: "they was tired", replacement: "they were tired", reason: "主谓一致"),
                ProposedEdit(original: "it have some erors to fix", replacement: "and it has some errors to fix", reason: "语法和拼写；逗号连接两个句子")
            ])
            model.editChoices = [true, false, true]
        }
        if options.contains("pill") {
            model.compact = true
            model.phase = .running
            model.status = "思考中…"
        }

        model.resultMaxHeight = options.contains("session") ? 560 : 340
        let size = NSRect(x: 0, y: 0, width: 688, height: options.contains("session") ? 860 : 640)
        render(PassthroughHostingView(rootView: PanelView(model: model, actions: PanelActions())), size: size, to: arguments[flag + 2])
        return true
    }

    private static let sampleTurn = SessionTurn(
        request: "帮我把 Hacker News 上今天的新闻整理一下，做成一个博客",
        steps: [SessionStep(text: "打开 news.ycombinator.com"), SessionStep(text: "读取首页 30 条"), SessionStep(text: "写入 hn.md")],
        reply: "已经整理好，保存在桌面的 `hn.md`，共 10 条，每条附一句点评。",
        timing: "21.4 秒",
        resources: [
            SessionResource(kind: .page, use: .read, title: "Hacker News", location: "https://news.ycombinator.com/"),
            SessionResource(kind: .file, use: .created, title: "hn.md", location: NSHomeDirectory() + "/Desktop/hn.md")
        ]
    )

    private static let sampleResources = [
        SessionResource(kind: .page, use: .context, title: "Agents in Games · Labs", location: "https://labs.ycombinator.com/projects/games/index.html"),
        SessionResource(kind: .file, use: .created, title: "hn-2026-10-30.md", location: NSHomeDirectory() + "/Desktop/hn-2026-10-30.md"),
        SessionResource(kind: .page, use: .opened, title: "Show HN: A tiny database", location: "https://news.ycombinator.com/item?id=4521")
    ]

    private static func renderHistory(reply: String, to path: String) {
        let model = HistoryModel()
        let now = Date()
        var second = sampleTurn
        second.request = "再把重点整理成表格，按热度排序"
        second.reply = (try? String(contentsOfFile: reply, encoding: .utf8)) ?? ""
        second.timing = "52.8 秒"
        second.resources = sampleResources
        model.sessions = [
            SessionRecord(title: "整理今天 Hacker News 的热门新闻", started: now.addingTimeInterval(-600), turns: [sampleTurn, second]),
            SessionRecord(title: "把未读邮件标为已读", started: now.addingTimeInterval(-7200), turns: [SessionTurn(request: "把这个邮箱里的未读邮件标为已读", reply: "已把 12 封未读邮件标为已读。", timing: "8.1 秒")]),
            SessionRecord(title: "把文章转成长图", started: now.addingTimeInterval(-90_000), turns: [SessionTurn(request: "把这篇文章的正文转成一张大图", reply: "没能打开这个页面：网络超时。", failed: true, timing: "30.2 秒")])
        ]
        model.selection = model.sessions.first?.id
        render(NSHostingView(rootView: HistoryView(model: model, rerun: { _ in })), size: NSRect(x: 0, y: 0, width: 960, height: 660), to: path)
    }

    private static func render(_ host: NSView, size: NSRect, to path: String) {
        host.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.8, alpha: 1)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        // Let the scroll areas measure their content and lay out again.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
