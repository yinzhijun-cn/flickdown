import AppKit
import Testing
@testable import Flickdown

@Suite("文档存储为", .serialized)
@MainActor
struct SaveAsDocumentTests {
    @Test("普通文本和 JSON 另存后更新文件身份，后续保存和重新载入使用新路径")
    func savingAsANewFilePreservesTheOriginalAndUpdatesDocumentIdentity() throws {
        _ = NSApplication.shared
        let automaticTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        defer { NSWindow.allowsAutomaticWindowTabbing = automaticTabbing }

        for fileExtension in ["txt", "json"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sourceURL = directory.appendingPathComponent("original.\(fileExtension)")
            let targetURL = directory.appendingPathComponent("saved-copy.\(fileExtension)")
            let original = "{\r\n  \"message\": \"原始内容 中文 😀\"\r\n}\r\n"
            try Data(original.utf8).write(to: sourceURL)

            let app = AppDelegate()
            var opened: [DocumentWindowController] = []
            defer { opened.forEach { $0.close() } }
            app.open([sourceURL], inNewWindow: true)
            let document = try #require(NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
                .first { $0.fileURL == sourceURL })
            opened.append(document)
            let editor = try #require(document.editor)
            let window = try #require(document.window)
            let changed = original.replacingOccurrences(of: "原始内容", with: "另存内容")
            editor.textView.insertText("另存内容", replacementRange: (original as NSString).range(of: "原始内容"))
            #expect(document.hasUnsavedChanges)

            #expect(document.write(to: targetURL))
            #expect(try Data(contentsOf: sourceURL) == Data(original.utf8))
            #expect(try Data(contentsOf: targetURL) == Data(changed.utf8))
            #expect(document.fileURL == targetURL)
            #expect(document.displayName == targetURL.lastPathComponent)
            #expect(window.title == targetURL.lastPathComponent)
            #expect(window.representedURL == targetURL)
            #expect(window.tab.toolTip == targetURL.path)
            #expect(document.mode == .source)
            #expect(!document.isMarkdown)
            #expect(document.loadedPage == nil)
            #expect(!document.hasUnsavedChanges)
            #expect(!window.isDocumentEdited)

            // The saved path now belongs to this controller, so opening it again selects this tab.
            let group = try #require(window.tabGroup)
            let tabCount = group.windows.count
            app.open([targetURL])
            let matching = NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
                .filter { $0.fileURL == targetURL }
            #expect(matching.count == 1)
            #expect(matching.first === document)
            #expect(group.windows.count == tabCount)
            #expect(group.selectedWindow === window)

            editor.textView.insertText("  ", replacementRange: NSRange(location: (changed as NSString).length, length: 0))
            var saved = false
            document.save { saved = $0 }
            #expect(saved)
            #expect(try Data(contentsOf: targetURL) == Data((changed + "  ").utf8))
            #expect(try Data(contentsOf: sourceURL) == Data(original.utf8))
            #expect(!document.hasUnsavedChanges)

            let external = "{\"message\": \"新路径上的外部修改 😀\"}\r\n"
            try Data(external.utf8).write(to: targetURL, options: .atomic)
            #expect(document.loadFromDisk(force: false))
            #expect(editor.text == external)
            #expect(!document.hasUnsavedChanges)
            #expect(document.loadedPage == nil)

            // The original path is free to open independently, with its unchanged disk contents.
            app.open([sourceURL])
            let originalDocument = try #require(NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
                .first { $0.fileURL == sourceURL })
            opened.append(originalDocument)
            #expect(originalDocument !== document)
            #expect(originalDocument.editor?.text == original)
            #expect(originalDocument.window?.tabGroup === group)
        }
    }

    @Test("UTF-16 文档另存和后续保存保留字节序、BOM、中文及换行")
    func savingAsPreservesUTF16EncodingAndByteOrderMark() throws {
        _ = NSApplication.shared
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sourceURL = directory.appendingPathComponent("original.txt")
            let targetURL = directory.appendingPathComponent("utf16-copy.txt")
            let original = "\u{FEFF}中文 English 😀\r\n保留编码与换行\r\n"
            let originalBytes = try #require(original.data(using: encoding))
            try originalBytes.write(to: sourceURL)
            let document = try #require(DocumentWindowController(fileURL: sourceURL))
            defer { document.close() }
            let editor = try #require(document.editor)
            #expect(editor.text == original)
            #expect(document.fileEncoding == encoding)

            #expect(document.write(to: targetURL))
            #expect(try Data(contentsOf: targetURL) == originalBytes)
            #expect(document.fileURL == targetURL)
            #expect(document.fileEncoding == encoding)

            let appended = "后续修改 😀\r\n"
            editor.textView.insertText(appended, replacementRange: NSRange(location: (original as NSString).length, length: 0))
            var saved = false
            document.save { saved = $0 }
            #expect(saved)
            let expectedBytes = try #require((original + appended).data(using: encoding))
            #expect(try Data(contentsOf: targetURL) == expectedBytes)
            #expect(try Data(contentsOf: sourceURL) == originalBytes)
            #expect(!document.hasUnsavedChanges)
            #expect(document.loadFromDisk(force: true))
            #expect(editor.text == original + appended)
            #expect(document.fileEncoding == encoding)
        }
    }
}
