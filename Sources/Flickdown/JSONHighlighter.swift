import Foundation

/// JSON tokens from RFC 8259; colour only, without parsing or rewriting the document.
enum JSONHighlighter {
    private static let whitespace: Set<unichar> = [9, 10, 13, 32]
    private static let punctuation: Set<unichar> = [91, 93, 123, 125, 58, 44] // []{}:,
    private static let number = try! NSRegularExpression(pattern:
        #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#)

    /// `range` is one line without its newline. Emitted ranges use the original UTF-16 offsets.
    static func scan(_ text: NSString, range: NSRange, emit: (NSRange, SyntaxTokenKind) -> Void) {
        var position = range.location
        let end = NSMaxRange(range)

        while position < end {
            let start = position
            let character = text.character(at: position)
            if character == 34 { // A double-quoted key or string value.
                position += 1
                var closed = false
                while position < end {
                    let current = text.character(at: position)
                    if current == 92 {
                        // An escaped quote must not end the string; an unfinished escape is safe to colour.
                        position = min(position + 2, end)
                    } else if current == 34 {
                        position += 1
                        closed = true
                        break
                    } else {
                        position += 1
                    }
                }

                // JSON permits whitespace, including newlines, between a key and its colon.
                var next = position
                if closed {
                    while next < text.length, whitespace.contains(text.character(at: next)) { next += 1 }
                }
                let isKey = closed && next < text.length && text.character(at: next) == 58
                emit(NSRange(location: start, length: position - start), isKey ? .key : .string)
            } else if punctuation.contains(character) {
                emit(NSRange(location: position, length: 1), .punctuation)
                position += 1
            } else if whitespace.contains(character) {
                position += 1
            } else {
                // Consume a whole bare token so malformed values such as trueValue or 01
                // don't get a valid literal or number highlighted inside them.
                repeat {
                    position += 1
                    if position == end { break }
                    let next = text.character(at: position)
                    if whitespace.contains(next) || punctuation.contains(next) || next == 34 { break }
                } while position < end
                let tokenRange = NSRange(location: start, length: position - start)
                let token = text.substring(with: tokenRange)
                if token == "true" || token == "false" || token == "null" {
                    emit(tokenRange, .literal)
                } else if character == 45 || (48...57).contains(character) {
                    if number.firstMatch(in: token, range: NSRange(location: 0, length: tokenRange.length)) != nil {
                        emit(tokenRange, .number)
                    }
                }
            }
        }
    }
}
