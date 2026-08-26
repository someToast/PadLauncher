import SwiftUI

/// Design tokens from the Figma mockup, at 1× (Figma px map to points directly).
enum LauncherTheme {
    static let contentColor = Color(red: 0x22 / 255, green: 0x54 / 255, blue: 0xA4 / 255) // #2254A4
    static let windowCorner: CGFloat = 28

    // Tabs bar
    static let barBackground = Color.black.opacity(0.3)
    static let barPadding: CGFloat = 20
    static let barSpacing: CGFloat = 20
    static let chipPaddingLeading: CGFloat = 16
    // Small trailing padding so the color chit's right inset matches its top/bottom inset.
    static let chipPaddingTrailing: CGFloat = 4
    static let chipHeight: CGFloat = 54
    static let chipSpacing: CGFloat = 12
    static let chipCorner: CGFloat = 12
    static let labelSize: CGFloat = 32
    static let numberSize: CGFloat = 15.5
    static let gearSize: CGFloat = 36
    static let maxTabNameLength = 32
    // A constant-width trailing slot keeps the label from shifting as the number,
    // color chit, and clear button swap in and out across modes.
    static let trailingSlotWidth: CGFloat = 22
    static let chitWidth: CGFloat = 22
    // Height leaves an inset equal to chipPaddingTrailing on top/bottom → (54-46)/2 = 4.
    static let chitHeight: CGFloat = 46
    static let chitCorner: CGFloat = 10

    // Content grid
    static let contentSidePadding: CGFloat = 60
    static let contentVerticalPadding: CGFloat = 10
    static let gridSpacing: CGFloat = 26
    static let cellMinWidth: CGFloat = 140
    static let cellMaxWidth: CGFloat = 180
    // Real macOS icons carry transparent padding inside their canvas, so the frame is
    // sized up from the mockup's 84 to keep the visible squircle near that size.
    static let iconSize: CGFloat = 104
    static let iconLabelSpacing: CGFloat = 12
    static let iconShadowRadius: CGFloat = 5.35
    static let iconShadowY: CGFloat = 6
    static let captionSize: CGFloat = 14
    // Fixed height for two caption lines so a wrapped label never shifts the icon or the
    // next row; single-line labels leave the second line blank.
    static let captionHeight: CGFloat = 34

    // Gap between the tabs bar and the content grid
    static let sectionSpacing: CGFloat = 20

    // Multi-select
    /// How far the selection border sits outside the icon on every side.
    static let selectionInset: CGFloat = 6
    static let selectionLineWidth: CGFloat = 2
    static let selectionCorner: CGFloat = 20

    /// Shared spring for rearrange/add/remove/color-change motion.
    static let motion: Animation = .spring(response: 0.3, dampingFraction: 0.82)

    /// White text/glyphs unless white fails WCAG AA contrast (4.5:1) against the tab's
    /// background color, in which case black reads better.
    static func foreground(onBackground color: NSColor) -> Color {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        return contrastWithWhite >= 4.5 ? .white : .black
    }
}

/// Selected tab + edit state, shared between the SwiftUI window and the controller
/// (so global hotkeys can drive selection too).
@MainActor
final class LauncherSelection: ObservableObject {
    @Published var tabID: LauncherTab.ID?
    @Published var isEditing = false
    /// Non-nil while a tab's title is being edited inline (suspends Escape-dismiss
    /// and bare-number tab switching so typing works).
    @Published var editingTitleTabID: LauncherTab.ID?
    /// The item currently being dragged (the anchor of a group drag), shared so the tab
    /// chips can accept it as a cross-tab move.
    @Published var draggingItemID: LauncherItem.ID?
    /// Icons selected via drag-select (marquee), styled with a border and movable as a group.
    @Published var selectedItemIDs: Set<LauncherItem.ID> = []
    /// The fixed point a Shift-click range extends from — set by the last ⌘-click, the first
    /// Shift-click, or the start of a marquee selection.
    @Published var selectionAnchorID: LauncherItem.ID?
    /// The set of items in the current group drag (a single item, or the whole selection).
    @Published var draggingItemIDs: Set<LauncherItem.ID> = []
    /// Drives the window's scale/fade in and out. False = slightly oversized + invisible.
    @Published var presented = false
}

/// The whole launcher in a single window: a tab bar across the top and the selected
/// tab's contents below, on a solid colored panel.
struct LauncherWindowView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject var selection: LauncherSelection
    /// Called after an item is opened so the launcher can dismiss itself.
    var onLaunch: () -> Void = {}
    /// Resizes the window to fit the tabs/icons.
    var onSizeToFit: (Int) -> Void = { _ in }

    private var currentTab: LauncherTab? {
        store.tabs.first(where: { $0.id == selection.tabID }) ?? store.tabs.first
    }

    /// The active tab's color themes the panel; the selected tab chip matches it so it
    /// appears to punch through the darkened bar.
    private var activeNSColor: NSColor {
        currentTab?.color ?? (NSColor(hex: "#2254A4") ?? .controlAccentColor)
    }
    private var activeColor: Color { Color(nsColor: activeNSColor) }
    private var foreground: Color { LauncherTheme.foreground(onBackground: activeNSColor) }

    var body: some View {
        // No gap here — the header/content spacing lives inside the scroll view's top
        // inset so content clips at the header edge, not below it.
        VStack(spacing: 0) {
            TabStripView(store: store, selection: selection, selectedColor: activeColor, foreground: foreground)

            if let tab = currentTab {
                LauncherPanelView(store: store, tab: tab, selection: selection, foreground: foreground, onLaunch: onLaunch, onSizeToFit: onSizeToFit)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(activeColor)
        .clipShape(RoundedRectangle(cornerRadius: LauncherTheme.windowCorner, style: .continuous))
        // Show/hide scale + fade is applied at the window/layer level by the controller
        // so the whole perimeter scales without the window frame clipping it.
    }
}
