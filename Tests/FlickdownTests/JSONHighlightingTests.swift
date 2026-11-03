import Foundation
import Testing
@testable import Flickdown

struct JSONHighlightingTests {
    @Test("JSON 的键、字符串、数字、字面值和结构符号独立着色")
    func standardJSONTokens() {
        let source = #"{"姓名":"中文 😀 true 123 #","active":true,"deleted":false,"value":null,"numbers":[-12.50e+2,0,3E-4]}"#
        let tokens = scan(source)
        #expect(tokens.filter { $0.kind == .key }.map(\.text) == ["\"姓名\"", "\"active\"", "\"deleted\"", "\"value\"", "\"numbers\""])
        #expect(tokens.filter { $0.kind == .string }.map(\.text) == ["\"中文 😀 true 123 #\""])
        #expect(tokens.filter { $0.kind == .literal }.map(\.text) == ["true", "false", "null"])
        #expect(tokens.filter { $0.kind == .number }.map(\.text) == ["-12.50e+2", "0", "3E-4"])
        #expect(tokens.filter { $0.kind == .punctuation }.map(\.text) == ["{", ":", ",", ":", ",", ":", ",", ":", ",", ":", "[", ",", ",", "]", "}"])
    }

    @Test("字符串转义、Unicode 和非 BMP 字符不破坏 UTF16 范围")
    func escapedStringsPreserveRanges() {
        let source = #"{"a\"b":"quote: \" slash: \\ solidus: \/ controls: \b\f\n\r\t unicode: \u4E2D\uD83D\uDE00 😀","next":true}"#
        let tokens = scan(source)
        #expect(tokens.filter { $0.kind == .key }.map(\.text) == [#""a\"b""#, #""next""#])
        let strings = tokens.filter { $0.kind == .string }
        #expect(strings.count == 1)
        #expect(strings.first?.text == #""quote: \" slash: \\ solidus: \/ controls: \b\f\n\r\t unicode: \u4E2D\uD83D\uDE00 😀""#)
        let literal = tokens.first { $0.kind == .literal }
        #expect(literal?.range == (source as NSString).range(of: "true", options: .backwards))
    }

    @Test("键名后跨行的冒号仍能识别，发出的范围保持绝对偏移")
    func keysLookAheadAcrossJSONWhitespace() {
        let prefix = "{\r\n"
        let keyLine = "  \"中文😀\"  "
        let source = prefix + keyLine + "\r\n\t : \"value\"\r\n}"
        let range = NSRange(location: (prefix as NSString).length, length: (keyLine as NSString).length)
        let tokens = scan(source, range: range)
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .key)
        #expect(tokens.first?.range == (source as NSString).range(of: "\"中文😀\""))

        let valueRange = (source as NSString).range(of: "\"value\"")
        #expect(scan(source, range: valueRange).first?.kind == .string)
        #expect(scan("\"key\"\u{00A0}:").first?.kind == .string)
    }

    @Test("完整 JSON 数字和小写字面值按词边界识别")
    func numbersAndLiteralsFollowJSONGrammar() {
        let valid = "[0,-0,10,-42,1.25,0.5,1e3,1E+3,-2.5e-12,true,false,null]"
        let tokens = scan(valid)
        #expect(tokens.filter { $0.kind == .number }.map(\.text) == ["0", "-0", "10", "-42", "1.25", "0.5", "1e3", "1E+3", "-2.5e-12"])
        #expect(tokens.filter { $0.kind == .literal }.map(\.text) == ["true", "false", "null"])

        let invalid = "[01,-01,+1,.5,1.,1e,1e+,0x10,NaN,Infinity,TRUE,False,NULL,trueValue,false1,nullish]"
        #expect(scan(invalid).allSatisfy { $0.kind == .punctuation })
    }

    @Test("不完整字符串和结尾反斜杠安全着色，不把下一行当成字符串续行")
    func incompleteEditingStaysWithinLine() {
        let line = "\"unterminated true 123 #\\"
        let source = line + "\nfalse"
        let firstLine = NSRange(location: 0, length: (line as NSString).length)
        let tokens = scan(source, range: firstLine)
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .string)
        #expect(tokens.first?.text == line)
        #expect(tokens.first?.range == firstLine)

        let secondLine = (source as NSString).range(of: "false")
        #expect(scan(source, range: secondLine).first?.kind == .literal)
        #expect(scan("", range: NSRange(location: 0, length: 0)).isEmpty)
    }

    @Test("单引号、裸键和注释不作为 JSON 扩展语法处理")
    func doesNotAddJSON5OrCommentSyntax() {
        let source = "{'key':'value',bare:undefined,//comment /*comment*/}"
        #expect(scan(source).allSatisfy { $0.kind == .punctuation })
    }

    private struct Token {
        let text: String
        let range: NSRange
        let kind: SyntaxTokenKind
    }

    private func scan(_ source: String, range: NSRange? = nil) -> [Token] {
        let text = source as NSString
        var tokens: [Token] = []
        JSONHighlighter.scan(text, range: range ?? NSRange(location: 0, length: text.length)) {
            tokens.append(Token(text: text.substring(with: $0), range: $0, kind: $1))
        }
        return tokens
    }
}
