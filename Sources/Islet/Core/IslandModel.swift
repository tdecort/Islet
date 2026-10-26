import AppKit
import Combine
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case call, nowPlaying, claude, calendar, weather, flow, shelf
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .claude: return "sparkle"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .flow: return "timer"
        case .shelf: return "tray.full.fill"
        case .call: return "phone.fill"
        }
    }

    var enabledKey: String {
        switch self {
        case .nowPlaying: return Prefs.nowPlayingEnabled
        case .claude: return Prefs.claudeEnabled
        case .calendar: return Prefs.calendarEnabled
        case .weather: return Prefs.weatherEnabled
        case .flow: return Prefs.flowEnabled
        case .shelf: return Prefs.shelfEnabled
        case .call: return Prefs.callEnabled
        }
    }

    static var enabled: [Page] {
        // The call page only exists while a call is going on.
        allCases.filter { Prefs.bool($0.enabledKey) && ($0 != .call || CallMonitor.shared.isActive) }
    }
}

enum Activity: String, Equatable {
    case call, nowPlaying, flow, claude

    var page: Page {
        switch self {
        case .nowPlaying: return .nowPlaying
        case .flow: return .flow
        case .claude: return .claude
        case .call: return .call
        }
    }
}

enum HUDKind: Equatable { case volume, brightness }

struct DeviceBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?
    var lowest: Int? { [left, right, single].compactMap { $0 }.min() }
}

enum NoticeKind: Equatable {
    case charging(Int)
    case lowBattery(Int)
    case lowPower(Bool)
    case deviceConnected(name: String, symbol: String, battery: DeviceBattery)
    case deviceDisconnected(name: String, symbol: String)
    case focus(name: String, symbol: String, tint: Color, active: Bool)
    case event(title: String, minutes: Int, tint: Color)
    case unlocked
    case flowPhase(FlowTimer.Phase)
    case shelfAdded(Int)
    case claudeDone(project: String)
    case claudeWaiting(project: String, message: String)
    case claudeUsage(percent: Int, window: String)

    var duration: Double {
        switch self {
        case .unlocked: return 1.5
        case .deviceConnected, .event, .claudeWaiting: return 4
        case .claudeDone, .claudeUsage: return 3.5
        // Stays up while the timer rings; touching the island silences it.
        case .flowPhase: return Prefs.bool(Prefs.flowSound) ? 30 : 2.8
        default: return 2.8
        }
    }

    /// Where a click on the notice leads.
    var page: Page? {
        switch self {
        case .event: return .calendar
        case .flowPhase: return .flow
        case .shelfAdded: return .shelf
        case .claudeDone, .claudeWaiting, .claudeUsage: return .claude
        default: return nil
        }
    }
}

struct Notice: Equatable {
    let id = UUID()
    let kind: NoticeKind
}

enum Transient: Equatable {
    case hud(HUDKind, Double, muted: Bool)
    case notice(Notice)
}

enum IslandState: Equatable {
    case idle
    case compact(Activity)
    case transient(Transient)
    case expanded(Page)
    /// A page previewed in compact form, reached by swiping on the folded island.
    case glance(Page)

    /// Identity for content transitions: value-only changes (a HUD level, a page
    /// switch) keep the same key so they animate in place instead of cross-blurring.
    var contentKey: String {
        switch self {
        case .idle: return "idle"
        case .compact(let a): return "compact.\(a.rawValue)"
        case .transient(.hud(let k, _, _)): return "hud.\(k)"
        case .transient(.notice(let n)): return "notice.\(n.id)"
        case .expanded: return "expanded"
        case .glance(let p): return "glance.\(p.rawValue)"
        }
    }

    var isExpanded: Bool { if case .expanded = self { return true }; return false }
}

struct IslandGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var shadow: Double = 0
    /// Horizontal shift of the shape's centre, so asymmetric wings stay around the camera.
    var offset: CGFloat = 0
}

enum SwipeDirection { case left, right, up, down }

enum DropZone { case shelf, airDrop }

final class IslandModel: ObservableObject {
    let services: Services

    // Screen
    @Published private(set) var notch = CGSize(width: 185, height: 32)
    @Published private(set) var detached = false
    /// Distance from the top of the screen to the island (0 when it hangs from the bezel).
    @Published private(set) var topInset: CGFloat = 0

