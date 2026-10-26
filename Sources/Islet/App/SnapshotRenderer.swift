import AppKit
import SwiftUI

/// `Islet --snapshot <dir>` renders every island state to PNG over a mock menu bar,
/// so the design can be checked without a screen recording permission.
/// `Islet --icon <dir>` renders the app icon set.
@MainActor
enum SnapshotRenderer {
    nonisolated(unsafe) static var isRendering = false
    /// Illustrative still standing in for the live call video in marketing renders.
    nonisolated(unsafe) static var callStill: NSImage?

    static func run(into dir: URL) {
        isRendering = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let services = Services()
        let model = IslandModel(services: services)
        model.setScreen(notch: CGSize(width: 179, height: 32), detached: false)
        let art = demoArtwork()
        let track = NowPlayingService.Track(title: "Essuie tes larmes", artist: "SCH", album: "Anarchie", duration: 166)

        func shot(_ name: String, _ configure: () -> Void) {
            configure()
            let view = ZStack(alignment: .top) {
                Backdrop()
                IslandRootView(model: model)
            }
            .frame(width: 820, height: 300)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage else { print("failed \(name)"); return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }

        shot("01-idle") { model.preview() }
        shot("02-bump") { model.preview(hovering: true, bumped: true) }
        shot("03-music-compact") {
            services.nowPlaying.loadPreview(track, artwork: art, playing: true, elapsed: 21)
            model.preview()
        }
        shot("04-music-hover") { model.preview(hovering: true) }
        shot("05-music-expanded") { model.preview(expanded: .nowPlaying) }
        shot("06-music-and-flow") {
            services.flow.start()
            model.preview()
        }
        shot("07-claude-hover") {
            services.flow.reset()
            services.nowPlaying.loadPreview(track, artwork: art, playing: false, elapsed: 21)
            services.claude.loadPreview(working: true)
            UserDefaults.standard.set(false, forKey: Prefs.nowPlayingEnabled)
            model.preview(hovering: true)
        }
        shot("08-claude-expanded") { model.preview(expanded: .claude) }
        shot("08b-claude-working-no-limits") {
            services.claude.loadPreview(working: true, limits: false)
            model.preview(expanded: .claude)
        }
        shot("09-hud-volume") { model.preview(transient: .hud(.volume, 0.62, muted: false)) }
        shot("10-hud-brightness-glow") {
            UserDefaults.standard.set("glow", forKey: Prefs.hudStyle)
            model.preview(transient: .hud(.brightness, 0.8, muted: false))
        }
        shot("11-notice-charging") {
            UserDefaults.standard.removeObject(forKey: Prefs.hudStyle)
            services.claude.loadPreview(working: false)
            model.preview(transient: .notice(Notice(kind: .charging(82))))
        }
        shot("12-notice-airpods") {
            model.preview(
                transient: .notice(
                    Notice(
                        kind: .deviceConnected(
                            name: "AirPods Pro", symbol: "airpodspro",
                            battery: DeviceBattery(left: 84, right: 80, caseLevel: 60)))))
        }
        shot("13-notice-claude-done") { model.preview(transient: .notice(Notice(kind: .claudeDone(project: "Islet")))) }
        shot("14-notice-focus") {
            model.preview(transient: .notice(Notice(kind: .focus(name: "Travail", symbol: "briefcase.fill", tint: .cyan, active: true))))
        }
        shot("15-weather") {
            let days = (1...5).map { i in
                WeatherService.Day(
                    id: "\(i)", date: Date().addingTimeInterval(Double(i) * 86400), code: [2, 1, 3, 61, 0][i - 1],
                    high: [24, 27, 27, 26, 27][i - 1], low: 14)
            }
            services.weather.loadPreview(.init(place: "Paris", temperature: 22, code: 2, isDay: true, high: 23, low: 13, days: days))
            model.preview(expanded: .weather)
        }
        shot("16-flow-expanded") {
            services.flow.start()
            model.preview(expanded: .flow)
        }
        shot("17-shelf") { model.preview(expanded: .shelf) }
        shot("18-call-compact") {
            services.flow.reset()
            services.claude.loadPreview(working: false)
            services.call.loadPreview(camera: true, muted: false)
            model.preview()
        }
        shot("19-call-expanded") {
            services.call.loadPreview(camera: true, muted: true)
            model.preview(expanded: .call)
        }
        shot("20-call-pinned") {
            model.preview()
            model.toggleVideoPin()
            model.preview()
        }
        shot("21-island-idle") {
            model.toggleVideoPin()
            services.call.loadPreview(camera: false, muted: false)
            UserDefaults.standard.set(false, forKey: Prefs.callEnabled)
            model.setScreen(notch: CGSize(width: 100, height: 32), detached: true, topInset: 0)
            model.preview()
        }
        shot("22-island-expanded") { model.preview(expanded: .weather) }
        UserDefaults.standard.removeObject(forKey: Prefs.callEnabled)
        model.setScreen(notch: CGSize(width: 179, height: 32), detached: false)
        shot("23-call-fitted") {
            services.call.loadPreview(camera: true, muted: false)
            model.preview()
        }
        shot("24-glance-weather") {
            model.preview()
            model.swipe(.left); model.swipe(.left); model.swipe(.left); model.swipe(.left)
            model.preview(hovering: false)
        }
        UserDefaults.standard.removeObject(forKey: Prefs.nowPlayingEnabled)
    }

    static func renderIconSet(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
            ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            let renderer = ImageRenderer(content: AppIcon().frame(width: 1024, height: 1024))
            renderer.scale = px / 1024
            guard let cg = renderer.cgImage else { continue }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("icon_\(name).png"))
        }
    }

    private static func demoArtwork() -> NSImage {
        let r = ImageRenderer(
            content:
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.55, green: 0.62, blue: 0.68), Color(red: 0.18, green: 0.22, blue: 0.26)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Color(red: 0.85, green: 0.72, blue: 0.62)).frame(width: 70).offset(y: 30)
                }
                .frame(width: 200, height: 200))
        return r.nsImage ?? NSImage()
    }
}

