import AppKit
import UniformTypeIdentifiers
import WebKit

/// The editor side: source mode (outline + editor) and edit mode (editor + live preview, scrolled in step),
/// plus saving and the prompts that protect unsaved changes.
extension DocumentWindowController {
    var hasUnsavedChanges: Bool { editor?.isDirty ?? false }

    // MARK: Switching modes

    func setMode(_ new: ViewMode) {
        guard isMarkdown else { return }
        modeSwitch.selectedSegment = new.rawValue
        guard new != mode else { return }
        if new != .edit { Prefs.sourceMode = new == .source }
        modeRequest += 1
        let request = modeRequest
        if mode == .preview, page.isReady {
            // Ask the page which source line the reader is at, then open the editor there.
            let editor = self.editor ?? makeEditor()
            webView.callAsyncJavaScript("return FLICK.topLine(text)", arguments: ["text": editor.text],
                                        in: nil, in: .page) { [weak self] result in
                guard let self, request == self.modeRequest else { return }
                let line = (try? result.get()) as? Double ?? 1
                self.switchMode(to: new, at: line)
            }
        } else {
            switchMode(to: new, at: editor?.topLine() ?? 1)
        }
    }

    /// Lays the window out for `new` and puts both views at source line `line`.
    private func switchMode(to new: ViewMode, at line: Double) {
        guard let window else { return }
        if new != .preview, editor == nil { _ = makeEditor() }
        // Only preview mode uses the custom find bar; source and edit use the system find bar.
        if new != .preview { hideFindBar() }
        mode = new
        applyLayout()
        if new == .preview {
            window.makeFirstResponder(webView)
        } else if let editor {
            editor.scroll(toLine: line)
            window.makeFirstResponder(editor.textView)
            refreshOutline()
        }
        guard previewVisible, page.isReady else { return }
        webView.evaluateJavaScript("FLICK.setEditing(\(new == .edit))")
        if previewStale || !previewHasLines {
            renderCurrent(keepScroll: true, followEditor: true)
        } else {
            // Let the web view take its new width before positioning.
            window.layoutIfNeeded()
            webView.evaluateJavaScript("FLICK.syncTo(\(line), \(editor?.lineCount ?? 0))")
        }
    }