    // State inputs
    @Published private(set) var expandedPage: Page?
    @Published private(set) var transient: Transient?
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var primaryIndex = 0
    @Published private(set) var hovering = false
    @Published private(set) var bumped = false
    @Published private(set) var dropTargeting = false
    @Published private(set) var dropZone: DropZone?
    @Published private(set) var pageForward = true
    /// The call video stays in the island, collapsed, whatever the user does elsewhere.
    @Published private(set) var videoPinned = false
    /// The timer duration is being typed: the island keeps the keyboard and stays open.
    @Published private(set) var timerEditing = false

    // Animated geometry (each field animates on its own spring)
    @Published private(set) var width: CGFloat = 175
    @Published private(set) var height: CGFloat = 30
    @Published private(set) var topRadius: CGFloat = 0
    @Published private(set) var bottomRadius: CGFloat = 8
    @Published private(set) var shadow: Double = 0
    @Published private(set) var xOffset: CGFloat = 0
    @Published private(set) var glance: Page?
    private var glanceWork: DispatchWorkItem?

    private var transientWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var pendingNotice: Notice?
    private var lastBump = Date.distantPast
    private var bag = Set<AnyCancellable>()

    init(services: Services) {
        self.services = services
        let g = target(for: .idle)
        width = g.width; height = g.height; topRadius = g.top; bottomRadius = g.bottom
    }

    // MARK: Derived state

    var state: IslandState {
        if let p = expandedPage { return .expanded(p) }
        if let t = transient { return .transient(t) }
        if let g = glance { return .glance(g) }
        if let a = primaryActivity { return .compact(a) }
        return .idle
    }

    var primaryActivity: Activity? {
        activities.isEmpty ? nil : activities[primaryIndex % activities.count]
    }

    /// The live activity in the side bubble: always one that is not on screen, so a
    /// swipe to Claude moves Spotify into the bubble instead of showing Claude twice.
    var secondaryActivity: Activity? {
        guard activities.count > 1, expandedPage == nil else { return nil }
        let shown = glance ?? primaryActivity?.page
        if let primary = primaryActivity, primary.page != shown { return primary }
        let start = primaryIndex % activities.count
        return (1..<activities.count).map { activities[(start + $0) % activities.count] }.first { $0.page != shown }
    }

    var isExpanded: Bool { expandedPage != nil }

    /// The size the island is heading to, used for hit-testing (never the in-flight value).
    var targetGeometry: IslandGeometry { target(for: state) }

    // MARK: Geometry table

    func target(for s: IslandState, includeHover: Bool = true) -> IslandGeometry {
        let n = notch
        var g: IslandGeometry
        switch s {
        case .idle:
            g =
                detached
                ? IslandGeometry(width: n.width + 26, height: n.height - 2, top: 0, bottom: 15)
                : IslandGeometry(width: n.width - 4, height: n.height - 2, top: 0, bottom: 8)
        case .compact(let a):
            g = IslandGeometry(width: n.width + 2 * Self.wing(a), height: n.height, top: 6, bottom: 12)
            if a == .claude, includeHover, hovering { g.height += 26; g.bottom = 16 }
            if let w = wingWidths(for: a.page) {
                g.width = n.width + w.leading + w.trailing
                g.offset = (w.trailing - w.leading) / 2
            }
            if a == .call, videoPinned {
                g = IslandGeometry(width: n.width + 2 * 92, height: n.height + 158, top: 10, bottom: 26, shadow: 0.4)
            }
        case .glance(let p):
            let w = wingWidths(for: p) ?? WingWidths(leading: 44, trailing: 44)
            g = IslandGeometry(
                width: n.width + w.leading + w.trailing, height: n.height, top: 6, bottom: 12, offset: (w.trailing - w.leading) / 2)
        case .transient(.hud):
            g = IslandGeometry(width: n.width + 2 * 104, height: n.height, top: 6, bottom: 12)
        case .transient(.notice(let notice)):
            g = Self.noticeGeometry(notice.kind, notch: n)
        case .expanded(let p):
            if p == .claude {
                g = claudePageGeometry(notch: n)
            } else {
                g = IslandGeometry(width: Self.pageWidth(p, notch: n), height: Self.pageHeight(p), top: 12, bottom: 28, shadow: 0.5)
            }
        }
        if detached {
            // Floating over content: fully rounded, and always lifted by a soft shadow.
            g.top = 0
            g.bottom = max(g.bottom, min(g.height / 2, 22))
            g.shadow = max(g.shadow, 0.3)
        }
        guard includeHover else { return g }
        if bumped, case .idle = s {
            g = IslandGeometry(
                width: n.width + (detached ? 56 : 30), height: n.height + (detached ? 5 : 7),
                top: detached ? 0 : 6, bottom: detached ? 18 : 15, shadow: detached ? 0.3 : 0)
        } else if hovering, !s.isExpanded, s != .idle, s != .compact(.claude), !(videoPinned && s == .compact(.call)) {
            g.width += 14; g.height += 4; g.bottom += 2
        }
        return g
    }

