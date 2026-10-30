@testable import CPUCore
import Foundation
import Testing

struct MarkdownTests {
    @Test func splitsAReplyIntoBlocks() {
        let reply = """
        我把四套配置逐行核对了一遍：

        **成本对比（单台）**

        | 配置 | PCBA 小计 | 整机成本 |
        |---|---:|:---:|
        | ① 32G 塑料壳 | 99.27 | 166.20 |
        | ② RV1106 外挂 | 100.96 | 167.89 |

        ## 怎么选

        1. **② 直接排除**：贵 1.69。
        2. **量大款选 ④**：毛利最高。
           前提是 64M 内存够用。
        - 备注 a
          - 嵌套 b

        ---
        > 一句话结论
        ```
        let x = 1
        ```
        """
        let blocks = Markdown.blocks(reply)
        #expect(blocks.count == 8)
        #expect(blocks[0] == .paragraph("我把四套配置逐行核对了一遍："))
        #expect(blocks[1] == .paragraph("**成本对比（单台）**"))
        guard case .table(let header, let alignments, let rows) = blocks[2] else {
            Issue.record("expected a table, got \(blocks[2])")
            return
        }
        #expect(header == ["配置", "PCBA 小计", "整机成本"])
        #expect(alignments == [.leading, .trailing, .center])
        #expect(rows.count == 2 && rows[1][2] == "167.89")
        #expect(blocks[3] == .heading(level: 2, text: "怎么选"))
        guard case .list(let items) = blocks[4] else {
            Issue.record("expected a list, got \(blocks[4])")
            return
        }
        #expect(items.map(\.marker) == ["1.", "2.", "•", "•"])
        #expect(items[1].text == "**量大款选 ④**：毛利最高。\n前提是 64M 内存够用。")
        #expect(items[3].depth == 1)
        #expect(blocks[5] == .rule)
        #expect(blocks[6] == .quote("一句话结论"))
        #expect(blocks[7] == .code("let x = 1"))
    }

    @Test func plainTextStaysOneParagraph() {
        #expect(Markdown.blocks("已打开计算器。") == [.paragraph("已打开计算器。")])
        #expect(Markdown.blocks("第一行\n第二行") == [.paragraph("第一行\n第二行")])
        // A number at the start of a sentence is not a list.
        #expect(Markdown.blocks("3.5 秒完成") == [.paragraph("3.5 秒完成")])
    }
}
