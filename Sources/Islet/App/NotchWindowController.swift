import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel parked over the notch. It never takes focus,
/// floats above the menu bar on every Space and lets clicks through everywhere
/// except on the island itself.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    /// Only while the user types into the island (the timer duration): the panel takes
    /// the keyboard without activating Islet, and gives it back right after.
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts the first click (the app is never active) and turns
/// trackpad scrolls into discrete swipes.
final class IslandHostingView: NSHostingView<IslandRootView> {
    var onPointer: (() -> Void)?
    var onSwipe: ((SwipeDirection) -> Void)?
    /// File drags: horizontal offset from the centre while hovering (nil when gone),
    /// and the drop itself. Handled here in AppKit because SwiftUI's drop handlers do not
    /// reliably receive the drop in a panel that never becomes active.
    var onDragMove: ((CGFloat?) -> Void)?
    var onDrop: (([URL], CGFloat) -> Bool)?
    private var accum = CGSize.zero
    private var fired = false
    private var lastWheel = Date.distantPast

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func offset(_ info: NSDraggingInfo) -> CGFloat { convert(info.draggingLocation, from: nil).x - bounds.midX }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragMove?(offset(sender))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragMove?(offset(sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragMove?(nil) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls =
            sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let x = offset(sender)
        onDragMove?(nil)
        return onDrop?(urls, x) ?? false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.userInfo?["islet"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self, userInfo: ["islet": true]))
    }

    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); onPointer?() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onPointer?() }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onPointer?() }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let inverted = event.isDirectionInvertedFromDevice
        // Normalise to finger direction: +x right, +y down.
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        if event.phase.contains(.began) { accum = .zero; fired = false }
        if event.phase.isEmpty {
            // Mouse wheel: one notch = one swipe, rate limited.
            guard Date().timeIntervalSince(lastWheel) > 0.35, abs(dy) + abs(dx) > 0.5 else { return }
            lastWheel = Date()
            emit(dx: dx * 10, dy: dy * 10)
            return
        }
        accum.width += dx
        accum.height += dy
        if !fired, max(abs(accum.width), abs(accum.height)) > 28 {
            fired = true
            emit(dx: accum.width, dy: accum.height)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { accum = .zero; fired = false }
    }

    private func emit(dx: CGFloat, dy: CGFloat) {
        if abs(dx) > abs(dy) { onSwipe?(dx < 0 ? .left : .right) } else { onSwipe?(dy > 0 ? .down : .up) }
    }
}

final class NotchWindowController {
    let model: IslandModel
    private let panel = NotchPanel()
    private let host: IslandHostingView
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private var screen: NSScreen?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragging = false

    /// Canvas big enough for the largest expanded state plus its shadow.
    private let canvas = CGSize(width: 820, height: 300)

