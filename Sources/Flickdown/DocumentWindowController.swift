import AppKit
import UniformTypeIdentifiers
import WebKit

enum ViewMode: Int {
    case preview, source, edit
}

/// One window showing one Markdown file, kept in sync with the file on disk, or an untitled document not yet saved.
/// Preview mode shows the rendered page; source mode is the editor (with an outline); edit mode is the
/// editor beside a live preview. The editor side lives in DocumentWindowController+Editing.swift.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate,
    WKNavigationDelegate, WKUIDelegate {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx", "mdtxt", "mdtext"]
    private static let frameName = "FlickDocumentWindow"

    /// nil for an untitled document until it is first saved.
    private(set) var fileURL: URL?
    private(set) var displayName: String
    var onClose: ((DocumentWindowController) -> Void)?

    /// The preview's web view, created on first use: a window opened in source mode doesn't wait for WebKit.
    private(set) var loadedPage: RenderPage?
    var page: RenderPage {
        if let loadedPage { return loadedPage }
        let page = WebViewPool.take()
        page.webView.navigationDelegate = self
        page.webView.uiDelegate = self
        page.webView.pageZoom = Prefs.zoom
        page.webView.underPageBackgroundColor = Self.pageBackground
        page.onReady = { [weak self] in self?.pageDidLoad() }
        page.onMessage = { [weak self] in self?.handle($0) }
        loadedPage = page
        let pane = PreviewPane(webView: page.webView)
        pane.configureFindBar = { [weak self] bar in
            bar.onSearch = { query, direction in self?.find(query, direction) }
            bar.onClose = { self?.hideFindBar() }
        }
        loadedPane = pane
        return page
    }
    var webView: WKWebView { page.webView }
    /// The web view with the find bar above it; this is what goes into the window.
    private(set) var loadedPane: PreviewPane?
    var previewPane: PreviewPane {
        _ = page
        return loadedPane!
    }
    private lazy var findFieldEditor: FindFieldEditor = {
        let editor = FindFieldEditor()
        editor.isFieldEditor = true
        editor.onFinderAction = { [weak self] sender in self?.performTextFinderAction(sender) }
        return editor
    }()
    private var watcher: FileWatcher?
    /// The file's bytes as last read or written; external changes are detected against this.
    var lastSource: Data?
    var fileEncoding: String.Encoding = .utf8
    private var queued: (chunks: [String], keepScroll: Bool)?
    private var generation = 0
    var mode: ViewMode
    lazy var modeSwitch = NSSegmentedControl(
        labels: [L("预览", "Preview"), L("源码", "Source"), L("编辑", "Edit")], trackingMode: .selectOne,
        target: self, action: #selector(modeSwitchChanged(_:)))
    private let openedAt = Bench.now()

    // Editor-side state, used by the +Editing extension.
    var editor: MarkdownEditor?
    var sourceOutline: SourceOutline?
    var splitView: NSSplitView?
    /// The preview doesn't show the current text (it was hidden while the text changed).
    var previewStale = false
    /// The preview was rendered with source-line marks, so it can be scrolled to an editor line.
    var previewHasLines = false
    var modeRequest = 0
    var pendingPreviewRender: DispatchWorkItem?
    var editorSyncQueued = false
    var askingAboutExternalChange = false
    var suddenTerminationDisabled = false

    convenience init(fileURL: URL) {
        self.init(fileURL: fileURL, displayName: fileURL.lastPathComponent)
    }

    /// A new, empty document. It opens in edit mode: an empty preview has nothing to show.
    convenience init(untitledName: String) {
        self.init(fileURL: nil, displayName: untitledName)
    }

    private init(fileURL: URL?, displayName: String) {
        self.fileURL = fileURL
        self.displayName = displayName
        mode = fileURL == nil ? .edit : (Prefs.sourceMode ? .source : .preview)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingIdentifier = Self.frameName
        window.minSize = NSSize(width: 360, height: 240)
        window.title = displayName
        window.representedURL = fileURL
        window.backgroundColor = Self.pageBackground
        super.init(window: window)

        window.delegate = self
        if mode == .preview { window.contentView = previewPane }
        addModeSwitch(to: window)
        place(window)
        Bench.mark("window created")

        if let fileURL {
            loadFromDisk(force: true)
            watcher = FileWatcher(url: fileURL) { [weak self] in self?.loadFromDisk(force: false) }
        }
        if mode != .preview {
            _ = makeEditor()
            applyLayout()
            refreshOutline()
        }

        // Show the window right away rather than after the first render, so WebKit's first-visibility
        // setup overlaps with page loading. The background matches the page, so nothing flashes.
        showWindow(nil)
        window.makeFirstResponder(mode == .preview ? webView : editor?.textView)
        Bench.mark("window shown")
        if mode == .source {
            // Native text needs no web render: it is on screen once this run-loop turn commits the window.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Bench.mark("painted", String(format: "%.1fms after open  %@ (source)", (Bench.now() - self.openedAt) * 1000, self.displayName))
                    DebugHooks.didPaint(self, webView: nil)
                }
            }
            // Have a web view ready by the time the preview is wanted.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                WebViewPool.prewarm()
            }
        }
    }

    /// Matches the page's CSS background so nothing flashes before the first paint.
    private static let pageBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1E / 255.0, green: 0x1F / 255.0, blue: 0x22 / 255.0, alpha: 1)
            : .white
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Rendering

    func loadFromDisk(force: Bool) {
        guard let fileURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if lastSource == nil { failToOpen(error) }
            return
        }
        if !force, data == lastSource { return }
        if let editor, editor.isDirty, lastSource != nil {
            // Never replace unsaved edits silently.
            if data != lastSource { fileChangedWhileEditing(data) }
            return
        }
        let keepScroll = lastSource != nil
        lastSource = data
        if let editor {
            let decoded = MarkdownRenderer.decode(data)
            fileEncoding = decoded.encoding
            if decoded.text != editor.text {
                editor.setText(decoded.text)
                refreshOutline()
            }
        }
        if previewVisible {
            render(editor.map { Data($0.text.utf8) } ?? data, keepScroll: keepScroll, followEditor: mode == .edit)
        } else {
            previewStale = true
        }
    }

    var previewVisible: Bool { mode == .preview || (mode == .edit && loadedPane?.isHidden != true) }

    /// Renders the current text: the editor's once there is one (it may hold unsaved changes), else the file.
    /// `followEditor` scrolls the preview to the editor's top line.
    func renderCurrent(keepScroll: Bool, followEditor: Bool = false) {
        if let editor {
            render(Data(editor.text.utf8), keepScroll: keepScroll, followEditor: followEditor)
        } else if let lastSource {
            render(lastSource, keepScroll: keepScroll, followEditor: false)
        }
    }

    func render(_ data: Data, keepScroll: Bool, followEditor: Bool) {
        generation += 1
        let gen = generation
        previewStale = false
        // Once the editor is in use, the preview carries source-line marks so the two can be aligned.
        let lines = editor != nil
        previewHasLines = lines
        // Small files (nearly all of them) parse in well under a millisecond; only big ones go off the main thread.
        if data.count < 512 << 10 {
            deliver(Self.parse(data, lines: lines), keepScroll: keepScroll, followEditor: followEditor)
        } else {
            Task.detached(priority: .userInitiated) {
                let chunks = Self.parse(data, lines: lines)
                await MainActor.run { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.deliver(chunks, keepScroll: keepScroll, followEditor: followEditor)
                }
            }
        }
    }

    private nonisolated static func parse(_ data: Data, lines: Bool) -> [String] {
        let t0 = Bench.now()
        let chunks = MarkdownRenderer.htmlChunks(from: data, lines: lines)
        Bench.mark("parsed", String(format: "%d bytes in %.2fms, %d chunks", data.count, (Bench.now() - t0) * 1000, chunks.count))
        return chunks
    }

    private func deliver(_ chunks: [String], keepScroll: Bool, followEditor: Bool) {
        guard page.isReady else {
            queued = (chunks, keepScroll)
            return
        }
        queued = nil
        // A reload keeps the scroll position, which needs the whole document in place at once.
        let streamed = !keepScroll && chunks.count > 1
        let following = followEditor ? editor : nil
        let options: [String: Any] = [
            "base": fileURL?.deletingLastPathComponent().absoluteString ?? "",
            "keep": keepScroll,
            "toc": Prefs.showOutline,
            "width": Prefs.pageWidth.rawValue,
            "more": streamed,
            "line": following.map { $0.topLine() } ?? NSNull(),
            "total": following?.lineCount ?? 0,
        ]
        webView.callAsyncJavaScript("return FLICK.render(html, o)",
                                    arguments: ["html": streamed ? chunks[0] : chunks.joined(), "o": options],
                                    in: nil, in: .page) { [weak self] result in
            self?.didRender(result)
        }
        if streamed {
            // The page attaches these one per frame after the first paint.
            webView.callAsyncJavaScript("FLICK.append(chunks)", arguments: ["chunks": Array(chunks.dropFirst())],
                                        in: nil, in: .page, completionHandler: nil)
        }
    }

    private func didRender(_ result: Result<Any, Error>) {
        switch result {
        case .success(let info):
            Bench.mark("rendered", "\(info)".replacingOccurrences(of: "\n", with: " "))
        case .failure(let error):
            NSLog("Flickdown: render failed: \(error)")
        }
    }

    private func pageDidLoad() {
        if mode == .edit { webView.evaluateJavaScript("FLICK.setEditing(true)") }
        if let queued {
            deliver(queued.chunks, keepScroll: queued.keepScroll, followEditor: mode == .edit)
        } else if lastSource != nil {
            // The page loaded after the preview was asked for (or reloaded after a content-process crash).
            // Render now, at the editor's position if there is an editor.
            if previewVisible { renderCurrent(keepScroll: false, followEditor: editor != nil) } else { previewStale = true }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "line":
            if mode == .edit, let line = message["line"] as? Double { editor?.scroll(toLine: line) }
        case "toggleOutline":
            toggleOutline(nil)
        case "pageWidth":
            if let width = (message["width"] as? String).flatMap(PageWidth.init) { Prefs.pageWidth = width }
        case "find":
            loadedPane?.loadedFindBar?.setResult(count: message["count"] as? Int ?? 0, current: message["current"] as? Int ?? 0,
                                          capped: message["capped"] as? Bool ?? false)
        case "complete":
            Bench.mark("complete", "\(message["blocks"] ?? 0) blocks, \(message["ms"] ?? 0)ms after render start")
        case "painted":
            Bench.mark("painted", String(format: "%.1fms after open  %@", (Bench.now() - openedAt) * 1000, displayName))
            DebugHooks.didPaint(self, webView: webView)
        default:
            break
        }
    }

    private func failToOpen(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
        close()
    }

    // MARK: View modes

    @objc func setViewMode(_ sender: NSMenuItem) {
        setMode(ViewMode(rawValue: sender.tag) ?? .preview)
    }

    /// ⌘/ flips between the preview and the source.
    @objc func toggleSource(_ sender: Any?) { setMode(mode == .source ? .preview : .source) }

    @objc private func modeSwitchChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .preview)
    }

    // MARK: Menu actions

    @objc func revealInFinder(_ sender: Any?) {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc func toggleOutline(_ sender: Any?) {
        Prefs.showOutline.toggle()
        loadedPage?.webView.evaluateJavaScript("FLICK.setTOC(\(Prefs.showOutline))")
        refreshOutline()
    }

    @objc func setPageWidth(_ sender: NSMenuItem) {
        guard let width = (sender.representedObject as? String).flatMap(PageWidth.init) else { return }
        Prefs.pageWidth = width
        loadedPage?.webView.evaluateJavaScript("FLICK.setPageWidth('\(width.rawValue)')")
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(Prefs.zoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Prefs.zoom / 1.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: Double) {
        let z = min(max(zoom, 0.5), 3)
        loadedPage?.webView.pageZoom = z
        editor?.setZoom(z)
        Prefs.zoom = z
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window else { return }
        if mode == .source, let editor {
            NSPrintOperation(view: editor.textView).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return
        }
        let op = webView.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleOutline(_:)):
            item.state = Prefs.showOutline ? .on : .off
        case #selector(setPageWidth(_:)):
            item.state = item.representedObject as? String == Prefs.pageWidth.rawValue ? .on : .off
        case #selector(setViewMode(_:)):
            item.state = item.tag == mode.rawValue ? .on : .off
        case #selector(toggleSource(_:)):
            item.state = mode == .source ? .on : .off
        case #selector(togglePreviewPane(_:)):
            item.state = mode == .edit && !previewPane.isHidden ? .on : .off
            return mode == .edit
        case #selector(saveDocument(_:)):
            return fileURL == nil || hasUnsavedChanges
        case #selector(saveDocumentAs(_:)):
            return editor != nil
        case #selector(reloadDocument(_:)), #selector(revealInFinder(_:)):
            return fileURL != nil
        default:
            break
        }
        return true
    }

    // MARK: Find

    /// Edit ▸ Find items (⌘F, ⌘G, ⇧⌘G, ⌘E). The editor handles them itself when it has focus;
    /// otherwise they arrive here. Whenever the editor is on screen (source and edit mode) find goes to it,
    /// so a window only ever shows the system find bar; the preview's own find bar is for preview mode.
    @objc override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard let action = NSTextFinder.Action(rawValue: tag) else { return }
        if mode != .preview, let editor {
            window?.makeFirstResponder(editor.textView)
            editor.textView.performTextFinderAction(sender)
            return
        }
        let bar = previewPane.findBar
        switch action {
        case .showFindInterface:
            showFindBar()
        case .nextMatch, .previousMatch:
            if bar.field.stringValue.isEmpty { return showFindBar() }
            if !previewPane.isFindBarVisible { previewPane.setFindBarVisible(true) }
            find(bar.field.stringValue, action == .nextMatch ? 1 : -1)
        case .setSearchString:
            webView.evaluateJavaScript("FLICK.selectedText()") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let text = value as? String, !text.isEmpty else { return }
                    bar.field.stringValue = text
                    self.showFindBar()
                }
            }
        case .hideFindInterface:
            hideFindBar()
        default:
            break
        }
    }

    private func showFindBar() {
        let bar = previewPane.findBar
        previewPane.setFindBarVisible(true)
        window?.makeFirstResponder(bar.field)
        bar.field.selectText(nil)
        if !bar.field.stringValue.isEmpty { find(bar.field.stringValue, 0) }
    }

    func hideFindBar() {
        guard let pane = loadedPane, pane.isFindBarVisible else { return }
        pane.setFindBarVisible(false)
        if page.isReady { webView.evaluateJavaScript("FLICK.endFind()") }
        window?.makeFirstResponder(webView)
    }

    private func find(_ query: String, _ direction: Int) {
        guard page.isReady else { return }
        webView.callAsyncJavaScript("FLICK.find(q, d)", arguments: ["q": query, "d": direction],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSSearchField, field === loadedPane?.loadedFindBar?.field else { return nil }
        return findFieldEditor
    }

    // MARK: Links

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL, url.path == RenderPage.templateURL.path, action.navigationType != .linkActivated {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        // Links the user clicked, plus files dragged onto the window.
        if action.navigationType == .linkActivated || (url.isFileURL && action.navigationType == .other) {
            open(link: url)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" links.
        if let url = action.request.url { open(link: url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        page.loadTemplate()
    }

    private func open(link url: URL) {
        if url.isFileURL {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists, !isDir.boolValue, Self.markdownExtensions.contains(url.pathExtension.lowercased()) {
                (NSApp.delegate as? AppDelegate)?.open(url)
            } else if exists, !isDir.boolValue, Self.isSafeToOpen(url) {
                NSWorkspace.shared.open(url)
            } else if exists {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A link in a document must not be able to launch scripts or apps; those are revealed in Finder instead.
    private static func isSafeToOpen(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        if type.conforms(to: .script) || type.conforms(to: .executable) || type.conforms(to: .application)
            || type.conforms(to: .applicationBundle) || type.conforms(to: .package) {
            return false
        }
        return [.image, .pdf, .text, .audiovisualContent].contains { type.conforms(to: $0) }
    }

    // MARK: Window

    /// Preview / Source / Edit switch at the trailing edge of the title bar.
    private func addModeSwitch(to window: NSWindow) {
        modeSwitch.controlSize = .small
        modeSwitch.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modeSwitch.selectedSegment = mode.rawValue
        modeSwitch.toolTip = L("预览 ⌘1 · 源码 ⌘2 · 编辑 ⌘3", "Preview ⌘1 · Source ⌘2 · Edit ⌘3")
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        let size = modeSwitch.fittingSize
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 12, height: size.height))
        container.addSubview(modeSwitch)
        NSLayoutConstraint.activate([
            modeSwitch.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            modeSwitch.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func place(_ window: NSWindow) {
        let others = NSApp.orderedWindows.filter { $0 !== window && $0.windowController is DocumentWindowController }
        if let front = others.first {
            window.setFrame(front.frame, display: false)
            window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
        } else if !window.setFrameUsingName(Self.frameName) {
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            window.setContentSize(NSSize(width: min(1100, visible.width - 80), height: min(1000, visible.height - 60)))
            window.center()
        }
    }

    /// After "Save As" (including the first save of an untitled document) the window shows and watches the new file.
    func attach(to url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        fileURL = url
        displayName = url.lastPathComponent
        window?.title = displayName
        window?.representedURL = url
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in self?.loadFromDisk(force: false) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// The "+" button in the tab bar.
    override func newWindowForTab(_ sender: Any?) {
        guard let delegate = NSApp.delegate as? AppDelegate, let window,
              let newWindow = delegate.openUntitled().window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    func windowDidEndLiveResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
    func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        pendingPreviewRender?.cancel()
        setSuddenTerminationAllowed(true)
        onClose?(self)
    }
}
