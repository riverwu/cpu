@testable import CPUCore
import CoreGraphics
import Foundation
import Testing

struct SafetyTests {
    @Test func terminalNeedsToBeAskedFor() {
        #expect(!Agent.mentionsTerminal("把当前网页保存为PDF，存到下载文件夹", app: "终端"))
        #expect(Agent.mentionsTerminal("在终端里运行 ls", app: "终端"))
        #expect(Agent.mentionsTerminal("open iTerm and run make", app: "iTerm2"))
        #expect(Agent.mentionsTerminal("用 Ghostty 跑一下测试", app: "Ghostty"))
        #expect(Agent.terminalApps.contains("com.apple.Terminal"))
    }

    @Test func modalDialogsAreListed() {
        // App-modal panels (save, open, alerts) sit at their own window level.
        #expect(WindowCatalog.modalLevel == Int(CGWindowLevelForKey(.modalPanelWindow)))
        #expect(WindowCatalog.modalLevel > 0)
    }
}

struct PlaybookTests {
    @Test func requestsPickTheirScenario() {
        #expect(Playbooks.guides(for: "帮我优化一下这篇文章").map(\.id) == ["edit-writing"])
        #expect(Playbooks.guides(for: "翻译一下这个页面").map(\.id) == ["translate"])
        #expect(Playbooks.guides(for: "把这个网页保存为一个 PDF").map(\.id) == ["export-pdf"])
        #expect(Playbooks.guides(for: "帮我检查一下这篇文章有没有语法错误").map(\.id) == ["proofread"])
        #expect(Playbooks.guides(for: "用计算器算 9 乘 9").isEmpty)
        // Once given in a session, a guide is not repeated.
        #expect(Playbooks.guides(for: "再润色一下", excluding: ["edit-writing"]).isEmpty)
    }
}
