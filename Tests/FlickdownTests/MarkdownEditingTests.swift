import Foundation
import Testing
@testable import Flickdown

struct MarkdownEditingTests {
    /// Applies the edit and returns the text with `|` at the caret (or `[...]` around the selection).
    private func run(_ marked: String, _ edit: (NSString, NSRange) -> MarkdownEditing.Edit?) -> String? {
        let (text, selection) = parse(marked)
        guard let change = edit(text as NSString, selection) else { return nil }
        let result = (text as NSString).replacingCharacters(in: change.range, with: change.text) as NSString
        if change.selection.length == 0 {
            return result.replacingCharacters(in: change.selection, with: "|")
        }
        let inner = result.substring(with: change.selection)
        return result.replacingCharacters(in: change.selection, with: "[\(inner)]")
    }

    private func parse(_ marked: String) -> (String, NSRange) {
        let ns = marked as NSString
        let caret = ns.range(of: "|")
        if caret.location != NSNotFound {
            return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let open = ns.range(of: "[[").location
        let close = ns.range(of: "]]").location
        let text = ns.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        return (text, NSRange(location: open, length: close - open - 2))
    }

    @Test("回车续写无序、有序、任务列表和引用")
    func newlineContinuesListsAndQuotes() {
        let newline = { MarkdownEditing.newline(in: $0, selection: $1) }
        #expect(run("- 苹果|", newline) == "- 苹果\n- |")
        #expect(run("  * 嵌套|", newline) == "  * 嵌套\n  * |")
        #expect(run("9. 第九|", newline) == "9. 第九\n10. |")
        #expect(run("1) 括号|", newline) == "1) 括号\n2) |")
        #expect(run("- [x] 已完成|", newline) == "- [x] 已完成\n- [ ] |")
        #expect(run("> 引用|", newline) == "> 引用\n> |")
        #expect(run("> - 引用里的列表|", newline) == "> - 引用里的列表\n> - |")
        #expect(run("- 中|间", newline) == "- 中\n- |间")
    }

    @Test("空列表项或空引用回车结束列表")
    func newlineOnEmptyItemEndsList() {
        let newline = { MarkdownEditing.newline(in: $0, selection: $1) }
        #expect(run("- 一\n- |", newline) == "- 一\n|")
        #expect(run("1. 一\n2. |\n", newline) == "1. 一\n|\n")
        #expect(run("> |", newline) == "|")
    }

    @Test("普通段落、缩进行和光标在标记内时保持系统默认回车")
    func newlineLeavesOtherLinesAlone() {
        let newline = { MarkdownEditing.newline(in: $0, selection: $1) }
        #expect(run("普通段落|", newline) == nil)
        #expect(run("    缩进|", newline) == nil)
        #expect(run("-| 项", newline) == nil)
        #expect(run("-not a list|", newline) == nil)
    }

    @Test("Tab 按标记宽度缩进列表项，Shift-Tab 反缩进")
    func tabIndentsListItems() {
        let indent = { MarkdownEditing.indent(in: $0, selection: $1, outdent: false) }
        let outdent = { MarkdownEditing.indent(in: $0, selection: $1, outdent: true) }
        #expect(run("- 一\n- 二|", indent) == "- 一\n  - 二|")
        #expect(run("1. 一\n2. 二|", indent) == "1. 一\n   2. 二|")
        #expect(run("- 一\n  - 二|", outdent) == "- 一\n- 二|")
        #expect(run("\t- 二|", outdent) == "- 二|")
        #expect(run("- 一|", outdent) == "- 一|")
        #expect(run("段落|", indent) == nil)
        #expect(run("[[- 一\n- 二]]\n", indent) == "[  - 一\n  - 二]\n")
    }

    @Test("加粗和斜体可以包裹、取消，空选区插入成对标记")
    func emphasisToggles() {
        let bold = { MarkdownEditing.toggleEmphasis("**", in: $0, selection: $1) }
        let italic = { MarkdownEditing.toggleEmphasis("*", in: $0, selection: $1) }
        #expect(run("一[[二]]三", bold) == "一**[二]**三")
        #expect(run("一**[[二]]**三", bold) == "一[二]三")
        #expect(run("一[[**二**]]三", bold) == "一[二]三")
        #expect(run("一|三", bold) == "一**|**三")
        #expect(run("一[[二]]三", italic) == "一*[二]*三")
        #expect(run("一*[[二]]*三", italic) == "一[二]三")
        // Italic on bold text adds italic rather than turning bold into italic.
        #expect(run("**[[二]]**", italic) == "***[二]***")
        #expect(run("***[[二]]***", italic) == "**[二]**")
    }

    @Test("链接：选中文字放进方括号，选中网址放进圆括号")
    func linkWrapsTextOrURL() {
        let link = { MarkdownEditing.link(in: $0, selection: $1) }
        #expect(run("看[[这里]]吧", link) == "看[这里](|)吧")
        #expect(run("[[https://a.cn]]", link) == "[|](https://a.cn)")
        #expect(run("|", link) == "[](|)")
    }

    @Test("字数统计：中日韩文字逐字计数，英文和数字按词计数")
    func wordCount() {
        #expect(StatusBar.wordCount("") == 0)
        #expect(StatusBar.wordCount("你好，世界") == 4)
        #expect(StatusBar.wordCount("Hello, world 2026") == 3)
        #expect(StatusBar.wordCount("# 标题 Title\n- 列表 item") == 6)
    }
}
