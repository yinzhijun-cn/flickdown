import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var documents: [DocumentWindowController] = []
    private var untitledCount = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        Bench.mark("willFinishLaunching")
        DebugHooks.configureApp()
        // Open requests choose their tab group explicitly, independent of the system preference.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()

        // Paths given on the command line (e.g. running the binary directly).
        open(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Bench.mark("didFinishLaunching")
        // Needed when started from a terminal; Finder and `open` already activate us.
        NSApp.activate()
        if documents.isEmpty { showOpenPanel(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Bench.mark("open event", urls.map(\.lastPathComponent).joined(separator: ", "))
        open(urls.filter(\.isFileURL))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showOpenPanel(nil) }
        return false
    }

    // Stay running after the last window closes so the next open skips process launch entirely.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = documents.filter(\.hasUnsavedChanges)
        guard !unsaved.isEmpty else { return .terminateNow }
        confirmQuit(reviewing: unsaved)
        return .terminateLater
    }

    /// Asks about each document with unsaved changes in turn; Cancel on any of them cancels quitting.
    private func confirmQuit(reviewing docs: [DocumentWindowController]) {
        guard let doc = docs.first else { return NSApp.reply(toApplicationShouldTerminate: true) }
        doc.showWindow(nil)
        doc.confirmUnsavedChanges { [weak self] proceed in
            if proceed {
                self?.confirmQuit(reviewing: Array(docs.dropFirst()))
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    func open(_ urls: [URL], inNewWindow: Bool = false) {
        let frontWindow = NSApp.orderedWindows.first { $0.windowController is DocumentWindowController } ?? documents.last?.window
        // Keep one destination for the whole selection, even when an existing file activates another group.
        var tabTarget = inNewWindow ? nil : (frontWindow?.tabGroup?.selectedWindow ?? frontWindow)
        for url in urls {
            let url = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = documents.first(where: { $0.fileURL == url }) {
                existing.showWindow(nil)
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }

            guard let doc = DocumentWindowController(fileURL: url, tabbedWith: tabTarget) else { continue }
            add(doc)
            tabTarget = doc.window
            // Updating the recent-items list is a synchronous XPC round trip; keep it off the open path.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
        }
    }

    func openSelectedText(_ text: String, from source: DocumentWindowController, inNewWindow: Bool) {
        guard !text.isEmpty else { return }
        let document = DocumentWindowController(selectedText: text, tabbedWith: inNewWindow ? nil : source.window)
        add(document)
    }

    @objc func newDocument(_ sender: Any?) {
        untitledCount += 1
        let name = untitledCount == 1 ? L("未命名", "Untitled") : L("未命名 \(untitledCount)", "Untitled \(untitledCount)")
        let frontWindow = NSApp.orderedWindows.first { $0.windowController is DocumentWindowController }
        let tabTarget = frontWindow?.tabGroup?.selectedWindow ?? frontWindow
        add(DocumentWindowController(untitledName: name, tabbedWith: tabTarget))
    }

    private func add(_ doc: DocumentWindowController) {
        doc.onClose = { [weak self] closed in self?.documents.removeAll { $0 === closed } }
        documents.append(doc)
        if let window = doc.window { DebugHooks.configure(window) }
    }

    @objc func mergeAllDocumentWindows(_ sender: Any?) {
        guard let frontWindow = NSApp.orderedWindows.first(where: { $0.windowController is DocumentWindowController }),
              let group = frontWindow.tabGroup else { return }
        let selectedWindow = group.selectedWindow
        // AppKit's mergeAllWindows action does nothing when automatic window tabbing is disabled.
        for document in documents {
            if let window = document.window, window.tabGroup !== group { group.addWindow(window) }
        }
        group.selectedWindow = selectedWindow
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(mergeAllDocumentWindows(_:)) {
            guard let group = documents.first?.window?.tabGroup else { return false }
            return documents.contains { $0.window?.tabGroup !== group }
        }
        return true
    }

    @objc func showOpenPanel(_ sender: Any?) {
        showOpenPanel(inNewWindow: false)
    }

    @objc func showOpenPanelInNewWindow(_ sender: Any?) {
        showOpenPanel(inNewWindow: true)
    }

    private func showOpenPanel(inNewWindow: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Text files can have any extension (or none); validate their contents when opening.
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                self?.open(panel.urls, inNewWindow: inNewWindow)
            }
        }
    }
}

/// Routes "Open Recent" (File menu and Dock) to AppDelegate; the app doesn't use NSDocument.
final class RecentDocumentsController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        (NSApp.delegate as? AppDelegate)?.open([url])
        completionHandler(nil, false, nil)
    }
}
