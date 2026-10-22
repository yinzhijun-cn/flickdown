import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documents: [DocumentWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        Bench.mark("willFinishLaunching")
        DebugHooks.configureApp()
        NSApp.mainMenu = MainMenu.build()

        // Paths given on the command line (e.g. running the binary directly).
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            if FileManager.default.fileExists(atPath: arg) { open(URL(fileURLWithPath: arg)) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Bench.mark("didFinishLaunching")
        // Needed when started from a terminal; Finder and `open` already activate us.
        NSApp.activate()
        if documents.isEmpty { showOpenPanel(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Bench.mark("open event", urls.map(\.lastPathComponent).joined(separator: ", "))
        for url in urls where url.isFileURL { open(url) }
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

    func open(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = documents.first(where: { $0.fileURL == url }) {
            existing.showWindow(nil)
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }

        let doc = DocumentWindowController(fileURL: url)
        doc.onClose = { [weak self] closed in self?.documents.removeAll { $0 === closed } }
        documents.append(doc)
        if let window = doc.window { DebugHooks.configure(window) }
        // Updating the recent-items list is a synchronous XPC round trip; keep it off the open path.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    @objc func showOpenPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { panel.urls.forEach { self?.open($0) } }
        }
    }
}

/// Routes "Open Recent" (File menu and Dock) to AppDelegate; the app doesn't use NSDocument.
final class RecentDocumentsController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        (NSApp.delegate as? AppDelegate)?.open(url)
        completionHandler(nil, false, nil)
    }
}
