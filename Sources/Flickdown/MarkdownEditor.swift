import AppKit

/// The text editor, with Markdown, SQL, JSON and YAML colouring and optional Markdown headings.
///
/// TextKit 1 with non-contiguous layout: mature, fast on large files, full input-method support.
/// Syntax colouring uses temporary attributes on visible lines and never triggers relayout.
/// The line index preserves the context of Markdown fences and multiline SQL/YAML tokens.
@MainActor
final class MarkdownEditor: NSObject, NSTextViewDelegate {
    enum Syntax {
        case plainText, markdown, sql, json, yaml
    }

    let scrollView = NSScrollView()
    let textView: NSTextView
    var onChange: (() -> Void)?
    var onScroll: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    /// Widest text column (at 100% zoom); nil fills the view. Wide windows centre the column.
    var maxTextWidth: CGFloat? {
        didSet { layoutTextColumn() }
    }

    private let storage = NSTextStorage()
    private let syntax: Syntax
    private let layoutManager = NSLayoutManager()
    private var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var zoom = 1.0
    private var fonts = (regular: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                         bold: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                         italic: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    private var savedText = ""
    private var editedSinceSave = false
    private var cachedIndex: TextIndex?
    private var cachedHeadings: [Heading]?
    private var highlightQueued = false
    private var scrollingProgrammatically = false
    private var ruler: LineNumberRuler!

    init(zoom: Double, syntax: Syntax) {
        self.syntax = syntax
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        textView = EditorTextView(frame: .zero, textContainer: container)
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
        textView.backgroundColor = Theme.background
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = Theme.background
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: scrollView)

        ruler = LineNumberRuler(editor: self)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        setZoom(zoom)
    }

