import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingLauncherController: NSObject {
    private let store: LauncherStore
    private let window: NSPanel
    private let selection = LauncherSelection()
    private var presentationScreen: NSScreen?
    private var keyMonitor: Any?
    private var clickOutsideMonitor: Any?
    /// A leading "1" is held briefly to see if a second digit follows (→ tabs 10–19).
    private var pendingLeadingOne = false
    private var pendingDigitResolve: DispatchWorkItem?
    private let multiDigitWindow = 0.35

    private var isRecentering = false
    private var cancellables = Set<AnyCancellable>()
    private let container = NSView()
    private var hosting: NSHostingView<LauncherWindowView>!
    private let openDuration = 0.25
    private let closeDuration = 0.25
    private let scaleAmount: CGFloat = 1.1
    private var animationToken = 0

    init(store: LauncherStore) {
        self.store = store
        window = Self.makePanel(size: NSSize(width: 1080, height: 620))

        super.init()

        window.contentView = container

        hosting = NSHostingView(rootView: LauncherWindowView(
            store: store,
            selection: selection,
            onLaunch: { [weak self] in self?.dismiss() },
            onSizeToFit: { [weak self] iconCount in self?.sizeWindowToFit(iconCount: iconCount) }
        ))
        hosting.wantsLayer = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        // A generous resize band just inside the window edges (borderless windows give
        // almost no native resize target).
        let resizer = ResizeBorderView()
        resizer.frame = container.bounds
        resizer.autoresizingMask = [.width, .height]
        container.addSubview(resizer)
        resizer.onResize = { [weak self] edges, mouse in
            self?.performEdgeResize(edges: edges, mouse: mouse)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Keep the window centered on its screen as the user drags an edge to resize.
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)

        // Keep the minimum size in step with the tabs so the header never clips.
        store.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMinimumSize() }
            .store(in: &cancellables)
        updateMinimumSize()
    }

    deinit {
        MainActor.assumeIsolated {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        }
    }

    var isPresented: Bool { selection.presented }

    /// Pinch / global entry point: show the launcher if hidden, hide it if shown.
    func togglePresentation() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    /// Reveals the launcher centered on the screen under the cursor, with the first
    /// tab selected by default.
    func present() {
        if selection.tabID == nil {
            selection.tabID = store.tabs.first?.id
        }
        selection.presented = true
        presentationScreen = Self.screenUnderCursor()
        updateMinimumSize()

        let restFrame = currentRestFrame()
        enlargeWindow(around: restFrame)   // grow window + center hosting at rest size
        window.alphaValue = 1
        window.setIsVisible(true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitors()

        animationToken += 1
        let token = animationToken
        animateHosting(fromScale: scaleAmount, fromOpacity: 0, toScale: 1, toOpacity: 1, duration: openDuration) { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.window.setFrame(restFrame, display: true)
            self.layoutHostingFilled()
        }
    }

    /// Hides the launcher and stops observing dismissal events.
    func dismiss() {
        guard selection.presented else { return }
        cancelPendingDigit()
        removeMonitors()
        selection.isEditing = false
        selection.editingTitleTabID = nil
        selection.presented = false
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
            NSColorPanel.shared.orderOut(nil)
        }

        let restFrame = currentRestFrame()
        enlargeWindow(around: restFrame)   // no visual change (hosting stays at rest size/scale)

        animationToken += 1
        let token = animationToken
        animateHosting(fromScale: 1, fromOpacity: 1, toScale: scaleAmount, toOpacity: 0, duration: closeDuration) { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.window.orderOut(nil)
            self.window.setFrame(restFrame, display: false)
            self.layoutHostingFilled()
        }
    }

    /// The window's resting (unscaled) frame, centered on the presentation screen. The
    /// hosting view's frame always carries the rest size, so this is correct even while a
    /// show/hide animation has the window temporarily enlarged.
    private func currentRestFrame() -> NSRect {
        let size = hosting.frame.size
        let vf = (presentationScreen ?? window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let w = min(max(size.width, window.minSize.width), vf.width)
        let h = min(max(size.height, window.minSize.height), vf.height)
        return NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
    }

    /// Grows the window to `scaleAmount`× the given (centered) frame and pins the content at
    /// its rest size in the center, so the layer scale can grow the content into the extra
    /// window area instead of clipping against the window edge.
    private func enlargeWindow(around restFrame: NSRect) {
        let size = restFrame.size
        let big = NSSize(width: size.width * scaleAmount, height: size.height * scaleAmount)
        hosting.autoresizingMask = []
        window.setFrame(NSRect(x: restFrame.midX - big.width / 2, y: restFrame.midY - big.height / 2, width: big.width, height: big.height), display: false)
        hosting.frame = NSRect(x: (big.width - size.width) / 2, y: (big.height - size.height) / 2, width: size.width, height: size.height)
        hosting.layer?.transform = CATransform3DIdentity
        hosting.alphaValue = 1
    }

    private func layoutHostingFilled() {
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        hosting.layer?.transform = CATransform3DIdentity
        hosting.alphaValue = 1
    }

    private func animateHosting(fromScale: CGFloat, fromOpacity: Float, toScale: CGFloat, toOpacity: Float,
                                duration: Double, completion: @escaping () -> Void) {
        guard let layer = hosting.layer else { completion(); return }
        let size = hosting.bounds.size
        let timing = CAMediaTimingFunction(name: fromScale > toScale ? .easeOut : .easeIn)

        layer.transform = Self.centeredScale(toScale, size: size)
        hosting.alphaValue = CGFloat(toOpacity)

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = Self.centeredScale(fromScale, size: size)
        scale.toValue = Self.centeredScale(toScale, size: size)
        scale.duration = duration
        scale.timingFunction = timing
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = toOpacity
        fade.duration = duration
        fade.timingFunction = timing
        layer.add(scale, forKey: "show.scale")
        layer.add(fade, forKey: "show.opacity")
        CATransaction.commit()
    }

    private static func centeredScale(_ s: CGFloat, size: CGSize) -> CATransform3D {
        var m = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        m = CATransform3DScale(m, s, s, 1)
        return CATransform3DTranslate(m, -size.width / 2, -size.height / 2, 0)
    }

    /// Selects a specific tab (global hotkey). Reveals the launcher if hidden; if the
    /// tab is already selected and visible, dismisses.
    func toggle(tabID: LauncherTab.ID) {
        if isPresented, selection.tabID == tabID {
            dismiss()
            return
        }
        selection.tabID = tabID
        if !isPresented {
            present()
        }
    }

    /// Routes a bare digit to a tab: 0 → tab 10; 2–9 → that tab immediately; 1 waits briefly
    /// for a second digit (→ tabs 10–19) and otherwise resolves to tab 1.
    private func handleTabDigit(_ digit: Int) {
        if pendingLeadingOne {
            cancelPendingDigit()
            selectTab(number: 10 + digit) // "1" + d → 10…19 ("1""0" also gives 10)
            return
        }
        switch digit {
        case 0:
            selectTab(number: 10)
        case 1:
            pendingLeadingOne = true
            let work = DispatchWorkItem { [weak self] in
                self?.pendingLeadingOne = false
                self?.pendingDigitResolve = nil
                self?.selectTab(number: 1)
            }
            pendingDigitResolve = work
            DispatchQueue.main.asyncAfter(deadline: .now() + multiDigitWindow, execute: work)
        default: // 2–9 (no two-digit tab can start with these, since the max is 19)
            selectTab(number: digit)
        }
    }

    private func cancelPendingDigit() {
        pendingDigitResolve?.cancel()
        pendingDigitResolve = nil
        pendingLeadingOne = false
    }

    /// Selects the tab at 1-based `number`, if it exists.
    private func selectTab(number: Int) {
        guard number >= 1, number <= store.tabs.count else { return }
        selection.tabID = store.tabs[number - 1].id
    }

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, self.window.isKeyWindow else { return event }

                // While editing a tab title, let typing through; Escape cancels the edit.
                if self.selection.editingTitleTabID != nil {
                    if event.keyCode == 53 {
                        self.selection.editingTitleTabID = nil
                        return nil
                    }
                    return event
                }

                if event.keyCode == 53 { // Escape
                    self.cancelPendingDigit()
                    self.dismiss()
                    return nil
                }

                // Bare number keys switch tabs by position: 1–9 select tabs 1–9, 0 selects
                // tab 10, and 10–19 are reached by typing "1" then a second digit quickly.
                // Modifiers are ignored so this never collides with anything system-wide.
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if modifiers.isEmpty,
                   let characters = event.charactersIgnoringModifiers, characters.count == 1,
                   let digit = Int(characters), (0...9).contains(digit) {
                    self.handleTabDigit(digit)
                    return nil
                }

                return event
            }
        }

        if clickOutsideMonitor == nil {
            // Fire on mouse-UP, not down, so a drag that starts outside — e.g. dragging
            // a file in from Finder — isn't cancelled the instant the drag begins. The
            // release that ends a drag is consumed by the system's drag loop, so a drop
            // never reaches here; and a release landing over our own window is ignored so
            // a successful drag-in leaves the launcher open.
            clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self else { return }
                    // Ignore releases over any of our own visible windows — the launcher
                    // itself or auxiliary panels like the color picker.
                    let insideOwnWindow = NSApp.windows.contains { $0.isVisible && NSMouseInRect(location, $0.frame, false) }
                    if insideOwnWindow { return }
                    self.dismiss()
                }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    /// Resizes the window to fit the header width and `iconCount` icons — widening beyond the
    /// header (with icons evenly distributed) when there are few, never exceeding the screen.
    /// Callers pass the current tab's icon count or the largest tab's, per the menu choice.
    func sizeWindowToFit(iconCount: Int) {
        guard let screen = presentationScreen ?? window.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame

        let cell = LauncherTheme.cellMinWidth
        let sp = LauncherTheme.gridSpacing
        let side = LauncherTheme.contentSidePadding
        let rowH = LauncherTheme.iconSize + LauncherTheme.iconLabelSpacing + LauncherTheme.captionHeight
        let vpad = LauncherTheme.contentVerticalPadding
        let headerH = LauncherTheme.barPadding * 2 + LauncherTheme.chipHeight
        let sectionGap = LauncherTheme.sectionSpacing

        func contentWidth(_ c: Int) -> CGFloat { side * 2 + CGFloat(c) * cell + CGFloat(max(0, c - 1)) * sp }
        func contentHeight(rows: Int) -> CGFloat { vpad * 2 + CGFloat(rows) * rowH + CGFloat(max(0, rows - 1)) * sp }
        func columns(forWidth w: CGFloat) -> Int { max(1, Int((max(0, w - side * 2) + sp) / (cell + sp))) }

        // Always size for the wider edit-mode header (it adds the ＋), so entering edit
        // mode never needs to widen the window and reflow the icons.
        let headerWidth = headerMinWidth(editing: true)

        let colsAtHeader = columns(forWidth: headerWidth)
        let colsSquare = iconCount > 0 ? Int(ceil(Double(iconCount).squareRoot())) : 1
        let colsMaxScreen = columns(forWidth: vf.width)

        var cols = min(max(colsAtHeader, colsSquare), max(1, iconCount))
        cols = min(cols, colsMaxScreen)
        var rows = iconCount > 0 ? Int(ceil(Double(iconCount) / Double(cols))) : 0

        // If too tall for the screen, add columns (fewer rows) until it fits or we run out.
        while iconCount > 0, headerH + sectionGap + contentHeight(rows: rows) > vf.height,
              cols < min(iconCount, colsMaxScreen) {
            cols += 1
            rows = Int(ceil(Double(iconCount) / Double(cols)))
        }

        // Breathing room below the last row ≈ 1.5 lines of caption text.
        let captionFont = NSFont.systemFont(ofSize: LauncherTheme.captionSize)
        let captionLine = captionFont.ascender - captionFont.descender + captionFont.leading
        let bottomPadding = captionLine * 1.5

        var width = max(headerWidth, contentWidth(cols))
        var height = headerH + sectionGap + contentHeight(rows: rows) + bottomPadding
        width = min(max(width, window.minSize.width), vf.width)
        height = min(max(height, window.minSize.height), vf.height)

        let origin = NSPoint(x: vf.midX - width / 2, y: vf.midY - height / 2)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true, animate: true)
    }

    private func chipWidth(for title: String) -> CGFloat {
        let labelFont = NSFont.systemFont(ofSize: LauncherTheme.labelSize, weight: .semibold)
        let labelWidth = (title as NSString).size(withAttributes: [.font: labelFont]).width
        return ceil(labelWidth) + LauncherTheme.chipPaddingLeading + LauncherTheme.chipSpacing
            + LauncherTheme.trailingSlotWidth + LauncherTheme.chipPaddingTrailing
    }

    private func headerExtras(editing: Bool) -> (extras: CGFloat, gapCount: Int) {
        var extras = symbolWidth("gearshape", size: LauncherTheme.gearSize, weight: .regular)
        if editing { extras += symbolWidth("plus", size: LauncherTheme.gearSize * 0.7, weight: .semibold) }
        // Gaps: between every element (chips + optional plus + spacer + gear).
        return (extras, store.tabs.count + (editing ? 1 : 0) + 1)
    }

    /// Full header width — every tab at its natural width (used by Size Window to Fit).
    private func headerMinWidth(editing: Bool) -> CGFloat {
        let chipsWidth = store.tabs.reduce(0) { $0 + chipWidth(for: $1.title) }
        let (extras, gapCount) = headerExtras(editing: editing)
        return LauncherTheme.barPadding * 2 + chipsWidth + extras + CGFloat(gapCount) * LauncherTheme.barSpacing
    }

    /// Collapsed header width — the widest tab shown full (worst-case selected) with the
    /// rest truncated to a minimum. Used for the window's minimum width so tabs may
    /// truncate rather than forcing the window wide.
    private func headerCollapsedWidth(editing: Bool) -> CGFloat {
        guard !store.tabs.isEmpty else {
            let (extras, gapCount) = headerExtras(editing: editing)
            return LauncherTheme.barPadding * 2 + extras + CGFloat(gapCount) * LauncherTheme.barSpacing
        }
        let labelFont = NSFont.systemFont(ofSize: LauncherTheme.labelSize, weight: .semibold)
        let chrome = LauncherTheme.chipPaddingLeading + LauncherTheme.chipSpacing
            + LauncherTheme.trailingSlotWidth + LauncherTheme.chipPaddingTrailing
        func minChip(_ title: String) -> CGFloat {
            let sample = (String(title.prefix(1)) + "…") as NSString
            // +8 slack so the HStack reliably honors each label's first-char minimum at
            // the window's minimum width (avoids some collapsing to just "…").
            return ceil(sample.size(withAttributes: [.font: labelFont]).width) + chrome + 8
        }
        // The widest tab is shown full (worst case if it's the selected one); the rest
        // collapse to their first-character-plus-ellipsis minimum.
        let fulls = store.tabs.map { chipWidth(for: $0.title) }
        let longestIndex = fulls.indices.max(by: { fulls[$0] < fulls[$1] }) ?? 0
        var chipsWidth: CGFloat = 0
        for (index, tab) in store.tabs.enumerated() {
            chipsWidth += index == longestIndex ? fulls[index] : minChip(tab.title)
        }
        let (extras, gapCount) = headerExtras(editing: editing)
        return LauncherTheme.barPadding * 2 + chipsWidth + extras + CGFloat(gapCount) * LauncherTheme.barSpacing
    }

    private func symbolWidth(_ name: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            return image.size.width
        }
        return size
    }

    /// Minimum window size = the (edit-mode) header width and enough height for the header
    /// plus one full row of icons, so shrinking never clips the tabs or the first row.
    private func updateMinimumSize() {
        let vf = (presentationScreen ?? window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let headerH = LauncherTheme.barPadding * 2 + LauncherTheme.chipHeight
        let cellHeight = LauncherTheme.iconSize + LauncherTheme.iconLabelSpacing + LauncherTheme.captionHeight
        let captionFont = NSFont.systemFont(ofSize: LauncherTheme.captionSize)
        let captionLine = captionFont.ascender - captionFont.descender + captionFont.leading
        let minWidth = headerCollapsedWidth(editing: true)
        let minHeight = headerH + LauncherTheme.sectionSpacing + LauncherTheme.contentVerticalPadding * 2 + cellHeight + captionLine * 1.5

        window.minSize = NSSize(
            width: vf.width > 0 ? min(minWidth, vf.width) : minWidth,
            height: vf.height > 0 ? min(minHeight, vf.height) : minHeight
        )

        // Grow the window if it's currently below the new minimum.
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var frame = window.frame
            frame.size.width = max(frame.size.width, window.minSize.width)
            frame.size.height = max(frame.size.height, window.minSize.height)
            if vf.width > 0 {
                frame.origin = NSPoint(x: vf.midX - frame.size.width / 2, y: vf.midY - frame.size.height / 2)
            }
            window.setFrame(frame, display: true)
        }
    }

    /// Live edge/corner resize driven by the custom border band. Keeps the window
    /// centered (the grabbed edge follows the cursor as the opposite edge mirrors it).
    private func performEdgeResize(edges: ResizeBorderView.Edges, mouse: NSPoint) {
        guard let screen = presentationScreen ?? window.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var size = window.frame.size
        if edges.contains(.left) || edges.contains(.right) {
            size.width = min(max(2 * abs(mouse.x - vf.midX), window.minSize.width), vf.width)
        }
        if edges.contains(.top) || edges.contains(.bottom) {
            size.height = min(max(2 * abs(mouse.y - vf.midY), window.minSize.height), vf.height)
        }
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func positionWindow() {
        guard let screen = presentationScreen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }

    @objc private func screenParametersChanged() {
        if isPresented { positionWindow() }
    }

    @objc private func windowDidResize() {
        // Re-center on the presentation screen so resizing grows/shrinks symmetrically.
        guard isPresented, !isRecentering, let screen = presentationScreen ?? NSScreen.main else { return }
        isRecentering = true
        defer { isRecentering = false }
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.minSize = NSSize(width: 640, height: 360)
        return panel
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A transparent overlay that only hit-tests a border band inside the window edges,
/// showing resize cursors there and reporting drags for a custom resize (the OS resize
/// edge on a borderless window is too thin to grab reliably).
final class ResizeBorderView: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    var onResize: ((Edges, NSPoint) -> Void)?
    private let band: CGFloat = 10
    // Larger corner zone so grabbing a corner (both axes) is easy to hit.
    private let cornerBand: CGFloat = 24
    private var activeEdges: Edges = []

    private func edges(at point: NSPoint) -> Edges {
        let w = bounds.width, h = bounds.height
        // Corners first, using the larger corner zone: near both a vertical and a
        // horizontal edge → resize both axes.
        let nearLeft = point.x <= cornerBand, nearRight = point.x >= w - cornerBand
        let nearBottom = point.y <= cornerBand, nearTop = point.y >= h - cornerBand
        if nearLeft && nearBottom { return [.left, .bottom] }
        if nearLeft && nearTop { return [.left, .top] }
        if nearRight && nearBottom { return [.right, .bottom] }
        if nearRight && nearTop { return [.right, .top] }

        var result: Edges = []
        if point.x <= band { result.insert(.left) }
        if point.x >= w - band { result.insert(.right) }
        if point.y <= band { result.insert(.bottom) }
        if point.y >= h - band { result.insert(.top) }
        return result
    }

    // Only claim clicks in the border band; everything else falls through to the content.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return edges(at: local).isEmpty ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeEdges.isEmpty else { return }
        onResize?(activeEdges, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
    }

    override func resetCursorRects() {
        let w = bounds.width, h = bounds.height
        addCursorRect(NSRect(x: 0, y: 0, width: band, height: h), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - band, y: 0, width: band, height: h), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: w, height: band), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: h - band, width: w, height: band), cursor: .resizeUpDown)

        // Corner diagonal cursors (added last so they win at the corners). Origin is
        // bottom-left: "/" runs bottom-left↔top-right (NESW), "\" runs top-left↔bottom-right.
        let c = cornerBand
        let nwse = Self.diagonalCursor(northEast: false) ?? .resizeLeftRight
        let nesw = Self.diagonalCursor(northEast: true) ?? .resizeLeftRight
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: nesw)          // bottom-left
        addCursorRect(NSRect(x: w - c, y: 0, width: c, height: c), cursor: nwse)      // bottom-right
        addCursorRect(NSRect(x: 0, y: h - c, width: c, height: c), cursor: nwse)      // top-left
        addCursorRect(NSRect(x: w - c, y: h - c, width: c, height: c), cursor: nesw)  // top-right
    }

    /// Private diagonal resize cursors (no public API); falls back to nil if unavailable.
    private static func diagonalCursor(northEast: Bool) -> NSCursor? {
        let name = northEast ? "_windowResizeNorthEastSouthWestCursor" : "_windowResizeNorthWestSouthEastCursor"
        let selector = NSSelectorFromString(name)
        guard NSCursor.responds(to: selector),
              let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor else { return nil }
        return cursor
    }
}
