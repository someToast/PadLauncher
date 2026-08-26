import SwiftUI
import UniformTypeIdentifiers

struct LauncherPanelView: View {
    @ObservedObject var store: LauncherStore
    let tab: LauncherTab
    @ObservedObject var selection: LauncherSelection
    var foreground: Color = .white
    /// Called after an item is opened so the launcher can dismiss itself.
    var onLaunch: () -> Void = {}
    /// Resizes the window to fit the tabs/icons.
    var onSizeToFit: (Int) -> Void = { _ in }
    @State private var dropTarget: DropTarget?
    @State private var gridWidth: CGFloat = 0
    @State private var scrollTop: CGFloat = 0
    /// The in-progress marquee rectangle, in grid content coordinates.
    @State private var marqueeRect: CGRect?
    /// The selection as it stood when a ⌘-marquee began, so swept icons toggle against it.
    @State private var marqueeBaseline: Set<LauncherItem.ID>?
    /// The selection captured at the start of a Shift-click run. Each Shift-click unions the
    /// anchor→target range onto this base, so re-extending resizes only the range and never
    /// drops items that were selected some other way (⌘-click, marquee). Nil = not in a run.
    @State private var shiftBase: Set<LauncherItem.ID>?

    private var currentTab: LauncherTab {
        store.tabs.first(where: { $0.id == tab.id }) ?? tab
    }

    /// Hide items whose target no longer exists on disk.
    private var visibleItems: [LauncherItem] {
        currentTab.items.filter { $0.exists }
    }

