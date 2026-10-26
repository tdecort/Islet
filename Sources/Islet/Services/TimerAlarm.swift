import AVFoundation
import AppKit

/// End-of-timer ring: an iPhone timer tone looped like on the phone, until the user
/// touches the island or 30 seconds pass. The tones ship with macOS (ToneLibrary).
final class TimerAlarm {
    static let shared = TimerAlarm()

    static let tones = ["Radar", "Reflection", "Beacon", "Apex", "Constellation", "Ding"]
    private static let library = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones"

    private var player: AVAudioPlayer?
    private var stopWork: DispatchWorkItem?

    var isRinging: Bool { player?.isPlaying == true }

    func ring() {
        stop()
        let tone = Prefs.string(Prefs.flowTone)
        let url = URL(fileURLWithPath: "\(Self.library)/\(tone).m4r")
        guard tone != "Ding", let p = try? AVAudioPlayer(contentsOf: url) else {
            NSSound(named: "Glass")?.play()  // the short chime, or a fallback if the tone is gone
            return
        }
        p.numberOfLoops = -1
        p.play()
        player = p
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Play a tone once, for picking one in the settings.
    func preview(_ tone: String) {
        stop()
        guard tone != "Ding", let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: "\(Self.library)/\(tone).m4r")) else {
            NSSound(named: "Glass")?.play()
            return
        }
        p.play()
        player = p
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        player = nil
    }
}
