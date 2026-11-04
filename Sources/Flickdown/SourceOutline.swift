import AppKit

/// The outline sidebar beside the editor in source mode: the document's headings, with the one
/// at the top of the editor highlighted. Matches the look of the preview's outline.
@MainActor
final class SourceOutline: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSStackView()
    let editorPane = NSStackView()
    let toggleButton = NSButton()
    /// Called with the 0-based source line of a heading the user clicked.
    var onSelect: ((Int) -> Void)?

    private let header = NSView()
    private let title = NSTextField(labelWithString: L("目录", "CONTENTS"))
    private lazy var buttonLeading = toggleButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16)
    private lazy var buttonTrailing = toggleButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10)
    private let table = NSTableView()
    private var headings: [MarkdownEditor.Heading] = []
    private var minLevel = 1
    private var active = -1

    /// Same colour as the preview's outline background.
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xF6 / 255.0, green: 0xF8 / 255.0, blue: 0xFA / 255.0, alpha: 1)
    }

    override init() {
        super.init()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading")))
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = Self.background
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.background
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)

        for pane in [view, editorPane] {
            pane.orientation = .vertical
            pane.alignment = .width
            pane.spacing = 0
        }
        view.addArrangedSubview(scrollView)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        toggleButton.bezelStyle = .push
        toggleButton.controlSize = .small
        for control in [title, toggleButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(control)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
            toggleButton.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            toggleButton.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
        ])
    }

    var isEmpty: Bool { headings.count < 2 }

    /// Keep the same control reachable above the editor when its sidebar is hidden.
    func placeToggle(expanded: Bool) {
        guard !isEmpty else {
            header.removeFromSuperview()
            return
        }
        let pane = expanded ? view : editorPane
        guard header.superview !== pane else { return }
        let focused = toggleButton.window?.firstResponder === toggleButton
        header.removeFromSuperview()
        NSLayoutConstraint.deactivate([buttonLeading, buttonTrailing])
        (expanded ? buttonTrailing : buttonLeading).isActive = true
        title.isHidden = !expanded
        toggleButton.title = expanded ? "«" : L("☰ 目录", "☰ Contents")
        let actionLabel = expanded ? L("收起目录", "Hide Contents") : L("展开目录", "Show Contents")
        toggleButton.toolTip = actionLabel
        toggleButton.setAccessibilityLabel(actionLabel)
        pane.insertArrangedSubview(header, at: 0)
        if focused { toggleButton.window?.makeFirstResponder(toggleButton) }
    }

    func update(_ headings: [MarkdownEditor.Heading]) {
        guard headings != self.headings else { return }
        self.headings = headings
        minLevel = headings.map(\.level).min() ?? 1
        active = -1
        table.reloadData()
    }

    /// Highlights the last heading at or above `line` (0-based).
    func highlight(line: Int) {
        var lo = 0, hi = headings.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if headings[mid].line <= line { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found != active else { return }
        let rows = IndexSet([active, found].filter { $0 >= 0 && $0 < headings.count })
        active = found
        table.reloadData(forRowIndexes: rows, columnIndexes: [0])
        if found >= 0 { table.scrollRowToVisible(found) }
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, row < headings.count else { return }
        onSelect?(headings[row].line)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: OutlineCell.id, owner: nil) as? OutlineCell ?? OutlineCell()
        let heading = headings[row]
        cell.show(heading.title, indent: CGFloat(heading.level - minLevel) * 12,
                  top: heading.level == minLevel, active: row == active)
        return cell
    }
}

private final class OutlineCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("OutlineCell")
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        for v in [pill, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ title: String, indent: CGFloat, top: Bool, active: Bool) {
        label.stringValue = title
        label.toolTip = title
        leading.constant = 18 + indent
        label.font = .systemFont(ofSize: 13, weight: top || active ? .semibold : .regular)
        label.textColor = active ? .linkColor : top ? .labelColor : .secondaryLabelColor
        pill.layer?.backgroundColor = active ? NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor : nil
    }
}
