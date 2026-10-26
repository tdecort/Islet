import SwiftUI

/// Compact previews reached by swiping on the folded island: each page shows its one
/// key fact without expanding. Live activities reuse their own compact view.
struct GlanceView: View {
    @ObservedObject var model: IslandModel
    let page: Page

    var body: some View {
        let s = model.services
        let n = model.notch
        switch page {
        case .call:
            CallCompact(call: s.call, notch: n)
        case .nowPlaying:
            NowPlayingGlance(np: s.nowPlaying, notch: n)
        case .claude:
            ClaudeGlance(claude: s.claude, notch: n)
        case .flow:
            FlowCompact(flow: s.flow, notch: n)
        case .calendar:
            CalendarGlance(calendar: s.calendar, notch: n)
        case .weather:
            WeatherGlance(weather: s.weather, notch: n)
        case .shelf:
            ShelfGlance(shelf: s.shelf, notch: n)
        }
    }
}

private struct GlanceText: View {
    let text: String
    var tint: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct NowPlayingGlance: View {
    @ObservedObject var np: NowPlayingService
    let notch: CGSize

    var body: some View {
        if np.track != nil {
            NowPlayingCompact(np: np, notch: notch)
        } else {
            Wings(notch: notch, inset: 6) {
                Image(systemName: "music.note").font(.island(12.5, .semibold)).foregroundStyle(.pink)
            } trailing: {
                GlanceText(text: "—", tint: .white.opacity(0.5))
            }
        }
    }
}

private struct ClaudeGlance: View {
    @ObservedObject var claude: ClaudeMonitor
    let notch: CGSize

    var body: some View {
        if claude.isWorking {
            ClaudeCompact(claude: claude, notch: notch, hovering: false)
        } else {
            Wings(notch: notch, inset: 6) {
                ClaudeGlyph(size: 14)
            } trailing: {
                GlanceText(text: IslandModel.claudeGlanceText(claude), tint: claude.session?.pace.tint ?? .white.opacity(0.6))
            }
        }
    }
}

private struct CalendarGlance: View {
    @ObservedObject var calendar: CalendarService
    let notch: CGSize

    var body: some View {
        Wings(notch: notch, inset: 6) {
            Image(systemName: "calendar").font(.island(12.5, .semibold)).foregroundStyle(.red)
        } trailing: {
            GlanceText(text: IslandModel.calendarGlanceText(calendar), tint: calendar.events.first?.tint ?? .white.opacity(0.6))
        }
    }
}

private struct WeatherGlance: View {
    @ObservedObject var weather: WeatherService
    let notch: CGSize

    var body: some View {
        Wings(notch: notch, inset: 6) {
            Image(systemName: weather.report.map { WeatherService.describe($0.code, day: $0.isDay).symbol } ?? "cloud.fill")
                .symbolRenderingMode(.multicolor)
                .font(.island(13))
        } trailing: {
            GlanceText(text: IslandModel.weatherGlanceText(weather))
        }
    }
}

private struct ShelfGlance: View {
    @ObservedObject var shelf: ShelfStore
    let notch: CGSize

    var body: some View {
        Wings(notch: notch, inset: 6) {
            Image(systemName: "tray.full.fill").font(.island(12.5, .semibold)).foregroundStyle(.teal)
        } trailing: {
            GlanceText(text: "\(shelf.items.count)", tint: .white.opacity(0.8))
        }
    }
}
