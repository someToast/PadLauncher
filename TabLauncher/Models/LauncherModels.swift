import AppKit
import Foundation

struct LauncherTab: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var colorHex: String
    var hotKeyNumber: Int?
    var items: [LauncherItem]

    init(id: UUID = UUID(), title: String, colorHex: String, hotKeyNumber: Int? = nil, items: [LauncherItem] = []) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.hotKeyNumber = hotKeyNumber
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, colorHex, colorName, hotKeyNumber, items
    }

    // Tolerant decoding: accept the new `colorHex`, or migrate the old `colorName`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        hotKeyNumber = try container.decodeIfPresent(Int.self, forKey: .hotKeyNumber)
        items = try container.decodeIfPresent([LauncherItem].self, forKey: .items) ?? []

        if let hex = try container.decodeIfPresent(String.self, forKey: .colorHex) {
            colorHex = hex
        } else if let name = try container.decodeIfPresent(String.self, forKey: .colorName) {
            colorHex = Self.legacyHex(forName: name)
        } else {
            colorHex = "#2254A4"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(hotKeyNumber, forKey: .hotKeyNumber)
        try container.encode(items, forKey: .items)
    }

    private static func legacyHex(forName name: String) -> String {
        switch name {
        case "teal": return "#30B0C7"
        case "green": return "#34C759"
        case "orange": return "#FF9500"
        case "pink": return "#FF2D55"
        case "indigo": return "#5856D6"
        default: return "#2254A4"
        }
    }
}

struct LauncherItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case application
        case file
        case folder
        case url
    }

    var id: UUID
    var title: String
    var kind: Kind
    var url: URL
    var bookmarkData: Data?
    /// A user-supplied name that overrides the live filesystem name.
    var customName: String?

    init(id: UUID = UUID(), title: String, kind: Kind, url: URL, bookmarkData: Data? = nil, customName: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.url = url
        self.bookmarkData = bookmarkData
        self.customName = customName
    }
}

extension LauncherItem {
    var resolvedURL: URL {
        guard let bookmarkData else { return url }

        var isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return resolved
        }

        return url
    }

    var icon: NSImage {
        if kind == .url {
            return NSWorkspace.shared.icon(for: .url)
        }

        return NSWorkspace.shared.icon(forFile: resolvedURL.path)
    }

    /// The live, localized filesystem name (nil for URLs or if unreadable).
    var liveName: String? {
        guard kind != .url else { return nil }
        return try? resolvedURL.resourceValues(forKeys: [.localizedNameKey]).localizedName
    }

    /// What to show under the icon: a manual rename wins, otherwise the current
    /// filesystem name, otherwise the name captured when the item was added.
    var displayName: String {
        customName ?? liveName ?? title
    }

    /// Whether the target still exists (URLs are always considered present).
    var exists: Bool {
        if kind == .url { return true }
        return FileManager.default.fileExists(atPath: resolvedURL.path)
    }
}

extension LauncherTab {
    var color: NSColor {
        NSColor(hex: colorHex) ?? .controlAccentColor
    }
}

extension NSColor {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (with or without the leading `#`).
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }

        if string.count == 3 {
            string = string.map { "\($0)\($0)" }.joined()
        }

        guard let value = UInt64(string, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        switch string.count {
        case 6:
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = CGFloat((value & 0xFF000000) >> 24) / 255
            g = CGFloat((value & 0x00FF0000) >> 16) / 255
            b = CGFloat((value & 0x0000FF00) >> 8) / 255
            a = CGFloat(value & 0x000000FF) / 255
        default:
            return nil
        }

        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB` in sRGB, used when persisting tab colors.
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#2254A4" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
