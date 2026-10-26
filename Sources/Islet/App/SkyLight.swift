import AppKit

/// Moves a window into a private, always-shown SkyLight space that sits above the user's
/// desktops, so it no longer slides away during a three-finger Space swipe. This is the
/// window server API notch apps rely on for that; it is private, so every symbol is
/// resolved at runtime and the call is a no-op when one is missing.
enum SkyLight {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }

    private static var space: UInt64?

    /// Returns true when the window now lives in the pinned space.
    @discardableResult
    static func pin(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0,
            let connection = symbol("SLSMainConnectionID", MainConnectionFn.self),
            let create = symbol("SLSSpaceCreate", SpaceCreateFn.self),
            let setLevel = symbol("SLSSpaceSetAbsoluteLevel", SetAbsoluteLevelFn.self),
            let show = symbol("SLSShowSpaces", ShowSpacesFn.self),
            let add = symbol("SLSAddWindowsToSpaces", AddWindowsFn.self)
        else { return false }
        let cid = connection()
        if space == nil {
            let id = create(cid, 1, nil)
            guard id != 0 else { return false }
            _ = setLevel(cid, id, 100)
            _ = show(cid, [NSNumber(value: id)] as CFArray)
            space = id
        }
        guard let space else { return false }
        add(cid, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
        return true
    }

    /// Back onto the current desktop. Drag and drop ignores windows in the pinned space,
    /// so the island steps out of it while a file is being dragged.
    static func unpin(_ window: NSWindow) {
        guard let space, window.windowNumber > 0,
            let connection = symbol("SLSMainConnectionID", MainConnectionFn.self),
            let remove = symbol("SLSRemoveWindowsFromSpaces", AddWindowsFn.self),
            let add = symbol("SLSAddWindowsToSpaces", AddWindowsFn.self),
            let active = symbol("SLSGetActiveSpace", ActiveSpaceFn.self)
        else { return }
        let cid = connection()
        let current = active(cid)
        guard current != 0 else { return }
        let windows = [NSNumber(value: window.windowNumber)] as CFArray
        add(cid, windows, [NSNumber(value: current)] as CFArray)
        remove(cid, windows, [NSNumber(value: space)] as CFArray)
    }
}
