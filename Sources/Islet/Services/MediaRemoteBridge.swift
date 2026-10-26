import Foundation

/// Talks to the system Now Playing service (what Control Center shows: YouTube in any
/// browser, podcasts, …) through IsletNowPlaying.dylib loaded into /usr/bin/perl, the
/// Apple binary macOS still lets read it. One JSON object per line comes back on stdout;
/// commands go down on stdin. The helper quits on its own when Islet goes away.
final class MediaRemoteBridge {
    var onUpdate: (([String: Any]) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0

    private static let loader =
        #"use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die; "#
        + #"my $s = DynaLoader::dl_find_symbol($l, "islet_np_" . $ARGV[1]) or die; "#
        + #"my $x = DynaLoader::dl_install_xsub("main::np", $s); &$x();"#

    static var helperPath: String? { Bundle.main.path(forResource: "IsletNowPlaying", ofType: "dylib") }

    func start() {
        guard process == nil, let helper = Self.helperPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, helper, "stream"]
        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.input = nil
                // Restart a few times if it dies; give up quietly after that.
                guard self.restarts < 3 else { return }
                self.restarts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.start() }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            process = nil
        }
    }

    func stop() {
        restarts = 3
        try? input?.close()
        process?.terminate()
        process = nil
    }

    /// toggle, next, prev, seek <seconds>
    func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { onUpdate?(json) }
        }
    }

    /// For `--diagnose`: what the system service answers right now, through perl.
    static func probe() -> String {
        guard let helper = helperPath else { return "helper missing" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", loader, helper, "probe"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "perl failed to start" }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
