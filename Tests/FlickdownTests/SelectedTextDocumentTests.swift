import AppKit
import Testing
@testable import Flickdown

@Suite("选中文字打开为文档", .serialized)
@MainActor
struct SelectedTextDocumentTests {
    @Test("选中文字完整保留为未保存的纯文本，磁盘操作在首次保存前不可用")
    func selectionBecomesAnUnsavedTextDocument() throws {
        _ = NSApplication.shared
        let selection = " \t# 中文 😀\r\n" + String(repeating: "**保留原文** English\n", count: 30) + "\r\n  "
        let document = DocumentWindowController(selectedText: selection)
        defer { document.close() }
        let editor = try #require(document.editor)
        let window = try #require(document.window)

        #expect(document.fileURL == nil)
        #expect(window.representedURL == nil)
        #expect(document.mode == .source)
        #expect(!document.isMarkdown)
        #expect(document.loadedPage == nil)
        #expect(editor.text == selection)
        #expect(editor.headings().isEmpty)
        #expect(document.hasUnsavedChanges)
        #expect(window.isDocumentEdited)
        #expect(document.suddenTerminationDisabled)

        let save = NSMenuItem(title: "", action: #selector(DocumentWindowController.saveDocument(_:)), keyEquivalent: "")
        let reload = NSMenuItem(title: "", action: #selector(DocumentWindowController.reloadDocument(_:)), keyEquivalent: "")
        let reveal = NSMenuItem(title: "", action: #selector(DocumentWindowController.revealInFinder(_:)), keyEquivalent: "")
        #expect(document.validateMenuItem(save))
        #expect(!document.validateMenuItem(reload))
        #expect(!document.validateMenuItem(reveal))
    }

    @Test("新标签跟随选区所在窗口，新窗口独立，选区文档的编辑和撤销不影响原文")
    func selectionUsesTheSourceWindowAndKeepsIndependentState() throws {
        _ = NSApplication.shared
        let automaticTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        defer { NSWindow.allowsAutomaticWindowTabbing = automaticTabbing }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.txt")
        let otherURL = directory.appendingPathComponent("other.txt")
        let original = "原文件内容 😀\n"
        try Data(original.utf8).write(to: sourceURL)
        try Data("另一个窗口\n".utf8).write(to: otherURL)

        let app = AppDelegate()
        var opened: [DocumentWindowController] = []
        defer { opened.forEach { $0.close() } }
        func documents() -> [DocumentWindowController] {
            NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
        }
        app.open([sourceURL], inNewWindow: true)
        let source = try #require(documents().first { $0.fileURL == sourceURL })
        opened.append(source)
        let sourceWindow = try #require(source.window)
        let sourceEditor = try #require(source.editor)
        app.open([otherURL], inNewWindow: true)
        let other = try #require(documents().first { $0.fileURL == otherURL })
        opened.append(other)
        other.showWindow(nil)

        let selection = " \t中文 😀\r\n" + String(repeating: "selected text\n", count: 30) + "  "
        app.openSelectedText(selection, from: source, inNewWindow: false)
        let tab = try #require(documents().first { $0.fileURL == nil && $0.editor?.text == selection })
        opened.append(tab)
        let tabWindow = try #require(tab.window)
        let group = try #require(sourceWindow.tabGroup)
        #expect(group.windows == [sourceWindow, tabWindow])
        #expect(group.selectedWindow === tabWindow)
        #expect(other.window?.tabGroup !== group)

        let tabEditor = try #require(tab.editor)
        let sourceUndo = try #require(sourceEditor.textView.undoManager)
        let tabUndo = try #require(tabEditor.textView.undoManager)
        #expect(tabUndo !== sourceUndo)
        tabUndo.groupsByEvent = false
        tabUndo.beginUndoGrouping()
        tabEditor.textView.insertText("新增", replacementRange: NSRange(location: 0, length: 0))
        tabUndo.endUndoGrouping()
        #expect(tabEditor.text == "新增" + selection)
        #expect(sourceEditor.text == original)
        #expect(!source.hasUnsavedChanges)
        tabUndo.undo()
        #expect(tabEditor.text == selection)
        #expect(tab.hasUnsavedChanges)
        tabUndo.redo()
        #expect(tabEditor.text == "新增" + selection)
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == original)

        app.openSelectedText(selection, from: source, inNewWindow: true)
        let separate = try #require(documents().first {
            $0.fileURL == nil && $0 !== tab && $0.editor?.text == selection
        })
        opened.append(separate)
        let separateWindow = try #require(separate.window)
        #expect(!group.windows.contains(separateWindow))
        #expect((separateWindow.tabGroup?.windows ?? [separateWindow]) == [separateWindow])
        #expect(separate.editor?.text == selection)
        #expect(separate.hasUnsavedChanges)

        let count = documents().count
        app.openSelectedText("", from: source, inNewWindow: false)
        #expect(documents().count == count)
        let whitespace = " \t\r\n"
        app.openSelectedText(whitespace, from: source, inNewWindow: false)
        let blank = try #require(documents().first { $0.fileURL == nil && $0.editor?.text == whitespace })
        opened.append(blank)
        #expect(blank.window?.tabGroup === group)
        #expect(blank.hasUnsavedChanges)
    }

