import AppKit
import CoreAudio
import CoreMediaIO

/// Detects an ongoing call (FaceTime, Zoom, Teams…) without any permission: a call app is
/// running *and* a microphone is in use somewhere. The camera only tells video from audio.
/// Everything is driven by CoreAudio / CoreMediaIO property listeners and workspace
/// notifications — nothing is polled.
final class CallMonitor: ObservableObject {
    static let shared = CallMonitor()

    struct App: Equatable {
        let bundleID: String
        let name: String
    }

    static let knownApps: [App] = [
        App(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        App(bundleID: "us.zoom.xos", name: "Zoom"),
        App(bundleID: "com.microsoft.teams2", name: "Teams"),
        App(bundleID: "com.microsoft.teams", name: "Teams"),
        App(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        App(bundleID: "com.hnc.Discord", name: "Discord"),
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        App(bundleID: "com.skype.skype", name: "Skype"),
    ]

    @Published private(set) var isActive = false
    @Published private(set) var app: App?
    @Published private(set) var cameraOn = false
    @Published private(set) var micMuted = false
    @Published private(set) var startedAt: Date?

    private var micRunning = false
    private var settle: DispatchWorkItem?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var listenedAudio: [AudioObjectID] = []
    private var cameraListener: CMIOObjectPropertyListenerBlock?
    private var listenedCameras: [CMIOObjectID] = []
    private var muteDevice = AudioObjectID(0)
    private var mutedByIslet: AudioObjectID?
    private var launchChecked = false
    private static let startKey = "callStartedAt"

    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var inputMuteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    private var cameraRunningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))

    func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &a, .main) { [weak self] _, _ in self?.attachAudio() }
        }
        var cams = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cams, .main) { [weak self] _, _ in self?.attachCameras() }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(self, selector: #selector(appsChanged), name: name, object: nil)
        }
        attachAudio()
        attachCameras()
    }

    @objc private func appsChanged() { evaluate() }

    // MARK: Listeners

    private func attachAudio() {
        if let block = audioListener {
            for id in listenedAudio {
                AudioObjectRemovePropertyListenerBlock(id, &runningAddress, .main, block)
                AudioObjectRemovePropertyListenerBlock(id, &inputMuteAddress, .main, block)
            }
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
        audioListener = block
        listenedAudio = Self.inputDevices()
        for id in listenedAudio {
            AudioObjectAddPropertyListenerBlock(id, &runningAddress, .main, block)
            if AudioObjectHasProperty(id, &inputMuteAddress) {
                AudioObjectAddPropertyListenerBlock(id, &inputMuteAddress, .main, block)
            }
        }
        muteDevice = Self.defaultInput()
        evaluate()
    }

    private func attachCameras() {
        if let block = cameraListener {
            for id in listenedCameras { CMIOObjectRemovePropertyListenerBlock(id, &cameraRunningAddress, .main, block) }
        }
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
        cameraListener = block
        listenedCameras = Self.cameras()
        for id in listenedCameras { CMIOObjectAddPropertyListenerBlock(id, &cameraRunningAddress, .main, block) }
        evaluate()
    }

    // MARK: State

    /// The microphone the call is really using: the running input device, else the default.
    /// (An iPhone can be listed as an input too, so "default" is not enough.)
    private var activeInput: AudioObjectID {
        listenedAudio.first { flag(audio: $0, &runningAddress) && AudioObjectHasProperty($0, &inputMuteAddress) } ?? muteDevice
    }

    private func evaluate() {
        micRunning = listenedAudio.contains { flag(audio: $0, &runningAddress) }
        let camera = listenedCameras.contains { id in
            var v = UInt32(0)
            var used = UInt32(0)
            return CMIOObjectGetPropertyData(id, &cameraRunningAddress, 0, nil, 4, &used, &v) == 0 && v != 0
        }
        let muted = flag(audio: activeInput, &inputMuteAddress)
        if camera != cameraOn { cameraOn = camera }
        if muted != micMuted { micMuted = muted }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let callApp = Self.knownApps.first { running.contains($0.bundleID) }
        // Starting needs a microphone (FaceTime previews the camera while idle); once going,
        // a call survives on the camera alone and through short microphone drop-outs.
        let live = Prefs.bool(Prefs.callEnabled) && callApp != nil && (isActive ? micRunning || camera : micRunning)
        if !launchChecked {
            launchChecked = true
            if !live { UserDefaults.standard.removeObject(forKey: Self.startKey) }
        }
        guard live != isActive else {
            if isActive, callApp != app { app = callApp }
            settle?.cancel()
            return
        }
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if live {
                self.startedAt = Self.resumableStart() ?? Date()
                UserDefaults.standard.set(self.startedAt?.timeIntervalSince1970, forKey: Self.startKey)
            } else {
                self.startedAt = nil
                UserDefaults.standard.removeObject(forKey: Self.startKey)
                self.restoreMicrophone()
            }
            self.app = live ? callApp : nil
            self.isActive = live
            CallWindowKeeper.shared.watch(bundleID: live ? callApp?.bundleID : nil)
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (live ? 1.0 : 6.0), execute: work)
    }

    /// The real start of a call that was already running when Islet (re)launched.
    private static func resumableStart() -> Date? {
        let t = UserDefaults.standard.double(forKey: startKey)
        guard t > 0 else { return nil }
        let date = Date(timeIntervalSince1970: t)
        return Date().timeIntervalSince(date) < 6 * 3600 ? date : nil
    }

    func toggleMute() {
        let device = activeInput
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &inputMuteAddress, &settable) == noErr, settable.boolValue else { return }
        // Flip the device's real state, never a cached one, then read back what stuck.
        var v = UInt32(flag(audio: device, &inputMuteAddress) ? 0 : 1)
        AudioObjectSetPropertyData(device, &inputMuteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        micMuted = flag(audio: device, &inputMuteAddress)
        mutedByIslet = micMuted ? device : nil
        Motion.haptic(.generic)
    }

    /// Never leave the Mac's microphone muted system-wide after the call that needed it.
    private func restoreMicrophone() {
        guard let device = mutedByIslet else { return }
        mutedByIslet = nil
        var v = UInt32(0)
        AudioObjectSetPropertyData(device, &inputMuteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        micMuted = false
    }

    func showApp() {
        guard let id = app?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func loadPreview(camera: Bool, muted: Bool) {
        app = Self.knownApps[0]
        cameraOn = camera
        micMuted = muted
        startedAt = Date().addingTimeInterval(-754)
        isActive = true
    }

    // MARK: Device lists

    private func flag(audio id: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard id != 0, AudioObjectHasProperty(id, &address) else { return false }
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &v) == noErr && v != 0
    }

    private static func inputDevices() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var n = UInt32(0)
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr && n > 0
        }
    }

    private static func defaultInput() -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private static func cameras() -> [CMIOObjectID] {
        var a = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size = UInt32(0)
        CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &a, 0, nil, &size)
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used = UInt32(0)
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &a, 0, nil, size, &used, &ids)
        return ids
    }
}
