import AppKit
import SwiftUI

/// Owns every system integration and routes their events into the island.
final class Services {
    let nowPlaying = NowPlayingService()
    let audio = SystemAudio.shared
    let hud = HUDController()
    let battery = BatteryMonitor()
    let bluetooth = BluetoothMonitor()
    let focus = FocusMonitor()
    let calendar = CalendarService()
    let weather = WeatherService()
    let flow = FlowTimer()
    let shelf = ShelfStore()
    let claude = ClaudeMonitor()
    let call = CallMonitor.shared
    let session = SessionMonitor()

    private weak var model: IslandModel?

    func start(model: IslandModel) {
        self.model = model
        let notify: (NoticeKind) -> Void = { [weak model] kind in model?.notify(kind) }

        hud.onShow = { [weak model] kind, value, muted in
            guard Prefs.bool(Prefs.hudEnabled) else { return }
            model?.show(.hud(kind, value, muted: muted), duration: max(0.6, Prefs.double(Prefs.hudDuration)))
        }
        battery.onNotice = notify
        bluetooth.onNotice = notify
        focus.onNotice = notify
        calendar.onNotice = notify
        flow.onNotice = notify
        shelf.onNotice = notify
        claude.onNotice = notify
        session.onUnlock = { if Prefs.bool(Prefs.unlockAnimation) { notify(.unlocked) } }

        audio.start()
        hud.start()
        nowPlaying.start()
        battery.start()
        bluetooth.start()
        focus.start()
        calendar.startIfAuthorized()
        claude.start()
        call.start()
        session.start()
    }

    func prefsChanged() {
        hud.syncTap()
        claude.prefsChanged()
    }

    /// Lazily wake services that cost something (permissions, network) the first
    /// time their page is actually shown.
    func pageWillAppear(_ page: Page) {
        switch page {
        case .calendar: calendar.requestAccess()
        case .weather: weather.refreshIfStale()
        case .claude: claude.refreshUsage(force: false)
        case .nowPlaying: nowPlaying.resync()
        default: break
        }
    }
}

/// Screen lock / unlock.
final class SessionMonitor {
    var onUnlock: (() -> Void)?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func unlocked() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.onUnlock?() }
    }
}
