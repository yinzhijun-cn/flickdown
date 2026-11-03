/// Semantic token categories shared by the native text highlighters.
/// The editor owns their colours; scanners only identify text ranges.
enum SyntaxTokenKind {
    case keyword, key, string, number, literal, identifier, comment, punctuation, anchor, tag
}
