import AppKit
import WebKit

/// A WKWebView with the viewer page (web/index.html + app.js) loaded and ready to receive HTML.
///
/// Spinning up a web view starts WebKit's content process, which costs far more than parsing
/// Markdown, so the pool below keeps one page warm before any document asks for it.
@MainActor
final class RenderPage: NSObject, WKScriptMessageHandler {
    static let templateURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")!

    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static let bootstrap: WKUserScript = {
        let jsURL = Bundle.main.url(forResource: "app", withExtension: "js", subdirectory: "web")!
        let appJS = (try? String(contentsOf: jsURL, encoding: .utf8)) ?? ""
        let config: [String: String] = [
            "res": templateURL.deletingLastPathComponent().absoluteString,
            "lang": isChinese ? "zh" : "en",
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        return WKUserScript(source: "window.__FLICK__=\(json);\n\(appJS)",
                            injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }()

    let webView: WKWebView
    private(set) var isReady = false
    var onReady: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(Self.bootstrap)
        webView = ViewerWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "flick")
        webView.allowsMagnification = true
        webView.isInspectable = Bench.env["FLICK_INSPECT"] != nil
        loadTemplate()
    }

    /// Also used to recover after the content process crashes.
    func loadTemplate() {
        isReady = false
        // Read access to "/" lets documents show images referenced by relative or absolute paths.
        webView.loadFileURL(Self.templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            isReady = true
            Bench.mark("template ready")
            onReady?()
        } else {
            onMessage?(body)
        }
    }
}

/// Keeps one prewarmed page so opening a document never waits for WebKit to boot.
@MainActor
enum WebViewPool {
    private static var spare: RenderPage?

    static func prewarm() {
        if spare == nil { spare = RenderPage() }
    }

    static func take() -> RenderPage {
        let page = spare ?? RenderPage()
        spare = nil
        // Refill once the current document has had the CPU to itself.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            prewarm()
        }
        return page
    }
}

/// WKUserContentController retains its handlers; this breaks the page <-> controller cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Drops context-menu items that would navigate away from the viewer page.
final class ViewerWebView: WKWebView {
    private static let hidden: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
    ]

    /// Find goes to the window's own find bar (WKWebView's built-in one doesn't work in this setup).
    override func performTextFinderAction(_ sender: Any?) {
        window?.windowController?.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where Self.hidden.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        super.willOpenMenu(menu, with: event)
    }
}
