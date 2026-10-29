import OSLog
import AppKit
import CoreBluetooth
import IOBluetooth
import IOKit.ps
import SwiftUI

// MARK: - Battery

/// Power source changes pushed by IOKit (no polling): charger plugged in, low battery
/// crossing, Low Power Mode. Ambient brightness and other noise never reach here.
final class BatteryMonitor: ObservableObject {
    @Published private(set) var percent = 100
    @Published private(set) var onAC = true
    @Published private(set) var charging = false
    @Published private(set) var hasBattery = false

    func loadPreview(percent: Int, charging: Bool) {
        hasBattery = true
        self.percent = percent
        onAC = charging
        self.charging = charging
    }
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var onNotice: ((NoticeKind) -> Void)?
    private var source: CFRunLoopSource?
    private var primed = false

    var symbol: String {
        if charging || onAC { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var tint: Color {
        if lowPower { return .yellow }
        if onAC || charging { return .green }
        return percent <= 20 ? .red : .white
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource(
            { ctx in
                guard let ctx else { return }
                Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().refresh()
            }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
        refresh()
        primed = true
    }

    @objc private func powerStateChanged() {
        DispatchQueue.main.async {
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard on != self.lowPower else { return }
            self.lowPower = on
            if Prefs.bool(Prefs.batteryNotify), Prefs.bool(Prefs.batteryLowPower) { self.onNotice?(.lowPower(on)) }
        }
    }

    private func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                (d["Type"] as? String) == "InternalBattery"
            else { continue }
            let current = d["Current Capacity"] as? Int ?? 0
            let max = d["Max Capacity"] as? Int ?? 100
            let pct = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let ac = (d["Power Source State"] as? String) == "AC Power"
            let isCharging = d["Is Charging"] as? Bool ?? false
            let wasAC = onAC, previous = percent
            hasBattery = true
            percent = pct
            onAC = ac
            charging = isCharging
            guard primed, Prefs.bool(Prefs.batteryNotify) else { return }
            if ac, !wasAC {
                onNotice?(.charging(pct))
            } else if !ac {
                let threshold = Prefs.int(Prefs.batteryLowThreshold)
                if (previous > threshold && pct <= threshold) || (previous > 10 && pct <= 10) {
                    onNotice?(.lowBattery(pct))
                }
            }
            return
        }
    }
}

// MARK: - Bluetooth

private let bluetoothLog = Logger(subsystem: "app.islet.Islet", category: "bluetooth")

/// Bluetooth connect / disconnect. AirPods expose left, right and case levels through
/// IOBluetoothDevice selectors that are probed before use.
final class BluetoothMonitor: NSObject, CBCentralManagerDelegate {
    var onNotice: ((NoticeKind) -> Void)?
    private var connectNote: IOBluetoothUserNotification?
    private var central: CBCentralManager?
    /// Devices already connected when Islet started listening: the registration replays
    /// them, and they are not news.
    private var connectedAtStart = Set<String>()
    /// Last announcement per device: one connection can be reported more than once.
    private var lastConnect: [String: Date] = [:]
    private var lastDisconnect: [String: Date] = [:]

    /// IOBluetooth blocks its calling thread until Bluetooth access is decided, and the
    /// permission prompt itself needs the main thread. So access is requested first,
    /// asynchronously, through CoreBluetooth; IOBluetooth is touched only once granted.
    func start() {
        bluetoothLog.notice("bluetooth access: \(CBCentralManager.authorization.rawValue, privacy: .public)")
        switch CBCentralManager.authorization {
        case .allowedAlways:
            register()
        case .notDetermined:
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        default:
            break
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBCentralManager.authorization != .notDetermined else { return }
        self.central = nil
        if CBCentralManager.authorization == .allowedAlways { register() }
    }

    private func register() {
        guard connectNote == nil else { return }
        connectedAtStart = Set(((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter { $0.isConnected() }.compactMap(\.addressString))
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        bluetoothLog.notice("connected: \(device.name ?? "?", privacy: .public) as \(Self.symbol(for: device), privacy: .public)")
        let address = device.addressString ?? device.name ?? "?"
        if connectedAtStart.remove(address) != nil { return }
        if let last = lastConnect[address], Date().timeIntervalSince(last) < 5 { return }
        lastConnect[address] = Date()
        guard Prefs.bool(Prefs.bluetoothNotify) else { return }
        // Battery levels arrive a moment after the link comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let battery = DeviceBattery(
                left: Self.level(device, "batteryPercentLeft"),
                right: Self.level(device, "batteryPercentRight"),
                caseLevel: Self.level(device, "batteryPercentCase"),
                single: Self.level(device, "batteryPercentSingle"))
            let symbol = Self.symbol(for: device)
            guard symbol != Self.unknownSymbol else { return }
            self?.onNotice?(.deviceConnected(name: device.name ?? "Device", symbol: symbol, battery: battery))
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        bluetoothLog.notice("disconnected: \(device.name ?? "?", privacy: .public)")
        let address = device.addressString ?? device.name ?? "?"
        connectedAtStart.remove(address)
        if let last = lastDisconnect[address], Date().timeIntervalSince(last) < 5 { return }
        lastDisconnect[address] = Date()
        guard Prefs.bool(Prefs.bluetoothNotify) else { return }
        let symbol = Self.symbol(for: device)
        guard symbol != Self.unknownSymbol else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onNotice?(.deviceDisconnected(name: device.name ?? "Device", symbol: symbol))
        }
    }

    private static func level(_ d: IOBluetoothDevice, _ key: String) -> Int? {
        guard d.responds(to: NSSelectorFromString(key)), let n = d.value(forKey: key) as? NSNumber, n.intValue > 0 else { return nil }
        return n.intValue
    }

    static func symbol(for d: IOBluetoothDevice) -> String {
        let name = (d.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") || name.contains("clavier") { return "keyboard" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("magic mouse") { return "magicmouse" }
        if name.contains("mouse") || name.contains("souris") { return "computermouse" }
        switch d.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio): return "headphones"
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            // The minor class says keyboard, pointing device (mouse, trackpad) or both.
            let minor = d.deviceClassMinor
            if minor & UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing) != 0,
                minor & UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard) == 0
            {
                return "computermouse"
            }
            return "keyboard"
        case UInt32(kBluetoothDeviceClassMajorPhone): return "iphone"
        default: return unknownSymbol
        }
    }

    /// A device of no known kind: often one connecting by itself in the background
    /// (Continuity, a watch), so Islet doesn't announce it.
    static let unknownSymbol = "dot.radiowaves.left.and.right"
}

