import AppKit
import Combine
import Foundation

@MainActor
final class LauncherStore: ObservableObject {
    @Published var tabs: [LauncherTab] = [] {
        didSet { scheduleSave() }
    }

    /// Invoked after a change to the set/order of tabs (add/remove/move), so global
    /// hotkeys can be re-registered to match the new positions.
    var onTabsStructureChanged: (() -> Void)?

    private let saveURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("TabLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saveURL = directory.appendingPathComponent("tabs.json")
        load()
    }

    func add(url: URL, to tabID: LauncherTab.ID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isDirectoryKey, .localizedNameKey])
        let title = values?.localizedName ?? url.deletingPathExtension().lastPathComponent
        let kind: LauncherItem.Kind

        if url.scheme?.lowercased().hasPrefix("http") == true {
            kind = .url
        } else if values?.isApplication == true {
            kind = .application
        } else if values?.isDirectory == true {
            kind = .folder
        } else {
            kind = .file
        }

        let bookmarkData = try? url.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil)
        tabs[tabIndex].items.append(LauncherItem(title: title, kind: kind, url: url, bookmarkData: bookmarkData))
    }

    func remove(itemID: LauncherItem.ID, from tabID: LauncherTab.ID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[tabIndex].items.removeAll { $0.id == itemID }
    }

    // MARK: - Multi-item (group) operations

    func removeItems(_ ids: Set<LauncherItem.ID>, from tabID: LauncherTab.ID) {
        guard !ids.isEmpty, let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[tabIndex].items.removeAll { ids.contains($0.id) }
    }

    /// Moves the given items (kept in their current relative order) as a contiguous block
    /// so they land immediately before `targetItemID`.
    func moveItems(_ ids: Set<LauncherItem.ID>, in tabID: LauncherTab.ID, before targetItemID: LauncherItem.ID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let moving = tabs[tabIndex].items.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        var remaining = tabs[tabIndex].items.filter { !ids.contains($0.id) }
        let insertAt = remaining.firstIndex(where: { $0.id == targetItemID }) ?? remaining.count
        remaining.insert(contentsOf: moving, at: insertAt)
        tabs[tabIndex].items = remaining
    }

    func moveItemsToEnd(_ ids: Set<LauncherItem.ID>, in tabID: LauncherTab.ID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let moving = tabs[tabIndex].items.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        tabs[tabIndex].items.removeAll { ids.contains($0.id) }
        tabs[tabIndex].items.append(contentsOf: moving)
    }

    /// Moves the given items to another tab, appended in their existing order. No-op for
    /// items already there.
    func moveItems(_ ids: Set<LauncherItem.ID>, toTab destTabID: LauncherTab.ID) {
        guard let destIndex = tabs.firstIndex(where: { $0.id == destTabID }) else { return }
        var moved: [LauncherItem] = []
        for tabIndex in tabs.indices where tabs[tabIndex].id != destTabID {
            let picked = tabs[tabIndex].items.filter { ids.contains($0.id) }
            guard !picked.isEmpty else { continue }
            tabs[tabIndex].items.removeAll { ids.contains($0.id) }
            moved.append(contentsOf: picked)
        }
        guard !moved.isEmpty else { return }
        tabs[destIndex].items.append(contentsOf: moved)
    }

    /// Copies the given items into another tab (fresh identities), appended in existing order.
    func duplicateItems(_ ids: Set<LauncherItem.ID>, toTab destTabID: LauncherTab.ID) {
        guard let destIndex = tabs.firstIndex(where: { $0.id == destTabID }) else { return }
        let copies = tabs.flatMap(\.items)
            .filter { ids.contains($0.id) }
            .map { item -> LauncherItem in
                var copy = item
                copy.id = UUID()
                return copy
            }
        guard !copies.isEmpty else { return }
        tabs[destIndex].items.append(contentsOf: copies)
    }

    // MARK: - Tab management

    /// The most tabs allowed — the bare-number shortcuts address 1–10.
    static let maxTabCount = 10

    @discardableResult
    func addTab(title: String = "New Tab", colorHex: String = "#686868") -> LauncherTab? {
        guard tabs.count < Self.maxTabCount else { return nil }
        let tab = LauncherTab(title: title, colorHex: colorHex)
        tabs.append(tab)
        normalizeHotKeyNumbers()
        onTabsStructureChanged?()
        return tab
    }

    func removeTab(_ tabID: LauncherTab.ID) {
        tabs.removeAll { $0.id == tabID }
        normalizeHotKeyNumbers()
        onTabsStructureChanged?()
    }

    func renameTab(_ tabID: LauncherTab.ID, to title: String) {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !trimmed.isEmpty, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].title = trimmed
    }

    func setColor(_ tabID: LauncherTab.ID, hex: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].colorHex = hex
    }

    func moveTabToEnd(_ tabID: LauncherTab.ID) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }), sourceIndex != tabs.count - 1 else { return }
        let tab = tabs.remove(at: sourceIndex)
        tabs.append(tab)
        normalizeHotKeyNumbers()
        onTabsStructureChanged?()
    }

    func moveTab(_ tabID: LauncherTab.ID, before targetTabID: LauncherTab.ID) {
        guard tabID != targetTabID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetTabID }) else { return }

        let tab = tabs.remove(at: sourceIndex)
        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(tab, at: adjustedTargetIndex)
        normalizeHotKeyNumbers()
        onTabsStructureChanged?()
    }

    // MARK: - Tab color styling

    func setAllTabsColor(_ hex: String) {
        for index in tabs.indices { tabs[index].colorHex = hex }
    }

    // MARK: Color harmonies (derived from the current tab's color)

    /// Base hue + its complement (180° apart).
    func setAllTabsToComplementary(of hex: String) { applyHueHarmony([0, 180], base: hex) }

    /// Base hue + the two hues adjacent to its complement (±30°).
    func setAllTabsToSplitComplementary(of hex: String) { applyHueHarmony([0, 150, 210], base: hex) }

    /// Base hue + an analogous neighbour + the complementary pair.
    func setAllTabsToCompound(of hex: String) { applyHueHarmony([0, 30, 180, 210], base: hex) }

    /// Three hues evenly spaced 120° apart.
    func setAllTabsToTriad(of hex: String) { applyHueHarmony([0, 120, 240], base: hex) }

    /// Same hue/saturation as the base, brightness ramped across the tabs from 20% to 70%.
    func setAllTabsToShades(of hex: String) { applyBrightnessRamp(from: hex, start: 0.20, end: 0.70) }

    /// A spectrum sweep interpolated from #77241C to #78257D (deep red → purple).
    func rainbowTabs() {
        let n = tabs.count
        guard n > 0,
              let start = NSColor(hex: "#77241C")?.usingColorSpace(.sRGB),
              let end = NSColor(hex: "#78257D")?.usingColorSpace(.sRGB) else { return }
        var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var h2: CGFloat = 0, s2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        start.getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1)
        end.getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2)
        let hStart = h1 * 360
        var hEnd = h2 * 360
        if hEnd < hStart { hEnd += 360 } // sweep forward through the whole spectrum
        for index in tabs.indices {
            let t = n == 1 ? 0 : CGFloat(index) / CGFloat(n - 1)
            var hue = (hStart + (hEnd - hStart) * t).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            let s = s1 + (s2 - s1) * t
            let b = b1 + (b2 - b1) * t
            tabs[index].colorHex = NSColor(hue: hue / 360, saturation: s, brightness: b, alpha: 1).hexString
        }
    }

    /// Cycles the given hue offsets (degrees, relative to the base hue) across the tabs,
    /// holding the base saturation. Brightness is distributed across the tabs (20%→70%)
    /// rather than anchored to the base — so repeated hues stay distinguishable and a dark
    /// base doesn't push later tabs toward black.
    private func applyHueHarmony(_ offsets: [CGFloat], base hex: String) {
        let n = tabs.count
        guard n > 0, let base = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let count = offsets.count
        for index in tabs.indices {
            let offset = offsets[index % count]
            var hue = (h * 360 + offset).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            let t = n == 1 ? 0 : CGFloat(index) / CGFloat(n - 1)
            let brightness = 0.20 + (0.70 - 0.20) * t
            tabs[index].colorHex = NSColor(hue: hue / 360, saturation: s, brightness: brightness, alpha: 1).hexString
        }
    }

    /// Reverses the color assignments: first↔last, second↔second-last, …
    func flipTabColors() {
        let colors = tabs.map(\.colorHex)
        for index in tabs.indices { tabs[index].colorHex = colors[colors.count - 1 - index] }
    }

    private func applyBrightnessRamp(from hex: String, start: CGFloat, end: CGFloat) {
        let n = tabs.count
        guard n > 0, let base = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        for index in tabs.indices {
            let t = n == 1 ? 0 : CGFloat(index) / CGFloat(n - 1)
            let brightness = start + (end - start) * t
            tabs[index].colorHex = NSColor(hue: h, saturation: s, brightness: brightness, alpha: 1).hexString
        }
    }

    /// Numbers/hotkeys follow tab position: the first nine tabs get 1…9.
    private func normalizeHotKeyNumbers() {
        for index in tabs.indices {
            tabs[index].hotKeyNumber = index < 9 ? index + 1 : nil
        }
    }

    func rename(itemID: LauncherItem.ID, in tabID: LauncherTab.ID, to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let itemIndex = tabs[tabIndex].items.firstIndex(where: { $0.id == itemID }) else { return }

        tabs[tabIndex].items[itemIndex].customName = trimmedTitle
    }

    /// Moves an item to another tab (appended at the end). No-op if already there.
    func moveItem(_ itemID: LauncherItem.ID, toTab destTabID: LauncherTab.ID) {
        guard let sourceIndex = tabs.firstIndex(where: { tab in tab.items.contains(where: { $0.id == itemID }) }),
              tabs[sourceIndex].id != destTabID,
              let itemIndex = tabs[sourceIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = tabs[sourceIndex].items.remove(at: itemIndex)
        guard let destIndex = tabs.firstIndex(where: { $0.id == destTabID }) else { return }
        tabs[destIndex].items.append(item)
    }

    func moveItemToEnd(itemID: LauncherItem.ID, in tabID: LauncherTab.ID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let sourceIndex = tabs[tabIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = tabs[tabIndex].items.remove(at: sourceIndex)
        tabs[tabIndex].items.append(item)
    }

    func move(itemID: LauncherItem.ID, in tabID: LauncherTab.ID, before targetItemID: LauncherItem.ID) {
        guard itemID != targetItemID,
              let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let sourceIndex = tabs[tabIndex].items.firstIndex(where: { $0.id == itemID }),
              let targetIndex = tabs[tabIndex].items.firstIndex(where: { $0.id == targetItemID }) else { return }

        let item = tabs[tabIndex].items.remove(at: sourceIndex)
        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs[tabIndex].items.insert(item, at: adjustedTargetIndex)
    }

    func open(_ item: LauncherItem) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(item.resolvedURL, configuration: configuration)
    }

    func save() {
        saveTask?.cancel()
        do {
            let data = try JSONEncoder.pretty.encode(tabs)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            NSLog("Failed to save tabs: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([LauncherTab].self, from: data) else {
            tabs = Self.sampleTabs()
            save()
            return
        }

        tabs = decoded
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.save()
        }
    }

    private static func sampleTabs() -> [LauncherTab] {
        [LauncherTab(title: "New Tab", colorHex: "#2254A4", hotKeyNumber: 1)]
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
