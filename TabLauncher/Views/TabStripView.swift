import AppKit
import SwiftUI

struct TabStripView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject var selection: LauncherSelection
    var selectedColor: Color
    var foreground: Color
    @State private var draggedTabID: LauncherTab.ID?

    var body: some View {
        GeometryReader { geo in
            let widths = labelWidths(totalWidth: geo.size.width)
            barRow(labelWidths: widths)
                .padding(LauncherTheme.barPadding)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .background(LauncherTheme.barBackground)
                // Animate the selected tab's expansion and the others' reflow on a switch.
                // Scoped to the bar, so the tab's contents still swap instantly.
                .animation(LauncherTheme.motion, value: selection.tabID)
        }
        .frame(height: LauncherTheme.barPadding * 2 + LauncherTheme.chipHeight)
    }

    private func barRow(labelWidths: [LauncherTab.ID: CGFloat]) -> some View {
        HStack(spacing: LauncherTheme.barSpacing) {
            ForEach(store.tabs) { tab in
                TabChipView(
                    store: store,
                    selection: selection,
                    tab: tab,
                    number: (store.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1,
                    selectedColor: selectedColor,
                    foreground: foreground,
                    labelWidth: labelWidths[tab.id],
                    draggedTabID: $draggedTabID
                )
            }

            if selection.isEditing && store.tabs.count < LauncherStore.maxTabCount {
                Button {
                    guard let new = store.addTab() else { return }
                    withAnimation(LauncherTheme.motion) {
                        selection.tabID = new.id
                    }
                    // Drop straight into renaming the new tab, with its name preselected.
                    selection.editingTitleTabID = new.id
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: LauncherTheme.gearSize * 0.7, weight: .semibold))
                        .foregroundStyle(foreground.opacity(0.8))
                        .frame(height: LauncherTheme.chipHeight)
                }
                .buttonStyle(.plain)
                .help("Add tab")
                .onDrop(of: [.plainText], delegate: TabEndDropDelegate(store: store, draggedTabID: $draggedTabID))
            }

            // The empty area after the tabs is a drop zone that moves a dragged tab to the
            // end (there's no chip there to drop "before"). Fixed height so the greedy
            // Color doesn't inflate the bar vertically.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: LauncherTheme.chipHeight)
                .contentShape(Rectangle())
                .onDrop(of: [.plainText], delegate: TabEndDropDelegate(store: store, draggedTabID: $draggedTabID))

            Button {
                if selection.isEditing {
                    selection.editingTitleTabID = nil
                    // Leaving edit mode: close the floating color palette if it's open.
                    if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
                        NSColorPanel.shared.orderOut(nil)
                    }
                }
                selection.isEditing.toggle()
            } label: {
                Image(systemName: selection.isEditing ? "checkmark.circle.fill" : "gearshape")
                    .font(.system(size: LauncherTheme.gearSize, weight: .regular))
                    .foregroundStyle(foreground.opacity(selection.isEditing ? 0.9 : 0.15))
                    .frame(height: LauncherTheme.chipHeight)
            }
            .buttonStyle(.plain)
            .help(selection.isEditing ? "Done" : "Edit tabs")
        }
    }

    private func measure(_ string: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: LauncherTheme.labelSize, weight: .semibold)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    private func symbolWidth(_ name: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)?.size.width ?? size
    }

    /// An explicit label width for every tab, so each chip's label is the same view branch
    /// (a fixed-width frame) whose width can animate as the selection changes. The selected
    /// tab always gets its full width; the rest shrink longest-first when the bar is tight,
    /// none below their first-character-plus-ellipsis width.
    private func labelWidths(totalWidth: CGFloat) -> [LauncherTab.ID: CGFloat] {
        guard totalWidth > 0, !store.tabs.isEmpty else { return [:] }
        let chrome = LauncherTheme.chipPaddingLeading + LauncherTheme.chipSpacing
            + LauncherTheme.trailingSlotWidth + LauncherTheme.chipPaddingTrailing
        var extras = symbolWidth("gearshape", size: LauncherTheme.gearSize, weight: .regular)
        if selection.isEditing { extras += symbolWidth("plus", size: LauncherTheme.gearSize * 0.7, weight: .semibold) }
        let gapCount = store.tabs.count + (selection.isEditing ? 1 : 0) + 1
        let labelBudget = totalWidth - LauncherTheme.barPadding * 2 - extras
            - CGFloat(gapCount) * LauncherTheme.barSpacing - CGFloat(store.tabs.count) * chrome

        let selectedID = selection.tabID ?? store.tabs.first?.id
        let selectedFull = store.tabs.first(where: { $0.id == selectedID }).map { measure($0.title) } ?? 0
        let others = store.tabs.filter { $0.id != selectedID }
        let fulls = others.map { measure($0.title) }
        let mins = others.map { measure(String($0.title.prefix(1)) + "…") }

        var result: [LauncherTab.ID: CGFloat] = [:]
        if let selectedID { result[selectedID] = selectedFull }

        let othersBudget = labelBudget - selectedFull
        if othersBudget >= fulls.reduce(0, +) {
            for (index, tab) in others.enumerated() { result[tab.id] = fulls[index] } // all fit full
            return result
        }

        // Water-fill: cap label widths at L (tallest shrinks first), never below each min.
        func total(_ cap: CGFloat) -> CGFloat { zip(fulls, mins).reduce(0) { $0 + max($1.1, min($1.0, cap)) } }
        var lo: CGFloat = 0
        var hi = fulls.max() ?? 0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if total(mid) > othersBudget { hi = mid } else { lo = mid }
        }
        for (index, tab) in others.enumerated() {
            result[tab.id] = max(mins[index], min(fulls[index], lo))
        }
        return result
    }
}

