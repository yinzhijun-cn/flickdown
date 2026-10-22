import CMd4c
import Foundation

// Measures raw md4c throughput: md-bench <file.md> [iterations]
// md-bench <file.md> --html prints the HTML with source-line marks instead.
let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]) else {
    print("usage: md-bench <file.md> [iterations | --html]")
    exit(1)
}
if args.count >= 3, args[2] == "--html" {
    var buf = flick_buf()
    _ = data.withUnsafeBytes { raw in
        flick_render_html(raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count, &buf, UInt32(FLICK_LINES))
    }
    FileHandle.standardOutput.write(Data(bytes: buf.data, count: buf.size))
    flick_buf_free(&buf)
    exit(0)
}
let iterations = args.count >= 3 ? Int(args[2]) ?? 20 : 20

var best = Double.infinity
var outSize = 0
for _ in 0..<iterations {
    var buf = flick_buf()
    let t0 = DispatchTime.now().uptimeNanoseconds
    _ = data.withUnsafeBytes { raw in
        flick_render_html(raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count, &buf, 0)
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    outSize = buf.size
    flick_buf_free(&buf)
    best = min(best, ms)
}
let mb = Double(data.count) / 1_048_576
print(String(format: "input %.2f MB -> html %.2f MB | best %.2f ms | %.0f MB/s",
             mb, Double(outSize) / 1_048_576, best, mb / (best / 1000)))
