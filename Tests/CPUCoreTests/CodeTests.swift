@testable import CPUCore
import Foundation
import Testing

struct CodeSafetyTests {
    private func verdict(_ code: String, _ language: String = "applescript") -> CodeSafety.Verdict {
        CodeSafety.check(language: language, code: code)
    }

    @Test func refusesSudoAndSimulatedInput() {
        guard case .refuse = verdict("sudo rm -rf /tmp/x", "shell") else {
            Issue.record("sudo should be refused")
            return
        }
        guard case .refuse = verdict(#"tell application "System Events" to keystroke "v" using command down"#) else {
            Issue.record("keystrokes should be refused")
            return
        }
        guard case .refuse = verdict(#"do shell script "sudo shutdown -h now""#) else {
            Issue.record("sudo inside do shell script should be refused")
            return
        }
    }

    @Test func asksBeforeSendingOrChangingManyThings() {
        #expect(verdict(#"tell application "Mail" to send (make new outgoing message with properties {subject:"hi"})"#) == .confirm(["发送邮件或消息"]))
        #expect(verdict("curl -X POST -d 'a=1' https://example.com", "shell") == .confirm(["向网络发送或上传数据"]))
        #expect(verdict(#"tell application "Mail" to set read status of every message of inbox to true"#) == .confirm(["批量修改应用里的数据"]))
        #expect(verdict(#"tell application "Safari" to quit"#) == .confirm(["退出应用或结束进程（未保存的内容可能丢失）"]))
        #expect(verdict("brew install ffmpeg", "shell") == .confirm(["安装或卸载软件"]))
    }

    @Test func readingAndMakingFilesJustRun() {
        #expect(verdict(#"tell application "Finder" to set names to name of every file of desktop"#) == .run)
        #expect(verdict("say -v Tingting -o a.aiff -f script.txt && afconvert -f m4af -d aac a.aiff ~/Desktop/a.m4a", "shell") == .run)
        #expect(verdict(#"echo "we kill time and send letters" > notes.txt"#, "shell") == .run)
        #expect(verdict("rm scratch.txt", "shell") == .run)
    }

    @Test func pathsTheCodeNames() {
        let paths = CodeRunner.mentionedPaths(in: #"""
        echo hi > ~/Desktop/a.txt
        cp "/Users/me/My Docs/b.docx" out.docx
        open /Applications/Foo.app
        """#)
        #expect(paths.contains((("~/Desktop/a.txt") as NSString).expandingTildeInPath))
        #expect(paths.contains("/Users/me/My Docs/b.docx"))
    }
}

struct CodeRunnerTests {
    private func runner() -> CodeRunner {
        CodeRunner(task: "test-\(UUID().uuidString.prefix(8))", helper: nil)
    }

    @Test func reportsOutputExitAndFiles() throws {
        let runner = runner()
        defer { try? FileManager.default.removeItem(at: runner.workspace) }
        let report = try runner.run(CodeRunner.Request(language: .shell, code: "cat in.txt | tr a-z A-Z > out.txt; echo done; exit 3", files: ["in.txt": "hello\n"])).report
        #expect(report.contains("exit 3 (failed)"))
        #expect(report.contains("done"))
        #expect(report.contains("workspace/out.txt"))
        #expect(try String(contentsOf: runner.workspace.appendingPathComponent("out.txt"), encoding: .utf8) == "HELLO\n")
    }

    @Test func explainsAppleScriptErrorsByLine() throws {
        let runner = runner()
        defer { try? FileManager.default.removeItem(at: runner.workspace) }
        let report = try runner.run(CodeRunner.Request(language: .applescript, code: "set x to 1\nerror \"boom\" number -1728")).report
        #expect(report.contains("line 2"))
        #expect(report.contains("-1728: the object does not exist"))
    }

    @Test func stopsAtTheTimeLimit() throws {
        let runner = runner()
        defer { try? FileManager.default.removeItem(at: runner.workspace) }
        let started = Date()
        let report = try runner.run(CodeRunner.Request(language: .shell, code: "sleep 30", timeout: 1)).report
        #expect(report.hasPrefix("Stopped after"))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func undoPutsChangedFilesBack() throws {
        let runner = runner()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-undo-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: runner.workspace)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("keep.txt")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let report = try runner.run(CodeRunner.Request(language: .shell, code: "echo changed > '\(file.path)'")).report
        #expect(report.contains("backup kept"))
        #expect(runner.hasUndoableFiles)
        #expect(runner.undoFiles() != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")
    }

    @Test func backgroundJobsReportWhenDone() throws {
        let runner = runner()
        defer { try? FileManager.default.removeItem(at: runner.workspace) }
        let job = try runner.startInBackground(CodeRunner.Request(language: .shell, code: "sleep 1; echo finished", timeout: 10))
        #expect(runner.wait(job: job.id, timeout: 0.2).contains("still running"))
        #expect(runner.wait(job: job.id, timeout: 5).contains("finished"))
    }
}

struct PageScriptTests {
    @Test func pageScriptsOnlyRead() {
        #expect(CodeSafety.pageRefusal("[...document.querySelectorAll('tr')].map(r => r.innerText)") == nil)
        #expect(CodeSafety.pageRefusal("document.querySelector('button').click()") != nil)
        #expect(CodeSafety.pageRefusal("document.querySelector('input').value = 'x'") != nil)
        #expect(CodeSafety.pageRefusal("fetch('/api')") != nil)
        #expect(CodeSafety.pageRefusal("const ok = a.value === 'x'; return ok") == nil)
    }

    @Test func expressionsAndBodiesBothReturnJSON() {
        #expect(CodeSafety.pageScript("document.title").contains("return (\ndocument.title\n);"))
        #expect(!CodeSafety.pageScript("const t = document.title; return t").contains("return (\n"))
    }

    @Test func theTabIsFoundByTitle() {
        let script = CodeSafety.browserScript(bundleId: "com.google.Chrome", title: "Say \"hi\" - Google Chrome", scriptFile: ".cpu-page.js")
        #expect(script.contains(#"if title of active tab of w is "Say \"hi\"" then"#))
        #expect(script.contains("execute (active tab of target) javascript js"))
    }
}
