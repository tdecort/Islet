import CoreAudio
import CoreGraphics
import Foundation

/// Default output device volume and mute, observed through CoreAudio listeners
/// (no polling). Changes caused by switching output device are flagged so the
/// HUD can ignore them.
final class SystemAudio: ObservableObject {
    static let shared = SystemAudio()

    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false

    /// Called for user-visible changes only (device switches are filtered out).
    var onChange: ((Float, Bool) -> Void)?

    private var device = AudioDeviceID(0)
    private var lastDeviceSwitch = Date.distantPast
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663  // 'vmvc'

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: SystemAudio.virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    func start() {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main) { [weak self] _, _ in
            self?.lastDeviceSwitch = Date()
            self?.attach()
        }
        attach()
    }

    private func attach() {
        if let block = deviceListener, device != 0 {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, .main, block)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, block)
        }
        device = Self.defaultOutput()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.read(notify: true) }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(device, &volumeAddress, .main, block)
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectAddPropertyListenerBlock(device, &muteAddress, .main, block)
        }
        read(notify: false)
    }

    private func read(notify: Bool) {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &v)
        var m = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &m)
        }
        let changed = abs(v - volume) > 0.001 || (m != 0) != muted
        volume = v
        muted = m != 0
        // Output switches (AirPods connecting, HDMI…) report their own level: not a user action.
        if notify, changed, Date().timeIntervalSince(lastDeviceSwitch) > 1.2 {
            onChange?(volume, muted)
        }
    }

    var canSetVolume: Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
    }

    func setVolume(_ value: Float) {
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if v > 0, muted { setMuted(false) }
        volume = v
    }

    func setMuted(_ on: Bool) {
        guard AudioObjectHasProperty(device, &muteAddress) else { return }
        var m = UInt32(on ? 1 : 0)
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        muted = on
    }

    private static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}

/// Built-in display brightness through the DisplayServices private framework
/// (resolved at runtime; every call is a no-op if it is missing).
enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count = UInt32(0)
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static func get() -> Float? {
        guard let getFn else { return nil }
        var v: Float = 0
        return getFn(display, &v) == 0 ? v : nil
    }

    static func set(_ value: Float) {
        _ = setFn?(display, min(1, max(0, value)))
    }
}
