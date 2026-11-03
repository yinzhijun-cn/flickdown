import AppKit
import Testing
@testable import Flickdown

@Suite("JSON 与 YAML 文档", .serialized)
@MainActor
struct StructuredTextDocumentTests {
    @Test("JSON、YAML、YML 自动高亮，保存保持原文和换行")
    func structuredFilesOpenAndSaveWithoutReformatting() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["config.json", "config.JSON", "config.yaml", "config.YML"] {
            let json = name.lowercased().hasSuffix(".json")
            let text = json ? "{\r\n  \"enabled\": true, \"count\": 42, \"name\": \"中文 😀\"\r\n}\r\n"
                            : "enabled: true\r\ncount: 42\r\nname: \"中文 😀\"\r\n"
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            let document = try #require(DocumentWindowController(fileURL: url))
            defer { document.close() }
            let editor = try #require(document.editor)
            await flushHighlighting()

            #expect(document.mode == .source)
            #expect(document.loadedPage == nil)
            #expect(editor.headings().isEmpty)
            #expect(!document.hasUnsavedChanges)
            let layout = try #require(editor.textView.layoutManager)
            let string = editor.text as NSString
            #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: string.range(of: "enabled").location,
                                             effectiveRange: nil) as? NSColor == NSColor.systemTeal)
            #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: string.range(of: "true").location,
                                             effectiveRange: nil) as? NSColor == NSColor.systemPurple)
            #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: string.range(of: "42").location,
                                             effectiveRange: nil) as? NSColor == NSColor.systemBlue)
            var saved = false
            document.save { saved = $0 }
            #expect(saved)
            #expect(try Data(contentsOf: url) == Data(text.utf8))

            editor.textView.insertText(" ", replacementRange: NSRange(location: string.length, length: 0))
            #expect(document.hasUnsavedChanges)
            saved = false
            document.save { saved = $0 }
            #expect(saved)
            #expect(try Data(contentsOf: url) == Data((text + " ").utf8))
            #expect(!document.hasUnsavedChanges)
        }
    }

    @Test("YAML 文本块滚动后保持字符串颜色，修改块标记后刷新")
    func yamlBlockStateTracksScrollingAndEdits() async throws {
        _ = NSApplication.shared
        let editor = MarkdownEditor(zoom: 1, syntax: .yaml)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let text = (["script: |"] + (1...80).map { "  # line \($0): true" } + ["enabled: false"]).joined(separator: "\n")
        editor.setText(text)
        window.layoutIfNeeded()
        let layout = try #require(editor.textView.layoutManager)
        let container = try #require(editor.textView.textContainer)
        layout.ensureLayout(for: container)
        editor.scroll(toLine: 41)
        await flushHighlighting()
        var offset = (editor.text as NSString).range(of: "# line 40").location
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
                == NSColor.systemRed)
        #expect(!editor.isDirty)

        editor.textView.insertText("", replacementRange: (editor.text as NSString).range(of: "|"))
        layout.ensureLayout(for: container)
        editor.scroll(toLine: 41)
        await flushHighlighting()
        offset = (editor.text as NSString).range(of: "# line 40").location
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
                == NSColor.secondaryLabelColor)

        editor.textView.insertText("|", replacementRange: NSRange(location: 8, length: 0))
        layout.ensureLayout(for: container)
        editor.scroll(toLine: 41)
        await flushHighlighting()
        offset = (editor.text as NSString).range(of: "# line 40").location
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
                == NSColor.systemRed)
        #expect(editor.text == text)
    }

    @Test("Unicode 分隔符留在字符串内，高亮与行索引使用同一边界")
    func unicodeSeparatorsDoNotSplitSyntaxLines() async throws {
        _ = NSApplication.shared
        let cases: [(MarkdownEditor.Syntax, String)] = [
            (.json, "{\"name\": \"first\u{2028}middle\u{2029}last\",\n\"enabled\": true}"),
            (.yaml, "name: \"first\u{2028}middle\u{2029}last\"\nenabled: true"),
            (.sql, "SELECT 'first\u{2028}middle\u{2029}last';\nSELECT true;")
        ]
        for (syntax, text) in cases {
            let editor = MarkdownEditor(zoom: 1, syntax: syntax)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor.scrollView
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            editor.setText(text)
            await flushHighlighting()
            let layout = try #require(editor.textView.layoutManager)
            let string = text as NSString
            #expect(editor.lineCount == 2)
            #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: string.range(of: "middle").location,
                                             effectiveRange: nil) as? NSColor == NSColor.systemRed)
            #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: string.range(of: "true").location,
                                             effectiveRange: nil) as? NSColor == NSColor.systemPurple)
            #expect(editor.text == text)
            #expect(!editor.isDirty)
        }
    }

    private func flushHighlighting() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
