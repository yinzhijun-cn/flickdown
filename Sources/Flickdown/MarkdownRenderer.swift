import CMd4c
import Foundation

/// Markdown bytes -> HTML, via md4c (~300 MB/s). Pure and thread-safe.
enum MarkdownRenderer {
    /// The HTML split at top-level block boundaries: a small first piece that fills the first
    /// screens, then larger ones. Each piece is valid HTML on its own. Short documents give one piece.
    /// With `lines`, top-level blocks carry their source line (`data-l`) for editor/preview scroll sync.
    static func htmlChunks(from source: Data, lines: Bool = false, first: Int = 48 << 10, rest: Int = 512 << 10) -> [String] {
        let bytes = utf8(source)
        guard !bytes.isEmpty else { return [""] }
        var buf = flick_buf()
        defer { flick_buf_free(&buf) }
        let rc = bytes.withUnsafeBytes { raw in
            flick_render_html(raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count, &buf, lines ? UInt32(FLICK_LINES) : 0)
        }
        guard rc == 0, let out = buf.data else {
            return ["<pre>" + escape(String(decoding: bytes, as: UTF8.self)) + "</pre>"]
        }
        let html = UnsafeRawBufferPointer(start: out, count: buf.size)
        func piece(_ from: Int, _ to: Int) -> String {
            String(decoding: UnsafeRawBufferPointer(rebasing: html[from..<to]), as: UTF8.self)
        }

        var chunks: [String] = []
        var start = 0
        var limit = first
        for i in 0..<buf.nbounds {
            let end = buf.bounds[i]
            if end - start >= limit, buf.size - end >= limit / 2 {
                chunks.append(piece(start, end))
                start = end
                limit = rest
            }
        }
        chunks.append(piece(start, buf.size))
        return chunks
    }

    /// The document as text (for the source view and the editor), decoded the same way as for rendering.
    /// A UTF-8 byte-order mark stays in the text, so saving writes it back unchanged.
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: gb18030) { return (text, gb18030) }
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    static func sourceText(_ data: Data) -> String { decode(data).text }

    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// md4c expects UTF-8. Older Chinese documents are often GBK/GB18030, so fall back to that.
    private static func utf8(_ data: Data) -> Data {
        if String(data: data, encoding: .utf8) != nil { return data }
        if let text = String(data: data, encoding: gb18030) { return Data(text.utf8) }
        return data
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
