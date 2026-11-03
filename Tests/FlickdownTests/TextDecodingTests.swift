import Foundation
import Testing
@testable import Flickdown

struct TextDecodingTests {
    @Test("支持的文本编码及 BOM 可以无损往返")
    func supportedEncodingsRoundTrip() throws {
        let text = "中文 text\r\n\t# ** <html> 😀\n"
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let fixtures: [Data] = [
            Data(),
            Data(text.utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8),
            try #require(text.data(using: gb18030)),
            Data([0xFF, 0xFE]) + (try #require(text.data(using: .utf16LittleEndian))),
            Data([0xFE, 0xFF]) + (try #require(text.data(using: .utf16BigEndian)))
        ]
        for bytes in fixtures {
            let decoded = try #require(MarkdownRenderer.decode(bytes))
            #expect(decoded.text.data(using: decoded.encoding) == bytes)
            if !bytes.isEmpty {
                #expect(decoded.text.replacingOccurrences(of: "\u{FEFF}", with: "") == text)
            }
        }
    }

    @Test("二进制和不可解码的字节不能作为文本编辑")
    func invalidTextIsRejected() {
        for bytes in [Data([0, 1, 2, 3]), Data("text\u{0}data".utf8), Data([0xFF]), Data([0xFF, 0xFE, 0x41])] {
            #expect(MarkdownRenderer.decode(bytes) == nil)
        }
    }
}
