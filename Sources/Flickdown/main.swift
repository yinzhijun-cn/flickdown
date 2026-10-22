import AppKit

Bench.mark("main")
// Create the first web view as early as possible so WebKit's helper processes start booting.
// Source mode opens in the native editor and doesn't need it yet.
if !Prefs.sourceMode { WebViewPool.prewarm() }
Bench.mark("web view created")
let app = NSApplication.shared
// The first NSDocumentController instance becomes the shared one.
_ = RecentDocumentsController()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
