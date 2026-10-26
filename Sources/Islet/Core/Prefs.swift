import Foundation

/// UserDefaults keys. Views bind with `@AppStorage(Prefs.x)`, services read `Prefs.bool(...)`.
enum Prefs {
    static let showMenuBarIcon = "showMenuBarIcon"
    static let showInFullScreen = "showInFullScreen"
    static let showInScreenshots = "showInScreenshots"
    static let haptics = "haptics"
    static let emptyClickOpensDashboard = "emptyClickOpensDashboard"
    static let unlockAnimation = "unlockAnimation"

    static let hudEnabled = "hudEnabled"
    static let hudReplaceSystem = "hudReplaceSystem"
    static let hudStyle = "hudStyle"  // white | accent | glow
    static let hudSpeed = "hudSpeed"  // smooth | fast | instant
    static let hudDuration = "hudDuration"
    static let hudShowPercent = "hudShowPercent"
    static let hudScaleSymbol = "hudScaleSymbol"

    static let batteryNotify = "batteryNotify"
    static let batteryLowThreshold = "batteryLowThreshold"
    static let batteryLowPower = "batteryLowPower"
    static let batteryInHeader = "batteryInHeader"

    static let bluetoothNotify = "bluetoothNotify"
    static let focusNotify = "focusNotify"

    static let nowPlayingEnabled = "nowPlayingEnabled"
    static let sourceMusic = "sourceMusic"
    static let sourceSpotify = "sourceSpotify"
    static let sourceWeb = "sourceWeb"
    static let visualizer = "visualizer"
    static let artworkTint = "artworkTint"

    static let calendarEnabled = "calendarEnabled"
    static let calendarLead = "calendarLead"

    static let weatherEnabled = "weatherEnabled"
    static let weatherCity = "weatherCity"
    static let weatherFahrenheit = "weatherFahrenheit"

    static let flowEnabled = "flowEnabled"
    static let flowFocus = "flowFocus"
    static let flowShort = "flowShort"
    static let flowLong = "flowLong"
    static let flowRounds = "flowRounds"
    static let flowAutoContinue = "flowAutoContinue"
    static let flowSound = "flowSound"
    static let flowTone = "flowTone"

    static let shelfEnabled = "shelfEnabled"
    static let callEnabled = "callEnabled"
    static let islandStyle = "islandStyle"  // auto | notch | island
    static let menuBarVeil = "menuBarVeil"
    static let pinAcrossSpaces = "pinAcrossSpaces"
    static let keepCallCapturable = "keepCallCapturable"
    static let shelfItems = "shelfItems"

    static let claudeEnabled = "claudeEnabled"
    static let claudeOnlyWhenAway = "claudeOnlyWhenAway"
    static let claudeSound = "claudeSound"
    static let claudeUsage = "claudeUsage"
    static let claudeUsageAlerts = "claudeUsageAlerts"

    static let lastPage = "lastPage"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showMenuBarIcon: true, showInFullScreen: false, showInScreenshots: true,
            haptics: true, emptyClickOpensDashboard: true, unlockAnimation: true,
            hudEnabled: true, hudReplaceSystem: true, hudStyle: "glow", hudSpeed: "smooth",
            hudDuration: 1.5, hudShowPercent: false, hudScaleSymbol: true,
            batteryNotify: true, batteryLowThreshold: 20, batteryLowPower: true, batteryInHeader: true,
            bluetoothNotify: true, focusNotify: true,
            nowPlayingEnabled: true, sourceMusic: true, sourceSpotify: true, sourceWeb: true, visualizer: true, artworkTint: true,
            calendarEnabled: true, calendarLead: 5,
            weatherEnabled: true, weatherCity: "", weatherFahrenheit: false,
            flowEnabled: true, flowFocus: 25, flowShort: 5, flowLong: 15, flowRounds: 4, flowAutoContinue: true, flowSound: true, flowTone: "Radar",
            shelfEnabled: true, callEnabled: true, islandStyle: "auto", menuBarVeil: true, pinAcrossSpaces: true, keepCallCapturable: true,
            claudeEnabled: true, claudeOnlyWhenAway: true, claudeSound: true, claudeUsage: true, claudeUsageAlerts: true,
            lastPage: "nowPlaying",
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
}
