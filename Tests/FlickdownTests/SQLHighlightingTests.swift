import AppKit
import Testing
@testable import Flickdown

@Suite("SQL 语法高亮", .serialized)
@MainActor
struct SQLHighlightingTests {
    @Test("SQL 标记保持边界，字符串和注释中的关键字不被重新着色")
    func tokensRespectQuotesCommentsAndUnicode() {
        let source = "select 名称, 中文SELECT, my_select, SELECTED, '😀 SELECT -- /* it''s', 'it\\'s', \"a\\\"FROM\", `order``by`, 12.5 FROM records -- WHERE 999" as NSString
        var state = SQLHighlighter.State.code
        var tokens: [(NSRange, SyntaxTokenKind)] = []
        SQLHighlighter.scan(source, range: NSRange(location: 0, length: source.length), state: &state) {
            tokens.append(($0, $1))
        }

        let keywords = tokens.compactMap { range, kind -> String? in
            guard case .keyword = kind else { return nil }
            return source.substring(with: range)
        }
        let strings = tokens.compactMap { range, kind -> String? in
            guard case .string = kind else { return nil }
            return source.substring(with: range)
        }
        let identifiers = tokens.compactMap { range, kind -> String? in
            guard case .identifier = kind else { return nil }
            return source.substring(with: range)
        }
        let numbers = tokens.compactMap { range, kind -> String? in
            guard case .number = kind else { return nil }
            return source.substring(with: range)
        }
        let comments = tokens.compactMap { range, kind -> String? in
            guard case .comment = kind else { return nil }
            return source.substring(with: range)
        }
        #expect(keywords == ["select", "FROM"])
        #expect(strings == ["'😀 SELECT -- /* it''s'", "'it\\'s'"])
        #expect(identifiers == ["\"a\\\"FROM\"", "`order``by`"])
        #expect(numbers == ["12.5"])
        #expect(comments == ["-- WHERE 999"])
    }

    @Test("多行注释和引号跨行延续，闭合后恢复 SQL 高亮")
    func multilineStateSurvivesLineBoundaries() {
        let lines = [
            "SELECT /* first 'ignored'",
            "SELECT 99 -- ignored",
            "*/ SELECT '跨行 😀",
            "FROM -- still string''quote'",
            "FROM records; # WHERE 123"
        ]
        let source = lines.joined(separator: "\r\n") as NSString
        var state = SQLHighlighter.State.code
        var tokens: [(NSRange, SyntaxTokenKind)] = []
        var offset = 0
        for line in lines {
            let length = (line as NSString).length
            SQLHighlighter.scan(source, range: NSRange(location: offset, length: length), state: &state) {
                tokens.append(($0, $1))
            }
            offset += length + 2
        }

        let keywords = tokens.compactMap { range, kind -> String? in
            guard case .keyword = kind else { return nil }
            return source.substring(with: range)
        }
        let strings = tokens.compactMap { range, kind -> String? in
            guard case .string = kind else { return nil }
            return source.substring(with: range)
        }
        let comments = tokens.compactMap { range, kind -> String? in
            guard case .comment = kind else { return nil }
            return source.substring(with: range)
        }
        #expect(keywords == ["SELECT", "SELECT", "FROM"])
        #expect(strings == ["'跨行 😀", "FROM -- still string''quote'"])
        #expect(comments == ["/* first 'ignored'", "SELECT 99 -- ignored", "*/", "# WHERE 123"])
        if case .code = state {} else { Issue.record("行注释结束后应该回到代码状态") }
    }