// MARK: - Focus

/// Focus mode changes, read from the DoNotDisturb database macOS keeps in the user
/// library and watched with a file-system event source (no polling). macOS protects
/// that folder, so it needs Full Disk Access; without it the monitor stays silent.
final class FocusMonitor {
    var onNotice: ((NoticeKind) -> Void)?
    private(set) var available = false
    private var source: DispatchSourceFileSystemObject?
    private var activeMode: String?
    private var debounce: DispatchWorkItem?
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")

    private var retry: Timer?

    func start() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            available = false
            // Full Disk Access can be granted at any time: pick it up without a relaunch.
            if retry == nil {
                let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.start() }
                t.tolerance = 5
                RunLoop.main.add(t, forMode: .common)
                retry = t
            }
            return
        }
        retry?.invalidate()
        retry = nil
        available = true
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRead() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        activeMode = readActiveMode()
    }

    /// For `--diagnose`: whether the Focus database is readable and what it says now.
    func diagnostics() -> String {
        guard Self.hasAccess else { return "focus: no access (Full Disk Access needed)" }
        guard let id = readActiveMode() else { return "focus: readable, no mode active" }
        let info = modeInfo(id)
        return "focus: readable, active \(id) → \(info.name) [\(info.symbol)]"
    }

    static var hasAccess: Bool {
        FileManager.default.isReadableFile(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/DoNotDisturb/DB/ModeConfigurations.json").path)
    }

    private func scheduleRead() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func read() {
        let mode = readActiveMode()
        guard mode != activeMode else { return }
        let previous = activeMode
        activeMode = mode
        guard Prefs.bool(Prefs.focusNotify), let id = mode ?? previous else { return }
        let info = modeInfo(id)
        onNotice?(.focus(name: info.name, symbol: info.symbol, tint: info.tint, active: mode != nil))
    }

    private func json(_ file: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readActiveMode() -> String? {
        guard let root = json("Assertions.json"), let data = (root["data"] as? [[String: Any]])?.first,
            let records = data["storeAssertionRecords"] as? [[String: Any]]
        else { return nil }
        let ids = records.compactMap { ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }
        return ids.last
    }

    private func modeInfo(_ id: String) -> (name: String, symbol: String, tint: Color) {
        let configs = ((json("ModeConfigurations.json")?["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any])
        let mode = (configs?[id] as? [String: Any])?["mode"] as? [String: Any]
        let name = mode?["name"] as? String ?? "Do Not Disturb"
        let symbol = mode?["symbolImageName"] as? String ?? "moon.fill"
        return (name, symbol, Self.tint(mode?["tintColorName"] as? String))
    }

    private static func tint(_ name: String?) -> Color {
        switch name {
        case "systemPurpleColor": return .purple
        case "systemOrangeColor": return .orange
        case "systemGreenColor": return .green
        case "systemBlueColor": return .blue
        case "systemPinkColor": return .pink
        case "systemRedColor": return .red
        case "systemYellowColor": return .yellow
        case "systemTealColor": return .teal
        case "systemCyanColor": return .cyan
        case "systemMintColor": return .mint
        case "systemBrownColor": return .brown
        case "systemGrayColor": return .gray
        default: return .indigo
        }
    }
}
