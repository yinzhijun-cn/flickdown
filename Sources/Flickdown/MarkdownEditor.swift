import AppKit

/// The Markdown source editor, used in source mode (on its own) and edit mode (beside the preview).
///
/// TextKit 1 with non-contiguous layout: mature, fast on large files, full input-method support.
/// Syntax colouring is applied as temporary attributes to the visible lines only, so its cost
/// doesn't grow with the file and it never triggers relayout.
@MainActor
final class MarkdownEditor: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView: NSTextView
    var onChange: (() -> Void)?
    var onScroll: (() -> Void)?

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var savedText = ""
    private var editedSinceSave = false
    private var cachedIndex: TextIndex?
    private var cachedHeadings: [Heading]?
    private var highlightQueued = false
    private var scrollingProgrammatically = false
    private var ruler: LineNumberRuler!

    init(zoom: Double) {
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init()

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 18, height: 20)
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        ruler = LineNumberRuler(editor: self)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        setZoom(zoom)
    }

    var text: String { textView.string }

    var isDirty: Bool {
        if editedSinceSave, textView.string == savedText { editedSinceSave = false }
        return editedSinceSave
    }

    func markSaved(_ text: String) {
        savedText = text
        editedSinceSave = textView.string != text
    }

    /// Replaces the whole text (on open or after the file changed on disk), keeping caret and scroll where possible.
    func setText(_ text: String) {
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
        storage.endEditing()
        savedText = text
        editedSinceSave = false
        textChanged()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        queueHighlight()
    }

    func setZoom(_ zoom: Double) {
        let font = NSFont.monospacedSystemFont(ofSize: 13 * zoom, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        baseAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor]
        textView.typingAttributes = baseAttributes
        storage.addAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        ruler.update(zoom: zoom, lineCount: lineCount)
        queueHighlight()
    }

    // MARK: Lines and scroll position

    var lineCount: Int { index().lineStarts.count }

    /// The source line at the top of the view (1-based) plus how far it is scrolled through.
    func topLine() -> Double {
        guard storage.length > 0, let container = textView.textContainer else { return 1 }
        let y = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: container)
        let line = lineNumber(at: layoutManager.characterIndexForGlyph(at: glyph))
        let rect = lineRect(line)
        let fraction = rect.height > 0 ? min(max((y - rect.minY) / rect.height, 0), 0.999) : 0
        return Double(line + 1) + fraction
    }

    /// Scrolls so that `line` (1-based, fractional) is at the top, without reporting it back via `onScroll`.
    func scroll(toLine line: Double) {
        let idx = index()
        let n = min(max(Int(line) - 1, 0), idx.lineStarts.count - 1)
        let rect = lineRect(n)
        let target = rect.minY + (line - line.rounded(.down)) * rect.height + textView.textContainerOrigin.y
        let maxY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
        scrollingProgrammatically = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, target), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollingProgrammatically = false
    }

    private func lineRect(_ line: Int) -> NSRect {
        let idx = index()
        guard let container = textView.textContainer, line < idx.lineStarts.count else { return .zero }
        let start = idx.lineStarts[line]
        let end = line + 1 < idx.lineStarts.count ? idx.lineStarts[line + 1] : storage.length
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: max(end - start, 0)), actualCharacterRange: nil)
        if glyphs.length == 0 {
            // Empty last line: use the extra line fragment after the final newline.
            return layoutManager.extraLineFragmentRect
        }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    // MARK: Text index

    /// Line starts and fenced code blocks, rebuilt lazily after each edit.
    private struct TextIndex {
        var lineStarts: [Int] = [0]
        /// Line numbers of the opening and closing fence of each fenced code block (Int.max if unclosed).
        var fences: [(open: Int, close: Int)] = []
    }

    /// Start offset (UTF-16) of each line.
    var lineStarts: [Int] { index().lineStarts }

    private func textChanged() {
        cachedIndex = nil
        cachedHeadings = nil
        ruler?.update(lineCount: lineCount)
        queueHighlight()
    }

    private func index() -> TextIndex {
        if let cachedIndex { return cachedIndex }
        let s = textView.string as NSString
        let length = s.length
        var idx = TextIndex()
        var line = 0
        var start = 0
        var open: (line: Int, char: unichar, count: Int)?

        func endLine(at end: Int, next: Int) {
            if let fence = Self.fence(in: s, line: NSRange(location: start, length: end - start)) {
                if let o = open {
                    if fence.char == o.char, fence.count >= o.count, fence.bare {
                        idx.fences.append((o.line, line))
                        open = nil
                    }
                } else {
                    open = (line, fence.char, fence.count)
                }
            }
            line += 1
            start = next
            idx.lineStarts.append(next)
        }

        // Scan UTF-16 in large buffers: far cheaper than a lineRange(for:) call per line on big files.
        var buffer = [unichar](repeating: 0, count: 1 << 16)
        var base = 0
        while base < length {
            let n = min(buffer.count, length - base)
            s.getCharacters(&buffer, range: NSRange(location: base, length: n))
            var i = 0
            while i < n {
                let c = buffer[i]
                if c == 10 {
                    endLine(at: base + i, next: base + i + 1)
                } else if c == 13 {
                    let crlf = base + i + 1 < length && (i + 1 < n ? buffer[i + 1] : s.character(at: base + i + 1)) == 10
                    endLine(at: base + i, next: base + i + (crlf ? 2 : 1))
                    if crlf { i += 1 }
                }
                i += 1
            }
            base += n
        }
        // A trailing newline leaves an empty last line, matching how md4c numbers lines; lineStarts already has it.
        if start < length { endLine(at: length, next: length) ; idx.lineStarts.removeLast() }
        if let o = open { idx.fences.append((o.line, Int.max)) }
        cachedIndex = idx
        return idx
    }

    private static func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 }

    /// A ``` or ~~~ fence at the start of the line (after up to 3 spaces).
    private static func fence(in s: NSString, line: NSRange) -> (char: unichar, count: Int, bare: Bool)? {
        var i = line.location
        let end = NSMaxRange(line)
        while i < end, i - line.location < 4, s.character(at: i) == 32 { i += 1 }
        guard i - line.location <= 3, i < end else { return nil }
        let c = s.character(at: i)
        guard c == 96 || c == 126 else { return nil }
        var n = 0
        while i + n < end, s.character(at: i + n) == c { n += 1 }
        guard n >= 3 else { return nil }
        let rest = s.substring(with: NSRange(location: i + n, length: end - i - n))
        return (c, n, rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// 0-based line containing the character at `char`.
    func lineNumber(at char: Int) -> Int {
        let starts = index().lineStarts
        var lo = 0, hi = starts.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= char { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private enum LineKind { case text, fence, code }

    private func kind(ofLine line: Int) -> LineKind {
        let fences = index().fences
        var lo = 0, hi = fences.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if fences[mid].open <= line { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return .text }
        let f = fences[found]
        if line == f.open || line == f.close { return .fence }
        return line < f.close ? .code : .text
    }

    // MARK: Headings

    struct Heading: Equatable {
        let line: Int // 0-based
        let level: Int
        let title: String
    }

    /// ATX (`## Title`) and setext (underlined) headings outside fenced code, for the outline.
    func headings() -> [Heading] {
        if let cachedHeadings { return cachedHeadings }
        let s = textView.string as NSString
        let starts = index().lineStarts
        func text(_ line: Int) -> String {
            let end = line + 1 < starts.count ? starts[line + 1] : s.length
            var t = s.substring(with: NSRange(location: starts[line], length: end - starts[line]))
            while let last = t.unicodeScalars.last, last == "\n" || last == "\r" { t.unicodeScalars.removeLast() }
            return t
        }
        var result: [Heading] = []
        for line in 0..<starts.count {
            // Character checks only; text is extracted just for actual headings.
            let start = starts[line]
            var end = line + 1 < starts.count ? starts[line + 1] : s.length
            while end > start, Self.isNewline(s.character(at: end - 1)) { end -= 1 }
            var i = start
            while i < end, i - start < 4, s.character(at: i) == 32 { i += 1 }
            guard i < end, i - start <= 3 else { continue }
            let c = s.character(at: i)
            guard c == 35 || c == 61 || c == 45 else { continue }
            var n = 0
            while i + n < end, s.character(at: i + n) == c { n += 1 }
            if c == 35 {
                // ATX: 1-6 '#' followed by a space or the end of the line.
                guard n <= 6, i + n == end || [32, 9].contains(s.character(at: i + n)), kind(ofLine: line) == .text else { continue }
                var title = s.substring(with: NSRange(location: i + n, length: end - i - n)).trimmingCharacters(in: .whitespaces)
                if let closing = title.range(of: "\\s+#+$", options: .regularExpression) { title.removeSubrange(closing) }
                else if title.allSatisfy({ $0 == "#" }) { title = "" }
                result.append(Heading(line: line, level: n, title: Self.plain(title)))
            } else {
                // Setext: a line of only '=' or only '-' underlines the paragraph line above it.
                var j = i + n
                while j < end, [32, 9].contains(s.character(at: j)) { j += 1 }
                guard j == end, line > 0, kind(ofLine: line) == .text, kind(ofLine: line - 1) == .text,
                      result.last?.line != line - 1 else { continue }
                let previous = text(line - 1)
                let range = NSRange(location: 0, length: (previous as NSString).length)
                if !previous.trimmingCharacters(in: .whitespaces).isEmpty, Self.blockStartRx.firstMatch(in: previous, range: range) == nil {
                    result.append(Heading(line: line - 1, level: c == 61 ? 1 : 2, title: Self.plain(previous)))
                }
            }
        }
        cachedHeadings = result
        return result
    }

    private static let blockStartRx = regex("^\\s*(?:[-*+>#|]|\\d{1,9}[.)]|`{3}|~{3})")
    private static let linkTextRx = regex("!?\\[([^\\]]*)\\]\\([^)]*\\)")

    /// Heading text without Markdown punctuation, as the outline shows it.
    private static func plain(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let unlinked = linkTextRx.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        return unlinked.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Highlighting

    private enum Palette {
        static let heading = NSColor.systemBlue
        static let mark = NSColor.systemOrange
        static let code = NSColor.systemPurple
        static let link = NSColor.linkColor
        static let tag = NSColor.systemGreen
        static let muted = NSColor.secondaryLabelColor
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
    private static let headingRx = regex("^ {0,3}#{1,6}(?:\\s|$)")
    private static let ruleRx = regex("^ {0,3}(?:([-*_])(?:\\s*\\1){2,}|=+)\\s*$")
    private static let quoteRx = regex("^\\s*(?:>\\s?)+")
    private static let listRx = regex("^\\s*([-*+]|\\d{1,9}[.)])\\s+(\\[[ xX]\\](?=\\s))?")
    private static let tableRx = regex("^\\s*\\|.*\\|\\s*$")
    private static let inlineRx = regex("(`[^`]+`)|(!?\\[[^\\]]*\\])(\\([^)]*\\))|(<!--.*?-->|</?[A-Za-z][^<>]*>)|(https?://[^\\s<>()]+)")

    private func queueHighlight() {
        guard !highlightQueued else { return }
        highlightQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.highlightQueued = false
                self?.highlightVisible()
            }
        }
    }

    private func highlightVisible() {
        guard storage.length > 0, !textView.hasMarkedText(), let container = textView.textContainer else { return }
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -textView.visibleRect.height / 2)
        let origin = textView.textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let s = textView.string as NSString
        let range = s.lineRange(for: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)

        var line = lineNumber(at: range.location)
        var pos = range.location
        while pos < NSMaxRange(range) {
            let lineRange = s.lineRange(for: NSRange(location: pos, length: 0))
            var content = lineRange
            while content.length > 0, Self.isNewline(s.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            colour(line: s.substring(with: content), at: content.location, kind: kind(ofLine: line))
            pos = NSMaxRange(lineRange)
            line += 1
        }
    }

    private func colour(line: String, at base: Int, kind: LineKind) {
        let full = NSRange(location: 0, length: (line as NSString).length)
        func paint(_ r: NSRange, _ color: NSColor) {
            guard r.location != NSNotFound, r.length > 0 else { return }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color,
                                                forCharacterRange: NSRange(location: base + r.location, length: r.length))
        }
        switch kind {
        case .fence: return paint(full, Palette.muted)
        case .code: return paint(full, Palette.code)
        case .text: break
        }
        if Self.headingRx.firstMatch(in: line, range: full) != nil { return paint(full, Palette.heading) }
        if Self.ruleRx.firstMatch(in: line, range: full) != nil { return paint(full, Palette.mark) }

        if let m = Self.quoteRx.firstMatch(in: line, range: full) {
            paint(m.range, Palette.mark)
            paint(NSRange(location: NSMaxRange(m.range), length: full.length - NSMaxRange(m.range)), Palette.muted)
        } else if let m = Self.listRx.firstMatch(in: line, range: full) {
            paint(m.range(at: 1), Palette.mark)
            paint(m.range(at: 2), Palette.mark)
        } else if Self.tableRx.firstMatch(in: line, range: full) != nil {
            let ns = line as NSString
            for i in 0..<ns.length where ns.character(at: i) == 124 { paint(NSRange(location: i, length: 1), Palette.mark) }
        }
        for m in Self.inlineRx.matches(in: line, range: full) {
            if m.range(at: 1).location != NSNotFound {
                paint(m.range(at: 1), Palette.code)
            } else if m.range(at: 2).location != NSNotFound {
                paint(m.range(at: 2), Palette.link)
                paint(m.range(at: 3), Palette.muted)
            } else if m.range(at: 4).location != NSNotFound {
                paint(m.range(at: 4), Palette.tag)
            } else {
                paint(m.range(at: 5), Palette.muted)
            }
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        editedSinceSave = true
        textChanged()
        // Wait for the input method to commit before re-rendering (e.g. while composing pinyin).
        if !textView.hasMarkedText() { onChange?() }
    }

    @objc private func boundsChanged(_ notification: Notification) {
        queueHighlight()
        ruler.needsDisplay = true
        if !scrollingProgrammatically { onScroll?() }
    }
}

/// Line numbers beside the editor. Only the visible lines are drawn; a wrapped line is numbered once.
@MainActor
final class LineNumberRuler: NSRulerView {
    private weak var editor: MarkdownEditor?
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var digits = 0

    init(editor: MarkdownEditor) {
        self.editor = editor
        super.init(scrollView: editor.scrollView, orientation: .verticalRuler)
        // No clientView: that would make the text view manage this as a formatting ruler.
        // The ruler floats over the text; views no longer clip to their bounds by default.
        clipsToBounds = true
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    func update(zoom: Double? = nil, lineCount: Int) {
        if let zoom {
            font = .monospacedDigitSystemFont(ofSize: 11 * zoom, weight: .regular)
            digits = 0
        }
        let needed = max(3, String(lineCount).count)
        if needed != digits {
            digits = needed
            let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
            ruleThickness = ceil(CGFloat(digits) * digitWidth) + 16
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.textView.layoutManager, let container = editor.textView.textContainer else { return }
        let textView = editor.textView
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(rect).fill()

        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let chars = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: visible, in: container),
                                          actualGlyphRange: nil)
        let starts = editor.lineStarts
        let length = (textView.string as NSString).length
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        var line = editor.lineNumber(at: chars.location)
        while line < starts.count, starts[line] <= NSMaxRange(chars) {
            let fragment: NSRect
            var baseline = font.ascender
            if starts[line] >= length {
                fragment = layout.extraLineFragmentRect // empty last line
            } else {
                let glyph = layout.glyphIndexForCharacter(at: starts[line])
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                baseline = layout.location(forGlyphAt: glyph).y
            }
            // Align the number's baseline with the text's first baseline on that line.
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let label = String(line + 1) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: ruleThickness - width - 8, y: top + baseline - font.ascender), withAttributes: attributes)
            line += 1
        }
    }
}
