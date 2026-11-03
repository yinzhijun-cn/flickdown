import AppKit
import Testing
@testable import Flickdown

@Suite("文档标签", .serialized)
@MainActor
struct DocumentTabTests {
    @Test("打开、切换和关闭标签保留独立的编辑、撤销和保存状态")
    func documentsOpenInTabsAndKeepIndependentState() throws {
        _ = NSApplication.shared
        let automaticTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        defer { NSWindow.allowsAutomaticWindowTabbing = automaticTabbing }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["first.txt", "second.txt", "third.txt", "separate.txt"].map {
            directory.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath()
        }
        for (index, url) in urls.enumerated() {
            try Data("文件 \(index)\n".utf8).write(to: url)
        }

        let app = AppDelegate()
        var opened: [DocumentWindowController] = []
        defer { opened.forEach { $0.close() } }
        func document(at url: URL, excluding closed: DocumentWindowController? = nil) throws -> DocumentWindowController {
            try #require(NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
                .first { $0.fileURL == url && $0 !== closed })
        }

        // The first explicit window isolates this scenario from other AppKit test windows.
        app.open([urls[0]], inNewWindow: true)
        let first = try document(at: urls[0])
        opened.append(first)
        let firstWindow = try #require(first.window)
        first.showWindow(nil)
        app.open([urls[1]])
        let second = try document(at: urls[1])
        opened.append(second)
        let secondWindow = try #require(second.window)
        app.open([urls[2]])
        let third = try document(at: urls[2])
        opened.append(third)
        let thirdWindow = try #require(third.window)
        let group = try #require(firstWindow.tabGroup)

        #expect(group.windows == [firstWindow, secondWindow, thirdWindow])
        #expect(group.selectedWindow === thirdWindow)
        #expect(secondWindow.tabGroup === group)
        #expect(thirdWindow.tabGroup === group)

