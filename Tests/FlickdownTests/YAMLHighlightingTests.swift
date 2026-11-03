import Foundation
import Testing
@testable import Flickdown

struct YAMLHighlightingTests {
    @Test("YAML 键和完整标量按边界识别，URL 内的冒号和井号保留原义")
    func keysScalarsAndCommentsRespectBoundaries() {
        let tokens = scan([
            "标题 😀: http://example.test/a#fragment",
            "\"键: #\": 'it''s # plain'",
            "truth: true story",
            "flag: true",
            "false-key: FALSE",
            "count: -12.5e+2",
            "duration: 12ms",
            "nullish: nullish",
            "nil: ~",
            "hash: foo#bar # actual comment",
            "legacy: yes"
        ])
        #expect(tokens.filter { $0.1 == .key }.map(\.0) == [
            "标题 😀", "\"键: #\"", "truth", "flag", "false-key", "count", "duration", "nullish", "nil", "hash", "legacy"
        ])
        #expect(tokens.filter { $0.1 == .literal }.map(\.0) == ["true", "FALSE", "~"])
        #expect(tokens.filter { $0.1 == .number }.map(\.0) == ["-12.5e+2"])
        #expect(tokens.filter { $0.1 == .comment }.map(\.0) == ["# actual comment"])
        #expect(tokens.filter { $0.1 == .string }.map(\.0) == [
            "http://example.test/a#fragment", "'it''s # plain'", "true story", "12ms", "nullish", "foo#bar", "yes"
        ])
    }

    @Test("流式集合支持引号键、锚点、别名和标签，嵌套结构不切断 URL")
    func flowCollectionsAnchorsAndTags() {
        let tokens = scan([
            "defaults: &base { enabled: true, count: 0x2A, label: \"x:y#z\" }",
            "copy: *base",
            "typed: !!str value",
            "tagged: !<tag:example.org,2026:test> value",
            "flow: {\"a\":true, bare: false, url: http://host/#x,",
            "  nested: [null, .Inf, 10ms, yes, 'a''b']}"
        ])
        #expect(tokens.filter { $0.1 == .anchor }.map(\.0) == ["&base", "*base"])
        #expect(tokens.filter { $0.1 == .tag }.map(\.0) == ["!!str", "!<tag:example.org,2026:test>"])
        #expect(tokens.filter { $0.1 == .literal }.map(\.0) == ["true", "true", "false", "null"])
        #expect(tokens.filter { $0.1 == .number }.map(\.0) == ["0x2A", ".Inf"])
        #expect(tokens.filter { $0.1 == .comment }.isEmpty)
        #expect(tokens.contains { $0.0 == "\"a\"" && $0.1 == .key })
        #expect(tokens.contains { $0.0 == "http://host/#x" && $0.1 == .string })
        #expect(tokens.contains { $0.0 == "nested" && $0.1 == .key })
        #expect(tokens.contains { $0.0 == "'a''b'" && $0.1 == .string })
    }

    @Test("单双引号跨行延续并处理各自转义，闭合后恢复注释和映射")
    func multilineQuotesProtectContent() {
        let tokens = scan([
            "message: \"first # not a comment",
            "  still : quoted \\\"value\\\"",
            "  end\" # comment",
            "single: 'one",
            "  it''s # still text",
            "  end'",
            "next: false"
        ])
        #expect(tokens.filter { $0.1 == .key }.map(\.0) == ["message", "single", "next"])
        #expect(tokens.filter { $0.1 == .comment }.map(\.0) == ["# comment"])
        #expect(tokens.filter { $0.1 == .literal }.map(\.0) == ["false"])
        #expect(tokens.filter { $0.1 == .string }.map(\.0) == [
            "\"first # not a comment", "  still : quoted \\\"value\\\"", "  end\"", "'one", "  it''s # still text", "  end'"
        ])
    }

    @Test("块标量按正文缩进和显式指示退出，列表内的井号与冒号仍是字符串")
    func blockScalarsRespectMappingAndSequenceIndentation() {
        let tokens = scan([
            "script: |",
            "",
            "  # shell comment",
            "  key: literal text",
            "after: true",
            "&root !!str anchored: |2",
            "  # root block text",
            "---",
            "- &item !!str note: >2-",
            "    # folded text",
            "    folded: remains text",
            "  sibling: false",
            "- |1+",
            " text: still scalar",
            "- >-2",
            "  another: block",
            "- done"
        ])
        #expect(tokens.filter { $0.1 == .key }.map(\.0) == ["script", "after", "anchored", "note", "sibling"])
        #expect(tokens.filter { $0.1 == .anchor }.map(\.0) == ["&root", "&item"])
        #expect(tokens.filter { $0.1 == .literal }.map(\.0) == ["true", "false"])
        #expect(tokens.filter { $0.1 == .comment }.isEmpty)
        #expect(tokens.filter { $0.1 == .string }.map(\.0) == [
            "  # shell comment", "  key: literal text", "  # root block text", "    # folded text", "    folded: remains text",
            " text: still scalar", "  another: block", "done"
        ])
        for header in ["|", "|2", ">2-", "|1+", ">-2"] {
            #expect(tokens.contains { $0.0 == header && $0.1 == .punctuation })
        }
    }

    @Test("普通标量中的符号不创建文本块，数值只采用 YAML 1.2 完整标量")
    func ordinarySymbolsAndCoreNumbers() {
        let tokens = scan([
            "pattern: a | b > c",
            "unfinished: |word",
            "next: true",
            "percent: 99%",
            "numbers: [0o17, 0xFF, .5, +12e03, -.Inf, .NaN, 1_000, 0b10]"
        ])
        #expect(tokens.filter { $0.1 == .key }.map(\.0) == ["pattern", "unfinished", "next", "percent", "numbers"])
        #expect(tokens.filter { $0.1 == .number }.map(\.0) == ["0o17", "0xFF", ".5", "+12e03", "-.Inf", ".NaN"])
        #expect(tokens.filter { $0.1 == .string }.map(\.0) == ["a | b > c", "|word", "99%", "1_000", "0b10"])
    }

    /// Exercise the same line ranges twice: index construction and visible-token emission must agree.
    private func scan(_ lines: [String]) -> [(String, SyntaxTokenKind)] {
        let text = lines.joined(separator: "\r\n") as NSString
        var indexedState = YAMLHighlighter.State()
        var colouredState = YAMLHighlighter.State()
        var result: [(String, SyntaxTokenKind)] = []
        var offset = 0
        for line in lines {
            let range = NSRange(location: offset, length: (line as NSString).length)
            YAMLHighlighter.scan(text, range: range, state: &indexedState)
            YAMLHighlighter.scan(text, range: range, state: &colouredState) { range, kind in
                result.append((text.substring(with: range), kind))
            }
            #expect(indexedState == colouredState)
            offset += range.length + 2
        }
        #expect(colouredState == YAMLHighlighter.State())
        return result
    }
}
