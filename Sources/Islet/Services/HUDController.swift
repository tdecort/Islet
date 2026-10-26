import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "app.islet.Islet", category: "hud")

/// Volume and brightness HUD.
///
/// With Accessibility permission, the hardware keys are intercepted through an event
/// tap and the system OSD never appears: Islet applies the change itself and shows
/// its own HUD. Without the permission it falls back to listening (volume only),
/// next to the system OSD.
final class HUDController {
    var onShow: ((HUDKind, Double, Bool) -> Void)?

    private let tap = MediaKeyTap()
    private var trustTimer: Timer?
    private var lastKeyHandled = Date.distantPast
    private var passiveMonitor: Any?
    private var prompted = false

    func start() {
        SystemAudio.shared.onChange = { [weak self] volume, muted in
            // Our own key handling already showed the HUD.
            guard let self, Date().timeIntervalSince(self.lastKeyHandled) > 0.4 else { return }
            self.onShow?(.volume, Double(volume), muted)
        }
        tap.handler = { [weak self] key, down, modifiers in self?.handle(key, down: down, modifiers: modifiers) ?? false }
        syncTap()
    }

    /// Start or stop the tap to match preferences and permission.
    func syncTap() {
        let wanted = Prefs.bool(Prefs.hudEnabled) && Prefs.bool(Prefs.hudReplaceSystem)
        let trusted = AXIsProcessTrusted()
        if wanted, trusted {
            trustTimer?.invalidate(); trustTimer = nil
            if !tap.isRunning {
                tap.start()
                log.notice("media key tap \(self.tap.isRunning ? "running" : "failed to start", privacy: .public)")
            }
            removePassive()
        } else {
            if tap.isRunning || trustTimer == nil {
                log.notice("system HUD not replaced: wanted=\(wanted, privacy: .public) accessibility=\(trusted, privacy: .public)")
            }
            // Ask once per launch through the system prompt: it registers exactly this
            // signed app in Privacy & Security, which a hand-added entry may not.
            if wanted, !prompted {
                prompted = true
                Self.requestAccessibility()
            }
            tap.stop()
            installPassive()
            if wanted, trustTimer == nil {
                // Wait for the user to grant Accessibility, then switch over without a relaunch.
                trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    if AXIsProcessTrusted() { self?.syncTap() }
                }
            }
        }
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Without a tap we can still notice brightness keys and read the new level.
    private func installPassive() {
        guard passiveMonitor == nil else { return }
        passiveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] e in
            guard e.subtype.rawValue == 8 else { return }
            let code = (e.data1 & 0xFFFF_0000) >> 16
            guard code == MediaKey.brightnessUp.rawValue || code == MediaKey.brightnessDown.rawValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if Prefs.bool(Prefs.hudEnabled), let b = Brightness.get() { self?.onShow?(.brightness, Double(b), false) }
            }
        }
    }

    private func removePassive() {
        if let m = passiveMonitor { NSEvent.removeMonitor(m) }
        passiveMonitor = nil
    }

    /// Returns true when the event is consumed.
    private func handle(_ key: MediaKey, down: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Swallow key-ups too so the system never sees half a keystroke.
        guard down else { return true }
        // Option+Shift gives quarter steps, like macOS.
        let fine = modifiers.contains(.option) && modifiers.contains(.shift)
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        lastKeyHandled = Date()
        let audio = SystemAudio.shared
        switch key {
        case .soundUp, .soundDown:
            guard audio.canSetVolume else { return false }
            let delta = key == .soundUp ? step : -step
            let v = (audio.volume / step).rounded() * step + delta
            audio.setVolume(v)
            if v <= 0 { audio.setMuted(true) }
            onShow?(.volume, Double(audio.volume), audio.muted)
        case .mute:
            audio.setMuted(!audio.muted)
            onShow?(.volume, Double(audio.volume), audio.muted)
        case .brightnessUp, .brightnessDown:
            guard let current = Brightness.get() else { return false }
            let delta = key == .brightnessUp ? step : -step
            let v = min(1, max(0, (current / step).rounded() * step + delta))
            Brightness.set(v)
            onShow?(.brightness, Double(v), false)
        }
        return true
    }
}

enum MediaKey: Int {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

/// CGEvent tap on NX_SYSDEFINED events (media keys).
final class MediaKeyTap {
    var handler: ((MediaKey, Bool, NSEvent.ModifierFlags) -> Bool)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { port != nil }

    func start() {
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                },
                userInfo: refcon)
        else { return }
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = ns.data1
        let code = (data & 0xFFFF_0000) >> 16
        let state = (data & 0x0000_FF00) >> 8
        guard let key = MediaKey(rawValue: code), state == 0xA || state == 0xB else {
            // Special keys Islet does not handle yet (Focus, dictation…), to learn their codes.
            if state == 0xA { log.notice("unhandled special key code \(code, privacy: .public)") }
            return Unmanaged.passUnretained(event)
        }
        let consumed = handler?(key, state == 0xA, ns.modifierFlags) ?? false
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}