    private var metrics: GridMetrics {
        GridMetrics(width: gridWidth, count: visibleItems.count)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topLeading) { dropIndicator }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Add…") { multiAdd() }
                Button("Size Window to Fit") {
                    onSizeToFit(store.tabs.map { $0.items.filter(\.exists).count }.max() ?? 0)
                }
                Menu("Styling") {
                    Button("Set All Tabs to Current Color") { withAnimation(LauncherTheme.motion) { store.setAllTabsColor(currentTab.colorHex) } }
                    Divider()
                    Button("Complementary") { withAnimation(LauncherTheme.motion) { store.setAllTabsToComplementary(of: currentTab.colorHex) } }
                    Button("Split Complementary") { withAnimation(LauncherTheme.motion) { store.setAllTabsToSplitComplementary(of: currentTab.colorHex) } }
                    Button("Compound") { withAnimation(LauncherTheme.motion) { store.setAllTabsToCompound(of: currentTab.colorHex) } }
                    Button("Shades") { withAnimation(LauncherTheme.motion) { store.setAllTabsToShades(of: currentTab.colorHex) } }
                    Button("Triad") { withAnimation(LauncherTheme.motion) { store.setAllTabsToTriad(of: currentTab.colorHex) } }
                    Button("Rainbow") { withAnimation(LauncherTheme.motion) { store.rainbowTabs() } }
                    Divider()
                    Button("Flip tab colors") { withAnimation(LauncherTheme.motion) { store.flipTabColors() } }
                }
            }
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(ScrollTopKey.self) { scrollTop = $0 }
            .onDrop(of: [.fileURL, .url, .plainText], delegate: ContainerDropDelegate(
                tabID: currentTab.id,
                store: store,
                draggedItemID: $selection.draggingItemID,
                groupIDs: selection.draggingItemIDs,
                dropTarget: $dropTarget,
                orderedIDs: visibleItems.map(\.id),
                metrics: metrics,
                scrollTop: scrollTop
            ))
    }

    @ViewBuilder private var content: some View {
        if visibleItems.isEmpty {
            emptyState
        } else {
            GeometryReader { geo in
                let m = GridMetrics(width: geo.size.width, count: visibleItems.count)
                // Fill at least the viewport so marquee/deselect also work below the last row.
                let canvasHeight = max(m.contentHeight(count: visibleItems.count), geo.size.height)
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // Reports the content's current scroll position for drop math.
                        Color.clear
                            .frame(height: 0)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: ScrollTopKey.self, value: proxy.frame(in: .named(Self.gridSpace)).minY)
                            })

                        // Full-content interaction layer beneath the icons: a drag over empty
                        // space rubber-band-selects; a plain click clears the selection.
                        Color.clear
                            .frame(width: geo.size.width, height: canvasHeight)
                            .contentShape(Rectangle())
                            .gesture(marqueeGesture(m))
                            // A plain click on empty space clears the selection; a ⌘-click
                            // leaves it be (⌘ is reserved for adding to the selection).
                            .onTapGesture {
                                if !NSEvent.modifierFlags.contains(.command) {
                                    clearSelection()
                                }
                            }

                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            itemCell(item)
                                .frame(width: m.cellWidth, height: m.cellHeight)
                                .offset(x: m.x(index), y: m.y(index))
                                .transition(.scale.combined(with: .opacity))
                        }

                        if let rect = marqueeRect {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .overlay(Rectangle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: geo.size.width, height: canvasHeight, alignment: .topLeading)
                    // Column count changes on resize animate the reflow; id-order changes
                    // animate reordering, insertion, and removal.
                    .animation(LauncherTheme.motion, value: m.columns)
                    .animation(LauncherTheme.motion, value: visibleItems.map(\.id))
                }
                // Fresh identity per tab, so switching tabs swaps instantly (no scale-in);
                // within-tab changes still animate.
                .id(currentTab.id)
                .onAppear { gridWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newWidth in gridWidth = newWidth }
            }
        }
    }

    @ViewBuilder private func itemCell(_ item: LauncherItem) -> some View {
        LauncherItemView(item: item, foreground: foreground, selected: selection.selectedItemIDs.contains(item.id))
            .opacity(selection.draggingItemIDs.contains(item.id) ? 0.45 : 1)
            .overlay(
                ItemInteractionView(
                    item: item,
                    groupCount: selection.selectedItemIDs.contains(item.id) ? selection.selectedItemIDs.count : 1,
                    onOpen: { handleClick(item) },
                    onRename: { rename(item) },
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting([item.resolvedURL]) },
                    onRemove: { store.remove(itemID: item.id, from: currentTab.id) },
                    onDragStart: { beginDrag(of: item) },
                    onDragEnd: { outside in endDrag(outside: outside) }
                )
            )
    }

    private func handleClick(_ item: LauncherItem) {
        let modifiers = NSEvent.modifierFlags
        // ⌘-click toggles an icon in/out of the selection — the macOS convention for
        // discontiguous selection — and starts a selection if none exists. Never launches.
        if modifiers.contains(.command) {
            if selection.selectedItemIDs.contains(item.id) {
                selection.selectedItemIDs.remove(item.id)
            } else {
                selection.selectedItemIDs.insert(item.id)
            }
            selection.selectionAnchorID = item.id
            shiftBase = nil // a ⌘-click ends the current Shift run
            return
        }
        // Shift-click adds the contiguous range (anchor→this icon, in flow order) to the
        // selection that existed when the run began. The anchor and that base both stay put,
        // so repeated Shift-clicks re-extend without dropping items selected other ways.
        if modifiers.contains(.shift) {
            let anchor = selection.selectionAnchorID ?? item.id
            if shiftBase == nil { shiftBase = selection.selectedItemIDs }
            let range = rangeIDs(from: anchor, to: item.id) ?? [item.id]
            selection.selectedItemIDs = (shiftBase ?? []).union(range)
            if selection.selectionAnchorID == nil { selection.selectionAnchorID = item.id }
            return
        }
        // A plain click ends any Shift run. With a selection active it dismisses it (a click
        // on a member keeps it, so the group stays grabbable); with none, it opens the item.
        shiftBase = nil
        if !selection.selectedItemIDs.isEmpty {
            if !selection.selectedItemIDs.contains(item.id) {
                clearSelection()
            }
            return
        }
        launch(item)
    }

    /// The item IDs from `a` to `b` inclusive, in visible flow order (nil if either is gone).
    private func rangeIDs(from a: LauncherItem.ID, to b: LauncherItem.ID) -> [LauncherItem.ID]? {
        guard let i = visibleItems.firstIndex(where: { $0.id == a }),
              let j = visibleItems.firstIndex(where: { $0.id == b }) else { return nil }
        return visibleItems[min(i, j)...max(i, j)].map(\.id)
    }

    private func clearSelection() {
        selection.selectedItemIDs = []
        selection.selectionAnchorID = nil
        shiftBase = nil
    }

    /// Starts a drag of either the whole selection (when the grabbed icon belongs to it)
    /// or just the grabbed icon (which also clears any prior selection).
    private func beginDrag(of item: LauncherItem) {
        let group: Set<LauncherItem.ID>
        if selection.selectedItemIDs.contains(item.id) {
            group = selection.selectedItemIDs
        } else {
            selection.selectedItemIDs = []
            shiftBase = nil
            group = [item.id]
        }
        selection.draggingItemID = item.id
        selection.draggingItemIDs = group
    }

    /// Ends a drag: an off-window release deletes the whole group; otherwise the drop was
    /// handled by the grid (reorder) or a tab chip (move/duplicate). Clears drag state.
    private func endDrag(outside: Bool) {
        if outside {
            withAnimation(LauncherTheme.motion) {
                store.removeItems(selection.draggingItemIDs, from: currentTab.id)
            }
        }
        selection.draggingItemID = nil
        selection.draggingItemIDs = []
        selection.selectedItemIDs = []
        selection.selectionAnchorID = nil
        shiftBase = nil
        dropTarget = nil
    }

    private func marqueeGesture(_ m: GridMetrics) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // Snapshot the starting selection once, so a Shift-drag toggles against it.
                if marqueeBaseline == nil { marqueeBaseline = selection.selectedItemIDs }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marqueeRect = rect
                var hit = Set<LauncherItem.ID>()
                for (index, item) in visibleItems.enumerated() where rect.intersects(iconFrame(index, m)) {
                    hit.insert(item.id)
                }
                if NSEvent.modifierFlags.contains(.command) {
                    // ⌘-marquee adds swept icons; those already selected that the box passes
                    // over drop out (discontiguous toggle against the starting selection).
                    selection.selectedItemIDs = (marqueeBaseline ?? []).symmetricDifference(hit)
                } else {
                    selection.selectedItemIDs = hit
                }
            }
            .onEnded { _ in
                marqueeRect = nil
                marqueeBaseline = nil
                shiftBase = nil // a marquee ends any Shift run and reseeds the base
                // Anchor the first selected icon so a following Shift-click extends from there.
                selection.selectionAnchorID = visibleItems.first { selection.selectedItemIDs.contains($0.id) }?.id
            }
    }

    /// The icon glyph's frame within the grid content (the selection border hugs this too).
    private func iconFrame(_ index: Int, _ m: GridMetrics) -> CGRect {
        CGRect(
            x: m.x(index) + (m.cellWidth - LauncherTheme.iconSize) / 2,
            y: m.y(index),
            width: LauncherTheme.iconSize,
            height: LauncherTheme.iconSize
        )
    }

    private static let gridSpace = "launcherGrid"

    /// A white bar shown between icons at the position a dragged item would drop, anchored
    /// to a specific item's leading/trailing edge (so a row's end reads distinctly from
    /// the next row's start).
    @ViewBuilder private var dropIndicator: some View {
        if let target = dropTarget, let rect = indicatorRect(target) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.white)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private func indicatorRect(_ target: DropTarget) -> CGRect? {
        guard let index = visibleItems.firstIndex(where: { $0.id == target.anchorID }) else { return nil }
        let m = metrics
        let half = m.spacing / 2
        let leadingX = m.x(index)
        let x = (target.after ? leadingX + m.cellWidth + half : leadingX - half) - 1.5
        return CGRect(x: x, y: scrollTop + m.y(index), width: 3, height: m.cellHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            Text("Drop apps, files, folders, or URLs here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LauncherTheme.contentSidePadding)
    }

    private func launch(_ item: LauncherItem) {
        store.open(item)
        onLaunch()
    }

    /// Right-click "Multi-add…": pick multiple apps/files/folders at once to add.
    private func multiAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Select apps, files, or folders to add to “\(currentTab.title)”."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            store.add(url: url, to: currentTab.id)
        }
    }

    private func rename(_ item: LauncherItem) {
        let alert = NSAlert()
        alert.messageText = "Rename Item"
        alert.informativeText = "Enter a display name for this launcher item."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = item.displayName
        textField.selectText(nil)
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        store.rename(itemID: item.id, in: currentTab.id, to: textField.stringValue)
    }
}