    /// Preview: the web view. Source: outline + editor. Edit: editor + preview.
    func applyLayout() {
        guard let window else { return }
        loadedPane?.removeFromSuperview()
        editor?.scrollView.removeFromSuperview()
        sourceOutline?.view.removeFromSuperview()
        splitView = nil
        if !isMarkdown, let editor {
            window.contentView = editor.scrollView
            return
        }
        guard mode != .preview, let editor else {
            previewPane.isHidden = false
            window.contentView = previewPane
            return
        }
        let split = NSSplitView(frame: window.contentView?.bounds ?? .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        window.contentView = split
        splitView = split
        if mode == .source {
            let outline = sourceOutline ?? makeOutline()
            outline.editorPane.addArrangedSubview(editor.scrollView)
            split.addArrangedSubview(outline.editorPane)
            split.adjustSubviews()
        } else {
            layoutEditPanes(in: split, editor: editor, preview: previewPane)
        }
    }

    func layoutEditPanes(in split: NSSplitView, editor: MarkdownEditor, preview: PreviewPane) {
        // Source mode's stack disables frame-based layout; restore it before the split sizes the editor.
        editor.scrollView.translatesAutoresizingMaskIntoConstraints = true
        split.addArrangedSubview(editor.scrollView)
        split.addArrangedSubview(preview)
        split.adjustSubviews()
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
    }

    func makeEditor() -> MarkdownEditor {
        let syntax: MarkdownEditor.Syntax
        if isMarkdown {
            syntax = .markdown
        } else {
            switch fileURL?.pathExtension.lowercased() {
            case "sql": syntax = .sql
            case "json": syntax = .json
            case "yaml", "yml": syntax = .yaml
            default: syntax = .plainText
            }
        }
        let editor = MarkdownEditor(zoom: Prefs.zoom, syntax: syntax)
        // Disk contents are validated on load; new text documents start with UTF-8 bytes.
        let decoded = MarkdownRenderer.decode(lastSource ?? Data())!
        editor.setText(decoded.text)
        editor.onChange = { [weak self] in self?.editorChanged() }
        editor.onScroll = { [weak self] in self?.editorScrolled() }
        self.editor = editor
        return editor
    }

    private func makeOutline() -> SourceOutline {
        let outline = SourceOutline()
        outline.toggleButton.target = self
        outline.toggleButton.action = #selector(toggleOutline(_:))
        outline.onSelect = { [weak self] line in
            guard let editor = self?.editor else { return }
            editor.scroll(toLine: Double(line + 1))
            outline.highlight(line: line)
            self?.window?.makeFirstResponder(editor.textView)
        }
        sourceOutline = outline
        return outline
    }

    /// Updates the source-mode outline from the editor's headings and shows or hides it.
    func refreshOutline() {
        guard mode == .source, let editor, let outline = sourceOutline, let splitView else { return }
        outline.update(editor.headings())
        if Prefs.showOutline && !outline.isEmpty {
            if outline.view.superview == nil {
                splitView.insertArrangedSubview(outline.view, at: 0)
                // Window resizes go to the editor; the outline keeps its width.
                splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
                splitView.adjustSubviews()
                splitView.setPosition(240, ofDividerAt: 0)
            }
            outline.placeToggle(expanded: true)
            outline.highlight(line: Int(editor.topLine()) - 1)
        } else {
            outline.placeToggle(expanded: false)
            if outline.view.superview != nil {
                outline.view.removeFromSuperview()
                splitView.adjustSubviews()
            }
        }
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        guard mode == .edit, let splitView else { return }
        previewPane.isHidden.toggle()
        splitView.adjustSubviews()
        if !previewPane.isHidden {
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
            renderCurrent(keepScroll: true, followEditor: true)
        }
    }

    // MARK: Live preview and scroll sync

    private func editorChanged() {
        window?.isDocumentEdited = true
        if !isMarkdown {
            updateEditedState()
            return
        }
        previewStale = true
        guard let editor else { return }
        // Refresh once typing pauses; bigger documents wait longer since each render is a full re-parse.
        pendingPreviewRender?.cancel()
        let length = editor.textView.textStorage?.length ?? 0
        let delay = length < 100_000 ? 0.03 : min(Double(length) / 1_000_000 * 0.3, 1.5)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateEditedState()
                self.refreshOutline()
                if self.previewVisible { self.renderCurrent(keepScroll: true, followEditor: true) }
            }
        }
        pendingPreviewRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func editorScrolled() {
        guard isMarkdown, mode != .preview, !editorSyncQueued else { return }
        editorSyncQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let editor = self.editor else { return }
                self.editorSyncQueued = false
                let line = editor.topLine()
                if self.mode == .source {
                    self.sourceOutline?.highlight(line: Int(line) - 1)
                } else if self.previewVisible {
                    self.webView.evaluateJavaScript("FLICK.syncTo(\(line), \(editor.lineCount))")
                }
            }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, mode == .source ? 140 : 240)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, mode == .source ? 420 : splitView.bounds.width - 240)
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) {
        save { _ in }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        saveAs { _ in }
    }

    /// An untitled document completes saving only after its save sheet finishes.
    func save(_ completion: @escaping (Bool) -> Void) {
        guard let fileURL else { return saveAs(completion) }
        completion(write(to: fileURL))
    }

    func saveAs(_ completion: @escaping (Bool) -> Void) {
        guard let window else { return completion(false) }
        let panel = NSSavePanel()
        if isMarkdown {
            panel.allowedContentTypes = [UTType("net.daringfireball.markdown")].compactMap { $0 }
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "\(displayName).md"
        } else {
            // Existing text files keep their extension, including unknown types and extensionless files.
            if fileURL == nil { panel.allowedContentTypes = [.plainText] }
            panel.nameFieldStringValue = displayName
        }
        if let fileURL { panel.directoryURL = fileURL.deletingLastPathComponent() }
        panel.canCreateDirectories = true
        if editor == nil { _ = makeEditor() }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return completion(false) }
                completion(self.write(to: url))
            }
        }
    }

    /// Saves the bytes, then binds first saves and Save As to their new file identity.
    @discardableResult
    func write(to url: URL) -> Bool {
        guard let editor, let window else { return true }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let text = editor.text
        guard let data = text.data(using: fileEncoding) ?? text.data(using: .utf8) else { return false }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                // Swap in a complete copy, preserving the existing file's permissions and metadata.
                let fm = FileManager.default
                let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
                defer { try? fm.removeItem(at: dir) }
                let temp = dir.appendingPathComponent(url.lastPathComponent)
                try data.write(to: temp)
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
            return false
        }
        // Our own write must not look like an external change to the file watcher.
        lastSource = data
        editor.markSaved(text)
        if fileURL != url {
            fileURL = url
            displayName = url.lastPathComponent
            window.title = displayName
            window.representedURL = url
            window.tab.toolTip = url.path
            watcher?.stop()
            watcher = FileWatcher(url: url) { [weak self] in self?.loadFromDisk(force: false) }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            // Relative images and links must now resolve against the new folder.
            if previewVisible { renderCurrent(keepScroll: true, followEditor: mode == .edit) }
        }
        updateEditedState()
        return true
    }

    func updateEditedState() {
        let dirty = hasUnsavedChanges
        window?.isDocumentEdited = dirty
        setSuddenTerminationAllowed(!dirty)
    }

    /// While there are unsaved changes, macOS must not quit the app without asking (e.g. at logout).
    func setSuddenTerminationAllowed(_ allowed: Bool) {
        if allowed, suddenTerminationDisabled {
            ProcessInfo.processInfo.enableSuddenTermination()
            suddenTerminationDisabled = false
        } else if !allowed, !suddenTerminationDisabled {
            ProcessInfo.processInfo.disableSuddenTermination()
            suddenTerminationDisabled = true
        }
    }

    private func discardEdits() {
        guard let editor else { return }
        editor.markSaved(editor.text)
        updateEditedState()
    }

    // MARK: Unsaved changes

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges else { return true }
        confirmUnsavedChanges { [weak self] proceed in
            if proceed { self?.close() }
        }
        return false
    }

    /// Save / Don't Save / Cancel. `completion(true)` means the caller may go ahead (saved or discarded).
    func confirmUnsavedChanges(_ completion: @escaping (Bool) -> Void) {
        guard let window else { return completion(false) }
        let alert = NSAlert()
        alert.messageText = L("要存储对“\(displayName)”所做的更改吗？", "Do you want to save the changes you made to “\(displayName)”?")
        alert.informativeText = L("如果不存储，你的更改将会丢失。", "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: L("存储", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        let dontSave = alert.addButton(withTitle: L("不存储", "Don’t Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return completion(false) }
                switch response {
                case .alertFirstButtonReturn:
                    self.save(completion)
                case .alertThirdButtonReturn:
                    self.discardEdits()
                    completion(true)
                default:
                    completion(false)
                }
            }
        }
    }

    @objc func reloadDocument(_ sender: Any?) {
        guard fileURL != nil else { return }
        guard hasUnsavedChanges, let window else {
            loadFromDisk(force: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("放弃未存储的更改并重新载入？", "Discard unsaved changes and reload?")
        alert.addButton(withTitle: L("重新载入", "Reload"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                self.discardEdits()
                self.loadFromDisk(force: true)
            }
        }
    }

    /// The file changed on disk while the editor has unsaved changes.
    func fileChangedWhileEditing(_ data: Data) {
        guard !askingAboutExternalChange, let window else { return }
        askingAboutExternalChange = true
        let alert = NSAlert()
        alert.messageText = L("“\(displayName)”已被其他应用修改", "“\(displayName)” was changed by another application")
        alert.informativeText = L("这里还有未存储的更改。保留它们，还是载入磁盘上的新版本？",
                                  "You have unsaved changes here. Keep them, or load the new version from disk?")
        alert.addButton(withTitle: L("保留我的更改", "Keep My Changes"))
        alert.addButton(withTitle: L("载入磁盘版本", "Load Disk Version"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.askingAboutExternalChange = false
                if response == .alertSecondButtonReturn {
                    self.discardEdits()
                    self.loadFromDisk(force: true)
                } else {
                    // Don't ask again about this same version; saving will overwrite it.
                    self.lastSource = data
                }
            }
        }
    }
}