private struct TabChipView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject var selection: LauncherSelection
    let tab: LauncherTab
    let number: Int
    let selectedColor: Color
    let foreground: Color
    /// Explicit label width when the bar is compressing this (non-selected) tab; nil = full.
    var labelWidth: CGFloat?
    @Binding var draggedTabID: LauncherTab.ID?

    @State private var editingText = ""
    @State private var isItemDropTarget = false

    private var isSelected: Bool { tab.id == selection.tabID }
    private var isEditingTitle: Bool { selection.editingTitleTabID == tab.id }

    var body: some View {
        chip
            .background(
                RoundedRectangle(cornerRadius: LauncherTheme.chipCorner, style: .continuous)
                    .fill(isSelected ? selectedColor : Color.clear)
            )
            .overlay {
                if isEditingTitle || isItemDropTarget {
                    RoundedRectangle(cornerRadius: LauncherTheme.chipCorner, style: .continuous)
                        .stroke(foreground, lineWidth: 2)
                }
            }
            .opacity(draggedTabID == tab.id ? 0.4 : 1)
            .modifier(TabInteractionModifier(
                store: store, selection: selection, tab: tab,
                draggedTabID: $draggedTabID, isItemDropTarget: $isItemDropTarget,
                isEditingTitle: isEditingTitle,
                beginTitleEditing: beginTitleEditing
            ))
            .transition(.scale.combined(with: .opacity))
            // Seed the editable text whenever editing begins (double-click or the ＋ button).
            .onChange(of: isEditingTitle) { _, editing in
                if editing { editingText = tab.title }
            }
    }

    private var labelFont: Font { .system(size: LauncherTheme.labelSize, weight: .semibold) }

    private var chip: some View {
        HStack(alignment: .center, spacing: LauncherTheme.chipSpacing) {
            leadingWithInteraction
            trailing
                .frame(width: LauncherTheme.trailingSlotWidth) // constant slot → no shift
        }
        .frame(height: LauncherTheme.chipHeight)
        .padding(.leading, LauncherTheme.chipPaddingLeading)
        .padding(.trailing, LauncherTheme.chipPaddingTrailing)
    }

    // In editing mode the label carries an AppKit drag source: click selects, double-click
    // edits the title, dragging reorders, and dragging off the window deletes the tab.
    @ViewBuilder private var leadingWithInteraction: some View {
        if selection.isEditing && !isEditingTitle {
            leading.overlay(
                TabInteractionView(
                    tab: tab,
                    foreground: foreground,
                    onClick: { selection.tabID = tab.id },
                    onDoubleClick: beginTitleEditing,
                    onRemove: { withAnimation(LauncherTheme.motion) { store.removeTab(tab.id) } },
                    onDragStart: { draggedTabID = tab.id },
                    onDragEnd: { outside in
                        draggedTabID = nil
                        // Dragged off the window → delete the tab (matches icon behavior).
                        if outside { withAnimation(LauncherTheme.motion) { store.removeTab(tab.id) } }
                    }
                )
            )
        } else {
            leading
        }
    }

    // Selected (and editing) tabs show full, non-truncated text; other tabs may truncate
    // when the bar is tight. A width-driving hidden Text keeps the editable field from
    // shifting neighbors.
    @ViewBuilder private var leading: some View {
        if isEditingTitle {
            Text(editingText.isEmpty ? " " : editingText)
                .font(labelFont)
                .foregroundStyle(.clear)
                .lineLimit(1)
                .fixedSize()
                .overlay {
                    // AppKit-backed so it reliably focuses and preselects its text on appear.
                    TabTitleField(
                        text: $editingText,
                        font: NSFont.systemFont(ofSize: LauncherTheme.labelSize, weight: .semibold),
                        textColor: NSColor(foreground),
                        maxLength: LauncherTheme.maxTabNameLength,
                        onCommit: commitTitleEditing
                    )
                }
        } else if let width = labelWidth {
            // Every chip uses a fixed-width frame (selected = full width) so the width can
            // animate smoothly as the selection changes, revealing/truncating the label.
            Text(tab.title)
                .font(labelFont)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
        } else {
            Text(tab.title)
                .font(labelFont)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder private var trailing: some View {
        if isEditingTitle {
            Button {
                editingText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: LauncherTheme.labelSize * 0.6))
                    .foregroundStyle(foreground.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Clear")
        } else if selection.isEditing {
            RoundedRectangle(cornerRadius: LauncherTheme.chitCorner, style: .continuous)
                .fill(Color(nsColor: tab.color))
                .frame(width: LauncherTheme.chitWidth, height: LauncherTheme.chitHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: LauncherTheme.chitCorner, style: .continuous)
                        .stroke(foreground, lineWidth: 2)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // Clicking a chit also activates that tab.
                    selection.tabID = tab.id
                    TabColorPanel.shared.present(initialHex: tab.colorHex) { hex in
                        store.setColor(tab.id, hex: hex)
                    }
                }
                .help("Change color")
        } else {
            // The bare-number shortcut: tabs 1–9 show their digit, the 10th shows "0",
            // and 11–19 show their two-digit number.
            Text(number == 10 ? "0" : "\(number)")
                .font(.system(size: LauncherTheme.numberSize, weight: .medium))
                .foregroundStyle(foreground.opacity(0.6))
        }
    }

    private func beginTitleEditing() {
        // The field's onAppear seeds the text, focuses, and preselects it.
        selection.editingTitleTabID = tab.id
    }

    private func commitTitleEditing() {
        guard selection.editingTitleTabID == tab.id else { return } // avoid double-commit
        store.renameTab(tab.id, to: editingText)
        selection.editingTitleTabID = nil
    }
}