    @Test("右键菜单保留完整选区快照和原生复制项，选区变化不改变待打开内容")
    func contextMenuOpensTheCapturedSelection() throws {
        _ = NSApplication.shared
        let automaticTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        defer { NSWindow.allowsAutomaticWindowTabbing = automaticTabbing }
        let previousDelegate = NSApp.delegate
        let app = AppDelegate()
        NSApp.delegate = app
        defer { NSApp.delegate = previousDelegate }

        let prefix = "选区外 😀\n"
        let selection = " \t菜单快照 😀 English\r\n" + String(repeating: "完整保留 selected text\n", count: 30) + "  "
        let text = prefix + selection + "\n选区外结尾"
        let document = DocumentWindowController(selectedText: text)
        var opened = [document]
        defer { opened.forEach { $0.close() } }
        let editor = try #require(document.editor)
        let window = try #require(document.window)
        let range = NSRange(location: (prefix as NSString).length, length: (selection as NSString).length)
        editor.textView.setSelectedRange(range)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let originalMenu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        originalMenu.addItem(copy)
        let menu = try #require(editor.textView(editor.textView, menu: originalMenu, for: event, at: range.location))
        let newTab = try #require(menu.items.first { $0.action == #selector(DocumentWindowController.openSelectionInNewTab(_:)) })
        let newWindow = try #require(menu.items.first { $0.action == #selector(DocumentWindowController.openSelectionInNewWindow(_:)) })

        #expect(menu === originalMenu)
        #expect(menu.items.contains { $0 === copy })
        for item in [newTab, newWindow] {
            #expect(item.representedObject as? String == selection)
            #expect((item.target as? DocumentWindowController) === document)
        }

        editor.textView.setSelectedRange(NSRange(location: 0, length: (prefix as NSString).length))
        document.openSelectionInNewTab(newTab)
        let copied = try #require(NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
            .first { $0 !== document && $0.fileURL == nil && $0.editor?.text == selection })
        opened.append(copied)
        #expect(copied.editor?.text == selection)
        #expect(editor.text == text)
        #expect(copied.window?.tabGroup === window.tabGroup)
        #expect(window.tabGroup?.selectedWindow === copied.window)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let emptyMenu = NSMenu()
        emptyMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        let unchanged = try #require(editor.textView(editor.textView, menu: emptyMenu, for: event, at: 0))
        #expect(unchanged === emptyMenu)
        #expect(unchanged.items.count == 1)
        #expect(unchanged.items[0].action == #selector(NSText.copy(_:)))
    }

    @Test("首次保存建立文件身份，后续保存和重新载入沿用同一个文件")
    func firstSaveCreatesAFileAndEnablesNormalDocumentOperations() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("所选文字.txt")
        let text = " \t中文 😀 English\r\n保留首尾空白\r\n  "
        let document = DocumentWindowController(selectedText: text)
        defer { document.close() }
        let editor = try #require(document.editor)
        let window = try #require(document.window)

        #expect(document.write(to: url))
        #expect(try Data(contentsOf: url) == Data(text.utf8))
        #expect(document.fileURL == url)
        #expect(window.representedURL == url)
        #expect(window.title == url.lastPathComponent)
        #expect(window.tab.toolTip == url.path)
        #expect(!document.hasUnsavedChanges)
        #expect(!window.isDocumentEdited)
        #expect(!document.suddenTerminationDisabled)

        let reload = NSMenuItem(title: "", action: #selector(DocumentWindowController.reloadDocument(_:)), keyEquivalent: "")
        let reveal = NSMenuItem(title: "", action: #selector(DocumentWindowController.revealInFinder(_:)), keyEquivalent: "")
        #expect(document.validateMenuItem(reload))
        #expect(document.validateMenuItem(reveal))

        editor.textView.insertText("后续修改\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(document.hasUnsavedChanges)
        var saved = false
        document.save { saved = $0 }
        #expect(saved)
        #expect(try Data(contentsOf: url) == Data(("后续修改\n" + text).utf8))
        #expect(!document.hasUnsavedChanges)

        let external = "外部修改 😀\r\n"
        try Data(external.utf8).write(to: url, options: .atomic)
        #expect(document.loadFromDisk(force: false))
        #expect(editor.text == external)
        #expect(!document.hasUnsavedChanges)
        #expect(document.loadedPage == nil)
    }
}
