import CoreGraphics
import Foundation

/// Built-in display brightness via the private `DisplayServices` framework —
/// the only route that still works on Apple silicon (IOKit's `IODisplay`
/// brightness parameter is not exposed for the internal panel).
@MainActor
final class SystemBrightness {

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private let handle: UnsafeMutableRawPointer?
    private let getFn: GetFn?
    private let setFn: SetFn?

    /// The internal panel; falls back to the main display.
    private var display: CGDirectDisplayID = CGMainDisplayID()

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getFn = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        display = Self.builtInDisplay() ?? CGMainDisplayID()
    }

    var isAvailable: Bool { getFn != nil && setFn != nil }

    var brightness: Float {
        get {
            guard let getFn else { return 0 }
            var value: Float = 0
            guard getFn(display, &value) == 0 else { return 0 }
            return value
        }
        set {
            guard let setFn else { return }
            _ = setFn(display, max(0, min(1, newValue)))
        }
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? ids.first
    }
}