/// An AppKit-backed single-line field for editing a tab title. Unlike SwiftUI's TextField it
/// reliably takes focus and selects its whole contents when it appears, so a freshly created
/// tab can be renamed by just typing.
private struct TabTitleField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var maxLength: Int
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusSelectingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.font = font
        field.textColor = textColor
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = font
        field.textColor = textColor
        if field.stringValue != text { field.stringValue = text }
        if !context.coordinator.hasFocused {
            context.coordinator.hasFocused = true
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TabTitleField
        var hasFocused = false
        init(_ parent: TabTitleField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if field.stringValue.count > parent.maxLength {
                field.stringValue = String(field.stringValue.prefix(parent.maxLength))
            }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCommit()
        }
    }
}

/// NSTextField that selects all of its text the moment it becomes first responder.
private final class FocusSelectingTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return didBecome
    }
}

/// Single-click selects; in editing mode a double-click on the title begins inline
/// editing, and chips can be dragged to reorder.
private struct TabInteractionModifier: ViewModifier {
    let store: LauncherStore
    let selection: LauncherSelection
    let tab: LauncherTab
    @Binding var draggedTabID: LauncherTab.ID?
    @Binding var isItemDropTarget: Bool
    let isEditingTitle: Bool
    let beginTitleEditing: () -> Void

