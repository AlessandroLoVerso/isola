import Foundation
import IsolaCore

/// Ripetizione di un promemoria (come nella versione Windows).
enum ReminderRepeat: String, Codable, CaseIterable {
    case none, daily, weekdays, weekly

    var label: String {
        switch self {
        case .none: "Mai"
        case .daily: "Ogni giorno"
        case .weekdays: "Giorni feriali"
        case .weekly: "Ogni settimana"
        }
    }

    var next: ReminderRepeat {
        switch self {
        case .none: .daily
        case .daily: .weekdays
        case .weekdays: .weekly
        case .weekly: .none
        }
    }
}

/// Ora locale "da orologio a muro": un promemoria per le 20:00 resta alle 20:00 anche se cambiano
/// il fuso o l'ora legale. Salvata come "yyyy-MM-dd HH:mm".
struct WallTime: Codable, Hashable, Comparable {
    var year: Int, month: Int, day: Int, hour: Int, minute: Int

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        (self.year, self.month, self.day, self.hour, self.minute) = (year, month, day, hour, minute)
    }

    init(_ date: Date) {
        let c = RemCal.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// Il momento corrispondente nel fuso attuale.
    var date: Date {
        RemCal.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
            ?? Date.distantFuture
    }

    private var key: [Int] { [year, month, day, hour, minute] }
    static func < (a: WallTime, b: WallTime) -> Bool { a.key.lexicographicallyPrecedes(b.key) }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        let parts = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 5 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "data non valida"))
        }
        self.init(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute))
    }
}

/// Un promemoria. `anchor` tiene l'ora (e il giorno della settimana) per cui la serie è stata
/// creata, così un "Rimanda" non sposta le ripetizioni.
struct Reminder: Codable, Identifiable {
    var id = UUID()
    var text: String
    var due: WallTime
    var anchor: WallTime
    var repeats: ReminderRepeat

    init(id: UUID = UUID(), text: String, due: WallTime, anchor: WallTime, repeats: ReminderRepeat) {
        (self.id, self.text, self.due, self.anchor, self.repeats) = (id, text, due, anchor, repeats)
    }

    enum CodingKeys: String, CodingKey { case id, text, due, anchor, repeats = "repeat" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        due = try c.decode(WallTime.self, forKey: .due)
        anchor = try c.decodeIfPresent(WallTime.self, forKey: .anchor) ?? due
        repeats = (try? c.decodeIfPresent(ReminderRepeat.self, forKey: .repeats)) ?? ReminderRepeat.none
    }
}

struct ReminderData: Codable {
    var items: [Reminder] = []
}

/// File JSON nella cartella dati del modulo.
@MainActor
final class ReminderStore {
    private let url: URL
    var items: [Reminder]

    init(directory: URL) {
        url = directory.appendingPathComponent("reminders.json")
        items = JSONStore.load(ReminderData.self, from: url, fallback: ReminderData()).items
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func save() { JSONStore.save(ReminderData(items: items), to: url) }
}

enum RemCal {
    static let italian = Locale(identifier: "it_IT")

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = italian
        c.timeZone = .autoupdatingCurrent
        c.firstWeekday = 2
        return c
    }
}

enum Recurrence {
    /// `day` va bene per la serie? (giorni feriali: lun-ven; settimanale: stesso giorno dell'ancora)
    static func matches(_ repeats: ReminderRepeat, day: Date, anchor: Date) -> Bool {
        let cal = RemCal.calendar
        let wd = cal.component(.weekday, from: day) // 1 = domenica, 7 = sabato
        switch repeats {
        case .weekdays: return wd != 1 && wd != 7
        case .weekly: return wd == cal.component(.weekday, from: anchor)
        default: return true
        }
    }

    /// Il giorno di `date` all'ora dell'ancora.
    private static func at(_ anchor: WallTime, on date: Date) -> Date {
        let cal = RemCal.calendar
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return WallTime(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1,
                        hour: anchor.hour, minute: anchor.minute).date
    }

