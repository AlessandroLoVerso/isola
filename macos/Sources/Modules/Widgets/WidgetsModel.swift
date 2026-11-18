import AppKit
import Foundation
import IsolaCore
import SwiftUI

// MARK: - Impostazioni (settings/widgets.json)

enum WidgetsFace: String, Codable { case clock, weather }
enum DayVertical: String, Codable, CaseIterable { case top, center, bottom }
enum DayHorizontal: String, Codable, CaseIterable { case left, center, right }

struct DaySettings: Codable, Equatable {
    /// L'orologio Day sul desktop. Spento di default.
    var pinned = false
    var color = "#FFFFFF"
    /// Corpo del giorno della settimana, in punti.
    var size: Double = 120
    var vertical: DayVertical = .top
    var horizontal: DayHorizontal = .center

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DaySettings()
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? d.pinned
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? d.color
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? d.size
        vertical = (try? c.decodeIfPresent(DayVertical.self, forKey: .vertical)) ?? d.vertical
        horizontal = (try? c.decodeIfPresent(DayHorizontal.self, forKey: .horizontal)) ?? d.horizontal
    }
}

struct WidgetsSettings: Codable, Equatable {
    /// Nessuna città predefinita: finché l'utente non la sceglie il meteo non chiede niente alla rete.
    var city = ""
    /// Nome completo del luogo scelto ("Palermo, Sicilia, Italia") e coordinate.
    var cityLabel: String?
    var latitude: Double?
    var longitude: Double?
    var timeZones = ["Europe/Rome", "America/New_York", "Asia/Tokyo"]
    /// "clock" lascia la pillola al modulo Ora; "weather" mostra temperatura e icona.
    var restingFace: WidgetsFace = .clock
    var day = DaySettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WidgetsSettings()
        city = (try? c.decodeIfPresent(String.self, forKey: .city)) ?? d.city
        cityLabel = try? c.decodeIfPresent(String.self, forKey: .cityLabel)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        timeZones = (try? c.decodeIfPresent([String].self, forKey: .timeZones)) ?? d.timeZones
        restingFace = (try? c.decodeIfPresent(WidgetsFace.self, forKey: .restingFace)) ?? d.restingFace
        day = (try? c.decodeIfPresent(DaySettings.self, forKey: .day)) ?? d.day
    }

    var hasPlace: Bool { latitude != nil && longitude != nil }
}

// MARK: - Da fare (data/widgets/todo.json)

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var created = Date()
}

struct TodoData: Codable { var items: [TodoItem] = [] }

@MainActor
final class TodoStore {
    private let url: URL
    var items: [TodoItem]

    init(directory: URL) {
        url = directory.appendingPathComponent("todo.json")
        items = JSONStore.load(TodoData.self, from: url, fallback: TodoData()).items
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func save() { JSONStore.save(TodoData(items: items), to: url) }
}

// MARK: - Fusi orari

enum Zones {
    /// I fusi proposti nelle impostazioni, con i nomi italiani delle città.
    static let known: [(id: String, name: String)] = [
        ("Europe/Rome", "Roma"), ("Europe/London", "Londra"), ("Europe/Lisbon", "Lisbona"),
        ("Europe/Paris", "Parigi"), ("Europe/Berlin", "Berlino"), ("Europe/Madrid", "Madrid"),
        ("Europe/Athens", "Atene"), ("Europe/Istanbul", "Istanbul"), ("Europe/Moscow", "Mosca"),
        ("Atlantic/Reykjavik", "Reykjavík"), ("Africa/Cairo", "Il Cairo"), ("Africa/Johannesburg", "Johannesburg"),
        ("Asia/Dubai", "Dubai"), ("Asia/Kolkata", "Nuova Delhi"), ("Asia/Bangkok", "Bangkok"),
        ("Asia/Singapore", "Singapore"), ("Asia/Shanghai", "Pechino"), ("Asia/Hong_Kong", "Hong Kong"),
        ("Asia/Seoul", "Seul"), ("Asia/Tokyo", "Tokyo"), ("Australia/Sydney", "Sydney"),
        ("Pacific/Auckland", "Auckland"), ("Pacific/Honolulu", "Honolulu"), ("America/Los_Angeles", "Los Angeles"),
        ("America/Denver", "Denver"), ("America/Chicago", "Chicago"), ("America/Mexico_City", "Città del Messico"),
        ("America/New_York", "New York"), ("America/Toronto", "Toronto"), ("America/Sao_Paulo", "San Paolo"),
        ("America/Argentina/Buenos_Aires", "Buenos Aires"), ("Etc/UTC", "UTC"),
    ]

    static func name(_ id: String) -> String {
        known.first { $0.id == id }?.name
            ?? (id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id)
    }

    static func offsetText(_ tz: TimeZone) -> String {
        let s = tz.secondsFromGMT()
        let a = abs(s)
        return String(format: "UTC%@%02d:%02d", s < 0 ? "−" : "+", a / 3600, (a % 3600) / 60)
    }
}

struct ClockRow: Identifiable, Equatable {
    var id: String
    var city: String
    var time: String
    var dayHint: String
}

// MARK: - Testi

@MainActor
enum WText {
    static let italian = Locale(identifier: "it_IT")
    private static var formatters: [String: DateFormatter] = [:]

    static func formatter(_ pattern: String, zone: TimeZone = .autoupdatingCurrent) -> DateFormatter {
        let key = pattern + "|" + zone.identifier
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = italian
        f.timeZone = zone
        f.dateFormat = pattern
        formatters[key] = f
        return f
    }