    var text: String { textView.string }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let range = view.selectedRange()
        guard range.length > 0 else { return menu }
        let text = (view.string as NSString).substring(with: range)
        SelectedTextMenu.addItems(to: menu, text: text, window: view.window)
        return menu
    }

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
        self.zoom = zoom
        let font = NSFont.monospacedSystemFont(ofSize: 13 * zoom, weight: .regular)
        let italic = font.fontDescriptor.withSymbolicTraits(.italic)
        fonts = (font, .monospacedSystemFont(ofSize: 13 * zoom, weight: .semibold), NSFont(descriptor: italic, size: font.pointSize) ?? font)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        baseAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: Theme.text]
        textView.typingAttributes = baseAttributes
        storage.addAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        ruler.update(zoom: zoom, lineCount: lineCount)
        layoutTextColumn()
        queueHighlight()
    }

    /// Caps the text column at `maxTextWidth` and centres it. The left margin goes into the line-number ruler,
    /// so the numbers stay beside the text; the right margin is left outside the text container.
    private func layoutTextColumn() {
        guard let container = textView.textContainer else { return }
        let inset = textView.textContainerInset.width
        let column = maxTextWidth.map { $0 * zoom + 2 * inset }
        let margin = column.map { max(0, (scrollView.bounds.width - ruler.numbersThickness - $0) / 2) } ?? 0
        ruler.margin = margin
        container.widthTracksTextView = margin == 0
        if let column, margin > 0 {
            container.size = NSSize(width: column - 2 * inset, height: CGFloat.greatestFiniteMagnitude)
        } else {
            container.size = NSSize(width: max(0, textView.bounds.width - 2 * inset), height: CGFloat.greatestFiniteMagnitude)
        }
        queueHighlight()
    }

    /// 1-based line and column of the caret, as the status bar shows them.
    func caretPosition() -> (line: Int, column: Int) {
        let caret = textView.selectedRange().location
        let line = lineNumber(at: caret)
        let start = index().lineStarts[line]
        let column = (textView.string as NSString).substring(with: NSRange(location: start, length: caret - start)).count
        return (line + 1, column + 1)
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
        /// SQL state at each line's start; no full-document token list is needed.
        var sqlStates: [SQLHighlighter.State] = []
        var yamlStates: [YAMLHighlighter.State] = []
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
        var sqlState = SQLHighlighter.State.code
        var yamlState = YAMLHighlighter.State()

        func endLine(at end: Int, next: Int) {
            if syntax == .sql {
                idx.sqlStates.append(sqlState)
                SQLHighlighter.scan(s, range: NSRange(location: start, length: end - start), state: &sqlState)
            } else if syntax == .yaml {
                idx.yamlStates.append(yamlState)
                YAMLHighlighter.scan(s, range: NSRange(location: start, length: end - start), state: &yamlState)
            } else if syntax == .markdown, let fence = Self.fence(in: s, line: NSRange(location: start, length: end - start)) {
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
            // A CRLF at the buffer boundary also consumes the next buffer's leading LF.
            base += i
        }
        // A trailing newline leaves an empty last line, matching how md4c numbers lines; lineStarts already has it.
        if start < length { endLine(at: length, next: length) ; idx.lineStarts.removeLast() }
        if syntax == .sql, idx.sqlStates.count < idx.lineStarts.count { idx.sqlStates.append(sqlState) }
        if syntax == .yaml, idx.yamlStates.count < idx.lineStarts.count { idx.yamlStates.append(yamlState) }
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
        guard syntax == .markdown else { return [] }
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
        static let mark = Theme.accent
        static let code = Theme.code
        static let link = Theme.accent
        static let tag = Theme.htmlTag
        static let muted = Theme.muted
        static let punctuation = Theme.syntaxPunctuation
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
    private static let headingRx = regex("^ {0,3}#{1,6}(?:\\s|$)")
    private static let boldRx = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicRx = regex("(?<!\\*)\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?!\\*)|(?<![_\\p{L}\\p{N}])_(?=[^\\s_])(.+?)(?<=[^\\s_])_(?![_\\p{L}\\p{N}])")
    private static let ruleRx = regex("^ {0,3}(?:([-*_])(?:\\s*\\1){2,}|=+)\\s*$")
    private static let quoteRx = regex("^\\s*(?:>\\s?)+")
    private static let listRx = regex("^\\s*([-*+]|\\d{1,9}[.)])\\s+(\\[[ xX]\\](?=\\s))?")
    private static let tableRx = regex("^\\s*\\|.*\\|\\s*$")
    private static let inlineRx = regex("(`[^`]+`)|(!?\\[[^\\]]*\\])(\\([^)]*\\))|(<!--.*?-->|</?[A-Za-z][^<>]*>)|(https?://[^\\s<>()]+)")

    private func queueHighlight() {
        guard syntax != .plainText, !highlightQueued else { return }
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
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let idx = index()
        let firstLine = lineNumber(at: characters.location)
        let lastLine = lineNumber(at: max(characters.location, NSMaxRange(characters) - 1))
        let end = lastLine + 1 < idx.lineStarts.count ? idx.lineStarts[lastLine + 1] : s.length
        let range = NSRange(location: idx.lineStarts[firstLine], length: end - idx.lineStarts[firstLine])
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        var styled: [(range: NSRange, font: NSFont)] = []

        // Use the same CR/LF boundaries as the index. Unicode separators can be string content.
        for line in firstLine...lastLine {
            let start = idx.lineStarts[line]
            let lineEnd = line + 1 < idx.lineStarts.count ? idx.lineStarts[line + 1] : s.length
            var content = NSRange(location: start, length: lineEnd - start)
            while content.length > 0, Self.isNewline(s.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            switch syntax {
            case .markdown:
                colour(line: s.substring(with: content), at: content.location, kind: kind(ofLine: line), styled: &styled)
            case .sql:
                var state = idx.sqlStates[line]
                SQLHighlighter.scan(s, range: content, state: &state, emit: applyHighlight)
            case .json:
                JSONHighlighter.scan(s, range: content, emit: applyHighlight)
            case .yaml:
                var state = idx.yamlStates[line]
                YAMLHighlighter.scan(s, range: content, state: &state, emit: applyHighlight)
            case .plainText:
                break
            }
        }
        if syntax == .markdown { applyFonts(styled, in: range) }
    }

    /// Bold headings and emphasis. Fonts live in the text storage (unlike colours), so it is only touched when
    /// the visible lines' styling actually changed; bold and italic SF Mono keep the regular advance width.
    private func applyFonts(_ styled: [(range: NSRange, font: NSFont)], in range: NSRange) {
        let styled = styled.sorted { $0.range.location < $1.range.location }
        var current: [(range: NSRange, font: NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? NSFont, font != fonts.regular { current.append((run, font)) }
        }
        guard !current.elementsEqual(styled, by: { $0.range == $1.range && $0.font == $1.font }) else { return }
        storage.beginEditing()
        storage.addAttribute(.font, value: fonts.regular, range: range)
        for run in styled { storage.addAttribute(.font, value: run.font, range: run.range) }
        storage.endEditing()
    }

    private func applyHighlight(_ range: NSRange, _ kind: SyntaxTokenKind) {
        let color: NSColor
        switch kind {
        case .keyword, .literal: color = .systemPurple
        case .key, .identifier, .anchor: color = .systemTeal
        case .string: color = .systemRed
        case .number: color = .systemBlue
        case .comment, .punctuation: color = .secondaryLabelColor
        case .tag: color = .systemOrange
        }
        layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
    }

    private func colour(line: String, at base: Int, kind: LineKind, styled: inout [(range: NSRange, font: NSFont)]) {
        let full = NSRange(location: 0, length: (line as NSString).length)
        func paint(_ r: NSRange, _ color: NSColor) {
            guard r.location != NSNotFound, r.length > 0 else { return }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color,
                                                forCharacterRange: NSRange(location: base + r.location, length: r.length))
        }
        func style(_ r: NSRange, _ font: NSFont) {
            guard r.location != NSNotFound, r.length > 0 else { return }
            styled.append((NSRange(location: base + r.location, length: r.length), font))
        }
        switch kind {
        case .fence: return paint(full, Palette.punctuation)
        case .code: return paint(full, Palette.code)
        case .text: break
        }
        if let m = Self.headingRx.firstMatch(in: line, range: full) {
            paint(m.range, Palette.mark)
            return style(full, fonts.bold)
        }
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
                paint(m.range(at: 3), Palette.punctuation)
            } else if m.range(at: 4).location != NSNotFound {
                paint(m.range(at: 4), Palette.tag)
            } else {
                paint(m.range(at: 5), Palette.link)
            }
        }
        // Emphasis: the markers fade, the text takes the bold or italic face.
        for m in Self.boldRx.matches(in: line, range: full) {
            let marker = m.range(at: 1).length
            paint(NSRange(location: m.range.location, length: marker), Palette.punctuation)
            paint(NSRange(location: NSMaxRange(m.range) - marker, length: marker), Palette.punctuation)
            style(m.range(at: 2), fonts.bold)
        }
        for m in Self.italicRx.matches(in: line, range: full) {
            paint(NSRange(location: m.range.location, length: 1), Palette.punctuation)
            paint(NSRange(location: NSMaxRange(m.range) - 1, length: 1), Palette.punctuation)
            style(m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2), fonts.italic)
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        editedSinceSave = true
        textChanged()
        // Wait for the input method to commit before re-rendering (e.g. while composing pinyin).
        if !textView.hasMarkedText() { onChange?() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
    }

    /// Return, Tab and Shift-Tab on list items and quotes (outside fenced code).
    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard syntax == .markdown, !view.hasMarkedText() else { return false }
        let text = view.string as NSString
        let selection = view.selectedRange()
        guard kind(ofLine: lineNumber(at: selection.location)) == .text else { return false }
        let edit: MarkdownEditing.Edit?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            edit = MarkdownEditing.newline(in: text, selection: selection)
        case #selector(NSResponder.insertTab(_:)):
            edit = MarkdownEditing.indent(in: text, selection: selection, outdent: false)
        case #selector(NSResponder.insertBacktab(_:)):
            edit = MarkdownEditing.indent(in: text, selection: selection, outdent: true)
        default:
            edit = nil
        }
        guard let edit else { return false }
        apply(edit)
        return true
    }

    // MARK: Formatting

    func toggleEmphasis(_ marker: String) {
        apply(MarkdownEditing.toggleEmphasis(marker, in: textView.string as NSString, selection: textView.selectedRange()))
    }

    func insertLink() {
        apply(MarkdownEditing.link(in: textView.string as NSString, selection: textView.selectedRange()))
    }

    /// One undoable change, as if typed.
    private func apply(_ edit: MarkdownEditing.Edit) {
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.text, attributes: baseAttributes))
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
        textView.scrollRangeToVisible(edit.selection)
    }

    @objc private func frameChanged(_ notification: Notification) {
        if maxTextWidth != nil { layoutTextColumn() }
    }

    @objc private func boundsChanged(_ notification: Notification) {
        queueHighlight()
        ruler.needsDisplay = true
        if !scrollingProgrammatically { onScroll?() }
    }
}

private final class EditorTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        // Without layout at the caret, TextKit can loop while focusing a newly selected tab.
        if let storage = textStorage, storage.length > 0 {
            let character = min(selectedRange().location, storage.length - 1)
            layoutManager?.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
        }
        return super.becomeFirstResponder()
    }
}

/// Line numbers beside the editor. Only the visible lines are drawn; a wrapped line is numbered once.
@MainActor
final class LineNumberRuler: NSRulerView {
    private weak var editor: MarkdownEditor?
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var digits = 0
    /// Width the line numbers need.
    private(set) var numbersThickness: CGFloat = 0
    /// Extra space to the left of the numbers, which centres a capped text column.
    var margin: CGFloat = 0 {
        didSet { if margin != oldValue { ruleThickness = numbersThickness + margin } }
    }

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
            numbersThickness = ceil(CGFloat(digits) * digitWidth) + 16
            ruleThickness = numbersThickness + margin
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.textView.layoutManager, let container = editor.textView.textContainer else { return }
        let textView = editor.textView
        Theme.background.setFill()
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