/// Mock desktop: wallpaper, translucent menu bar and the hardware notch.
private struct Backdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.62, blue: 0.48), Color(red: 0.78, green: 0.35, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.white.opacity(0.18)).frame(height: 32)
            HStack {
                Text("Finder   Fichier   Édition   Présentation").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("82 %   lun. 26 oct. 14:30").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.black.opacity(0.75))
            .padding(.horizontal, 14)
            .frame(height: 32)
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                .fill(.black).frame(width: 179, height: 32)
        }
    }
}

/// App icon: a Mac display whose notch has come alive.
struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.36, green: 0.42, blue: 0.95), Color(red: 0.62, green: 0.32, blue: 0.86),
                            Color(red: 0.98, green: 0.52, blue: 0.42),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 824, height: 824)
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                )
                .shadow(color: .black.opacity(0.3), radius: 18, y: 12)
            VStack(spacing: 0) {
                NotchShape(topRadius: 34, bottomRadius: 92)
                    .fill(.black)
                    .frame(width: 600, height: 220)
                    .overlay {
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                                .frame(width: 120, height: 120)
                            Spacer()
                            HStack(spacing: 14) {
                                ForEach([0.5, 0.9, 0.65, 1.0, 0.45], id: \.self) { h in
                                    Capsule().fill(Color(red: 1, green: 0.62, blue: 0.5)).frame(width: 18, height: 110 * h)
                                }
                            }
                        }
                        .padding(.horizontal, 82)
                        .padding(.top, 10)
                    }
                Spacer()
            }
            .frame(width: 824, height: 824)
            .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
        }
        .frame(width: 1024, height: 1024)
    }
}
