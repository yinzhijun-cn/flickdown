import AppKit

/// A window's content: the current mode's view (`body`) above the status bar.
@MainActor
final class DocumentContentView: NSView {
    let statusBar = StatusBar()
    var body: NSView? {
        didSet {
            guard body !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let body { addSubview(body) }
            layoutChildren()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(statusBar)
        layoutChildren()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var bodyBounds: NSRect {
        NSRect(x: 0, y: StatusBar.height, width: bounds.width, height: max(0, bounds.height - StatusBar.height))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutChildren()
    }

    private func layoutChildren() {
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: StatusBar.height)
        body?.frame = bodyBounds
    }
}

/// Word count and reading time or caret position on the left, the text encoding on the right.
@MainActor
final class StatusBar: NSView {
    static let height: CGFloat = 24

    private let summary = NSTextField(labelWithString: "")
    private let encoding = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [summary, encoding] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.muted
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        encoding.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            summary.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: encoding.leadingAnchor, constant: -12),
            encoding.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            encoding.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// `caret` is the editor's (line, column), or nil in preview mode, which shows the reading time instead.
    func show(words: Int, caret: (line: Int, column: Int)?, encoding name: String) {
        var parts = [L("\(words.formatted()) 字", words == 1 ? "1 word" : "\(words.formatted()) words")]
        if let caret {
            parts.append(L("第 \(caret.line) 行，第 \(caret.column) 列", "Line \(caret.line), Column \(caret.column)"))
        } else if words > 0 {
            let minutes = max(1, Int((Double(words) / Self.wordsPerMinute).rounded()))
            parts.append(L("约 \(minutes) 分钟读完", "\(minutes) min read"))
        }
        summary.stringValue = parts.joined(separator: "  ·  ")
        encoding.stringValue = name
    }

    /// Reading speed for the estimate; a CJK character counts as one word.
    private static let wordsPerMinute = 300.0

    /// Words in `text`: each CJK character is one word, as are runs of letters and digits.
    nonisolated static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    private nonisolated static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0xAC00...0xD7AF: return true // kana, Hangul syllables
        default: return scalar.properties.isIdeographic
        }
    }
}
