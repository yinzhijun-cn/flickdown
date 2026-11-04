import AppKit
import Testing
import WebKit
@testable import Flickdown

@Suite("文本文件", .serialized)
@MainActor
struct TextDocumentTests {
    @Test("普通文本按原文打开，Markdown 快捷动作不影响视图和偏好")
    func plainTextFilesStayInTextMode() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let sourceMode = defaults.object(forKey: "sourceMode")
        let showOutline = defaults.object(forKey: "showOutline")
        defer {
            defaults.set(sourceMode, forKey: "sourceMode")
            defaults.set(showOutline, forKey: "showOutline")
        }
        Prefs.sourceMode = false
        Prefs.showOutline = true

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "# 保留井号\n**保留星号**\n<html>原样显示</html>\n"
        for name in ["notes.txt", "server.log", "config.json", "config.yaml", "main.swift", "settings.custom", "LICENSE", ".env"] {
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            let document = try #require(DocumentWindowController(fileURL: url))
            defer { document.close() }
            let editor = try #require(document.editor)

            #expect(!document.isMarkdown)
            #expect(document.mode == .source)
            #expect(editor.text == text)
            #expect(editor.headings().isEmpty)
            #expect(document.window?.contentView === editor.scrollView)

            document.setMode(.preview)
            document.setMode(.edit)
            document.toggleSource(nil)
            document.toggleOutline(nil)
            document.togglePreviewPane(nil)

            #expect(document.mode == .source)
            #expect(document.loadedPage == nil)
            #expect(document.sourceOutline == nil)
            #expect(document.splitView == nil)
            #expect(!Prefs.sourceMode)
            #expect(Prefs.showOutline)
        }
    }

    @Test("文本修改可以保存并重新载入外部变更")
    func saveAndReloadPlainText() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = "{\r\n\t\"message\": \"中文 **原文**\"\r\n}\r\n"
        try Data(original.utf8).write(to: url)
        let document = try #require(DocumentWindowController(fileURL: url))
        defer { document.close() }
        let editor = try #require(document.editor)
        #expect(editor.text == original)

        let appended = "# appended\n"
        editor.textView.insertText(appended, replacementRange: NSRange(location: (original as NSString).length, length: 0))
        #expect(document.hasUnsavedChanges)
        var saved = false
        document.save { saved = $0 }
        #expect(saved)
        #expect(try Data(contentsOf: url) == Data((original + appended).utf8))
        #expect(!document.hasUnsavedChanges)

        let external = "{\"message\": \"外部修改\"}\n"
        try Data(external.utf8).write(to: url, options: .atomic)
        document.loadFromDisk(force: false)
        #expect(editor.text == external)
        #expect(!document.hasUnsavedChanges)
        #expect(document.loadedPage == nil)
    }

    @Test("普通文本保留行号但不应用 Markdown 染色")
    func plainTextEditorDoesNotHighlightMarkdown() async throws {
        _ = NSApplication.shared
        let editor = MarkdownEditor(zoom: 1, syntax: .plainText)
        editor.scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        editor.setText("# title\n```swift\nlet value = 1\n```\n")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(editor.lineCount == 5)
        #expect(editor.headings().isEmpty)
        let layout = try #require(editor.textView.layoutManager)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
    }

    @Test("Markdown 仍保留源码大纲和渲染")
    func markdownRetainsItsFeatures() throws {
        _ = NSApplication.shared
        let text = "# 标题\n\n**加粗**\n"
        let editor = MarkdownEditor(zoom: 1, syntax: .markdown)
        editor.setText(text)

        #expect(editor.headings().map(\.title) == ["标题"])
        let html = MarkdownRenderer.htmlChunks(from: Data(text.utf8)).joined()
        #expect(html.contains("<h1>标题</h1>"))
        #expect(html.contains("<strong>加粗</strong>"))
    }

    @Test("Markdown 源码目录可以从页面收起再展开，只有一个标题时隐藏按钮")
    func sourceOutlineButtonCollapsesAndReopensOutline() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let sourceMode = defaults.object(forKey: "sourceMode")
        let showOutline = defaults.object(forKey: "showOutline")
        defer {
            defaults.set(sourceMode, forKey: "sourceMode")
            defaults.set(showOutline, forKey: "showOutline")
        }
        Prefs.sourceMode = true
        Prefs.showOutline = true

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try Data("# 文档\n## 章节\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(DocumentWindowController(fileURL: url))
        defer { document.close() }
        let window = try #require(document.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        let outline = try #require(document.sourceOutline)
        let button = outline.toggleButton
        let content = try #require(document.splitView)
        let editor = try #require(document.editor)

        func clickOutlineButton() throws {
            window.layoutIfNeeded()
            try #require(button.window === window && !button.isHiddenOrHasHiddenAncestor)
            try #require(!button.bounds.isEmpty)
            let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            let hit = try #require(content.hitTest(button.convert(center, to: content.superview)))
            try #require(hit === button || hit.isDescendant(of: button))
            let frame = button.convert(button.bounds, to: content)
            if Prefs.showOutline {
                let sidebar = outline.view.convert(outline.view.bounds, to: content)
                #expect(abs(sidebar.maxX - frame.maxX) < 25)
            } else {
                #expect(frame.minX < 25)
                #expect(editor.scrollView.bounds.width == content.bounds.width)
            }
            button.performClick(nil)
        }
        #expect(content.arrangedSubviews == [outline.view, outline.editorPane])

        try clickOutlineButton()
        #expect(!Prefs.showOutline)
        #expect(content.arrangedSubviews == [outline.editorPane])

        try clickOutlineButton()
        #expect(Prefs.showOutline)
        #expect(content.arrangedSubviews == [outline.view, outline.editorPane])

        try Data("# 文档\n".utf8).write(to: url)
        #expect(document.loadFromDisk(force: true))
        #expect(content.arrangedSubviews == [outline.editorPane])
        #expect(button.window == nil || button.isHiddenOrHasHiddenAncestor)
    }

    @Test("从源码切换到编辑分栏后，正文可见且两栏等宽")
    func editPanesAfterSourceMode() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let sourceMode = defaults.object(forKey: "sourceMode")
        defer { defaults.set(sourceMode, forKey: "sourceMode") }
        Prefs.sourceMode = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try Data("# 文档\n## 章节\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(DocumentWindowController(fileURL: url))
        defer { document.close() }
        let window = try #require(document.window)
        let editor = try #require(document.editor)
        window.setContentSize(NSSize(width: 1200, height: 650))
        window.layoutIfNeeded()

        document.mode = .edit
        editor.scrollView.removeFromSuperview()
        document.sourceOutline?.view.removeFromSuperview()
        let split = NSSplitView(frame: try #require(window.contentView).bounds)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = document
        window.contentView = split
        let preview = PreviewPane(webView: WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800)))
        document.layoutEditPanes(in: split, editor: editor, preview: preview)
        editor.scroll(toLine: 1)
        window.makeFirstResponder(editor.textView)
        window.layoutIfNeeded()

        #expect(abs(editor.scrollView.frame.width - preview.frame.width) <= split.dividerThickness)
        #expect(editor.textView.visibleRect.width > 500)
    }
}
