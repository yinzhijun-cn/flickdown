import Foundation

/// Markdown typing aids: list and quote continuation, list indentation, emphasis and links.
/// Plain text in, one replacement out, so the editor applies it as a single undoable change.
enum MarkdownEditing {
    struct Edit: Equatable {
        let range: NSRange
        let text: String
        /// The selection after the change.
        let selection: NSRange
    }

    /// Quote markers, then an optional list marker: `> `, `- `, `1. `, `- [x] `.
    private static let continuationRx = try! NSRegularExpression(
        pattern: "^([ \\t]*(?:>[ \\t]?)*)(?:(?:([-*+])|(\\d{1,9})([.)]))([ \\t]+)(\\[[ xX]\\][ \\t]+)?)?")
    private static let listItemRx = try! NSRegularExpression(pattern: "^([ \\t]*)(?:[-*+]|\\d{1,9}[.)])(?:[ \\t]+|$)")

    /// Return on a list item or quote line continues it on the next line;
    /// Return at the end of an empty item ends the list or quote instead.
    static func newline(in text: NSString, selection: NSRange) -> Edit? {
        let line = contentRange(ofLineAt: selection.location, in: text)
        let content = text.substring(with: line) as NSString
        guard let match = continuationRx.firstMatch(in: content as String, range: NSRange(location: 0, length: content.length)) else { return nil }
        let quote = content.substring(with: match.range(at: 1))
        let isListItem = match.range(at: 5).location != NSNotFound
        guard isListItem || quote.contains(">") else { return nil }
        let prefixEnd = line.location + match.range.length
        guard selection.location >= prefixEnd else { return nil }

        let itemText = content.substring(from: match.range.length).trimmingCharacters(in: .whitespaces)
        if itemText.isEmpty, selection.length == 0 {
            return Edit(range: NSRange(location: line.location, length: line.length), text: "",
                        selection: NSRange(location: line.location, length: 0))
        }
        var prefix = quote
        if isListItem {
            if match.range(at: 3).location != NSNotFound {
                let number = Int(content.substring(with: match.range(at: 3)))!
                prefix += String(number + 1) + content.substring(with: match.range(at: 4))
            } else {
                prefix += content.substring(with: match.range(at: 2))
            }
            prefix += content.substring(with: match.range(at: 5))
            if match.range(at: 6).location != NSNotFound { prefix += "[ ] " }
        }
        let inserted = "\n" + prefix
        return Edit(range: selection, text: inserted,
                    selection: NSRange(location: selection.location + (inserted as NSString).length, length: 0))
    }

    /// Tab / Shift-Tab when the caret is on a list item: shifts every selected list item by its marker's width,
    /// which is how far a nested item must be indented. Returns nil elsewhere, so Tab inserts a tab as usual.
    static func indent(in text: NSString, selection: NSRange, outdent: Bool) -> Edit? {
        let block = text.lineRange(for: selection)
        let firstLine = contentRange(ofLineAt: selection.location, in: text)
        guard markerWidth(text.substring(with: firstLine)) != nil else { return nil }

        var result = ""
        var firstLineShift = 0
        var location = block.location
        while location < NSMaxRange(block) {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var line = text.substring(with: lineRange)
            if let width = markerWidth(line) {
                let shift = outdent ? -removableIndent(line, upTo: width) : width
                line = shift > 0 ? String(repeating: " ", count: shift) + line : String(line.dropFirst(-shift))
                if location == block.location { firstLineShift = shift }
            }
            result += line
            location = NSMaxRange(lineRange)
        }
        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: max(block.location, selection.location + firstLineShift), length: 0)
        } else {
            let trimmed = result.hasSuffix("\n") ? String(result.dropLast()) : result
            newSelection = NSRange(location: block.location, length: (trimmed as NSString).length)
        }
        return Edit(range: block, text: result, selection: newSelection)
    }

    /// Wraps the selection in `marker` (`**` bold, `*` italic), or unwraps it when it is already wrapped.
    static func toggleEmphasis(_ marker: String, in text: NSString, selection: NSRange) -> Edit {
        let m = (marker as NSString).length
        let star = marker.utf16.first!
        // A run of 3 is bold and italic together, so it counts as wrapped for both.
        func isMarker(_ run: Int) -> Bool { run == m || run == 3 }
        let before = run(of: star, in: text, endingAt: selection.location)
        let after = run(of: star, in: text, startingAt: NSMaxRange(selection))
        if isMarker(before), isMarker(after) {
            let outer = NSRange(location: selection.location - m, length: selection.length + 2 * m)
            return Edit(range: outer, text: text.substring(with: selection),
                        selection: NSRange(location: outer.location, length: selection.length))
        }
        let selected = text.substring(with: selection) as NSString
        if selection.length > 2 * m {
            let inner = NSRange(location: m, length: selected.length - 2 * m)
            if isMarker(run(of: star, in: selected, startingAt: 0)), isMarker(run(of: star, in: selected, endingAt: selected.length)) {
                return Edit(range: selection, text: selected.substring(with: inner),
                            selection: NSRange(location: selection.location, length: inner.length))
            }
        }
        return Edit(range: selection, text: marker + (selected as String) + marker,
                    selection: NSRange(location: selection.location + m, length: selection.length))
    }

    /// `[selection]()` with the caret in the parentheses; a selected URL becomes `[](url)` with the caret in the brackets.
    static func link(in text: NSString, selection: NSRange) -> Edit {
        let selected = text.substring(with: selection)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            return Edit(range: selection, text: "[](\(selected))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let inserted = "[\(selected)]()"
        return Edit(range: selection, text: inserted,
                    selection: NSRange(location: selection.location + (inserted as NSString).length - 1, length: 0))
    }

    // MARK: Helpers

    /// The line at `location` without its line break.
    private static func contentRange(ofLineAt location: Int, in text: NSString) -> NSRange {
        var line = text.lineRange(for: NSRange(location: location, length: 0))
        while line.length > 0, [10, 13].contains(text.character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
        return line
    }

    /// Width of a list item's marker and the spaces after it (`- ` is 2, `10. ` is 4); nil if the line is not a list item.
    private static func markerWidth(_ line: String) -> Int? {
        let ns = line as NSString
        guard let match = listItemRx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return match.range.length - match.range(at: 1).length
    }

    /// How many leading spaces Shift-Tab may remove; a leading tab counts as the whole step.
    private static func removableIndent(_ line: String, upTo width: Int) -> Int {
        if line.hasPrefix("\t") { return 1 }
        return min(line.prefix { $0 == " " }.count, width)
    }

    private static func run(of c: unichar, in text: NSString, endingAt end: Int) -> Int {
        var i = end
        while i > 0, text.character(at: i - 1) == c { i -= 1 }
        return end - i
    }

    private static func run(of c: unichar, in text: NSString, startingAt start: Int) -> Int {
        var i = start
        while i < text.length, text.character(at: i) == c { i += 1 }
        return i - start
    }
}
