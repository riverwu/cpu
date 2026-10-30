@testable import CPUCore
import Testing

struct OutlineIndexTests {
    private let calculator = OutlineIndex(outline: """
    [0] window "计算器"
      [2] text "上个表达式" value="54 × 26"
      [6] button "全部清除"
      [13] button "4"
      [14] button "5"
      [15] button "6"
      [24] button "等于"
      [26] button "显示边栏" (adjustable)
    """, screenText: nil)

    @Test func matchingIndexIsKept() throws {
        guard case .element(15, nil) = try calculator.resolve(target: "6", element: 15) else {
            Issue.record("expected [15] unchanged")
            return
        }
    }

    @Test func indexSlipIsCorrected() throws {
        guard case .element(15, let note?) = try calculator.resolve(target: "6", element: 14) else {
            Issue.record("expected correction to [15]")
            return
        }
        #expect(note.contains("[14] is button \"5\""))
    }

    @Test func digitsMatchExactlyNotBySubstring() throws {
        let outline = OutlineIndex(outline: "[1] button \"1\"\n[2] button \"10\"", screenText: nil)
        guard case .element(1, _) = try outline.resolve(target: "1", element: nil) else {
            Issue.record("expected [1]")
            return
        }
    }

    @Test func unlabeledElementCanBeNamedByItsKind() throws {
        let outline = OutlineIndex(outline: "[0] window \"文稿\"\n  [2] scrollarea\n    [3] textarea value=\"正文\"", screenText: nil)
        guard case .element(2, nil) = try outline.resolve(target: "scrollarea", element: 2) else {
            Issue.record("expected [2] kept")
            return
        }
    }

    @Test func unknownTargetRefusesInsteadOfGuessing() {
        #expect(throws: (any Error).self) { try calculator.resolve(target: "发送", element: 24) }
    }

    @Test func onScreenTextGivesCoordinates() throws {
        let wechat = OutlineIndex(outline: "[0] window \"微信\"", screenText: "text \"王宁\" @166,95\ntext \"发送\" @1138,1154")
        guard case .point(let x, let y, _) = try wechat.resolve(target: "王宁", element: nil) else {
            Issue.record("expected a point")
            return
        }
        #expect(x == 166 && y == 95)
    }

    @Test func ambiguousTextRefuses() {
        let wechat = OutlineIndex(outline: "", screenText: "text \"王宁\" @415,35\ntext \"王宁\" @166,95")
        #expect(throws: (any Error).self) { try wechat.resolve(target: "王宁", element: nil) }
    }
}
