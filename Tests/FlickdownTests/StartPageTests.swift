import AppKit
import SwiftUI
import Testing
@testable import Flickdown

@Suite("开始页", .serialized)
@MainActor
struct StartPageTests {
    @Test("无文件启动显示开始页，关闭后从 Dock 重开复用窗口")
    func launchAndReopenStartPage() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let start = try #require(delegate.startWindow)
        defer { start.close() }
        #expect(start.isVisible)

        delegate.showStartPage(nil)
        #expect(delegate.startWindow === start)
        start.performClose(nil)
        #expect(!start.isVisible)
        _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
        #expect(delegate.startWindow === start)
        #expect(start.isVisible)
    }

    @Test("带文件启动直接打开文档，从开始页重开同一文件复用文档")
    func directOpenAndReopenExistingDocument() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
            .standardizedFileURL.resolvingSymlinksInPath()
        try Data("开始页测试".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        delegate.application(app, open: [url])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(app.windows.first { ($0.windowController as? DocumentWindowController)?.fileURL == url })
        defer { window.close() }
        #expect(window.isVisible)
        #expect(delegate.startWindow?.isVisible != true)

        delegate.showStartPage(nil)
        let start = try #require(delegate.startWindow)
        defer { start.close() }
        let page = try #require((start.contentView as? NSHostingView<StartPage>)?.rootView)
        page.openRecent(url.appendingPathExtension("missing"))
        let alert = try #require(start.attachedSheet)
        #expect(start.isVisible)
        start.endSheet(alert)

        page.openRecent(url)
        #expect(!start.isVisible)
        #expect(app.windows.filter { ($0.windowController as? DocumentWindowController)?.fileURL == url } == [window])
        #expect(window.isVisible)

        window.performClose(nil)
        _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
        #expect(start.isVisible)
        page.openRecent(url)
        let reopened = try #require(app.windows.first {
            $0 !== window && ($0.windowController as? DocumentWindowController)?.fileURL == url
        })
        defer { reopened.close() }
        #expect(reopened.isVisible)
        #expect(!start.isVisible)
    }
}
