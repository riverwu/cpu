@testable import CPUCore
import Foundation
import Testing

struct EditCheckTests {
    private func edit(_ original: String, _ replacement: String) -> ProposedEdit {
        ProposedEdit(original: original, replacement: replacement, reason: "")
    }

    @Test func readsWhichEditsAreInTheDocument() {
        let document = """
        Knowledge is a blessing and can also be a waiting sin.
        He believed the act of teaching is an act of transferring condensed pellets, made by the myriads of astrologists, scholars.
        Childish? Isn’t it—since that environment was ultimately meant to be a lab,
        """
        let edits = [
            (1, edit("Knowledge is a bless and", "Knowledge is a blessing and")),
            (2, edit("made by the myriads of astrologists", "made by the myriad astrologers")),
            // Typed with a straight apostrophe, stored curly.
            (3, edit("Isn't it, as the environment", "Isn't it—since that environment")),
            (4, edit("a beautiful see arch", "a beautiful sea arch"))
        ]
        let outcome = EditCheck.verify(edits, in: document)
        #expect(outcome.applied == [1, 3])
        #expect(outcome.missing == [2])
        #expect(outcome.unclear == [4])
    }

    @Test func aShorterReplacementInsideTheOriginalIsNotApplied() {
        let outcome = EditCheck.verify([(1, edit("very very good", "very good"))], in: "It was very very good.")
        #expect(outcome.missing == [1])
        #expect(EditCheck.verify([(1, edit("very very good", "very good"))], in: "It was very good.").applied == [1])
    }
}

struct ActionLabelTests {
    @Test func ellipsisMeansADialog() {
        #expect(Computer.opensDialog(#"点击 [54] menuitem "修改(M)...""#))
        #expect(Computer.opensDialog(#"点击 [12] button "存储为 PDF…""#))
        #expect(!Computer.opensDialog(#"点击 [12] button "存储""#))
    }

    @Test func saveButtonsAreRecognized() {
        #expect(Computer.saves(#"点击 [50] button "保存""#))
        #expect(Computer.saves(#"点击 [5] button "替换""#))
        #expect(Computer.saves(#"点击 [8] button "Save""#))
        #expect(!Computer.saves(#"点击 [8] button "取消""#))
        #expect(!Computer.saves(#"点击 [8] combobox "保存位置""#))
    }

    @Test func onlyHarmlessKeysAreResent() throws {
        #expect(try KeyChord.parse("cmd+shift+e").safeToResend)
        #expect(try !KeyChord.parse("escape").safeToResend)
        #expect(try KeyChord.parse("escape").isEscape)
        #expect(try !KeyChord.parse("cmd+escape").isEscape)
        #expect(try !KeyChord.parse("delete").safeToResend)
        #expect(try !KeyChord.parse("a").safeToResend)
        #expect(try !KeyChord.parse("left").safeToResend)
    }
}

struct LateTargetTests {
    @Test func aFormLabelNamesTheControlAfterIt() throws {
        let index = OutlineIndex(outline: """
        [43] text "文件格式："
        [44] popup value="多信息文本文稿"
        """, screenText: nil)
        guard case .element(let element, _) = try index.resolve(target: "文件格式", element: nil) else {
            Issue.record("expected an element")
            return
        }
        #expect(element == 44)
    }

    @Test func aShortVisibleLabelDoesNotStandInForAnUnseenOne() {
        // "显示以供审阅" opens only once the 审阅 tab shows; until then it is not found, so the
        // act runs the earlier actions and looks again.
        let index = OutlineIndex(outline: """
        [13] radio "审阅" value="0"
        """, screenText: nil)
        #expect(throws: OutlineIndex.TargetNotFound.self) {
            try index.resolve(target: "显示以供审阅", element: nil)
        }
    }
}

struct LooseLabelTests {
    private func resolved(_ target: String, in outline: String) -> Int? {
        let index = OutlineIndex(outline: outline, screenText: nil)
        guard case .element(let element, _)? = try? index.resolve(target: target, element: nil) else {
            return nil
        }
        return element
    }

    @Test func oppositesDoNotMatch() {
        #expect(resolved("不保存", in: #"[83] button "保存""#) == nil)
        #expect(resolved("保存", in: #"[8] button "不保存""#) == nil)
        #expect(resolved("Save", in: #"[8] button "Don't Save""#) == nil)
    }

    @Test func extraWordsAboutTheControlStillMatch() {
        #expect(resolved("发送按钮", in: #"[3] button "发送""#) == 3)
        #expect(resolved("导出", in: #"[5] menuitem "导出为 PDF…""#) == 5)
        #expect(resolved("search field", in: #"[2] searchfield "Search""#) == 2)
    }
}

struct SlipTests {
    @Test func aLookAlikeCharacterWithTheRightIndexStillActs() throws {
        let index = OutlineIndex(outline: #"[61] row "未读 · 祁拓 · 11:33""#, screenText: nil)
        guard case .element(let element, let note) = try index.resolve(target: "未读 · 祺拓 · 11:33", element: 61) else {
            Issue.record("expected an element")
            return
        }
        #expect(element == 61)
        #expect(note != nil)
    }

    @Test func shortOrDifferentLabelsAreNotSlips() {
        #expect(!OutlineIndex.oneSlip("保存", "不保存"))
        #expect(!OutlineIndex.oneSlip("发送", "发给"))
        #expect(!OutlineIndex.oneSlip("report-1", "report-12x"))
        #expect(OutlineIndex.oneSlip("report-1", "report-12"))
        #expect(OutlineIndex.oneSlip("Selected", "Select3d"))
    }
}

struct MenuPathTests {
    @Test func pathsSplitOnAnyArrow() {
        #expect(MenuBar.parts("邮件 ▸ 标记 ▸ 标记为已读") == ["邮件", "标记", "标记为已读"])
        #expect(MenuBar.parts("File > Export As > PDF…") == ["File", "Export As", "PDF…"])
        #expect(MenuBar.parts("邮件") == ["邮件"])
    }

    @Test func titlesMatchWithoutEllipsisOrAccessKey() {
        #expect(MenuBar.normalize("修改(M)...") == MenuBar.normalize("修改"))
        #expect(MenuBar.normalize("存储为…") == "存储为")
        #expect(MenuBar.normalize("Export  As…") == "export as")
    }

    @Test func toolSchemasParse() {
        let names = Prompt.tools.compactMap { $0["name"] as? String }
        #expect(names.contains("act"))
        #expect(names.contains("read"))
    }
}