    @Test("滚动到块注释中部保持颜色，修改前面的分隔符后刷新可见区")
    func visibleHighlightingTracksEarlierEdits() async throws {
        _ = NSApplication.shared
        let editor = MarkdownEditor(zoom: 1, syntax: .sql)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let lines = ["/* 注释开始"] + (1...80).map { "SELECT \($0);" } + ["*/ SELECT 900;"]
        editor.setText(lines.joined(separator: "\n"))
        window.layoutIfNeeded()
        let layout = try #require(editor.textView.layoutManager)
        let container = try #require(editor.textView.textContainer)
        layout.ensureLayout(for: container)
        editor.scroll(toLine: 41)
        await flushHighlighting()

        var query = (editor.text as NSString).range(of: "SELECT 40;")
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: query.location, effectiveRange: nil) as? NSColor
                == NSColor.secondaryLabelColor)
        #expect(!editor.isDirty)

        editor.textView.insertText("", replacementRange: NSRange(location: 0, length: 2))
        layout.ensureLayout(for: container)
        editor.scroll(toLine: 41)
        await flushHighlighting()
        query = (editor.text as NSString).range(of: "SELECT 40;")
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: query.location, effectiveRange: nil) as? NSColor
                == NSColor.systemPurple)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: query.location + 7, effectiveRange: nil) as? NSColor
                == NSColor.systemBlue)
        #expect(editor.isDirty)

        editor.textView.insertText("/*", replacementRange: NSRange(location: 0, length: 0))
        layout.ensureLayout(for: container)
        editor.scroll(toLine: 41)
        await flushHighlighting()
        query = (editor.text as NSString).range(of: "SELECT 40;")
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: query.location, effectiveRange: nil) as? NSColor
                == NSColor.secondaryLabelColor)
    }

    @Test("CRLF 跨越行索引缓冲区时不重复计行，后续 SQL 状态正确")
    func crlfAcrossIndexBufferPreservesLineState() async throws {
        _ = NSApplication.shared
        let editor = MarkdownEditor(zoom: 1, syntax: .sql)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let firstLineLength = (1 << 16) - 1
        let firstLine = "/*" + String(repeating: "x", count: firstLineLength - 2)
        let secondLine = "*/ SELECT 1;"
        let text = firstLine + "\r\n" + secondLine + "\r\n"
        editor.setText(text)
        let secondLineStart = firstLineLength + 2
        #expect(editor.lineStarts == [0, secondLineStart, (text as NSString).length])
        #expect(editor.lineCount == 3)

        window.layoutIfNeeded()
        let layout = try #require(editor.textView.layoutManager)
        let container = try #require(editor.textView.textContainer)
        layout.ensureLayout(for: container)
        editor.scroll(toLine: 2)
        await flushHighlighting()
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: secondLineStart, effectiveRange: nil) as? NSColor
                == NSColor.secondaryLabelColor)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: secondLineStart + 3, effectiveRange: nil) as? NSColor
                == NSColor.systemPurple)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: secondLineStart + 10, effectiveRange: nil) as? NSColor
                == NSColor.systemBlue)
        #expect(editor.text == text)
    }

    @Test("大写 SQL 扩展名自动高亮，保存保留原文与换行")
    func sqlDocumentOpensAndSavesWithoutChangingText() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("query.SQL")
        let text = "SELECT '中文 😀' AS message;\r\n"
        try Data(text.utf8).write(to: url)
        let document = try #require(DocumentWindowController(fileURL: url))
        defer { document.close() }
        let editor = try #require(document.editor)
        await flushHighlighting()

        #expect(document.mode == .source)
        #expect(document.loadedPage == nil)
        #expect(editor.headings().isEmpty)
        #expect(editor.text == text)
        #expect(!document.hasUnsavedChanges)
        let layout = try #require(editor.textView.layoutManager)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
                == NSColor.systemPurple)
        var saved = false
        document.save { saved = $0 }
        #expect(saved)
        #expect(try Data(contentsOf: url) == Data(text.utf8))

        let appended = "-- 保存验证\r\n"
        editor.textView.insertText(appended, replacementRange: NSRange(location: (text as NSString).length, length: 0))
        #expect(document.hasUnsavedChanges)
        saved = false
        document.save { saved = $0 }
        #expect(saved)
        #expect(try Data(contentsOf: url) == Data((text + appended).utf8))
        #expect(!document.hasUnsavedChanges)
    }

    private func flushHighlighting() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
