import Foundation
import QuartzCore

// Global four-finger pinch-in detector built on the private MultitouchSupport
// framework. This is an "unsanctioned" API (used by BetterTouchTool, Multitouch,
// MiddleClick, etc.): it delivers raw trackpad contacts globally, on a background
// thread, with no Accessibility permission and regardless of the frontmost app.
//
// MultitouchSupport only *observes* — it does not suppress the system's own use of
// the gesture. To make the pinch open Tab Launcher instead of Launchpad, disable the
// Launchpad gesture in System Settings -> Trackpad -> More Gestures.

// MARK: - Reverse-engineered MultitouchSupport structs

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

// Canonical `Finger`/`MTTouch` layout (96 bytes). Stable across macOS releases to
// date. We only read `normalized.position`, but the full struct must be declared so
// the per-finger stride is correct when indexing the contact array.
private struct MTFinger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    var normalized: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var zero2: Int32
    var zero3: Int32
    var density: Float
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
// The contact array is passed as a raw pointer: `MTFinger` is a Swift struct and
// isn't representable in an `@convention(c)` signature, so we bind memory ourselves.
private typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterFn = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTStartFn = @convention(c) (MTDeviceRef?, Int32) -> Void
private typealias MTStopFn = @convention(c) (MTDeviceRef?) -> Void
private typealias MTUnregisterFn = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void

// Non-capturing C callback: routes each contact frame to the active monitor.
private let pinchContactCallback: MTContactCallback = { _, contacts, numFingers, timestamp, _ in
    PinchGestureMonitor.active?.handleFrame(contacts: contacts, numFingers: Int(numFingers), timestamp: timestamp)
    return 0
}

/// Detects a deliberate four-finger pinch-in and calls `onPinch` on the main thread.
final class PinchGestureMonitor {
    /// The monitor currently receiving contact frames (only one is expected).
    fileprivate static weak var active: PinchGestureMonitor?

    /// Number of simultaneous fingers required for the gesture.
    var fingerCount = 4
    /// How much the fingers must converge (in normalized 0...1 trackpad units,
    /// measured as mean distance to the contact centroid) to count as a pinch-in.
    var pinchInThreshold: Float = 0.09
    /// Minimum seconds between two triggers.
    var cooldown: Double = 0.6

    /// Invoked on the main thread when a pinch-in is recognized.
    var onPinch: (() -> Void)?

    // MultitouchSupport entry points (nil if the framework failed to load).
    private var handle: UnsafeMutableRawPointer?
    private var registerFn: MTRegisterFn?
    private var startFn: MTStartFn?
    private var stopFn: MTStopFn?
    private var unregisterFn: MTUnregisterFn?
    private var devices: [MTDeviceRef] = []

    // Detection state — only touched on the MultitouchSupport callback thread.
    private var tracking = false
    private var referenceSpread: Float = 0
    private var lastFireTime: Double = 0

    func start() {
        guard handle == nil else { return }

        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            NSLog("PinchGestureMonitor: failed to load MultitouchSupport")
            return
        }
        self.handle = handle

        guard let createList = symbol("MTDeviceCreateList", MTDeviceCreateListFn.self),
              let register = symbol("MTRegisterContactFrameCallback", MTRegisterFn.self),
              let start = symbol("MTDeviceStart", MTStartFn.self) else {
            NSLog("PinchGestureMonitor: missing MultitouchSupport symbols")
            return
        }
        registerFn = register
        startFn = start
        stopFn = symbol("MTDeviceStop", MTStopFn.self)
        unregisterFn = symbol("MTUnregisterContactFrameCallback", MTUnregisterFn.self)

        guard let list = createList()?.takeRetainedValue() else {
            NSLog("PinchGestureMonitor: no multitouch devices")
            return
        }

        PinchGestureMonitor.active = self

        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = MTDeviceRef(mutating: raw)
            register(device, pinchContactCallback)
            start(device, 0)
            devices.append(device)
        }
    }

    func stop() {
        for device in devices {
            stopFn?(device)
            unregisterFn?(device, pinchContactCallback)
        }
        devices.removeAll()
        if PinchGestureMonitor.active === self {
            PinchGestureMonitor.active = nil
        }
        if let handle {
            dlclose(handle)
            self.handle = nil
        }
    }

    deinit {
        stop()
    }

    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    // Called on the MultitouchSupport background thread.
    fileprivate func handleFrame(contacts: UnsafeMutableRawPointer?, numFingers: Int, timestamp: Double) {
        guard numFingers == fingerCount, let contacts else {
            tracking = false
            return
        }
        let fingers = contacts.bindMemory(to: MTFinger.self, capacity: numFingers)

        var centerX: Float = 0
        var centerY: Float = 0
        for i in 0..<numFingers {
            centerX += fingers[i].normalized.position.x
            centerY += fingers[i].normalized.position.y
        }
        let n = Float(numFingers)
        centerX /= n
        centerY /= n

        var spread: Float = 0
        for i in 0..<numFingers {
            let dx = fingers[i].normalized.position.x - centerX
            let dy = fingers[i].normalized.position.y - centerY
            spread += (dx * dx + dy * dy).squareRoot()
        }
        spread /= n

        if !tracking {
            tracking = true
            referenceSpread = spread
            return
        }

        // Track the widest spread so a pinch from any starting openness registers.
        if spread > referenceSpread {
            referenceSpread = spread
        }

        if referenceSpread - spread >= pinchInThreshold, timestamp - lastFireTime > cooldown {
            lastFireTime = timestamp
            tracking = false // require fingers to re-open before the next trigger
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onPinch?()
                }
            }
        }
    }
}
