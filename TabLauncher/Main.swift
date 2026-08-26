import AppKit

@MainActor
private var retainedAppDelegate: AppDelegate?

@main
enum TabLauncherMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedAppDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