/// Deterministic wrapping-grid geometry, shared by layout, the drop indicator, and hit
/// testing so they always agree.
struct GridMetrics {
    let columns: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let spacing: CGFloat
    let sidePadding: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(width: CGFloat, count: Int) {
        let side = LauncherTheme.contentSidePadding
        let sp = LauncherTheme.gridSpacing
        let target = LauncherTheme.cellMinWidth
        let available = max(0, width - side * 2)
        let cols = max(1, Int((available + sp) / (target + sp)))
        columns = cols
        cellWidth = max(1, (available - CGFloat(cols - 1) * sp) / CGFloat(cols))
        cellHeight = LauncherTheme.iconSize + LauncherTheme.iconLabelSpacing + LauncherTheme.captionHeight
        spacing = sp
        sidePadding = side
        // The header/content gap now lives here so the first row scrolls up to the header
        // edge before clipping.
        topInset = LauncherTheme.contentVerticalPadding + LauncherTheme.sectionSpacing
        bottomInset = LauncherTheme.contentVerticalPadding
    }

    func x(_ index: Int) -> CGFloat { sidePadding + CGFloat(index % columns) * (cellWidth + spacing) }
    func y(_ index: Int) -> CGFloat { topInset + CGFloat(index / columns) * (cellHeight + spacing) }

