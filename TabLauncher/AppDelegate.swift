import AppKit

/// Reads/writes the macOS four-finger pinch trackpad setting and can log the user out
/// so the change takes effect.
enum PinchGestureSetup {
    static let key = "TrackpadFourFingerPinchGesture"
    static let domains = [
        "com.apple.AppleMultitouchTrackpad",              // built-in trackpad
        "com.apple.driver.AppleBluetoothMultitouch.trackpad" // Magic Trackpad
    ]

    /// True when the pinch is turned off (0) everywhere it's configured. A domain with no
    /// value means that gesture is still on by default, so we offer to disable it.
    static var isDisabled: Bool {
        var sawValue = false
        for domain in domains {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int {
                sawValue = true
                if value != 0 { return false }
            }
        }
        return sawValue
    }

    static func disable() {
        for domain in domains {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            task.arguments = ["write", domain, key, "-int", "0"]
            try? task.run()
            task.waitUntilExit()
        }
    }

    static func logOut() {
        // «event aevtrlgo» is reallyLogOut — logs out immediately (we've already confirmed).
        let script = NSAppleScript(source: "tell application \"loginwindow\" to «event aevtrlgo»")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = LauncherStore()
    private var launcherController: FloatingLauncherController?
    private var pinchMonitor: PinchGestureMonitor?
    private var statusItem: NSStatusItem?
    private var finderIPC: FinderIPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon and no menu bar. The launcher stays hidden
        // until a four-finger pinch (or a global hotkey) reveals it.
        NSApp.setActivationPolicy(.accessory)

        // Accessory apps don't always resolve their bundle icon (e.g. for the About
        // panel); set it explicitly from the compiled AppIcon.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        let controller = FloatingLauncherController(store: store)
        launcherController = controller
        makeStatusItem()

        // The four-finger pinch is the only way to summon the launcher — no global hotkeys.
        let pinch = PinchGestureMonitor()
        pinch.onPinch = { [weak controller] in
            controller?.togglePresentation()
        }
        pinch.start()
        pinchMonitor = pinch

        startFinderIPC()

        // On first run, offer to free up the OS four-finger pinch (unless already done or
        // previously declined). Deferred so launch finishes before the modal appears.
        DispatchQueue.main.async { [weak self] in
            self?.maybeOfferPinchSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
        pinchMonitor?.stop()
    }

    /// Serves the Finder extension over a Mach message port: it answers with the current
    /// tabs and applies "add" requests. No files or App Group container are touched, so
    /// macOS never raises the "access data from other apps" prompt.
    private func startFinderIPC() {
        finderIPC = FinderIPCServer(
            tabsProvider: { [store] in store.tabs.map { .init(id: $0.id.uuidString, name: $0.title) } },
            addHandler: { [weak self] request in
                guard let self, let tabID = UUID(uuidString: request.tabID) else { return }
                for path in request.paths {
                    self.store.add(url: URL(fileURLWithPath: path), to: tabID)
                }
            }
        )
        finderIPC?.start()
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "Pad Launcher") {
            item.button?.image = image
        } else {
            item.button?.title = "Tabs"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About Pad Launcher", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Launcher", action: #selector(showLauncher), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide Launcher", action: #selector(hideLauncher), keyEquivalent: ""))
        // Available while the OS pinch is still enabled — the way back after "Not Now".
        if !PinchGestureSetup.isDisabled {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Free Up Four-finger Pinch…", action: #selector(freeUpPinch), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Pad Launcher", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    private func maybeOfferPinchSetup() {
        guard !PinchGestureSetup.isDisabled,
              !UserDefaults.standard.bool(forKey: "declinedPinchSetup") else { return }
        presentPinchOffer()
    }

    @objc private func freeUpPinch() {
        presentPinchOffer()
    }

    private func presentPinchOffer() {
        let alert = NSAlert()
        alert.messageText = "Free up the four-finger pinch for Pad Launcher?"
        alert.informativeText = """
        Pad Launcher opens when you pinch four fingers together on the trackpad. Right now macOS uses that same gesture to open Spotlight, so both will happen at once.

        Pad Launcher can turn off the system's four-finger pinch for you. This changes a Trackpad setting that only takes effect after you log out and back in.

        Save your work first — logging out will quit all your open apps. You can skip this and do it yourself later; Pad Launcher still works either way, the pinch will just also open Spotlight.
        """
        alert.addButton(withTitle: "Disable & Log Out…")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            confirmAndLogOut()
        } else {
            UserDefaults.standard.set(true, forKey: "declinedPinchSetup")
        }
    }

    private func confirmAndLogOut() {
        let alert = NSAlert()
        alert.messageText = "Log out now?"
        alert.informativeText = """
        Pad Launcher will turn off the four-finger pinch and log you out immediately. Any unsaved changes in open apps will be lost.

        If logging out doesn't start on its own, just log out manually (Apple menu → Log Out) — the setting is already saved and will take effect at your next login.
        """
        alert.addButton(withTitle: "Log Out Now")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.save()
        PinchGestureSetup.disable()
        PinchGestureSetup.logOut()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // Credits appear above the copyright line in the standard panel, so the byline
        // goes here and "RIP Launchpad…" is the copyright (set in Info.plist).
        let credits = NSAttributedString(
            string: "Rob Marquardt 2026",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        // Shows "Version 1.0" (empty `.version` omits the build number in parens).
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Pad Launcher",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .version: "",
            .credits: credits
        ]
        // Pass the icon explicitly (the panel otherwise caches a generic one in dev).
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            options[NSApplication.AboutPanelOptionKey(rawValue: "ApplicationIcon")] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func showLauncher() {
        launcherController?.present()
    }

    @objc private func hideLauncher() {
        launcherController?.dismiss()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Hosts the Mach message port the Finder extension talks to. Pure in-memory IPC — no
/// files, no App Group container access — so it never triggers a TCC data-access prompt.
@MainActor
final class FinderIPCServer {
    private let tabsProvider: @MainActor () -> [PadLauncherShared.TabSnapshot]
    private let addHandler: @MainActor (PadLauncherShared.AddRequest) -> Void
    private var port: CFMessagePort?

    init(tabsProvider: @escaping @MainActor () -> [PadLauncherShared.TabSnapshot],
         addHandler: @escaping @MainActor (PadLauncherShared.AddRequest) -> Void) {
        self.tabsProvider = tabsProvider
        self.addHandler = addHandler
    }

    func start() {
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // The callback is a C function pointer, so it must not capture; it recovers `self`
        // from the context `info` pointer. The port's run-loop source runs it on the main
        // thread, where touching the store and MainActor state is safe.
        let callback: CFMessagePortCallBack = { _, msgid, data, info in
            guard let info else { return nil }
            let server = Unmanaged<FinderIPCServer>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated { server.handle(msgid: msgid, data: data) }
        }
        guard let port = CFMessagePortCreateLocal(nil, PadLauncherShared.portName, callback, &context, nil) else {
            return
        }
        self.port = port
        if let source = CFMessagePortCreateRunLoopSource(nil, port, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func handle(msgid: Int32, data: CFData?) -> Unmanaged<CFData>? {
        switch PadLauncherShared.Message(rawValue: msgid) {
        case .getTabs:
            guard let encoded = try? JSONEncoder().encode(tabsProvider()) else { return nil }
            return Unmanaged.passRetained(encoded as CFData)
        case .addItems:
            if let data = data as Data?,
               let request = try? JSONDecoder().decode(PadLauncherShared.AddRequest.self, from: data) {
                addHandler(request)
            }
            return nil
        case .none:
            return nil
        }
    }
}