        // Reopening an existing path selects its tab, including through a symbolic link.
        let alias = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: urls[0])
        app.open([alias])
        #expect(group.windows.count == 3)
        #expect(group.selectedWindow === firstWindow)
        #expect(try document(at: urls[0]) === first)

        let firstEditor = try #require(first.editor)
        let secondEditor = try #require(second.editor)
        let firstUndo = try #require(firstEditor.textView.undoManager)
        let secondUndo = try #require(secondEditor.textView.undoManager)
        #expect(firstUndo !== secondUndo)
        firstUndo.groupsByEvent = false
        secondUndo.groupsByEvent = false

        firstUndo.beginUndoGrouping()
        firstEditor.textView.insertText("甲", replacementRange: NSRange(location: 0, length: 0))
        firstUndo.endUndoGrouping()
        firstEditor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        second.showWindow(nil)
        secondUndo.beginUndoGrouping()
        secondEditor.textView.insertText("乙", replacementRange: NSRange(location: 0, length: 0))
        secondUndo.endUndoGrouping()
        secondEditor.textView.setSelectedRange(NSRange(location: 2, length: 1))
        #expect(first.hasUnsavedChanges)
        #expect(second.hasUnsavedChanges)

        first.showWindow(nil)
        #expect(group.selectedWindow === firstWindow)
        #expect(firstEditor.textView.selectedRange() == NSRange(location: 1, length: 2))
        #expect(secondEditor.textView.selectedRange() == NSRange(location: 2, length: 1))
        firstUndo.undo()
        #expect(firstEditor.text == "文件 0\n")
        #expect(secondEditor.text == "乙文件 1\n")
        #expect(!first.hasUnsavedChanges)
        #expect(second.hasUnsavedChanges)
        firstUndo.redo()
        #expect(firstEditor.text == "甲文件 0\n")
        var saved = false
        first.save { saved = $0 }
        #expect(saved)
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "甲文件 0\n")
        #expect(try String(contentsOf: urls[1], encoding: .utf8) == "文件 1\n")
        #expect(!first.hasUnsavedChanges)
        #expect(second.hasUnsavedChanges)
        saved = false
        second.save { saved = $0 }
        #expect(saved)
        #expect(try String(contentsOf: urls[1], encoding: .utf8) == "乙文件 1\n")

        app.open([urls[3]], inNewWindow: true)
        let separate = try document(at: urls[3])
        opened.append(separate)
        let separateWindow = try #require(separate.window)
        #expect(!group.windows.contains(separateWindow))
        #expect(group.windows.count == 3)
        #expect((separateWindow.tabGroup?.windows ?? [separateWindow]) == [separateWindow])
        app.open([urls[0]], inNewWindow: true)
        #expect(try document(at: urls[0]) === first)
        #expect(group.selectedWindow === firstWindow)
        #expect(group.windows.count == 3)

        // A closed file must leave AppDelegate's registry so reopening loads a fresh controller.
        second.showWindow(nil)
        secondWindow.performClose(nil)
        #expect(group.windows == [firstWindow, thirdWindow])
        #expect(!secondWindow.isVisible)
        first.showWindow(nil)
        app.open([urls[1]])
        let reopened = try document(at: urls[1], excluding: second)
        opened.append(reopened)
        #expect(reopened !== second)
        #expect(reopened.editor?.text == "乙文件 1\n")
        #expect(!reopened.hasUnsavedChanges)
        #expect(reopened.window?.tabGroup === group)
        #expect(group.selectedWindow === reopened.window)
        #expect(group.windows.count == 3)
    }

    @Test("批量打开固定目标窗口，合并保留选中标签和未保存编辑")
    func batchesKeepTheirDestinationAndMergePreservesState() throws {
        _ = NSApplication.shared
        let automaticTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        defer { NSWindow.allowsAutomaticWindowTabbing = automaticTabbing }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["existing", "destination", "new-first", "new-second", "before-duplicate", "after-duplicate"]
        let urls = names.map { directory.appendingPathComponent("\($0).txt") }
        for url in urls { try Data("原文\n".utf8).write(to: url) }

        let app = AppDelegate()
        var opened: [DocumentWindowController] = []
        defer { opened.forEach { $0.close() } }
        func document(named name: String) throws -> DocumentWindowController {
            try #require(NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
                .first { $0.fileURL == directory.appendingPathComponent("\(name).txt") })
        }

        app.open([urls[0]], inNewWindow: true)
        let existing = try document(named: "existing")
        opened.append(existing)
        app.open([urls[1]], inNewWindow: true)
        let destination = try document(named: "destination")
        opened.append(destination)

        // Activating an existing first item must not consume the request for a new window.
        app.open([urls[0], urls[2], urls[3]], inNewWindow: true)
        let newFirst = try document(named: "new-first")
        let newSecond = try document(named: "new-second")
        opened.append(contentsOf: [newFirst, newSecond])
        let newFirstWindow = try #require(newFirst.window)
        let newSecondWindow = try #require(newSecond.window)
        let newGroup = try #require(newFirstWindow.tabGroup)
        #expect(newGroup.windows == [newFirstWindow, newSecondWindow])
        #expect(newGroup !== existing.window?.tabGroup)
        #expect(newGroup !== destination.window?.tabGroup)

        // An existing file in another group must not redirect the rest of this selection.
        destination.showWindow(nil)
        app.open([urls[4], urls[0], urls[5]])
        let beforeDuplicate = try document(named: "before-duplicate")
        let afterDuplicate = try document(named: "after-duplicate")
        opened.append(contentsOf: [beforeDuplicate, afterDuplicate])
        let destinationWindow = try #require(destination.window)
        let beforeWindow = try #require(beforeDuplicate.window)
        let afterWindow = try #require(afterDuplicate.window)
        let destinationGroup = try #require(destinationWindow.tabGroup)
        #expect(destinationGroup.windows == [destinationWindow, beforeWindow, afterWindow])
        #expect(destinationGroup.selectedWindow === afterWindow)
        #expect(existing.window?.tabGroup?.windows.count == 1)

        newFirst.showWindow(nil)
        let editor = try #require(newFirst.editor)
        editor.textView.insertText("未保存", replacementRange: NSRange(location: 0, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        beforeDuplicate.showWindow(nil)
        app.mergeAllDocumentWindows(nil)

        #expect(destinationGroup.windows.count == 6)
        #expect(destinationGroup.selectedWindow === beforeWindow)
        for document in opened { #expect(document.window?.tabGroup === destinationGroup) }
        #expect(editor.text == "未保存原文\n")
        #expect(editor.textView.selectedRange() == NSRange(location: 1, length: 2))
        #expect(newFirst.hasUnsavedChanges)
        #expect(try String(contentsOf: urls[2], encoding: .utf8) == "原文\n")
    }
}
