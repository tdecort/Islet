import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    let services = Services()
    private(set) lazy var model = IslandModel(services: services)
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        notch = NotchWindowController(model: model)
        services.start(model: model)
        model.bind()
        updateStatusItem()

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
                self?.notch?.applyPrefs()
                self?.services.prefsChanged()
            }
            .store(in: &bag)
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        if Prefs.bool(Prefs.showMenuBarIcon) {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Islet")
            item.button?.image?.size = NSSize(width: 18, height: 9)
            let menu = NSMenu()
            menu.addItem(withTitle: "Islet Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Islet", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.toolbar = NSToolbar(identifier: "settings")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 680, height: 460)
            window.title = "Islet"
            window.contentViewController = NSHostingController(rootView: SettingsView(services: services))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}