    func body(content: Content) -> some View {
        if isEditingTitle {
            content // no gestures while the text field is active
        } else if selection.isEditing {
            // Click/drag are handled by the AppKit source on the label; the whole chip is a
            // drop target for a dragged icon (move to this tab) or a dragged tab (reorder).
            content
                .contentShape(Rectangle())
                .onDrop(of: [.plainText], delegate: chipDelegate)
        } else {
            // The whole chip (not just the label text) is the click/drop target.
            content
                .contentShape(Rectangle())
                .onDrop(of: [.plainText], delegate: chipDelegate)
                .onTapGesture { selection.tabID = tab.id }
        }
    }

    private var chipDelegate: ChipDropDelegate {
        ChipDropDelegate(
            tab: tab, store: store, selection: selection,
            draggedTabID: $draggedTabID, isItemTarget: $isItemDropTarget
        )
    }
}

/// A tab chip as a drop target: a dragged icon moves to this tab; a dragged tab (in
/// editing mode) reorders before it.
private struct ChipDropDelegate: DropDelegate {
    let tab: LauncherTab
    let store: LauncherStore
    let selection: LauncherSelection
    @Binding var draggedTabID: LauncherTab.ID?
    @Binding var isItemTarget: Bool

    func dropEntered(info: DropInfo) {
        if selection.draggingItemID != nil {
            isItemTarget = true
        } else if let draggedTabID, draggedTabID != tab.id, selection.isEditing {
            withAnimation(LauncherTheme.motion) { store.moveTab(draggedTabID, before: tab.id) }
        }
    }

    func dropExited(info: DropInfo) {
        isItemTarget = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Show the copy (+) cursor while Option is held over a tab, matching the duplicate.
        if selection.draggingItemID != nil, NSEvent.modifierFlags.contains(.option) {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isItemTarget = false
        if let anchor = selection.draggingItemID {
            let group = selection.draggingItemIDs.isEmpty ? [anchor] : selection.draggingItemIDs
            // Option held → duplicate the items into this tab; otherwise move them.
            let duplicate = NSEvent.modifierFlags.contains(.option)
            withAnimation(LauncherTheme.motion) {
                if duplicate {
                    store.duplicateItems(group, toTab: tab.id)
                } else {
                    store.moveItems(group, toTab: tab.id)
                }
            }
            selection.draggingItemID = nil
            selection.draggingItemIDs = []
            selection.selectedItemIDs = []
            return true
        }
        draggedTabID = nil
        return true
    }
}

/// AppKit interaction layer for a tab label in editing mode (select / edit-title / drag /
/// drag-off-to-delete). Reuses `DragSourceView`.
private struct TabInteractionView: NSViewRepresentable {
    let tab: LauncherTab
    let foreground: Color
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onRemove: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: (_ droppedOutsideWindow: Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.idString = tab.id.uuidString
        view.deleteBadgeStyle = .corner
        view.dragImage = Self.dragImage(for: tab, foreground: foreground)
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onRemove = onRemove
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.menuItems = [("Rename…", onDoubleClick), (nil, nil), ("Delete Tab", onRemove)]
    }

    private static func dragImage(for tab: LauncherTab, foreground: Color) -> NSImage {
        let font = NSFont.systemFont(ofSize: LauncherTheme.labelSize, weight: .semibold)
        let textColor = NSColor(foreground)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let text = tab.title as NSString
        let textSize = text.size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: textSize.width + 24, height: textSize.height + 16))
        image.lockFocus()
        (tab.color.withAlphaComponent(0.9)).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: 10, yRadius: 10).fill()
        text.draw(at: NSPoint(x: 12, y: 8), withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}

/// Drop target for the empty area after the last tab: moves the dragged tab to the end.
private struct TabEndDropDelegate: DropDelegate {
    let store: LauncherStore
    @Binding var draggedTabID: LauncherTab.ID?

    func dropEntered(info: DropInfo) {
        guard let draggedTabID else { return }
        withAnimation(LauncherTheme.motion) { store.moveTabToEnd(draggedTabID) }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Thin wrapper over the shared `NSColorPanel` that reports live color changes as hex.
@MainActor
final class TabColorPanel: NSObject {
    static let shared = TabColorPanel()
    private var onChange: ((String) -> Void)?

    func present(initialHex: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let color = NSColor(hex: initialHex) {
            panel.color = color
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.level = .popUpMenu // float above the launcher window
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color.hexString)
    }
}
