import AppKit
import CoreMedia
import ScreenCaptureKit

/// Mirrors the call window (FaceTime, Zoom…) into the island with ScreenCaptureKit.
///
/// The stream only runs while at least one video tile is on screen (reference counted),
/// at a small size and 24 fps. Frames are handed to the tiles as IOSurfaces — no copy,
/// no SwiftUI redraw. Capturing a window works even when it is covered by other windows,
/// which is what lets a pinned call stay visible whatever else is in front.
final class CallVideo: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = CallVideo()

    enum Status: Equatable { case idle, needsPermission, needsRelaunch, noWindow, live }

    @Published private(set) var status: Status = .idle

    private var stream: SCStream?
    private var users = 0
    private var layers = NSHashTable<CALayer>.weakObjects()
    private let frames = DispatchQueue(label: "islet.call-video", qos: .userInteractive)
    private var starting = false

    // MARK: Tiles

    func attach(_ layer: CALayer) {
        layers.add(layer)
        users += 1
        if users == 1 { start() }
    }

    func detach(_ layer: CALayer) {
        layers.remove(layer)
        users = max(0, users - 1)
        if users == 0 { stop() }
    }

    /// Asks macOS for Screen Recording. macOS only applies the grant to a fresh process,
    /// so the tile then offers to restart Islet.
    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        status = .needsRelaunch
    }

    /// Relaunch Islet so a newly granted Screen Recording permission takes effect.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Re-pick the window, e.g. after the call window was recreated.
    func restart() {
        guard users > 0 else { return }
        stop()
        start()
    }

    // MARK: Stream

    private func start() {
        guard stream == nil, !starting else { return }
        // No CGPreflightScreenCaptureAccess() gate: its answer is frozen for the life of the
        // process, so it keeps saying "denied" after the user grants access. Just try.
        guard let bundleID = CallMonitor.shared.app?.bundleID else { status = .noWindow; return }
        starting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let candidates = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width >= 200
                }
                // Prefer a window that is on screen (it is being drawn), then the largest.
                let area: (SCWindow) -> CGFloat = { $0.frame.width * $0.frame.height }
                let drawable = candidates.filter { $0.isOnScreen && $0.frame.height >= 150 }
                guard let window = (drawable.isEmpty ? candidates : drawable).max(by: { area($0) < area($1) }) else {
                    await MainActor.run {
                        self.starting = false; self.status = .noWindow
                    }
                    return
                }
                let config = SCStreamConfiguration()
                let aspect = window.frame.height / max(1, window.frame.width)
                config.width = 640
                config.height = max(2, Int((640 * aspect).rounded()))
                config.minimumFrameInterval = CMTime(value: 1, timescale: 24)
                config.showsCursor = false
                config.queueDepth = 3
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frames)
                try await stream.startCapture()
                await MainActor.run {
                    self.starting = false
                    // Every tile may have gone away while the stream was spinning up.
                    if self.users == 0 {
                        Task { try? await stream.stopCapture() }
                    } else {
                        self.stream = stream
                        self.status = .live
                    }
                }
            } catch {
                await MainActor.run {
                    self.starting = false
                    let declined = (error as NSError).code == SCStreamError.Code.userDeclined.rawValue
                    if declined {
                        // Already asked in this run: only a restart can pick the grant up.
                        self.status = self.status == .needsRelaunch ? .needsRelaunch : .needsPermission
                    } else {
                        self.status = .noWindow
                    }
                }
            }
        }
    }

    private func stop() {
        guard let stream else { status = .idle; return }
        self.stream = nil
        status = .idle
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
            let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
            let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        else { return }
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layers.allObjects.forEach { $0.contents = surface }
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.status = .noWindow
        }
    }
}
