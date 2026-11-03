import Foundation

/// YAML 1.2 colouring with enough line state for quoted and indented block scalars.
/// This recognises presentation tokens; it does not validate or construct YAML nodes.
enum YAMLHighlighter {
    struct State: Equatable {
        fileprivate var quote: unichar?
        fileprivate var flowDepth = 0
        fileprivate var block: BlockScalar?

        init() {}
    }

    fileprivate struct BlockScalar: Equatable {
        let parentIndent: Int
        var contentIndent: Int?
    }

    private static let literals: Set<String> = ["true", "True", "TRUE", "false", "False", "FALSE", "null", "Null", "NULL", "~"]
    // YAML 1.2 core schema, section 10.3.2: match the entire plain scalar.
    private static let number = try! NSRegularExpression(pattern:
        #"^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+|[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$"#)

    /// `range` excludes the newline; emitted ranges retain the source's UTF-16 offsets.
    static func scan(_ text: NSString, range: NSRange, state: inout State,
                     emit: ((NSRange, SyntaxTokenKind) -> Void)? = nil) {
        let end = NSMaxRange(range)
        var position = range.location
        while position < end, text.character(at: position) == 32 { position += 1 }
        let indent = position - range.location

        if var block = state.block {
            var nonWhitespace = position
            while nonWhitespace < end, isWhitespace(text.character(at: nonWhitespace)) { nonWhitespace += 1 }
            if nonWhitespace == end {
                if range.length > 0 { emit?(range, .string) }
                return
            }
            if block.contentIndent == nil, indent > block.parentIndent { block.contentIndent = indent }
            if let contentIndent = block.contentIndent, indent >= contentIndent {
                state.block = block
                emit?(range, .string)
                return
            }
            state.block = nil
        }

        var blockParentIndent = indent
        // Mapping indentation starts before any tag or anchor attached to its key.
        var mappingIndent = indent
        if state.quote != nil { position = range.location }
        while position < end {
            if state.quote == nil, isWhitespace(text.character(at: position)) {
                position += 1
                continue
            }
            let start = position
            let c = text.character(at: position)

            if state.quote != nil || c == 34 || c == 39 {
                let continued = state.quote != nil
                let quote = state.quote ?? c
                state.quote = quote
                if !continued { position += 1 }
                while position < end {
                    let character = text.character(at: position)
                    if quote == 34, character == 92 {
                        position = min(position + 2, end)
                    } else if character == quote {
                        position += 1
                        if quote == 39, position < end, text.character(at: position) == quote {
                            position += 1
                        } else {
                            state.quote = nil
                            break
                        }
                    } else {
                        position += 1
                    }
                }
                var next = position
                while next < end, isWhitespace(text.character(at: next)) { next += 1 }
                let isKey = !continued && state.quote == nil && next < end && text.character(at: next) == 58
                emit?(NSRange(location: start, length: position - start), isKey ? .key : .string)
                if isKey {
                    emit?(NSRange(location: next, length: 1), .punctuation)
                    if state.flowDepth == 0 { blockParentIndent = mappingIndent }
                    position = next + 1
                }
                continue
            }

            if c == 35, start == range.location || isWhitespace(text.character(at: start - 1)) {
                emit?(NSRange(location: start, length: end - start), .comment)
                return
            }
            if c == 91 || c == 123 { // [ {
                state.flowDepth += 1
                emit?(NSRange(location: position, length: 1), .punctuation)
                position += 1
                continue
            }
            if state.flowDepth > 0, c == 93 || c == 125 || c == 44 { // ] } ,
                if c != 44 { state.flowDepth -= 1 }
                emit?(NSRange(location: position, length: 1), .punctuation)
                position += 1
                continue
            }

            if state.flowDepth == 0, start == range.location,
               end - start >= 3, (text.substring(with: NSRange(location: start, length: 3)) == "---"
                                 || text.substring(with: NSRange(location: start, length: 3)) == "..."),
               start + 3 == end || isWhitespace(text.character(at: start + 3)) {
                emit?(NSRange(location: start, length: 3), .punctuation)
                position += 3
                continue
            }
            if (c == 45 || c == 63 || c == 58), position + 1 == end || isWhitespace(text.character(at: position + 1)) {
                if state.flowDepth == 0, c == 45 {
                    blockParentIndent = position - range.location
                    var next = position + 1
                    while next < end, isWhitespace(text.character(at: next)) { next += 1 }
                    mappingIndent = next - range.location
                }
                emit?(NSRange(location: position, length: 1), .punctuation)
                position += 1
                continue
            }

            if c == 38 || c == 42 || c == 33 { // &anchor, *alias, !tag
                position += 1
                if c == 33, position < end, text.character(at: position) == 60 {
                    position += 1
                    while position < end, text.character(at: position) != 62 { position += 1 }
                    if position < end { position += 1 }
                } else {
                    while position < end, !isWhitespace(text.character(at: position)),
                          !isFlowPunctuation(text.character(at: position)) { position += 1 }
                }
                emit?(NSRange(location: start, length: position - start), c == 33 ? .tag : .anchor)
                continue
            }

            if state.flowDepth == 0, c == 124 || c == 62 { // | or > block scalar header
                var headerEnd = position + 1
                var increment: Int?
                var hasChomping = false
                while headerEnd < end {
                    let indicator = text.character(at: headerEnd)
                    if (49...57).contains(indicator), increment == nil {
                        increment = Int(indicator - 48)
                    } else if (indicator == 43 || indicator == 45), !hasChomping {
                        hasChomping = true
                    } else {
                        break
                    }
                    headerEnd += 1
                }
                var tail = headerEnd
                while tail < end, isWhitespace(text.character(at: tail)) { tail += 1 }
                if tail == end || (tail > headerEnd && text.character(at: tail) == 35) {
                    state.block = BlockScalar(parentIndent: blockParentIndent,
                                              contentIndent: increment.map { blockParentIndent + $0 })
                    emit?(NSRange(location: start, length: headerEnd - start), .punctuation)
                    if tail < end { emit?(NSRange(location: tail, length: end - tail), .comment) }
                    return
                }
            }

            // Plain scalars may contain spaces, colons and hashes. Only YAML separators end them.
            while position < end {
                let character = text.character(at: position)
                if state.flowDepth > 0, isFlowPunctuation(character) { break }
                if character == 35, position > start, isWhitespace(text.character(at: position - 1)) { break }
                if character == 58, position + 1 == end || isWhitespace(text.character(at: position + 1))
                    || (state.flowDepth > 0 && isFlowPunctuation(text.character(at: position + 1))) { break }
                position += 1
            }
            var scalarEnd = position
            while scalarEnd > start, isWhitespace(text.character(at: scalarEnd - 1)) { scalarEnd -= 1 }
            let scalar = NSRange(location: start, length: scalarEnd - start)
            let isKey = position < end && text.character(at: position) == 58
            if scalar.length > 0, let emit {
                if isKey {
                    emit(scalar, .key)
                } else {
                    let value = text.substring(with: scalar)
                    let full = NSRange(location: 0, length: scalar.length)
                    if literals.contains(value) {
                        emit(scalar, .literal)
                    } else if number.firstMatch(in: value, range: full) != nil {
                        emit(scalar, .number)
                    } else {
                        emit(scalar, .string)
                    }
                }
            }
            if isKey {
                emit?(NSRange(location: position, length: 1), .punctuation)
                if state.flowDepth == 0 { blockParentIndent = mappingIndent }
                position += 1
            }
        }
    }

    private static func isWhitespace(_ c: unichar) -> Bool { c == 32 || c == 9 }
    private static func isFlowPunctuation(_ c: unichar) -> Bool { c == 91 || c == 93 || c == 123 || c == 125 || c == 44 }
}
