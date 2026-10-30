@testable import CPUCore
import CoreText
import Foundation
import Testing

struct LongTextTests {
    private let text = (1...10).map { "line \($0)" }.joined(separator: "\n")

    @Test func shortTextComesWhole() {
        #expect(LongText.excerpt(text, budget: 1_000, file: "texts/a.txt") == text)
    }

    @Test func longTextSaysWhatItShowsAndHowToGoOn() {
        let part = LongText.excerpt(text, budget: 30, file: "texts/a.txt")
        #expect(part.hasPrefix("line 1\nline 2\nline 3\nline 4\n[Lines 1–4 of 10 shown"))
        #expect(part.contains(#"read_file {"path": "texts/a.txt", "from_line": 5}"#))
        let end = LongText.excerpt(text, from: 9, budget: 1_000, file: "texts/a.txt")
        #expect(end == "line 9\nline 10\n[Lines 9–10 of 10. That is the end.]")
        let two = LongText.excerpt(text, from: 3, count: 2, budget: 1_000, file: "texts/a.txt")
        #expect(two.hasPrefix("line 3\nline 4\n[Lines 3–4 of 10."))
        #expect(two.contains(#""from_line": 5"#))
    }

    @Test func aLineLongerThanTheBudgetShowsItsBeginning() {
        let long = String(repeating: "字", count: 50) + "\nnext"
        let part = LongText.excerpt(long, budget: 20, file: "texts/b.txt")
        #expect(part.hasPrefix(String(repeating: "字", count: 20) + "\n[Lines 1–1 of 2"))
        #expect(part.contains("Line 1 alone is 50 characters"))
        #expect(part.contains(#""from_line": 2"#))
    }

    @Test func savedNamesComeFromTitlesAndDoNotOverwrite() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-text-\(UUID().uuidString)")
        #expect(LongText.slug("Agents in Games · Labs") == "Agents-in-Games-Labs")
        #expect(LongText.slug("周报（终稿）.docx") == "周报-终稿-docx")
        #expect(LongText.save("a", name: "页面", in: workspace) == "texts/页面.txt")
        #expect(LongText.save("b", name: "页面", in: workspace) == "texts/页面-2.txt")
        #expect(try String(contentsOf: workspace.appendingPathComponent("texts/页面.txt"), encoding: .utf8) == "a")
    }
}

struct DocumentTextTests {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-docs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func plainTextInCommonEncodings() throws {
        let dir = folder()
        let utf8 = dir.appendingPathComponent("a.md")
        try "# 标题\n正文".write(to: utf8, atomically: true, encoding: .utf8)
        #expect(try DocumentText.read(utf8).text == "# 标题\n正文")
        let gb = dir.appendingPathComponent("b.txt")
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        try "中文编码".data(using: encoding)!.write(to: gb)
        #expect(try DocumentText.read(gb).text == "中文编码")
        let binary = dir.appendingPathComponent("c.bin")
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: binary)
        #expect(throws: (any Error).self) { try DocumentText.read(binary) }
    }

    @Test func wordDocumentsThroughTextutil() throws {
        let dir = folder()
        let source = dir.appendingPathComponent("s.txt")
        try "第一段\n第二段".write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", source.path, "-output", dir.appendingPathComponent("d.docx").path]
        try process.run()
        process.waitUntilExit()
        let read = try DocumentText.read(dir.appendingPathComponent("d.docx"))
        #expect(read.kind == "DOCX document")
        #expect(read.text.contains("第一段") && read.text.contains("第二段"))
    }

    @Test func pdfPageByPage() throws {
        let url = folder().appendingPathComponent("p.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in ["Hello page one", "Second page here"] {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: page, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let read = try DocumentText.read(url)
        #expect(read.kind == "PDF, 2 pages")
        #expect(read.text.contains("[page 1]\nHello page one"))
        #expect(read.text.contains("[page 2]\nSecond page here"))
    }
}

struct ClipboardTests {
    @Test func copyAndCutAskFirst() {
        #expect(Agent.clipboardWrite(in: [["do": "key", "key": "cmd+c"]]) != nil)
        #expect(Agent.clipboardWrite(in: [["do": "click", "target": "正文"], ["do": "key", "key": "cmd+x"]]) != nil)
        #expect(Agent.clipboardWrite(in: [["do": "menu", "path": "编辑 ▸ 拷贝"]]) != nil)
        #expect(Agent.clipboardWrite(in: [["do": "click", "target": "复制链接"]]) != nil)
        #expect(Agent.clipboardWrite(in: [["do": "click", "target": "Copy Link"]]) != nil)
    }

    @Test func otherActionsDoNot() {
        #expect(Agent.clipboardWrite(in: [["do": "key", "key": "cmd+shift+c"]]) == nil)
        #expect(Agent.clipboardWrite(in: [["do": "key", "key": "cmd+v"]]) == nil)
        #expect(Agent.clipboardWrite(in: [["do": "key", "key": "cmd+a"]]) == nil)
        // 文件 ▸ 复制 is Duplicate.
        #expect(Agent.clipboardWrite(in: [["do": "menu", "path": "文件 ▸ 复制"]]) == nil)
        #expect(Agent.clipboardWrite(in: [["do": "click", "target": "Copyright 2026"]]) == nil)
        #expect(Agent.clipboardWrite(in: [["do": "type", "text": "复制这段"]]) == nil)
    }

    @Test func codeThatWritesTheClipboardAsksFirst() {
        #expect(CodeSafety.check(language: "shell", code: "echo hi | pbcopy") == .confirm(["写入剪贴板（会替换你复制的内容）"]))
        #expect(CodeSafety.check(language: "applescript", code: "set the clipboard to \"x\"") != .run)
        #expect(CodeSafety.check(language: "shell", code: "pbpaste | wc -c") == .run)
    }

    @Test func credentialFilesStayOnTheMac() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(Agent.secretPlace(home.appendingPathComponent(".ssh/id_ed25519")) == "~/.ssh")
        #expect(Agent.secretPlace(URL(fileURLWithPath: "/tmp/project/.env")) == ".env")
        #expect(Agent.secretPlace(home.appendingPathComponent("Documents/report.docx")) == nil)
    }
}
