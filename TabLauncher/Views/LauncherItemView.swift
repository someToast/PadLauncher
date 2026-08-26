import AppKit
import SwiftUI

/// The visual for a launcher item (icon + caption). Interaction (click, right-click,
/// drag) is handled by an `ItemInteractionView` overlaid in the grid.
struct LauncherItemView: View {
    let item: LauncherItem
    var foreground: Color = .white
    var selected: Bool = false

    var body: some View {
        VStack(spacing: LauncherTheme.iconLabelSpacing) {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: LauncherTheme.iconSize, height: LauncherTheme.iconSize)
                // Drop shadow on the icon only — never the caption.
                .shadow(color: .black.opacity(0.3), radius: LauncherTheme.iconShadowRadius, x: 0, y: LauncherTheme.iconShadowY)
                // A translucent plate behind the selected icon, filling the border ring.
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: LauncherTheme.selectionCorner, style: .continuous)
                            .fill(foreground.opacity(0.25))
                            .padding(-LauncherTheme.selectionInset)
                    }
                }
                // Selection border, offset a fixed amount outside the icon on every side.
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: LauncherTheme.selectionCorner, style: .continuous)
                            .stroke(foreground, lineWidth: LauncherTheme.selectionLineWidth)
                            .padding(-LauncherTheme.selectionInset)
                    }
                }
            Text(item.displayName)
                .font(.system(size: LauncherTheme.captionSize, weight: .regular))
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .frame(height: LauncherTheme.captionHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .help(item.displayName)
    }
}

/// AppKit interaction layer: click to open, right-click menu, and a drag that the
/// SwiftUI grid handles for reordering — or, if released off the window, deletes the item.
struct ItemInteractionView: NSViewRepresentable {
    let item: LauncherItem
    /// How many icons would move if this one is dragged (1, or the whole selection when
    /// this icon is part of it) — drives the drag proxy's count badge.
    var groupCount: Int = 1
    var onOpen: () -> Void = {}
    var onRename: () -> Void = {}
    var onReveal: () -> Void = {}
    var onRemove: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: (_ droppedOutsideWindow: Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.idString = item.id.uuidString
        view.deleteBadgeStyle = .inset
        let base = item.icon.resized(to: NSSize(width: 84, height: 84), fraction: 0.85)
        view.dragImage = groupCount > 1 ? base.withCountBadge(groupCount) : base
        view.onClick = onOpen
        view.onDoubleClick = nil
        view.onRemove = onRemove
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.menuItems = [
            ("Open", onOpen),
            ("Rename…", onRename),
            ("Reveal in Finder", onReveal),
            (nil, nil),
            ("Remove", onRemove)
        ]
    }
}

/// Reusable AppKit drag source: click / double-click / right-click menu, a drag the
/// SwiftUI layer reorders, and deletion when released off the window.
final class DragSourceView: NSView, NSDraggingSource {
    var idString = ""
    var dragImage = NSImage()
    var deleteBadgeStyle: NSImage.DeleteBadgeStyle = .inset
    var onClick: () -> Void = {}
    var onDoubleClick: (() -> Void)?
    var onRemove: () -> Void = {}
    var onDragStart: () -> Void = {}
    /// Called once when the drag ends, reporting whether it was released off the window.
    var onDragEnd: (_ droppedOutsideWindow: Bool) -> Void = { _ in }
    /// (title, action) pairs for the right-click menu; a nil title is a separator.
    var menuItems: [(String?, (() -> Void)?)] = []
    private var menuActions: [() -> Void] = []