    init(model: IslandModel) {
        self.model = model
        host = IslandHostingView(rootView: IslandRootView(model: model))
        host.onPointer = { [weak self] in self?.pointerMoved() }
        host.onSwipe = { [weak self] in self?.model.swipe($0) }
        host.onDragMove = { [weak self] in self?.model.dragMoved(toOffset: $0) }
        host.onDrop = { [weak self] urls, x in self?.model.dropFiles(urls, atOffset: x) ?? false }
        host.registerForDraggedTypes([.fileURL])
        panel.contentView = host
        applyPrefs()
        place()
        panel.orderFrontRegardless()
        if Prefs.bool(Prefs.pinAcrossSpaces) { pinnedToSkyLight = SkyLight.pin(panel) }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place() }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                self?.panel.orderFrontRegardless()
                // Let the new Space settle before checking for a full-screen app.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.updateFullScreenVisibility(spaceChanged: true) }
            }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.updateFullScreenVisibility() }
            }
            .store(in: &bag)
        // A video can go full screen without the app or Space changing (a browser's player).
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.updateFullScreenVisibility() }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.place() }
            .store(in: &bag)
        // Hit region follows the target shape, so re-evaluate whenever it changes.
        model.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.pointerMoved() }
            .store(in: &bag)

        // Once the springs have settled, redraw the whole canvas: an inactive app's
        // transparent window can otherwise keep the last frame of a fading shadow.
        model.objectWillChange
            .debounce(for: .milliseconds(750), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.flushCanvas() }
            .store(in: &bag)

        model.$timerEditing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] editing in self?.setKeyboard(editing) }
            .store(in: &bag)

        installMonitors()
    }

    private func flushCanvas() {
        host.needsDisplay = true
        host.layer?.setNeedsDisplay()
        panel.display()
        panel.invalidateShadow()
    }

    private func setKeyboard(_ on: Bool) {
        panel.acceptsKeyboard = on
        if on {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
            NSWorkspace.shared.frontmostApplication?.activate()
        }
    }

    func applyPrefs() {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if Prefs.bool(Prefs.showInFullScreen) { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior
        panel.sharingType = Prefs.bool(Prefs.showInScreenshots) ? .readOnly : .none
        if screen != nil, Prefs.string(Prefs.islandStyle) != placedStyle { place() }
    }

    private var placedStyle = ""
    private var pinnedToSkyLight = false
    private var hiddenForFullScreen = false
    private var spaceLacksMenuBar = false

    /// A window in the pinned space ignores Spaces, full-screen ones included, so honour
    /// "show in full screen" by hand: hide while the app in front fills the whole screen
    /// (a full-screen app, or a video put full screen in the browser), or while the
    /// Space has no menu bar.
    private func updateFullScreenVisibility(spaceChanged: Bool = false) {
        guard let screen else { return }
        // The menu bar is only looked for right after a Space change: with "hide the menu
        // bar automatically" it is missing on ordinary desktops too, between changes.
        if spaceChanged { spaceLacksMenuBar = pinnedToSkyLight && !Self.menuBarVisible(on: screen) }
        let hide = !Prefs.bool(Prefs.showInFullScreen) && (Self.frontAppFillsScreen(screen) || spaceLacksMenuBar)
        guard hide != hiddenForFullScreen else { return }
        hiddenForFullScreen = hide
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = hide ? 0 : 1
        }
        if hide { panel.ignoresMouseEvents = true }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The frontmost app is full screen. macOS says so through Accessibility (a browser
    /// video put full screen counts too); without that permission, fall back to a window
    /// exactly the size of the screen.
    private static func frontAppFillsScreen(_ screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            var window: CFTypeRef?
            var full: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
                let window, CFGetTypeID(window) == AXUIElementGetTypeID()
            else { return false }
            let element = window as! AXUIElement
            guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &full) == .success else { return false }
            return (full as? Bool) == true
        }
        guard let id = displayID(screen),
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        let display = CGDisplayBounds(id)
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                (w[kCGWindowLayer as String] as? Int) == 0,
                let b = w[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return abs(r.minX - display.minX) < 1 && abs(r.minY - display.minY) < 1
                && abs(r.width - display.width) < 1 && abs(r.height - display.height) < 1
        }
    }

    private static func menuBarVisible(on screen: NSScreen) -> Bool {
        guard let id = displayID(screen),
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        let bounds = CGDisplayBounds(id)
        return windows.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.mainMenuWindow)),
                let b = w[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            return abs((b["Y"] ?? -1) - bounds.minY) < 1 && abs((b["X"] ?? -1) - bounds.minX) < 1
        }
    }

    /// The notched built-in display if there is one, otherwise the main screen. The style
    /// decides between hanging from the bezel (notch) and floating under the menu bar (island).
    private func place() {
        placedStyle = Prefs.string(Prefs.islandStyle)
        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }
        screen = target
        let f = target.frame
        let hasNotch = target.safeAreaInsets.top > 0
        let menuBar = hasNotch ? target.safeAreaInsets.top : max(24, f.maxY - target.visibleFrame.maxY)
        let detached = placedStyle == "island" || (placedStyle != "notch" && !hasNotch)
        var notch = CGSize(width: 185, height: menuBar)
        if detached {
            // A free island has no camera to dodge, only a narrow gap between its wings.
            notch = CGSize(width: 100, height: 32)
        } else if hasNotch, let l = target.auxiliaryTopLeftArea, let r = target.auxiliaryTopRightArea {
            notch = CGSize(width: f.width - l.width - r.width, height: target.safeAreaInsets.top)
        }
        let topInset: CGFloat = detached ? menuBar + 6 : 0
        model.setScreen(notch: notch, detached: detached, topInset: topInset)
        panel.setFrame(
            NSRect(
                x: f.midX - canvas.width / 2, y: f.maxY - canvas.height - topInset,
                width: canvas.width, height: canvas.height), display: true)
    }

    // MARK: Hit testing

    private func islandRect(padding: CGFloat) -> NSRect {
        guard let screen else { return .zero }
        // An island asleep still answers where it used to be.
        let g = model.islandAsleep ? model.wakeGeometry : model.targetGeometry
        var w = g.width + 2 * g.top
        if model.secondaryActivity != nil { w += 2 * (model.notch.height + 8) }
        let top = screen.frame.maxY - model.topInset
        let h = g.height + padding
        // +1 so the very top pixel row (where the cursor rests against the bezel) counts.
        return NSRect(x: screen.frame.midX + g.offset - w / 2 - padding, y: top - h, width: w + 2 * padding, height: h + 1)
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        let inside = !hiddenForFullScreen && islandRect(padding: model.isExpanded ? 4 : 2).contains(p)
        panel.ignoresMouseEvents = !(inside || dragging && model.dropTargeting)
        model.setHovering(inside)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.globalMove(e) }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.outsideClick() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in self?.dragEnded() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseUp,
            handler: { [weak self] e in
                self?.dragEnded(); return e
            })
        {
            monitors.append(m)
        }
    }

    private func globalMove(_ e: NSEvent) {
        if e.type == .leftMouseDragged { trackFileDrag() }
        pointerMoved()
    }

    private func outsideClick() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        guard model.isExpanded, !islandRect(padding: 4).contains(NSEvent.mouseLocation) else { return }
        model.collapse()
    }

    /// A Finder drag carrying files that comes near the notch opens the drop zone.
    private func trackFileDrag() {
        guard Prefs.bool(Prefs.shelfEnabled), let screen else { return }
        let pb = NSPasteboard(name: .drag)
        if !dragging {
            guard pb.changeCount != dragChangeCount,
                pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            else { return }
            dragging = true
            if pinnedToSkyLight { SkyLight.unpin(panel) }
        }
        let p = NSEvent.mouseLocation
        let zone = NSRect(x: screen.frame.midX - 300, y: screen.frame.maxY - 220, width: 600, height: 221)
        if zone.contains(p) {
            model.setDropTargeting(true)
            panel.ignoresMouseEvents = false
        }
    }

    private func dragEnded() {
        guard dragging else { return }
        dragging = false
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        // Let the drop land first, then fold the shelf and go back above the desktops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.model.setDropTargeting(false)
            self.pointerMoved()
            if self.pinnedToSkyLight { SkyLight.pin(self.panel) }
        }
    }
}
