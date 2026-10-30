import AppKit
import CPUCore
import SwiftUI

/// Development: `CPU --render-card reply.md out.png [expanded] [docked] [pill]` lays out a
/// finished card with that reply (or, with `pill`, a running task) in an off-screen window and
/// saves it, to check rendering and scrolling without driving the real panel.
enum CardPreview {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render-card"), arguments.count > flag + 2 else {
            return false
        }
        let model = PanelModel()
        model.title = "分析这几套配置的成本，给出选择建议"
        model.phase = .finished
        model.addStep("帮我分析一下这些不同配置的成本", fromUser: true)
        for index in 1...14 {
            model.addStep(index % 4 == 0 ? "向下滚动表格" : "读取第 \(index) 行")
        }
        model.reply = (try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8)) ?? ""
        model.footer = "52.8 秒 · 14 个动作"
        let options = Set(arguments.dropFirst(flag + 3))
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

        let size = NSRect(x: 0, y: 0, width: 688, height: 640)
        let host = PassthroughHostingView(rootView: PanelView(model: model, actions: PanelActions()))
        host.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.8, alpha: 1)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        // Let the scroll areas measure their content and lay out again.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return true
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[flag + 2]))
        return true
    }
}
