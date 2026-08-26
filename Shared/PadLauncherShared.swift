import Foundation

/// IPC bridge between the app and the Finder Sync extension.
///
/// This uses a Mach `CFMessagePort` rather than a shared App Group *file*. The port name is
/// prefixed with the app group identifier, which is what lets the sandboxed extension look
/// it up. Crucially, nothing here touches the group container on disk, so macOS never shows
/// the "…would like to access data from other apps" prompt (that prompt fires on
/// group-container filesystem access from a non-sandboxed app, and doesn't reliably persist).
///
/// Trade-off: the app must be running for the extension to fetch tabs or deliver an add.
/// The app is a background accessory, so it normally is.
enum PadLauncherShared {
    static let groupID = "group.com.toastbucket.PadLauncher"
    /// Prefixed with the app group id so the sandboxed extension is permitted to look it up.
    static let portName = "group.com.toastbucket.PadLauncher.ipc" as CFString

    enum Message: Int32 {
        case getTabs = 1
        case addItems = 2
    }

    struct TabSnapshot: Codable {
        let id: String
        let name: String
    }

    struct AddRequest: Codable {
        let tabID: String
        let paths: [String]
    }

    // MARK: Extension → app (client)

    /// Asks the running app for its current tabs. Returns `[]` if the app isn't running.
    static func requestTabs() -> [TabSnapshot] {
        guard let remote = CFMessagePortCreateRemote(nil, portName) else { return [] }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote, Message.getTabs.rawValue, nil,
            1.0, 1.0, CFRunLoopMode.defaultMode.rawValue, &reply
        )
        guard status == kCFMessagePortSuccess, let cfData = reply?.takeRetainedValue() else { return [] }
        return (try? JSONDecoder().decode([TabSnapshot].self, from: cfData as Data)) ?? []
    }

    /// Delivers an add request to the running app. Returns false if the app isn't running.
    @discardableResult
    static func sendAdd(_ request: AddRequest) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, portName),
              let data = try? JSONEncoder().encode(request) else { return false }
        let status = CFMessagePortSendRequest(
            remote, Message.addItems.rawValue, data as CFData,
            1.0, 0.0, nil, nil
        )
        return status == kCFMessagePortSuccess
    }
}
