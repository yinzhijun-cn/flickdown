import AppKit
import WebKit

/// The preview area: the find bar (when shown) above the web view.
@MainActor
final class PreviewPane: NSView {
    let webView: WKWebView
    /// Called once when the find bar is first needed; it is built lazily to keep window creation fast.
    var configureFindBar: ((FindBar) -> Void)?
    private(set) var loadedFindBar: FindBar?
    private static let barHeight: CGFloat = 36

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: webView.frame)
        addSubview(webView)
        layoutChildren()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var findBar: FindBar {
        if let loadedFindBar { return loadedFindBar }
        let bar = FindBar()
        bar.isHidden = true
        addSubview(bar)
        configureFindBar?(bar)
        loadedFindBar = bar
        return bar
    }

    var isFindBarVisible: Bool { loadedFindBar.map { !$0.isHidden } ?? false }

    func setFindBarVisible(_ visible: Bool) {
        findBar.isHidden = !visible
        layoutChildren()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutChildren()
    }

    private func layoutChildren() {
        let bar = isFindBarVisible ? Self.barHeight : 0
        loadedFindBar?.frame = NSRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bar)
    }
}

/// Search field, match count, previous/next and Done, like Safari's find bar.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    /// (query, direction): 0 starts a new search from the top of the view, 1 = next, -1 = previous.
    var onSearch: ((String, Int) -> Void)?
    var onClose: (() -> Void)?

    private let status = NSTextField(labelWithString: "")
    private lazy var arrows = NSSegmentedControl(
        images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("上一个", "Previous"))!,
                 NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("下一个", "Next"))!],
        trackingMode: .momentary, target: self, action: #selector(arrowClicked(_:)))
    private lazy var done = NSButton(title: L("完成", "Done"), target: self, action: #selector(closeClicked))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        field.placeholderString = L("在文档中查找", "Find in document")
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(fieldChanged)
        field.delegate = self
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        status.textColor = .secondaryLabelColor
        arrows.setToolTip(L("上一个 (⇧⌘G)", "Previous (⇧⌘G)"), forSegment: 0)
        arrows.setToolTip(L("下一个 (⌘G)", "Next (⌘G)"), forSegment: 1)
        arrows.isEnabled = false
        done.bezelStyle = .push
        done.controlSize = .small

        let spacer = NSView()
        let stack = NSStackView(views: [field, status, spacer, arrows, done])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        let fieldWidth = field.widthAnchor.constraint(equalToConstant: 300)
        fieldWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            fieldWidth,
        ])
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }

    func setResult(count: Int, current: Int, capped: Bool) {
        arrows.isEnabled = count > 0
        if field.stringValue.isEmpty {
            status.stringValue = ""
        } else if count == 0 {
            status.stringValue = L("无结果", "No results")
        } else {
            status.stringValue = "\(current)/\(count)\(capped ? "+" : "")"
        }
    }

    @objc private func fieldChanged() { onSearch?(field.stringValue, 0) }
    @objc private func arrowClicked(_ sender: NSSegmentedControl) { onSearch?(field.stringValue, sender.selectedSegment == 0 ? -1 : 1) }
    @objc private func closeClicked() { onClose?() }

    // Return = next, Shift-Return = previous, Esc = close.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onSearch?(field.stringValue, backwards ? -1 : 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// Field editor for the find field. A field editor is a text view, which would swallow ⌘G / ⇧⌘G / ⌘E
/// while typing; this one passes them to the window instead.
final class FindFieldEditor: NSTextView {
    var onFinderAction: ((Any?) -> Void)?

    override func performTextFinderAction(_ sender: Any?) { onFinderAction?(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}
