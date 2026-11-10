import AppKit

// MARK: - objc_msgSend bridge
//
// The Touch Bar takeover lives on private *class* methods of NSTouchBar and
// NSTouchBarItem. They cannot be reached with `as?` to an @objc protocol: that
// performs a real conformance check, the classes never declare conformance, and
// the cast silently yields nil — the calls vanish with no error at all.
// Sending the message directly is the only honest way in.

private let objcMsgSend: UnsafeMutableRawPointer? = {
    guard let image = dlopen(nil, RTLD_LAZY) else { return nil }
    return dlsym(image, "objc_msgSend")
}()

private typealias MsgSendObj = @convention(c) (AnyObject?, Selector, AnyObject?) -> Void
private typealias MsgSendObjIntObj = @convention(c) (AnyObject?, Selector, AnyObject?, Int64, AnyObject?) -> Void

private func send(_ target: AnyObject, _ selector: Selector, _ argument: AnyObject) -> Bool {
    guard let objcMsgSend, target.responds(to: selector) else { return false }
    unsafeBitCast(objcMsgSend, to: MsgSendObj.self)(target, selector, argument)
    return true
}

private func send(_ target: AnyObject, _ selector: Selector,
                  _ first: AnyObject, _ second: Int64, _ third: AnyObject) -> Bool {
    guard let objcMsgSend, target.responds(to: selector) else { return false }
    unsafeBitCast(objcMsgSend, to: MsgSendObjIntObj.self)(target, selector, first, second, third)
    return true
}

// MARK: - DFRFoundation

/// The private `DFRFoundation` entry points that let a third-party process own
/// the Touch Bar. Verified present on macOS 26.5.
enum DFR {

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    private typealias ShowsCloseBoxFn = @convention(c) (Bool) -> Void
    private typealias SetControlStripPresenceFn = @convention(c) (NSString, Bool) -> Void

    static var isAvailable: Bool { handle != nil }

    /// When our modal bar is front-most, should macOS draw its own close box?
    /// We provide our own chrome, so: no.
    static func showsCloseBoxWhenFrontMost(_ shows: Bool) {
        guard let h = handle, let sym = dlsym(h, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        unsafeBitCast(sym, to: ShowsCloseBoxFn.self)(shows)
    }

    /// Pins (or unpins) our tray item inside the system Control Strip.
    static func setControlStripPresence(_ identifier: String, present: Bool) {
        guard let h = handle, let sym = dlsym(h, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        unsafeBitCast(sym, to: SetControlStripPresenceFn.self)(identifier as NSString, present)
    }
}

// MARK: - NSTouchBarItem / NSTouchBar private class methods

extension NSTouchBarItem {
    @discardableResult
    static func addToSystemTray(_ item: NSTouchBarItem) -> Bool {
        send(NSTouchBarItem.self as AnyObject, Selector(("addSystemTrayItem:")), item)
    }

    @discardableResult
    static func removeFromSystemTray(_ item: NSTouchBarItem) -> Bool {
        send(NSTouchBarItem.self as AnyObject, Selector(("removeSystemTrayItem:")), item)
    }
}

extension NSTouchBar {
    /// `placement: 1` takes over the whole strip, above whatever app is front —
    /// which is the point: the bar must not depend on who is active.
    /// `placement: 0` leaves the system Control Strip visible on the right.
    @discardableResult
    static func presentSystemModal(_ bar: NSTouchBar, placement: Int64,
                                   systemTrayItemIdentifier id: NSTouchBarItem.Identifier) -> Bool {
        send(NSTouchBar.self as AnyObject,
             Selector(("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")),
             bar, placement, id.rawValue as NSString)
    }

    @discardableResult
    static func dismissSystemModal(_ bar: NSTouchBar) -> Bool {
        send(NSTouchBar.self as AnyObject, Selector(("dismissSystemModalTouchBar:")), bar)
    }
}
