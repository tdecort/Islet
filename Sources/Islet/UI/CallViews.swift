import AppKit
import SwiftUI

/// iOS call green.
private let callGreen = Color(red: 0.2, green: 0.84, blue: 0.29)

/// Compact call activity, as on iPhone: call glyph and running duration on the left,
/// microphone state on the right. Pinned, it grows a live video tile underneath.
struct CallCompact: View {
    @ObservedObject var call: CallMonitor
    let notch: CGSize
    var pinned = false
    var unpin: () -> Void = {}

    var body: some View {
        if pinned {
            VStack(spacing: 0) {
                Wings(notch: notch, inset: 10) {
                    status
                } trailing: {
                    Button(action: unpin) {
                        Image(systemName: "pin.slash.fill").font(.island(11.5, .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(PressableStyle())
                }
                CallVideoTile(cornerRadius: 18)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
        } else {
            Wings(notch: notch, inset: 6) {
                status
            } trailing: {
                Image(systemName: call.micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.island(12.5, .semibold))
                    .foregroundStyle(call.micMuted ? .orange : callGreen)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

    private var status: some View {
        HStack(spacing: 5) {
            Image(systemName: call.cameraOn ? "video.fill" : "phone.fill")
                .font(.island(11.5, .semibold))
                .contentTransition(.symbolEffect(.replace))
            CallDuration(since: call.startedAt)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(callGreen)
    }
}

struct CallBubble: View {
    @ObservedObject var call: CallMonitor

    var body: some View {
        Image(systemName: call.cameraOn ? "video.fill" : "phone.fill")
            .font(.island(10.5, .semibold))
            .foregroundStyle(callGreen)
    }
}

/// Expanded call page: who you are on with, how long, the controls Islet can genuinely
/// drive (system microphone mute, bring the call window forward, pin) and the live video.
struct CallPage: View {
    @ObservedObject var call: CallMonitor
    var pinned: Bool
    var togglePin: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    ZStack {
                        Circle().fill(callGreen.gradient)
                        Image(systemName: call.cameraOn ? "video.fill" : "phone.fill")
                            .font(.island(16, .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.app?.name ?? "Call").font(.island(14.5, .semibold)).foregroundStyle(.white)
                        HStack(spacing: 0) {
                            Text(call.cameraOn ? "Video · " : "Audio · ")
                            CallDuration(since: call.startedAt)
                        }
                        .font(.island(12).monospacedDigit())
                        .foregroundStyle(call.micMuted ? .orange : .white.opacity(0.55))
                    }
                }
                HStack(spacing: 12) {
                    CallControl(symbol: call.micMuted ? "mic.slash.fill" : "mic.fill", label: "Mute", on: call.micMuted) {
                        withAnimation(Motion.content) { call.toggleMute() }
                    }
                    CallControl(symbol: "macwindow", label: "Show", on: false) { call.showApp() }
                    CallControl(symbol: pinned ? "pin.fill" : "pin", label: "Pin", on: pinned, action: togglePin)
                }
            }
            CallVideoTile(cornerRadius: 16)
                .padding(.vertical, 2)
        }
    }
}

/// Round control like the iOS in-call buttons: frosted when off, white when on.
private struct CallControl: View {
    let symbol: String
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.island(14, .semibold))
                    .foregroundStyle(on ? .black : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? .white : .white.opacity(0.14)))
                Text(label).font(.island(10, .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.press, value: on)
    }
}

/// Elapsed call time, ticking once a second only while it is on screen.
private struct CallDuration: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(Format.clock(since.map { ctx.date.timeIntervalSince($0) } ?? 0))
                .contentTransition(.numericText())
        }
    }
}

/// Live mirror of the call window, or what is needed to get it.
struct CallVideoTile: View {
    @ObservedObject private var video = CallVideo.shared
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.white.opacity(0.06))
            if SnapshotRenderer.isRendering, let still = SnapshotRenderer.callStill {
                Image(nsImage: still).resizable().aspectRatio(contentMode: .fill)
            }
            if !SnapshotRenderer.isRendering {
                CallVideoLayer(cornerRadius: cornerRadius)
                    .opacity(video.status == .live ? 1 : 0)
                    .animation(Motion.content, value: video.status)
            }
            switch video.status {
            case .needsPermission:
                VStack(spacing: 6) {
                    Image(systemName: "video.badge.ellipsis").font(.island(17)).foregroundStyle(.white.opacity(0.5))
                    Button {
                        video.requestPermission()
                    } label: {
                        Text("Allow video").font(.island(11, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(PressableStyle())
                }
            case .needsRelaunch:
                VStack(spacing: 5) {
                    Text("Turn on Islet in Screen Recording,\nthen restart it.")
                        .font(.island(10.5)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                    Button {
                        CallVideo.relaunch()
                    } label: {
                        Text("Restart Islet").font(.island(11, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(PressableStyle())
                }
            case .noWindow:
                VStack(spacing: 4) {
                    Image(systemName: "video.slash.fill").font(.island(15)).foregroundStyle(.white.opacity(0.4))
                    Text("Call window not found").font(.island(10.5)).foregroundStyle(.white.opacity(0.45))
                }
                .contentShape(Rectangle())
                .onTapGesture { video.restart() }
            case .idle:
                if !SnapshotRenderer.isRendering { ProgressView().controlSize(.small) }
            case .live:
                EmptyView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct CallVideoLayer: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        view.layer = layer
        view.wantsLayer = true
        CallVideo.shared.attach(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        if let layer = view.layer { CallVideo.shared.detach(layer) }
    }
}
