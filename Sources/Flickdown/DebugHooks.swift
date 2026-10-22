import AppKit
import WebKit

/// Environment switches used by scripts/bench.sh and for visual checks. Inert unless set.
///   FLICK_QUIT=1              quit after the first paint (cold-start benchmark)
///   FLICK_CLOSE=1             close the window after the first paint (warm-open benchmark)
///   FLICK_SNAPSHOT=out.png    write the visible page to a PNG (then quits if FLICK_QUIT is set)
///   FLICK_SNAPSHOT_DELAY=1.0  seconds to wait before the snapshot (lets highlighting/KaTeX/Mermaid finish)
///   FLICK_SNAPSHOT_SCROLL=px  scroll offset for the snapshot
///   FLICK_WINDOW=1200x900     initial window content size
///   FLICK_APPEARANCE=dark     force light/dark appearance
@MainActor
enum DebugHooks {
    private static let env = Bench.env

    static func configureApp() {
        switch env["FLICK_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func configure(_ window: NSWindow) {
        guard let spec = env["FLICK_WINDOW"]?.split(separator: "x"), spec.count == 2,
              let w = Double(spec[0]), let h = Double(spec[1]) else { return }
        window.setContentSize(NSSize(width: w, height: h))
        window.center()
    }

    static func didPaint(_ doc: DocumentWindowController, webView: WKWebView?) {
        if let path = env["FLICK_SNAPSHOT"] {
            let delay = Double(env["FLICK_SNAPSHOT_DELAY"] ?? "") ?? 1.0
            if let scroll = Double(env["FLICK_SNAPSHOT_SCROLL"] ?? "") {
                webView?.evaluateJavaScript("window.scrollTo(0, \(scroll))")
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard let webView else { return }
                webView.takeSnapshot(with: nil) { image, _ in
                    if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                    if env["FLICK_QUIT"] != nil { NSApp.terminate(nil) }
                }
            }
        } else if env["FLICK_QUIT"] != nil {
            NSApp.terminate(nil)
        } else if env["FLICK_CLOSE"] != nil {
            doc.close()
        }
    }
}
