import AppKit
import Sparkle

/// The menu bar, built in code: no nib to load at launch.
@MainActor
enum MainMenu {
    static func build(updaterController: SPUStandardUpdaterController?) -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Flickdown"
        let bar = NSMenu()

        let app = submenu(of: bar, name)
        app.addItem(item(L("关于 \(name)", "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        if let updaterController {
            let check = item(L("检查更新…", "Check for Updates…"), #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
            check.target = updaterController
            app.addItem(check)
            app.addItem(item(L("自动检查更新", "Automatically Check for Updates"), #selector(AppDelegate.toggleAutomaticUpdateChecks(_:))))
        }
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(parent(L("服务", "Services"), services))
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item(L("隐藏 \(name)", "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item(L("隐藏其他", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item(L("全部显示", "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(L("退出 \(name)", "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(of: bar, L("文件", "File"))
        file.addItem(item(L("开始页", "Start Page"), #selector(AppDelegate.showStartPage(_:))))
        file.addItem(.separator())
        file.addItem(item(L("新建", "New"), #selector(AppDelegate.newDocument(_:)), "n"))
        file.addItem(item(L("打开…", "Open…"), #selector(AppDelegate.showOpenPanel(_:)), "o"))
        file.addItem(item(L("在新标签页中打开…", "Open in New Tab…"), #selector(AppDelegate.showOpenPanel(_:)), "t"))
        file.addItem(item(L("在新窗口中打开…", "Open in New Window…"), #selector(AppDelegate.showOpenPanelInNewWindow(_:)), "o", [.command, .shift]))
        let recent = NSMenu()
        recent.addItem(item(L("清除菜单", "Clear Menu"), #selector(NSDocumentController.clearRecentDocuments(_:))))
        file.addItem(parent(L("打开最近使用", "Open Recent"), recent))
        file.addItem(.separator())
        file.addItem(item(L("关闭", "Close"), #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item(L("存储", "Save"), #selector(DocumentWindowController.saveDocument(_:)), "s"))
        file.addItem(item(L("存储为…", "Save As…"), #selector(DocumentWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        file.addItem(item(L("重新载入", "Reload"), #selector(DocumentWindowController.reloadDocument(_:)), "r"))
        file.addItem(item(L("在访达中显示", "Show in Finder"), #selector(DocumentWindowController.revealInFinder(_:)), "r", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item(L("打印…", "Print…"), #selector(DocumentWindowController.printDocument(_:)), "p"))

        let edit = submenu(of: bar, L("编辑", "Edit"))
        edit.addItem(item(L("撤销", "Undo"), Selector(("undo:")), "z"))
        edit.addItem(item(L("重做", "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(L("剪切", "Cut"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(L("拷贝", "Copy"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(L("粘贴", "Paste"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(L("全选", "Select All"), #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = NSMenu()
        find.addItem(finder(L("查找…", "Find…"), .showFindInterface, "f"))
        find.addItem(finder(L("查找下一个", "Find Next"), .nextMatch, "g"))
        find.addItem(finder(L("查找上一个", "Find Previous"), .previousMatch, "g", [.command, .shift]))
        find.addItem(finder(L("使用所选内容查找", "Use Selection for Find"), .setSearchString, "e"))
        edit.addItem(parent(L("查找", "Find"), find))

        let format = submenu(of: bar, L("格式", "Format"))
        format.addItem(item(L("粗体", "Bold"), #selector(DocumentWindowController.toggleBold(_:)), "b"))
        format.addItem(item(L("斜体", "Italic"), #selector(DocumentWindowController.toggleItalic(_:)), "i"))
        format.addItem(item(L("链接", "Link"), #selector(DocumentWindowController.insertLink(_:)), "k"))

        let view = submenu(of: bar, L("显示", "View"))
        for (mode, title, key) in [(ViewMode.preview, L("预览", "Preview"), "1"), (.source, L("源码", "Source"), "2"),
                                   (.edit, L("编辑", "Edit"), "3")] {
            let modeItem = item(title, #selector(DocumentWindowController.setViewMode(_:)), key)
            modeItem.tag = mode.rawValue
            view.addItem(modeItem)
        }
        view.addItem(item(L("切换预览 / 源码", "Toggle Preview / Source"), #selector(DocumentWindowController.toggleSource(_:)), "/"))
        view.addItem(item(L("编辑时显示预览", "Show Preview While Editing"), #selector(DocumentWindowController.togglePreviewPane(_:)), "p", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item(L("大纲", "Outline"), #selector(DocumentWindowController.toggleOutline(_:)), "s", [.command, .control]))
        let width = NSMenu()
        for (pageWidth, title, key) in [(PageWidth.standard, L("标准", "Standard"), "1"), (.wide, L("宽", "Wide"), "2"),
                                        (.full, L("全宽", "Full Width"), "3")] {
            let widthItem = item(title, #selector(DocumentWindowController.setPageWidth(_:)), key, [.command, .option])
            widthItem.representedObject = pageWidth.rawValue
            width.addItem(widthItem)
        }
        view.addItem(parent(L("页宽", "Page Width"), width))
        view.addItem(.separator())
        view.addItem(item(L("放大", "Zoom In"), #selector(DocumentWindowController.zoomIn(_:)), "="))
        view.addItem(item(L("缩小", "Zoom Out"), #selector(DocumentWindowController.zoomOut(_:)), "-"))
        view.addItem(item(L("实际大小", "Actual Size"), #selector(DocumentWindowController.actualSize(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item(L("进入全屏幕", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let window = submenu(of: bar, L("窗口", "Window"))
        window.addItem(item(L("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(L("缩放", "Zoom"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(L("显示上一个标签页", "Show Previous Tab"), #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]))
        window.addItem(item(L("显示下一个标签页", "Show Next Tab"), #selector(NSWindow.selectNextTab(_:)), "\t", [.control]))
        window.addItem(item(L("将标签页移到新窗口", "Move Tab to New Window"), #selector(NSWindow.moveTabToNewWindow(_:))))
        window.addItem(item(L("合并所有窗口", "Merge All Windows"), #selector(AppDelegate.mergeAllDocumentWindows(_:))))
        window.addItem(item(L("显示所有标签页", "Show All Tabs"), #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
        window.addItem(.separator())
        window.addItem(item(L("前置全部窗口", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        return bar
    }

    private static func submenu(of bar: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        bar.addItem(parent(title, menu))
        return menu
    }

    private static func parent(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = item(title, nil)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// WKWebView implements the standard NSTextFinder find bar.
    private static func finder(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                               _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
        item.tag = action.rawValue
        return item
    }
}