    static var is24h: Bool {
        let f = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "HH"
        return !f.contains("a")
    }

    static func time(_ d: Date, zone: TimeZone = .autoupdatingCurrent) -> String {
        if is24h { return formatter("HH:mm", zone: zone).string(from: d) }
        let f = formatter("h:mm a", zone: zone)
        f.locale = .autoupdatingCurrent
        return f.string(from: d)
    }

    /// "MERCOLEDÌ".
    static func weekdayUpper(_ d: Date) -> String { formatter("EEEE").string(from: d).uppercased(with: italian) }
    /// "18 novembre 2026".
    static func longDate(_ d: Date) -> String { formatter("d MMMM yyyy").string(from: d) }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
}

// MARK: - Meteo (Open-Meteo, senza chiave)

enum WeatherKind: Equatable { case clear, partlyCloudy, cloudy, fog, drizzle, rain, snow, thunder }

struct WeatherNow: Equatable, Sendable {
    var temperature: Double
    var code: Int
    var isDay: Bool
    var max: Double?
    var min: Double?

    var kind: WeatherKind { WeatherCodes.kind(code) }
    var label: String { WeatherCodes.label(code, isDay: isDay) }
    var temperatureText: String { "\(Int(temperature.rounded()))°" }
}

struct GeoPlace: Equatable, Identifiable, Sendable {
    var name: String
    var label: String
    var latitude: Double
    var longitude: Double
    var id: String { "\(latitude),\(longitude)" }
}

/// Solo il nome della città scritto dall'utente (e poi le sue coordinate) lascia il Mac.
enum WeatherClient {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "Isola/0.1"]
        return URLSession(configuration: c)
    }()

    enum Failure: Error { case badResponse(Int) }

    private static func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct GeoResponse: Decodable {
        struct Result: Decodable {
            var name: String
            var latitude: Double
            var longitude: Double
            var admin1: String?
            var country: String?
        }
        var results: [Result]?
    }

    static func geocode(_ city: String, count: Int) async throws -> [GeoPlace] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            .init(name: "name", value: city.trimmingCharacters(in: .whitespaces)),
            .init(name: "count", value: String(count)),
            .init(name: "language", value: "it"),
            .init(name: "format", value: "json"),
        ]
        let r = try await get(c.url!, as: GeoResponse.self)
        return (r.results ?? []).map { g in
            var parts = [g.name]
            if let a = g.admin1, !a.isEmpty, a != g.name { parts.append(a) }
            if let k = g.country, !k.isEmpty { parts.append(k) }
            return GeoPlace(name: g.name, label: parts.joined(separator: ", "), latitude: g.latitude, longitude: g.longitude)
        }
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var weather_code: Int
            var is_day: Int?
        }
        struct Daily: Decodable {
            var temperature_2m_max: [Double?]?
            var temperature_2m_min: [Double?]?
        }
        var current: Current
        var daily: Daily?
    }

    static func forecast(latitude: Double, longitude: Double) async throws -> WeatherNow {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
        ]
        let r = try await get(c.url!, as: ForecastResponse.self)
        return WeatherNow(temperature: r.current.temperature_2m, code: r.current.weather_code,
                          isDay: (r.current.is_day ?? 1) == 1,
                          max: r.daily?.temperature_2m_max?.first ?? nil,
                          min: r.daily?.temperature_2m_min?.first ?? nil)
    }
}

/// Codici meteo WMO di Open-Meteo.
enum WeatherCodes {
    static func kind(_ code: Int) -> WeatherKind {
        switch code {
        case 0, 1: .clear
        case 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .fog
        case 51, 53, 55, 56, 57: .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: .rain
        case 71, 73, 75, 77, 85, 86: .snow
        case 95, 96, 99: .thunder
        default: .cloudy
        }
    }

    static func label(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "Sereno" : "Notte serena"
        case 1: "Poco nuvoloso"
        case 2: "Parzialmente nuvoloso"
        case 3: "Coperto"
        case 45: "Nebbia"
        case 48: "Nebbia con brina"
        case 51: "Pioviggine leggera"
        case 53: "Pioviggine"
        case 55: "Pioviggine intensa"
        case 56, 57: "Pioviggine gelata"
        case 61: "Pioggia leggera"
        case 63: "Pioggia"
        case 65: "Pioggia forte"
        case 66, 67: "Pioggia gelata"
        case 71: "Neve leggera"
        case 73: "Neve"
        case 75: "Neve forte"
        case 77: "Nevischio"
        case 80: "Rovesci leggeri"
        case 81: "Rovesci"
        case 82: "Rovesci violenti"
        case 85, 86: "Rovesci di neve"
        case 95: "Temporale"
        case 96, 99: "Temporale con grandine"
        default: "Variabile"
        }
    }

    /// Un SF Symbol per il tipo di tempo.
    static func symbol(_ kind: WeatherKind, isDay: Bool) -> String {
        switch kind {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .snow: "cloud.snow.fill"
        case .thunder: "cloud.bolt.rain.fill"
        }
    }
}

// MARK: - Colori

enum HexColor {
    static let swatches: [(hex: String, name: String)] = [
        ("#FFFFFF", "Bianco"), ("#F3E9D2", "Panna"), ("#FFC56B", "Ambra"), ("#FF7A6B", "Corallo"),
        ("#F5A3C7", "Rosa"), ("#C3A6FF", "Lilla"), ("#7FB8FF", "Cielo"), ("#7BE0B0", "Menta"), ("#111114", "Nero"),
    ]

    static func color(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let a = hasAlpha ? Double((v >> 24) & 0xFF) / 255 : 1
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    static func hex(_ color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
