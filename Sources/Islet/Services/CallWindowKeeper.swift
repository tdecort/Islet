import AppKit
import ApplicationServices

/// During a call, keeps the call app's windows drawable so ScreenCaptureKit always has
/// frames: macOS stops rendering a minimized or hidden window, so when the user
/// minimizes or hides it, the window is restored behind whatever app they were using.
/// Driven by Accessibility notifications; needs the Accessibility permission.
final class CallWindowKeeper {
    static let shared = CallWindowKeeper()

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var lastOtherApp: NSRunningApplication?
    private var activationToken: NSObjectProtocol?

    /// Start watching the given call app, or stop when nil.
    func watch(bundleID: String?) {
        stop()
        guard let bundleID, Prefs.bool(Prefs.keepCallCapturable), AXIsProcessTrusted(),
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        pid = app.processIdentifier
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let other = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                other.processIdentifier != self.pid, other.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            self.lastOtherApp = other
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid { lastOtherApp = front }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<CallWindowKeeper>.fromOpaque(refcon).takeUnretainedValue().handle(element, notification as String)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        observer = created
        let element = AXUIElementCreateApplication(pid)
        appElement = element
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXApplicationHiddenNotification, kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        windows().forEach { AXObserverAddNotification(created, $0, kAXWindowMiniaturizedNotification as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        // Already out of sight when the call was detected: bring it back behind.
        if app.isHidden { restoreHidden() }
        if windows().contains(where: isMinimized) { windows().filter(isMinimized).forEach(restore) }
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        appElement = nil
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
    }

    // MARK: Events

    private func handle(_ element: AXUIElement, _ notification: String) {
        switch notification {
        case kAXWindowMiniaturizedNotification:
            restore(element)
        case kAXApplicationHiddenNotification:
            restoreHidden()
        case kAXWindowCreatedNotification:
            if let observer {
                AXObserverAddNotification(observer, element, kAXWindowMiniaturizedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        default:
            break
        }
    }

    private func restore(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        sendBehind()
    }

    private func restoreHidden() {
        NSRunningApplication(processIdentifier: pid)?.unhide()
        sendBehind()
    }

    /// Hand focus back to the app the user was in, so the call window sits behind it.
    private func sendBehind() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.lastOtherApp?.activate()
            CallVideo.shared.restart()
        }
    }

    // MARK: AX helpers

    private func windows() -> [AXUIElement] {
        guard let appElement else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}
