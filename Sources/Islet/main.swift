import AppKit

Prefs.register()

let arguments = CommandLine.arguments

// Claude Code hook entry point: forward the event to the running app and exit at once.
if arguments.contains("--claude-event") {
    ClaudeHookRelay.run()
    exit(0)
}

if arguments.contains("--claude-status") {
    ClaudeHookRelay.runStatusLine()
    exit(0)
}

// `open -n Islet.app --args --diagnose <file>`: what macOS grants this exact signed app.
if let i = arguments.firstIndex(of: "--diagnose"), arguments.count > i + 1 {
    Diagnostics.write(to: URL(fileURLWithPath: arguments[i + 1]))
    exit(0)
}

if let i = arguments.firstIndex(of: "--snapshot") {
    let dir = arguments.count > i + 1 ? arguments[i + 1] : FileManager.default.currentDirectoryPath
    MainActor.assumeIsolated { SnapshotRenderer.run(into: URL(fileURLWithPath: dir)) }
    exit(0)
}

if let i = arguments.firstIndex(of: "--marketing") {
    let dir = arguments.count > i + 1 ? arguments[i + 1] : FileManager.default.currentDirectoryPath
    MainActor.assumeIsolated { MarketingRenderer.run(into: URL(fileURLWithPath: dir)) }
    exit(0)
}

if let i = arguments.firstIndex(of: "--icon") {
    let dir = arguments.count > i + 1 ? arguments[i + 1] : FileManager.default.currentDirectoryPath
    MainActor.assumeIsolated { SnapshotRenderer.renderIconSet(into: URL(fileURLWithPath: dir)) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