    private var mouseDownPoint: NSPoint = .zero
    private var isDragging = false
    private var showingDeleteBadge = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        // Reset drag state only at the start of a fresh interaction. A drag never resets it
        // (see mouseUp), so any mouse-up that trails a drag can't be mistaken for a click.
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging else { return }
        let dx = event.locationInWindow.x - mouseDownPoint.x
        let dy = event.locationInWindow.y - mouseDownPoint.y
        guard hypot(dx, dy) > 4 else { return }
        isDragging = true
        showingDeleteBadge = false

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(idString, forType: .string)
        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // Use the image's own size so it's never distorted (the tab pill and the square
        // icon have different aspect ratios).
        let imageSize = dragImage.size
        let local = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(
            NSRect(x: local.x - imageSize.width / 2, y: local.y - imageSize.height / 2,
                   width: imageSize.width, height: imageSize.height),
            contents: dragImage
        )
        onDragStart()
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        // No fly-back on a failed drop, so an off-window delete removes immediately
        // instead of snapping back to the bar first.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        // Only a clean click (no drag since the last mouse-down) launches. A mouse-up that
        // arrives after a drag — in either order relative to draggingSession(endedAt:) —
        // is ignored because isDragging stays true until the next mouseDown resets it.
        guard !isDragging else { return }
        if event.clickCount >= 2, let onDoubleClick {
            onDoubleClick()
        } else {
            onClick()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !menuItems.isEmpty else { return }
        let menu = NSMenu()
        menuActions = []
        for (title, action) in menuItems {
            guard let title, let action else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = menuActions.count
            menuActions.append(action)
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    private func isDeleteZone(_ screenPoint: NSPoint) -> Bool {
        window.map { !$0.frame.contains(screenPoint) } ?? false
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Badge the dragged image with a trashcan while over the delete zone, so it's clear
        // that letting go here removes the item(s). We badge the image (not the cursor): the
        // drag session keeps it in sync and never resets it, and the system's own copy ("+")
        // cursor for Option-drags is left untouched.
        let inZone = isDeleteZone(screenPoint)
        guard inZone != showingDeleteBadge else { return }
        showingDeleteBadge = inZone
        let image = inZone ? dragImage.withDeleteBadge(style: deleteBadgeStyle) : dragImage
        // A `.corner` badge makes the image larger; grow the dragging frame to match (anchored
        // at the proxy's top-left) so the proxy isn't scaled down. `.inset` keeps the size.
        let overhang = deleteBadgeStyle == .corner ? NSImage.deleteBadgeOverhang(for: dragImage.size) : 0
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self]) { item, _, stop in
            var frame = item.draggingFrame
            if overhang > 0 {
                let delta = inZone ? overhang : -overhang
                frame = NSRect(x: frame.minX, y: frame.minY - delta,
                               width: frame.width + delta, height: frame.height + delta)
            }
            item.setDraggingFrame(frame, contents: image)
            stop.pointee = true
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Released outside the window → "dragged off to delete". Inside the window is either a
        // handled reorder/tab-move or a harmless no-op. The panel decides what to remove (a
        // single item or the whole selected group) from the drag state.
        if isDeleteZone(screenPoint) {
            // Shrink the dropped proxy to a point, then commit the deletion.
            DeleteDragVisuals.shrink(image: dragImage.withDeleteBadge(style: deleteBadgeStyle), at: screenPoint) { [onDragEnd] in
                onDragEnd(true)
            }
        } else {
            onDragEnd(false)
        }
        // Deliberately do NOT reset isDragging here; the next mouseDown does. This keeps a
        // trailing mouse-up from being treated as a launch click.
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard menuActions.indices.contains(sender.tag) else { return }
        menuActions[sender.tag]()
    }
}

extension NSImage {
    /// A uniformly scaled copy at `size`, optionally translucent (for drag proxies).
    func resized(to size: NSSize, fraction: CGFloat = 1.0) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: fraction)
        output.unlockFocus()
        return output
    }

    /// A copy of this drag proxy with a red count badge in the top-right corner, used when
    /// several icons are dragged as a group.
    func withCountBadge(_ count: Int) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)

        let diameter: CGFloat = 26
        let badgeRect = NSRect(x: size.width - diameter, y: size.height - diameter, width: diameter, height: diameter)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()

        let text = "\(count)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2), withAttributes: attrs)

        output.unlockFocus()
        return output
    }

    enum DeleteBadgeStyle {
        /// Lower-right, fully inside the image (icons — clears the top-right count badge).
        case inset
        /// Straddling the bottom-right corner, hanging off it (tabs).
        case corner
    }

    /// The extra width/height a `.corner` badge adds beyond the image, so callers can grow
    /// the dragging frame to match and avoid the image being scaled down.
    static func deleteBadgeOverhang(for size: NSSize) -> CGFloat {
        deleteBadgeDiameter(for: size) / 2
    }

    private static func deleteBadgeDiameter(for size: NSSize) -> CGFloat {
        max(24, min(size.width, size.height) * 0.44)
    }

    /// A copy of this drag proxy with a red trashcan badge, shown while the drag is over the
    /// off-window delete zone.
    func withDeleteBadge(style: DeleteBadgeStyle) -> NSImage {
        let diameter = Self.deleteBadgeDiameter(for: size)
        switch style {
        case .inset:
            let output = NSImage(size: size)
            output.lockFocus()
            draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            drawTrashBadge(in: NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter))
            output.unlockFocus()
            return output
        case .corner:
            let overhang = diameter / 2
            let canvas = NSSize(width: size.width + overhang, height: size.height + overhang)
            let output = NSImage(size: canvas)
            output.lockFocus()
            // The proxy sits at the top-left; the badge straddles its bottom-right corner.
            draw(in: NSRect(x: 0, y: overhang, width: size.width, height: size.height),
                 from: .zero, operation: .sourceOver, fraction: 1)
            drawTrashBadge(in: NSRect(x: size.width - diameter / 2, y: overhang - diameter / 2,
                                      width: diameter, height: diameter))
            output.unlockFocus()
            return output
        }
    }
}

/// Draws a red trashcan disc into the current focus context (used by `withDeleteBadge`).
private func drawTrashBadge(in badgeRect: NSRect) {
    NSColor.white.setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: badgeRect.insetBy(dx: 1.5, dy: 1.5)).fill()

    let config = NSImage.SymbolConfiguration(pointSize: badgeRect.width * 0.55, weight: .bold)
    guard let trash = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "Delete")?
        .withSymbolConfiguration(config) else { return }
    let white = NSImage(size: trash.size)
    white.lockFocus()
    trash.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: trash.size).fill(using: .sourceAtop)
    white.unlockFocus()
    white.draw(at: NSPoint(x: badgeRect.midX - white.size.width / 2, y: badgeRect.midY - white.size.height / 2),
               from: .zero, operation: .sourceOver, fraction: 1)
}

/// The drop-to-delete animation: shows the dropped proxy and quickly shrinks it to a point.
@MainActor
enum DeleteDragVisuals {
    /// Shows `image` at `screenPoint` and quickly shrinks it to nothing, then runs `completion`.
    static func shrink(image: NSImage, at screenPoint: NSPoint, completion: @escaping () -> Void) {
        let size = image.size
        let win = NSWindow(
            contentRect: NSRect(x: screenPoint.x - size.width / 2, y: screenPoint.y - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .floating

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        win.contentView = host
        let iconLayer = CALayer()
        iconLayer.frame = CGRect(origin: .zero, size: size)
        iconLayer.contents = image
        iconLayer.contentsGravity = .resizeAspect
        host.layer?.addSublayer(iconLayer)
        win.orderFront(nil)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            win.orderOut(nil)
            completion()
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 0.02
        scale.duration = 0.18
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.18
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        iconLayer.add(scale, forKey: "shrink")
        iconLayer.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}