    /// La prima occorrenza della serie strettamente dopo `after`.
    static func nextAfter(_ r: Reminder, after: Date) -> WallTime {
        let cal = RemCal.calendar
        let anchorDate = r.anchor.date
        var day = after
        for _ in 0..<9 {
            let candidate = at(r.anchor, on: day)
            if candidate > after && matches(r.repeats, day: candidate, anchor: anchorDate) { return WallTime(candidate) }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return WallTime(cal.date(byAdding: .day, value: 1, to: after) ?? after.addingTimeInterval(86_400))
    }

    /// Per un promemoria ripetuto nuovo: il momento scelto, spostato avanti fino a un giorno valido.
    static func firstOnOrAfter(_ repeats: ReminderRepeat, chosen: Date) -> Date {
        let cal = RemCal.calendar
        var c = chosen
        for _ in 0..<8 where !matches(repeats, day: c, anchor: chosen) {
            c = cal.date(byAdding: .day, value: 1, to: c) ?? c.addingTimeInterval(86_400)
        }
        return c
    }
}

/// Testi di data e ora in italiano; 12 o 24 ore come nelle Impostazioni di macOS.
@MainActor
enum RemText {
    private static var formatters: [String: DateFormatter] = [:]

    static func format(_ pattern: String, _ date: Date) -> String {
        if let f = formatters[pattern] { return f.string(from: date) }
        let f = DateFormatter()
        f.locale = RemCal.italian
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = pattern
        formatters[pattern] = f
        return f.string(from: date)
    }

    static var is24h: Bool {
        let f = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "HH"
        return !f.contains("a")
    }

    static func time(_ t: Date) -> String {
        if is24h { return format("HH:mm", t) }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "h:mm a"
        return f.string(from: t)
    }

    static func day(_ t: Date, now: Date) -> String {
        let cal = RemCal.calendar
        let d = cal.startOfDay(for: t), today = cal.startOfDay(for: now)
        let diff = cal.dateComponents([.day], from: today, to: d).day ?? 0
        switch diff {
        case 0: return "oggi"
        case 1: return "domani"
        case -1: return "ieri"
        case 2..<7: return format("EEEE", t)
        default: return format("EEE d MMM", t).replacingOccurrences(of: ".", with: "")
        }
    }

    static func when(_ t: Date, now: Date) -> String { "\(day(t, now: now)) \(time(t))" }

    /// "20", "20:30", "20.30", "2030", "8:5". Restituisce (ora, minuti).
    static func parseTime(_ s: String) -> (Int, Int)? {
        var s = s.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacingOccurrences(of: ".", with: ":").replacingOccurrences(of: ",", with: ":")
        guard !s.isEmpty else { return nil }
        var pm = false, am = false
        if s.hasSuffix("pm") { pm = true; s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        else if s.hasSuffix("am") { am = true; s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        var h: Int, m: Int
        if s.contains(":") {
            let p = s.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 2, let hh = Int(p[0]), let mm = Int(p[1]), p[1].count <= 2 else { return nil }
            (h, m) = (hh, mm)
        } else {
            guard s.allSatisfy(\.isNumber), let n = Int(s) else { return nil }
            switch s.count {
            case 1, 2: (h, m) = (n, 0)
            case 3, 4: (h, m) = (n / 100, n % 100)
            default: return nil
            }
        }
        if pm || am {
            guard (1...12).contains(h) else { return nil }
            if pm && h < 12 { h += 12 }
            if am && h == 12 { h = 0 }
        }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    enum DateParse { case invalid, next, day(Date) }

    /// "oggi", "domani", "dopodomani", "gg/mm", "gg/mm/aaaa". Vuoto = prossima occorrenza.
    static func parseDate(_ s: String, now: Date) -> DateParse {
        let cal = RemCal.calendar
        var s = s.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacingOccurrences(of: ".", with: "/").replacingOccurrences(of: "-", with: "/")
        let today = cal.startOfDay(for: now)
        switch s {
        case "": return .next
        case "oggi": return .day(today)
        case "domani": return .day(cal.date(byAdding: .day, value: 1, to: today) ?? today)
        case "dopodomani": return .day(cal.date(byAdding: .day, value: 2, to: today) ?? today)
        default: break
        }
        let p = s.split(separator: "/").map { Int($0) }
        guard p.count == 2 || p.count == 3, p.allSatisfy({ $0 != nil }) else { return .invalid }
        let d = p[0]!, m = p[1]!
        var y = p.count == 3 ? p[2]! : cal.component(.year, from: now)
        if p.count == 3 && y < 100 { y += 2000 }
        var comps = DateComponents(year: y, month: m, day: d)
        guard let date = cal.date(from: comps), cal.component(.day, from: date) == d,
              cal.component(.month, from: date) == m else { return .invalid }
        if p.count == 2 && date < today {
            comps.year = y + 1
            guard let next = cal.date(from: comps) else { return .invalid }
            return .day(next)
        }
        return .day(date)
    }
}
