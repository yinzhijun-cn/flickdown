import Foundation

/// Lightweight SQL colouring, with line-to-line state for comments and quoted text.
/// Indexing only tracks delimiters; keywords and numbers are recognised when a line is visible.
enum SQLHighlighter {
    enum State: Equatable {
        case code, blockComment, quoted(unichar)
    }

    private static let keywords = Set("""
        ADD ALL ALTER ANALYZE AND AS ASC AUTO_INCREMENT BEGIN BETWEEN BIGINT BINARY BLOB BOOLEAN BY
        CALL CASCADE CASE CHAR CHARACTER CHECK COLLATE COLUMN COMMENT COMMIT CONSTRAINT CREATE CROSS
        CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP DATABASE DATE DATETIME DECIMAL DECLARE DEFAULT
        DELETE DESC DESCRIBE DISTINCT DOUBLE DROP ELSE END ENGINE ESCAPE EXCEPT EXISTS EXPLAIN FALSE
        FETCH FLOAT FOR FOREIGN FROM FULL FUNCTION GRANT GROUP HAVING IF IN INDEX INNER INSERT INT
        INTEGER INTERSECT INTERVAL INTO IS JOIN KEY LEFT LIKE LIMIT LOCK LONGTEXT NAMES NATURAL NOT NULL
        NUMERIC OFFSET ON ONLY OR ORDER OUTER OVER PARTITION PRECISION PRIMARY PROCEDURE RANGE
        REFERENCES REGEXP RENAME REPLACE RETURN RETURNS REVOKE RIGHT ROLLBACK ROW ROWS SELECT SET
        SHOW SMALLINT START TABLE TEMPORARY TEXT THEN TIME TIMESTAMP TINYINT TO TRANSACTION TRIGGER TRUE
        TRUNCATE UNION UNIQUE UNSIGNED UPDATE USE USING VALUES VARBINARY VARCHAR VIEW WHEN WHERE
        WINDOW WITH RECURSIVE
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let codeToken = try! NSRegularExpression(pattern:
        #"[\p{L}_$][\p{L}\p{N}\p{M}_$]*|0[xX][0-9A-Fa-f]+|0[bB][01]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"#)

    /// `range` is one line without its newline. Emitted ranges use the original UTF-16 offsets.
    static func scan(_ text: NSString, range: NSRange, state: inout State,
                     emit: ((NSRange, SyntaxTokenKind) -> Void)? = nil) {
        var position = range.location
        let end = NSMaxRange(range)

        func startsQuotedTextOrComment(at index: Int) -> Bool {
            let c = text.character(at: index)
            if c == 39 || c == 34 || c == 96 || c == 35 { return true } // ' " ` #
            guard index + 1 < end else { return false }
            let next = text.character(at: index + 1)
            return (c == 45 && next == 45) || (c == 47 && next == 42) // -- /*
        }

        while position < end {
            let start = position
            if state == .code {
                if !startsQuotedTextOrComment(at: position) {
                    repeat { position += 1 } while position < end && !startsQuotedTextOrComment(at: position)
                    if let emit {
                        colourCode(text.substring(with: NSRange(location: start, length: position - start)),
                                   at: start, emit: emit)
                    }
                    continue
                }

                let c = text.character(at: position)
                if c == 35 || c == 45 { // # or --: the rest of this line is a comment.
                    emit?(NSRange(location: start, length: end - start), .comment)
                    return
                } else if c == 47 { // /*
                    state = .blockComment
                    position += 2
                } else {
                    state = .quoted(c)
                    position += 1
                }
            }

            switch state {
            case .blockComment:
                while position < end {
                    if text.character(at: position) == 42, position + 1 < end,
                       text.character(at: position + 1) == 47 {
                        position += 2
                        state = .code
                        break
                    }
                    position += 1
                }
                emit?(NSRange(location: start, length: position - start), .comment)

            case .quoted(let quote):
                while position < end {
                    let c = text.character(at: position)
                    if c == 92, quote != 96 { // MySQL backslash escapes inside quoted strings.
                        position = min(position + 2, end)
                    } else if c == quote {
                        position += 1
                        if position < end, text.character(at: position) == quote {
                            position += 1 // SQL doubled quotes: 'it''s', "a""b", `a``b`.
                        } else {
                            state = .code
                            break
                        }
                    } else {
                        position += 1
                    }
                }
                emit?(NSRange(location: start, length: position - start), quote == 39 ? .string : .identifier)

            case .code:
                break
            }
        }
    }

    private static func colourCode(_ text: String, at base: Int, emit: (NSRange, SyntaxTokenKind) -> Void) {
        let string = text as NSString
        for match in codeToken.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let token = string.substring(with: match.range)
            let first = string.character(at: match.range.location)
            let kind: SyntaxTokenKind
            if keywords.contains(token.uppercased()) {
                kind = .keyword
            } else if (48...57).contains(first) || first == 46 {
                kind = .number
            } else {
                continue
            }
            emit(NSRange(location: base + match.range.location, length: match.range.length), kind)
        }
    }
}