    static func wing(_ a: Activity) -> CGFloat {
        switch a {
        case .nowPlaying: return 44
        case .flow: return 58
        case .claude: return 44
        case .call: return 76
        }
    }

    static func noticeGeometry(_ k: NoticeKind, notch n: CGSize) -> IslandGeometry {
        func wings(_ w: CGFloat) -> IslandGeometry { IslandGeometry(width: n.width + 2 * w, height: n.height, top: 6, bottom: 12) }
        func card(_ w: CGFloat, _ extra: CGFloat) -> IslandGeometry {
            IslandGeometry(width: n.width + 2 * w, height: n.height + extra, top: 10, bottom: 24, shadow: 0.35)
        }
        switch k {
        case .charging: return wings(88)
        case .lowBattery, .lowPower: return card(104, 46)
        case .deviceConnected: return wings(70)
        case .deviceDisconnected: return wings(86)
        case .focus: return wings(44)
        case .event: return card(120, 52)
        case .unlocked: return wings(34)
        case .flowPhase: return wings(96)
        case .shelfAdded: return wings(60)
        case .claudeDone: return card(112, 46)
        case .claudeWaiting: return card(124, 52)
        case .claudeUsage: return card(108, 46)
        }
    }

    /// Each page as wide as its content needs; the header wings (battery left, settings
    /// right of the camera) set the floor.
    static func pageWidth(_ p: Page, notch n: CGSize) -> CGFloat {
        let content: CGFloat
        switch p {
        case .calendar, .weather, .shelf, .call: content = 460
        case .nowPlaying, .claude: content = 400
        case .flow: content = 0
        }
        return max(content, minimumPageWidth(notch: n))
    }

    /// Battery on the left of the camera, settings on the right: nothing narrower fits.
    static func minimumPageWidth(notch n: CGSize) -> CGFloat { n.width + 2 * 84 }

    /// Claude idle with no limits to show: the page shrinks to a single line.
    /// The Claude page is as big as what it says: one status line at the narrowest width,
    /// growing a row per known limit (and a little wider, for the reset times).
    private func claudePageGeometry(notch n: CGSize) -> IslandGeometry {
        let c = services.claude
        let limitRows = [c.session, c.weekly].compactMap { $0 }.count
        let width = limitRows == 0 ? Self.minimumPageWidth(notch: n) : Self.pageWidth(.claude, notch: n)
        // 96 pt for the header and status line; each limit row is 23 pt plus its spacing.
        let rows = CGFloat(limitRows)
        let height = 96 + (limitRows == 0 ? 0 : 12 + rows * 23 + (rows - 1) * 8)
        return IslandGeometry(width: width, height: height, top: 12, bottom: 28, shadow: 0.5)
    }

    static func pageHeight(_ p: Page) -> CGFloat {
        switch p {
        case .nowPlaying: return 168
        case .call: return 176
        case .claude: return 150
        case .flow: return 142
        case .shelf: return 150
        default: return 160
        }
    }

    // MARK: Reconcile geometry

    private func reconcile(_ override: Animation? = nil) {
        let t = target(for: state)
        let opening = t.height > height + 0.5 || t.width > width + 0.5
        let wAnim = override ?? (opening ? Motion.openWidth : Motion.closeWidth)
        let hAnim = override ?? (opening ? Motion.openHeight : Motion.closeHeight)
        withAnimation(wAnim) {
            width = t.width; topRadius = t.top; xOffset = t.offset
        }
        withAnimation(hAnim) {
            height = t.height; bottomRadius = t.bottom; shadow = t.shadow
        }
    }

    /// Mutate state-defining inputs with the content transition, then morph the shape.
    private func mutate(_ body: () -> Void) {
        withAnimation(Motion.content) { body() }
        reconcile()
    }

    // MARK: Screen

    func setScreen(notch: CGSize, detached: Bool, topInset: CGFloat = 0) {
        self.notch = notch
        self.detached = detached
        self.topInset = topInset
        let g = target(for: state)
        width = g.width; height = g.height; topRadius = g.top; bottomRadius = g.bottom; shadow = g.shadow; xOffset = g.offset
    }

