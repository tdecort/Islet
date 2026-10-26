import AppKit
import CoreLocation
import EventKit
import SwiftUI

// MARK: - Calendar

final class CalendarService: ObservableObject {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let tint: Color
        let location: String?
    }

    enum Access { case unknown, granted, denied }

    /// A calendar as Settings lists it.
    struct CalendarEntry: Identifiable, Equatable {
        let id: String
        let title: String
        let account: String
        let color: Color
        let isGoogle: Bool
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [Event] = []
    @Published private(set) var calendars: [CalendarEntry] = []
    var onNotice: ((NoticeKind) -> Void)?

    private let store = EKEventStore()
    private var reminder: Timer?
    private var announced = Set<String>()
    private var observing = false

    func loadPreview(_ events: [Event]) {
        access = .granted
        self.events = events
    }

    func startIfAuthorized() {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { granted() }
    }

    func requestAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: granted()
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] ok, _ in
                DispatchQueue.main.async { ok ? self?.granted() : (self?.access = .denied) }
            }
        default: access = .denied
        }
    }

    private func granted() {
        access = .granted
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .EKEventStoreChanged, object: store)
        }
        reload()
    }

    @objc func reload() {
        DispatchQueue.main.async { [self] in
            guard access == .granted, Prefs.bool(Prefs.calendarEnabled) else { events = []; return }
            let all = store.calendars(for: .event)
            calendars = all.map {
                CalendarEntry(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "",
                         color: Color(nsColor: $0.color), isGoogle: Self.isGoogle($0))
            }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
            let shown = all.filter(Self.isShown)
            let now = Date()
            guard !shown.isEmpty else { events = []; return }
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(36 * 3600), calendars: shown)
            events = store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.endDate > now }
                .sorted { $0.startDate < $1.startDate }
                .prefix(6)
                .map {
                    Event(
                        id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Untitled",
                        start: $0.startDate, end: $0.endDate, tint: Color(nsColor: $0.calendar.color), location: $0.location)
                }
            scheduleReminder()
        }
    }

    /// Google accounts reach macOS through Internet Accounts as CalDAV sources named after
    /// the account, so the account address (or its name) says whether it is Google.
    static func isGoogle(_ calendar: EKCalendar) -> Bool {
        guard let source = calendar.source, source.sourceType == .calDAV else { return false }
        let title = source.title.lowercased()
        return title.contains("google") || title.hasSuffix("@gmail.com") || title.hasSuffix("@googlemail.com")
    }

    /// The source picked in Settings, minus the calendars turned off one by one.
    static func isShown(_ calendar: EKCalendar) -> Bool {
        let hidden = Set(Prefs.string(Prefs.calendarHidden).split(separator: ",").map(String.init))
        guard !hidden.contains(calendar.calendarIdentifier) else { return false }
        switch Prefs.string(Prefs.calendarSource) {
        case "google": return isGoogle(calendar)
        case "apple": return !isGoogle(calendar)
        default: return true
        }
    }

    /// One timer, aimed at the next "starts in N minutes" moment.
    private func scheduleReminder() {
        reminder?.invalidate()
        let lead = TimeInterval(Prefs.int(Prefs.calendarLead) * 60)
        guard let next = events.first(where: { $0.start.addingTimeInterval(-lead) > Date() && !announced.contains($0.id) }) else { return }
        let t = Timer(fire: next.start.addingTimeInterval(-lead), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.announced.insert(next.id)
            let minutes = max(1, Int((next.start.timeIntervalSinceNow / 60).rounded()))
            self.onNotice?(.event(title: next.title, minutes: minutes, tint: next.tint))
            self.scheduleReminder()
        }
        RunLoop.main.add(t, forMode: .common)
        reminder = t
    }
}

// MARK: - Weather

