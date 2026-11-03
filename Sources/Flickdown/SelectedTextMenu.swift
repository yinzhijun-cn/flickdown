import AppKit

/// Both native text and rendered Markdown open the selection captured when the menu appears.
@MainActor
enum SelectedTextMenu {
    static func addItems(to menu: NSMenu, text: String, window: NSWindow?) {
        guard !text.isEmpty, let document = window?.windowController as? DocumentWindowController else { return }
        let newTab = NSMenuItem(title: L("在新标签页中打开所选文本", "Open Selected Text in New Tab"),
                                action: #selector(DocumentWindowController.openSelectionInNewTab(_:)), keyEquivalent: "")
        let newWindow = NSMenuItem(title: L("在新窗口中打开所选文本", "Open Selected Text in New Window"),
                                   action: #selector(DocumentWindowController.openSelectionInNewWindow(_:)), keyEquivalent: "")
        for item in [newTab, newWindow] {
            item.target = document
            item.representedObject = text
        }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(newWindow, at: 0)
        menu.insertItem(newTab, at: 0)
    }
}

extension DocumentWindowController {
    @objc func openSelectionInNewTab(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.openSelectedText(text, from: self, inNewWindow: false)
    }

    @objc func openSelectionInNewWindow(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.openSelectedText(text, from: self, inNewWindow: true)
    }
}
