import Cocoa
import FinderSync

/// Finder Sync extension: adds an "Add to Pad Launcher ▸ <tab>" contextual menu for the
/// current Finder selection. It reads the tab list the app publishes to the App Group and
/// drops an add-request the app consumes.
class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Monitor the whole filesystem so the contextual menu is offered for any selection.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind == .contextualMenuForItems else { return menu }

        let parent = NSMenuItem(title: "Add to Pad Launcher", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "")
        let tabs = PadLauncherShared.requestTabs()
        if tabs.isEmpty {
            // Empty means the app isn't running (or has no tabs) — nothing to add into.
            let empty = NSMenuItem(title: "Open Pad Launcher to choose a tab", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for (index, tab) in tabs.enumerated() {
                let item = NSMenuItem(title: tab.name, action: #selector(addToTab(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                submenu.addItem(item)
            }
        }
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    @objc private func addToTab(_ sender: NSMenuItem) {
        let tabs = PadLauncherShared.requestTabs()
        guard tabs.indices.contains(sender.tag) else { return }
        let paths = (FIFinderSyncController.default().selectedItemURLs() ?? []).map(\.path)
        guard !paths.isEmpty else { return }

        PadLauncherShared.sendAdd(.init(tabID: tabs[sender.tag].id, paths: paths))
    }
}