/// Forecast from Open-Meteo (free, no key). Fetched only when the weather page is
/// opened and the last fetch is older than 30 minutes.
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Day: Identifiable, Equatable {
        let id: String
        let date: Date
        let code: Int
        let high: Double
        let low: Double
    }

    struct Report: Equatable {
        var place: String
        var temperature: Double
        var code: Int
        var isDay: Bool
        var high: Double
        var low: Double
        var days: [Day]
    }

    enum Status: Equatable { case idle, loading, failed(String), needsLocation }

    @Published private(set) var report: Report?
    @Published private(set) var status: Status = .idle

    private var lastFetch = Date.distantPast
    private var lastKey = ""
    private lazy var location: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        return m
    }()

    func refreshIfStale() {
        let city = Prefs.string(Prefs.weatherCity).trimmingCharacters(in: .whitespaces)
        let key = "\(city)|\(Prefs.bool(Prefs.weatherFahrenheit))"
        guard key != lastKey || Date().timeIntervalSince(lastFetch) > 1800 || report == nil, status != .loading else { return }
        lastKey = key
        status = .loading
        if city.isEmpty { locate() } else { geocode(city) }
    }

    private func locate() {
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted: status = .needsLocation
        default: location.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard status == .loading else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: status = .needsLocation
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let place = marks?.first?.locality ?? marks?.first?.name ?? "Current location"
            self?.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, place: place)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.status = .needsLocation }
    }

    private func geocode(_ city: String) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: "fr")]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, _ in
            struct R: Decodable { struct Hit: Decodable { let name: String; let latitude: Double; let longitude: Double }; let results: [Hit]? }
            guard let data, let hit = (try? JSONDecoder().decode(R.self, from: data))?.results?.first else {
                DispatchQueue.main.async { self?.status = .failed("City not found") }
                return
            }
            self?.fetch(lat: hit.latitude, lon: hit.longitude, place: hit.name)
        }.resume()
    }

    private func fetch(lat: Double, lon: Double, place: String) {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "6"),
            .init(name: "temperature_unit", value: Prefs.bool(Prefs.weatherFahrenheit) ? "fahrenheit" : "celsius"),
        ]
        URLSession.shared.dataTask(with: c.url!) { [weak self] data, _, _ in
            struct R: Decodable {
                struct Current: Decodable {
                    let temperature2m: Double
                    let weatherCode: Int
                    let isDay: Int
                    enum CodingKeys: String, CodingKey {
                        case temperature2m = "temperature_2m", weatherCode = "weather_code", isDay = "is_day"
                    }
                }
                struct Daily: Decodable {
                    let time: [String]
                    let weatherCode: [Int]
                    let temperature2mMax: [Double]
                    let temperature2mMin: [Double]
                    enum CodingKeys: String, CodingKey {
                        case time, weatherCode = "weather_code"
                        case temperature2mMax = "temperature_2m_max", temperature2mMin = "temperature_2m_min"
                    }
                }
                let current: Current
                let daily: Daily
            }
            let decoder = JSONDecoder()
            guard let data, let r = try? decoder.decode(R.self, from: data), !r.daily.time.isEmpty else {
                DispatchQueue.main.async { self?.status = .failed("Weather unavailable") }
                return
            }
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            let days = r.daily.time.indices.map {
                Day(
                    id: r.daily.time[$0], date: parser.date(from: r.daily.time[$0]) ?? Date(), code: r.daily.weatherCode[$0],
                    high: r.daily.temperature2mMax[$0], low: r.daily.temperature2mMin[$0])
            }
            let report = Report(
                place: place, temperature: r.current.temperature2m, code: r.current.weatherCode,
                isDay: r.current.isDay == 1, high: days[0].high, low: days[0].low, days: Array(days.dropFirst().prefix(5)))
            DispatchQueue.main.async {
                self?.lastFetch = Date()
                self?.status = .idle
                withAnimation(Motion.content) { self?.report = report }
            }
        }.resume()
    }

    func loadPreview(_ r: Report) { report = r }

    /// WMO weather code → SF Symbol + French label.
    static func describe(_ code: Int, day: Bool = true) -> (symbol: String, label: String) {
        switch code {
        case 0: return (day ? "sun.max.fill" : "moon.stars.fill", day ? "Sunny" : "Clear")
        case 1, 2: return (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: return ("cloud.fill", "Cloudy")
        case 45, 48: return ("cloud.fog.fill", "Fog")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 66: return ("cloud.rain.fill", "Rain")
        case 65, 67: return ("cloud.heavyrain.fill", "Heavy rain")
        case 71, 73, 75, 77, 85, 86: return ("cloud.snow.fill", "Snow")
        case 80, 81, 82: return (day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Showers")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "Thunderstorm")
        default: return ("cloud.fill", "Cloudy")
        }
    }
}