    func contentHeight(count: Int) -> CGFloat {
        let rows = count == 0 ? 0 : (count + columns - 1) / columns
        return topInset + CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * spacing + bottomInset
    }
}

/// Where a reordering drop would land: the anchor item and which of its edges.
struct DropTarget: Equatable {
    let anchorID: LauncherItem.ID
    let after: Bool
}

private struct ScrollTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Handles all drops on the grid: an in-progress reorder inserts the dragged item at the
/// slot nearest the drop point (any position, including a row's end); otherwise an
/// external file/URL is added to the tab.
private struct ContainerDropDelegate: DropDelegate {
    let tabID: LauncherTab.ID
    let store: LauncherStore
    @Binding var draggedItemID: LauncherItem.ID?
    /// The full set moving in this drag (matches `draggedItemID` alone for a single item).
    let groupIDs: Set<LauncherItem.ID>
    @Binding var dropTarget: DropTarget?
    let orderedIDs: [LauncherItem.ID]
    let metrics: GridMetrics
    let scrollTop: CGFloat

    /// Accept an internal item reorder, or external files/URLs to add. A tab dragged into the
    /// grid carries only plain text (no file/URL) and isn't a reorder, so it's rejected — no
    /// copy cursor, and dropping is a no-op.
    func validateDrop(info: DropInfo) -> Bool {
        isReordering || info.hasItemsConforming(to: [.fileURL, .url])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isReordering {
            dropTarget = nearestTarget(at: info.location)
            return DropProposal(operation: .move)
        }
        if info.hasItemsConforming(to: [.fileURL, .url]) {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        dropTarget = nil
    }

    private var isReordering: Bool {
        guard let draggedItemID else { return false }
        return orderedIDs.contains(draggedItemID)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        if let dragged = draggedItemID, orderedIDs.contains(dragged) {
            let group = groupIDs.isEmpty ? [dragged] : groupIDs
            reorder(group: group, to: info.location)
            draggedItemID = nil
            return true
        }
        draggedItemID = nil

        for provider in info.itemProviders(for: [UTType.fileURL, UTType.url]) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in store.add(url: url, to: tabID) }
                    } else if let url = item as? URL {
                        Task { @MainActor in store.add(url: url, to: tabID) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        Task { @MainActor in store.add(url: url, to: tabID) }
                    } else if let data = item as? Data, let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                        Task { @MainActor in store.add(url: url, to: tabID) }
                    }
                }
            }
        }
        return true
    }

    /// The item whose cell center is nearest the drop point, and which edge the point is on.
    private func nearestTarget(at location: CGPoint) -> DropTarget? {
        let px = location.x
        let py = location.y - scrollTop
        var nearest: (index: Int, distance: CGFloat, after: Bool)?
        for index in orderedIDs.indices {
            let centerX = metrics.x(index) + metrics.cellWidth / 2
            let centerY = metrics.y(index) + metrics.cellHeight / 2
            let distance = hypot(px - centerX, py - centerY)
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance, px > centerX)
            }
        }
        guard let n = nearest else { return nil }
        return DropTarget(anchorID: orderedIDs[n.index], after: n.after)
    }

    private func reorder(group: Set<LauncherItem.ID>, to location: CGPoint) {
        guard let target = nearestTarget(at: location),
              let anchorIndex = orderedIDs.firstIndex(of: target.anchorID) else {
            store.moveItemsToEnd(group, in: tabID)
            return
        }
        // Land the block before the first non-group item at/after the drop slot.
        var insertion = target.after ? anchorIndex + 1 : anchorIndex
        while insertion < orderedIDs.count && group.contains(orderedIDs[insertion]) { insertion += 1 }
        if insertion >= orderedIDs.count {
            store.moveItemsToEnd(group, in: tabID)
        } else {
            store.moveItems(group, in: tabID, before: orderedIDs[insertion])
        }
    }
}
