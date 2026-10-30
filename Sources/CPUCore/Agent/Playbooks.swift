import Foundation

/// How the user expects common kinds of work to go, and the path a practiced person takes.
/// A request's words pick the guides that go to the model with it. A user's own version in
/// ~/.config/cpu/playbooks/<id>.md replaces the built-in one.
struct Playbook {
    let id: String
    /// Any of these in the request selects the guide.
    let words: [String]
    let guide: String
}

enum Playbooks {
    static let all: [Playbook] = [
        Playbook(id: "edit-writing", words: [
            "优化", "润色", "改写", "修改一下", "改一下", "改得", "精简", "通顺", "改正式", "重写", "polish", "rewrite", "improve"
        ], guide: """
        Improving the user's own writing. They expect to see what would change and decide; the \
        original is never lost and its formatting stays.
        1. `read` the whole text.
        2. `propose_edits`: the fewest changes that achieve the goal and a one-line summary. \
        Keep each `original` short (the words that change plus enough to be unique, under \
        about 60 characters; split a long sentence into several edits) and copied exactly. \
        Change nothing before the user picks (unless they said to change it directly).
        3. Apply only the accepted edits, in place, where the user can see them.
        - Word: turn on Track Changes first (审阅 tab ▸ 修订) so each change shows as a \
        revision. Open the sidebar Find & Replace with cmd+shift+h (fields 搜索文档 and 替换为, \
        buttons 查找 / 替换 / 全部替换). For each edit, in one batch: click 搜索文档, cmd+a, \
        type the original; click 替换为, cmd+a, type the replacement; click 查找 (selects the \
        match), click 替换. Type into these fields; values set without typing are ignored.
        - Other apps: their Find & Replace the same way, or select the passage and type over it.
        4. Reply with how many changes were made and how to review them (Word: 审阅 ▸ 接受/拒绝).
        """),
        Playbook(id: "proofread", words: [
            "检查", "校对", "错别字", "语法", "拼写", "有没有错", "proofread", "grammar", "typo"
        ], guide: """
        Checking a text. The user expects a list of problems, not changes.
        1. `read` the whole text.
        2. Reply with the problems: a table of where (paragraph or the first words), the \
        original, the fix and why. Say plainly when you found none.
        3. Change nothing. If they then say "改吧", treat it as editing: `propose_edits` with \
        those fixes (or apply directly when they ask for that).
        """),
        Playbook(id: "translate", words: ["翻译", "译成", "译为", "translate"], guide: """
        Translating. The user wants to read the content in their language; the original stays.
        - A web page: use the browser's own translation (Chrome: right-click the page ▸ 翻译成 \
        中文, or the translate icon at the right of the address bar), which keeps the page and \
        its layout.
        - A document or selection: `read` it; give the translation in your reply when it is \
        short (about a screen), otherwise put it in a new document next to the original \
        (never overwrite the original) and say where it is.
        """),
        Playbook(id: "understand", words: [
            "总结", "概括", "摘要", "讲了什么", "说了什么", "分析", "对不对", "怎么选", "解读", "要点", "summarize", "analy"
        ], guide: """
        Understanding a document, page or table. The user wants an answer they can trust.
        - `read` it whole first instead of scrolling; open the source when they ask you to \
        check against one.
        - Answer with the conclusion first, then the evidence and where it is (section, page, \
        row, figure). Mark what is your inference.
        - Change nothing in the document.
        """),
        Playbook(id: "export-pdf", words: ["pdf", "导出", "另存为", "存成", "存为", "保存为"], guide: """
        Saving or exporting as PDF, the way a practiced user does it:
        - Browser page: cmd+p ▸ 目标打印机 = 另存为 PDF ▸ 保存 ▸ in the save dialog set the \
        name and folder ▸ 存储.
        - Word / Excel / PowerPoint: 文件 ▸ 另存为 ▸ 文件格式 = PDF ▸ 导出/保存. Pages / \
        Numbers / Keynote: 文件 ▸ 导出为 ▸ PDF.
        - Other apps: cmd+p ▸ PDF ▸ 存储为 PDF.
        Name it after the document; put it next to the source file, or in 下载 for a web page, \
        unless the user says otherwise. When the save dialog closes without an error the file \
        is there: reply with its path; do not open Finder to check.
        """),
        Playbook(id: "fill-form", words: ["填表", "填写", "填一下", "表单", "报名", "报销", "fill in", "fill out"], guide: """
        Filling in a form. The user expects every field filled from the information they gave \
        or pointed at, and to submit it themselves.
        - Fill all the fields you have information for; leave the rest and list them.
        - Stop before submitting unless the user said to submit; reply with what you filled.
        """)
    ]

    /// The guides for a request, in the user's version when they wrote one; nil when none apply.
    static func guides(for request: String, excluding given: Set<String> = []) -> [(id: String, text: String)] {
        let words = request.lowercased()
        return all.filter { playbook in
            !given.contains(playbook.id) && playbook.words.contains { words.contains($0) }
        }.map { playbook in
            (playbook.id, userGuide(playbook.id) ?? playbook.guide)
        }
    }

    private static func userGuide(_ id: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cpu/playbooks/\(id).md")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