    // MARK: Activities

    func bind() {
        let np = services.nowPlaying
        let flow = services.flow
        let claude = services.claude
        Publishers.CombineLatest4(np.$hasActivity, flow.$isActive, claude.$isWorking, services.call.$isActive)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshActivities() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshActivities() }
            .store(in: &bag)
        Publishers.MergeMany(
            services.call.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            services.nowPlaying.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            services.claude.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            services.calendar.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            services.weather.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            services.shelf.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.contentChanged() }
        .store(in: &bag)
    }

    func refreshActivities() {
        var list: [Activity] = []
        if services.call.isActive, Prefs.bool(Prefs.callEnabled) { list.append(.call) }
        if services.nowPlaying.hasActivity, Prefs.bool(Prefs.nowPlayingEnabled) { list.append(.nowPlaying) }
        if services.claude.isWorking, Prefs.bool(Prefs.claudeEnabled) { list.append(.claude) }
        if services.flow.isActive, Prefs.bool(Prefs.flowEnabled) { list.append(.flow) }
        guard list != activities else { return }
        let previous = primaryActivity
        let callStarted = list.contains(.call) && !activities.contains(.call)
        mutate {
            activities = list
            if !list.contains(.call) { videoPinned = false }
            if callStarted {
                // Like on iPhone, a call that begins takes the main island.
                primaryIndex = list.firstIndex(of: .call) ?? 0
            } else if let previous, let i = list.firstIndex(of: previous) {
                primaryIndex = i
            } else {
                primaryIndex = 0
            }
        }
    }

    // MARK: Transients

    func show(_ t: Transient, duration: Double) {
        if isExpanded {
            if case .notice(let n) = t { pendingNotice = n }
            return
        }
        transientWork?.cancel()
        if transient.map({ IslandState.transient($0).contentKey }) == IslandState.transient(t).contentKey {
            transient = t  // value update in place (HUD level)
        } else {
            mutate { transient = t }
        }
        scheduleTransientDismiss(after: duration)
    }

    func notify(_ kind: NoticeKind) {
        show(.notice(Notice(kind: kind)), duration: kind.duration)
    }

    private func scheduleTransientDismiss(after duration: Double) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hovering, case .notice = self.transient {
                self.scheduleTransientDismiss(after: 1.0)
                return
            }
            self.mutate { self.transient = nil }
        }
        transientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissTransient() {
        transientWork?.cancel()
        guard transient != nil else { return }
        mutate { transient = nil }
    }

    // MARK: Expansion

    func expand(_ page: Page? = nil) {
        collapseWork?.cancel()
        transientWork?.cancel()
        let p = page ?? defaultPage
        UserDefaults.standard.set(p.rawValue, forKey: Prefs.lastPage)
        services.pageWillAppear(p)
        glanceWork?.cancel()
        mutate {
            expandedPage = p; transient = nil; glance = nil
        }
        Motion.haptic()
    }

    func collapse() {
        collapseWork?.cancel()
        guard isExpanded else { return }
        timerEditing = false
        mutate {
            expandedPage = nil; dropTargeting = false
        }
        if let n = pendingNotice {
            pendingNotice = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.notify(n.kind) }
        }
    }

    func select(_ page: Page) {
        guard let current = expandedPage, current != page else { return }
        let all = Page.enabled
        pageForward = (all.firstIndex(of: page) ?? 0) > (all.firstIndex(of: current) ?? 0)
        UserDefaults.standard.set(page.rawValue, forKey: Prefs.lastPage)
        timerEditing = false
        services.pageWillAppear(page)
        withAnimation(Motion.content) { expandedPage = page }
        reconcile()
        Motion.haptic(.generic)
    }

    private var defaultPage: Page {
        if let a = primaryActivity { return a.page }
        let enabled = Page.enabled
        if let last = Page(rawValue: Prefs.string(Prefs.lastPage)), enabled.contains(last) { return last }
        return enabled.first ?? .weather
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.dropTargeting, !self.timerEditing else { return }
            if NSEvent.pressedMouseButtons != 0 { self.scheduleCollapse(); return }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Pointer input

    func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            collapseWork?.cancel()
            glanceWork?.cancel()
            TimerAlarm.shared.stop()
            switch state {
            case .idle: bump()
            case .expanded: break
            default: reconcile(Motion.lift)
            }
        } else {
            if isExpanded { scheduleCollapse() } else { reconcile(Motion.lift) }
            if glance != nil {
                // Leaving the island returns it to the live activity after a beat.
                let work = DispatchWorkItem { [weak self] in self?.clearGlance() }
                glanceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
            }
        }
    }

    /// The empty-island answer to a touch: swell, then settle back to show nothing is running.
    func bump() {
        guard Date().timeIntervalSince(lastBump) > 0.45 else { return }
        lastBump = Date()
        bumped = true
        reconcile(Motion.bumpOut)
        Motion.haptic(.generic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self else { return }
            self.bumped = false
            self.reconcile(Motion.bumpBack)
        }
    }

    func click() {
        TimerAlarm.shared.stop()
        switch state {
        case .idle:
            if Prefs.bool(Prefs.emptyClickOpensDashboard) { expand() } else { lastBump = .distantPast; bump() }
        case .compact(let a):
            expand(a.page)
        case .glance(let p):
            expand(p)
        case .transient(.notice(let n)):
            if let p = n.kind.page { expand(p) } else { dismissTransient() }
        case .transient(.hud):
            break
        case .expanded:
            break
        }
    }

    /// Bring forward the app a page stands for, then fold the island away.
    func openApp(for page: Page) {
        let bundleID: String?
        switch page {
        case .call: bundleID = services.call.app?.bundleID
        case .nowPlaying: bundleID = services.nowPlaying.source?.rawValue ?? NowPlayingService.Source.music.rawValue
        case .claude: bundleID = "com.anthropic.claudefordesktop"
        case .calendar: bundleID = "com.apple.iCal"
        case .weather: bundleID = "com.apple.weather"
        case .flow: bundleID = "com.apple.clock"
        case .shelf: bundleID = nil
        }
        if page == .shelf {
            let items = services.shelf.items
            if items.isEmpty {
                NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(items)
            }
        } else if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        collapse()
    }

    func beginTimerEdit() { timerEditing = true }
    func endTimerEdit() { timerEditing = false }

    func toggleVideoPin() {
        let pin = !videoPinned
        if pin, let i = activities.firstIndex(of: .call) { primaryIndex = i }
        if pin, isExpanded {
            videoPinned = true
            collapse()
        } else {
            mutate { videoPinned = pin }
        }
        Motion.haptic()
    }

    /// Bring the bubble's activity to the front; what was shown takes its place.
    func clickSecondary() {
        guard let target = secondaryActivity, let index = activities.firstIndex(of: target) else { return }
        glanceWork?.cancel()
        mutate {
            glance = nil
            primaryIndex = index
        }
        Motion.haptic(.generic)
    }

    func swipe(_ dir: SwipeDirection) {
        switch state {
        case .expanded(let p):
            let pages = Page.enabled
            guard let i = pages.firstIndex(of: p) else { return }
            switch dir {
            case .left where i + 1 < pages.count: select(pages[i + 1])
            case .right where i > 0: select(pages[i - 1])
            case .up: collapse()
            default: Motion.haptic(.generic)
            }
        case .compact, .glance:
            switch dir {
            case .left, .right: stepGlance(dir)
            case .down: click()
            case .up: if glance != nil { clearGlance() }
            }
        case .transient(.notice):
            if dir == .up { dismissTransient() } else if dir == .down { click() }
        case .idle:
            if dir == .down { expand() } else if dir == .left || dir == .right { stepGlance(dir) }
        case .transient(.hud):
            break
        }
    }

    // MARK: Glances

    /// Swipe through the pages in compact form, starting from what the island shows.
    private func stepGlance(_ dir: SwipeDirection) {
        let pages = Page.enabled
        guard !pages.isEmpty else { return }
        let current = glance ?? primaryActivity?.page
        let index = current.flatMap { pages.firstIndex(of: $0) }
        let next: Page
        switch (index, dir) {
        case (nil, .right): next = pages[pages.count - 1]
        case (nil, _): next = pages[0]
        case (let i?, .left): next = pages[(i + 1) % pages.count]
        case (let i?, _): next = pages[(i + pages.count - 1) % pages.count]
        }
        glanceWork?.cancel()
        services.pageWillAppear(next)
        // Landing back on the live activity drops the preview.
        mutate { glance = next == primaryActivity?.page ? nil : next }
        Motion.haptic(.generic)
    }

    private func clearGlance() {
        glanceWork?.cancel()
        guard glance != nil else { return }
        mutate { glance = nil }
    }

    /// Re-measure when what a compact state displays changes (a duration, a temperature…).
    func contentChanged() {
        switch state {
        case .compact, .glance, .expanded(.claude): reconcile()
        default: break
        }
    }

    // MARK: Wing widths

    /// Each wing sized to its own content: 10 pt from the island's edge, 6 pt from the camera.
    func wingWidths(for page: Page) -> WingWidths? {
        let pad: CGFloat = 16
        func text(_ s: String, _ size: CGFloat = 12.5) -> CGFloat {
            // Rounded digits run a little wider than the system face.
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            return ceil((s as NSString).size(withAttributes: [.font: font]).width) + 2
        }
        func wings(_ l: CGFloat, _ r: CGFloat) -> WingWidths { WingWidths(leading: max(30, pad + l), trailing: max(30, pad + r)) }
        let s = services
        switch page {
        case .call:
            guard !videoPinned else { return nil }
            let long = (s.call.startedAt.map { Date().timeIntervalSince($0) } ?? 0) >= 3540
            return wings(15 + 5 + text(long ? "0:00:00" : "00:00"), 16)
        case .nowPlaying:
            guard s.nowPlaying.track != nil else { return wings(15, text("—")) }
            return wings(22, Prefs.bool(Prefs.visualizer) ? 23 : 12)
        case .claude:
            if s.claude.isWorking { return hovering ? nil : wings(16, 15) }
            return wings(15, text(Self.claudeGlanceText(s.claude)))
        case .flow:
            return wings(17, text("00:00", 13))
        case .calendar:
            return wings(15, text(Self.calendarGlanceText(s.calendar)))
        case .weather:
            return wings(18, text(Self.weatherGlanceText(s.weather)))
        case .shelf:
            return wings(16, text("\(s.shelf.items.count)"))
        }
    }

    static func claudeGlanceText(_ claude: ClaudeMonitor) -> String {
        claude.session.map { "\(Int($0.utilization))%" } ?? "—"
    }

    static func calendarGlanceText(_ calendar: CalendarService) -> String {
        guard let next = calendar.events.first else { return calendar.access == .granted ? "Free" : "—" }
        return next.start <= Date() ? "Now" : Format.time.string(from: next.start)
    }

    static func weatherGlanceText(_ weather: WeatherService) -> String {
        weather.report.map { "\(Int($0.temperature.rounded()))°" } ?? "—"
    }

    /// Snapshot tooling: pin the island in a given state without timers or animation.
    func preview(expanded: Page? = nil, transient: Transient? = nil, hovering: Bool = false, bumped: Bool = false) {
        transientWork?.cancel()
        expandedPage = expanded
        self.transient = transient
        self.hovering = hovering
        self.bumped = bumped
        refreshActivities()
        let g = target(for: state)
        width = g.width; height = g.height; topRadius = g.top; bottomRadius = g.bottom; shadow = g.shadow; xOffset = g.offset
    }

    // MARK: Drop zone

    static let airDropZoneWidth: CGFloat = 110

    /// Which zone a file is over, from its horizontal distance to the island's centre.
    /// AirDrop is the right-hand tile of the shelf page; anywhere else lands on the shelf.
    private func zone(atOffset x: CGFloat) -> DropZone {
        guard expandedPage == .shelf else { return .shelf }
        let half = Self.pageWidth(.shelf, notch: notch) / 2
        let inset: CGFloat = 12 + 16
        return x > half - inset - Self.airDropZoneWidth - 6 ? .airDrop : .shelf
    }

    func dragMoved(toOffset x: CGFloat?) {
        let z = x.map(zone(atOffset:))
        guard z != dropZone else { return }
        dropZone = z
        if z != nil { Motion.haptic(.generic) }
    }

    func dropFiles(_ urls: [URL], atOffset x: CGFloat) -> Bool {
        guard Prefs.bool(Prefs.shelfEnabled), !urls.isEmpty else { return false }
        let target = zone(atOffset: x)
        dropZone = nil
        if target == .airDrop {
            services.shelf.airDrop(urls)
        } else {
            services.shelf.add(urls)
        }
        Motion.haptic(.levelChange)
        return true
    }

    func setDropTargeting(_ on: Bool) {
        guard on != dropTargeting, Prefs.bool(Prefs.shelfEnabled) else { return }
        dropTargeting = on
        if on {
            if expandedPage != .shelf { expand(.shelf) }
        } else if expandedPage == .shelf, !hovering {
            scheduleCollapse()
        }
    }
}
