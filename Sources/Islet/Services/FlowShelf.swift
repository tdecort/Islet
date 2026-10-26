import AppKit
import SwiftUI

// MARK: - Flow timer

/// Pomodoro-style focus timer. Stores an end date instead of ticking: views read the
/// remaining time from a `TimelineView`, and a single timer fires at the phase end.
final class FlowTimer: ObservableObject {
    enum Phase: String, Equatable {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: return "Focus"
            case .shortBreak: return "Break"
            case .longBreak: return "Long break"
            }
        }

        var tint: Color { self == .focus ? Color(red: 1, green: 0.58, blue: 0.0) : Color(red: 0.2, green: 0.84, blue: 0.6) }
    }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var completed = 0
    @Published private(set) var isActive = false

    var onNotice: ((NoticeKind) -> Void)?
    private var timer: Timer?

    var isRunning: Bool { endDate != nil }

    func duration(_ p: Phase) -> TimeInterval {
        let minutes: Int
        switch p {
        case .focus: minutes = Prefs.int(Prefs.flowFocus)
        case .shortBreak: minutes = Prefs.int(Prefs.flowShort)
        case .longBreak: minutes = Prefs.int(Prefs.flowLong)
        }
        return TimeInterval(max(1, minutes) * 60)
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return pausedRemaining ?? duration(phase)
    }

    func progress(at date: Date = Date()) -> Double {
        1 - remaining(at: date) / duration(phase)
    }

    func toggle() {
        TimerAlarm.shared.stop()
        isRunning ? pause() : start()
    }

    /// Pick the focus length from the island; applies right away when idle.
    func setFocusMinutes(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: Prefs.flowFocus)
        guard !isRunning else { return }
        phase = .focus
        pausedRemaining = nil
        objectWillChange.send()
        Motion.haptic(.generic)
    }

    func start() {
        let r = pausedRemaining ?? duration(phase)
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(r)
        isActive = true
        arm()
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        timer?.invalidate()
    }

    func reset() {
        timer?.invalidate()
        endDate = nil
        pausedRemaining = nil
        phase = .focus
        completed = 0
        isActive = false
    }

    func skip() { advance(announce: false) }

    private func arm() {
        timer?.invalidate()
        guard let endDate else { return }
        let t = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in self?.advance(announce: true) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func advance(announce: Bool) {
        timer?.invalidate()
        if phase == .focus {
            completed += 1
            phase = completed % max(1, Prefs.int(Prefs.flowRounds)) == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        pausedRemaining = nil
        if Prefs.bool(Prefs.flowAutoContinue) || !announce {
            endDate = Date().addingTimeInterval(duration(phase))
            arm()
        } else {
            endDate = nil
            pausedRemaining = duration(phase)
        }
        if announce {
            if Prefs.bool(Prefs.flowSound) { TimerAlarm.shared.ring() }
            onNotice?(.flowPhase(phase))
        }
    }
}

// MARK: - Shelf

/// Files dropped on the notch. Kept by path across launches; files that disappear
/// are dropped silently.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []
    var onNotice: ((NoticeKind) -> Void)?

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Prefs.shelfItems) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        let fresh = urls.filter { !items.contains($0) }
        guard !fresh.isEmpty else { return }
        withAnimation(Motion.content) { items.append(contentsOf: fresh) }
        save()
    }

    func remove(_ url: URL) {
        withAnimation(Motion.content) { items.removeAll { $0 == url } }
        save()
    }

    func clear() {
        withAnimation(Motion.content) { items.removeAll() }
        save()
    }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: Prefs.shelfItems)
    }
}
