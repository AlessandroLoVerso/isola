import AppKit
import IsolaCore
import SwiftUI

/// "Ora": scheda con l'ora grande, la data in italiano e il mese a colpo d'occhio; faccia a riposo
/// con l'ora (priorità 1). Sugli schermi con la notch la barra dei menu mostra già l'ora: lì la
/// faccia è spenta salvo l'opzione "Mostra l'ora accanto alla notch".
/// Timer: uno solo, allineato al minuto mentre la faccia o la scheda sono in vista, a ogni secondo
/// solo con la scheda aperta e i secondi accesi. Nient'altro gira nel frattempo.
public final class ClockModule: IslandModule, RestingFaceProvider {
    public init() {}
    public var id: String { "clock" }
    public var title: String { "Ora" }
    public var symbol: String { "clock" }
    public var order: Int { 100 }
    public var enabledByDefault: Bool { true }

    private let model = ClockModel()
    private weak var host: IslandHost?
    private var settings = ClockSettings()
    private var timer: Timer?
    private var cardVisible = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastPriority = 0

    // MARK: ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        settings = host.loadSettings(ClockSettings.self, fallback: ClockSettings())
        model.showSeconds = settings.showSeconds
        cardVisible = host.isCardVisible
        lastPriority = restingPriority
        host.onCardVisibilityChange { [weak self] visible in
            guard let self else { return }
            self.cardVisible = visible
            self.tick()
        }

        let nc = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observe(nc, name) { $0.tick() }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.tick() }
        // Un monitor esterno senza notch (o il ritorno al MacBook) cambia la priorità.
        observe(nc, NSApplication.didChangeScreenParametersNotification) { $0.priorityMaybeChanged() }
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        cardVisible = false
        host = nil
    }

    public func makeCard() -> AnyView? { AnyView(ClockCard(model: model)) }

    public func makeSettings() -> AnyView? {
        AnyView(ClockSettingsView(
            showSeconds: settings.showSeconds,
            showNextToNotch: settings.showNextToNotch,
            hasNotch: host?.screenHasNotch ?? false,
            onSeconds: { [weak self] in self?.setShowSeconds($0) },
            onNotch: { [weak self] in self?.setShowNextToNotch($0) }))
    }

    // MARK: faccia a riposo

    public var restingPriority: Int {
        guard let host else { return 0 }
        if host.screenHasNotch { return settings.showNextToNotch ? 1 : 0 }
        return 1
    }

    public func makeRestingFace() -> RestingFace {
        RestingFace(sideWidth: 72, leading: ClockFaceLeading(model: model), trailing: ClockFaceTrailing(model: model))
    }

    // MARK: impostazioni

    private func setShowSeconds(_ on: Bool) {
        settings.showSeconds = on
        model.showSeconds = on
        host?.saveSettings(settings)
        tick()
    }

    private func setShowNextToNotch(_ on: Bool) {
        settings.showNextToNotch = on
        host?.saveSettings(settings)
        priorityMaybeChanged()
    }

    private func priorityMaybeChanged() {
        let p = restingPriority
        if p != lastPriority {
            lastPriority = p
            host?.refreshRestingFace()
        }
        tick()
    }

    // MARK: tempo

    /// Aggiorna i testi e programma il prossimo giro: a ogni secondo con la scheda aperta e i
    /// secondi accesi, altrimenti all'inizio del prossimo minuto; nessun timer se niente è in vista.
    private func tick() {
        timer?.invalidate()
        timer = nil
        guard host != nil else { return }
        let now = Date()
        model.update(now)

        let fast = cardVisible && settings.showSeconds
        guard fast || cardVisible || restingPriority > 0 else { return }
        let t = now.timeIntervalSinceReferenceDate
        let wait = fast
            ? (1 - t.truncatingRemainder(dividingBy: 1)) + 0.015
            : (60 - t.truncatingRemainder(dividingBy: 60)) + 0.03
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = fast ? 0.02 : 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (ClockModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}

struct ClockSettings: Codable {
    var showSeconds = true
    var showNextToNotch = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showSeconds = try c.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? true
        showNextToNotch = try c.decodeIfPresent(Bool.self, forKey: .showNextToNotch) ?? false
    }
}

// MARK: - Modello

struct MonthCell: Identifiable, Equatable {
    let id: Int
    let day: Int?
    let isToday: Bool
    let isWeekend: Bool
}

@MainActor
final class ClockModel: ObservableObject {
    @Published var time = ""
    @Published var seconds = ""
    @Published var date = ""
    @Published var shortDate = ""
    @Published var week = ""
    @Published var monthTitle = ""
    @Published var cells: [MonthCell] = []
    @Published var showSeconds = true

    private var builtDay = ""

    func update(_ now: Date) {
        set(\.time, ClockText.time(now))
        set(\.seconds, ClockText.format("ss", now))
        let dayKey = ClockText.format("yyyy-MM-dd", now)
        guard dayKey != builtDay else { return }
        // Il resto cambia una volta al giorno (o con il fuso).
        builtDay = dayKey
        date = ClockText.capitalized(ClockText.format("EEEE d MMMM", now))
        shortDate = ClockText.format("EEE d MMM", now).replacingOccurrences(of: ".", with: "")
        let cal = ClockText.calendar
        let weekNo = cal.component(.weekOfYear, from: now)
        let dayNo = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        week = "Settimana \(weekNo) · giorno \(dayNo) dell'anno"
        monthTitle = ClockText.capitalized(ClockText.format("LLLL yyyy", now))
        cells = Self.month(of: now)
    }

    private func set(_ key: ReferenceWritableKeyPath<ClockModel, String>, _ value: String) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// Le caselle del mese, da lunedì: vuote prima del primo giorno, poi 1...n.
    private static func month(of now: Date) -> [MonthCell] {
        let cal = ClockText.calendar
        guard let first = cal.dateInterval(of: .month, for: now)?.start,
              let days = cal.range(of: .day, in: .month, for: now)?.count else { return [] }
        let weekday = cal.component(.weekday, from: first) // 1 = domenica
        let lead = (weekday + 5) % 7                         // lunedì = 0
        let today = cal.component(.day, from: now)
        var cells: [MonthCell] = []
        for i in 0..<lead { cells.append(MonthCell(id: -1 - i, day: nil, isToday: false, isWeekend: false)) }
        for d in 1...days {
            let column = (lead + d - 1) % 7
            cells.append(MonthCell(id: d, day: d, isToday: d == today, isWeekend: column >= 5))
        }
        return cells
    }
}

/// Testi di data e ora in italiano; 12 o 24 ore come nelle Impostazioni di macOS.
enum ClockText {
    static let italian = Locale(identifier: "it_IT")

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = italian
        c.timeZone = .autoupdatingCurrent
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4 // settimane ISO
        return c
    }

    static var is24h: Bool {
        let f = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "HH"
        return !f.contains("a")
    }

    @MainActor private static var formatters: [String: DateFormatter] = [:]

    @MainActor static func format(_ pattern: String, _ date: Date) -> String {
        if let f = formatters[pattern] { return f.string(from: date) }
        let f = DateFormatter()
        f.locale = italian
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = pattern
        formatters[pattern] = f
        return f.string(from: date)
    }

    @MainActor static func time(_ date: Date) -> String { format(is24h ? "HH:mm" : "h:mm", date) }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

// MARK: - Viste

struct ClockCard: View {
    @ObservedObject var model: ClockModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(model.time)
                        .font(.system(size: 64, weight: .light).monospacedDigit())
                        .foregroundStyle(theme.foreground)
                    if model.showSeconds {
                        Text(model.seconds)
                            .font(.system(size: 22, weight: .regular).monospacedDigit())
                            .foregroundStyle(theme.muted)
                    }
                }
                .lineLimit(1)
                Text(model.date)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.muted)
                    .padding(.top, 0)
                Text(model.week)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted.opacity(0.75))
                    .padding(.top, 6)
            }
            .padding(.leading, 8)
            Spacer(minLength: 0)
            MonthView(model: model)
                .frame(width: 196)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MonthView: View {
    @ObservedObject var model: ClockModel
    @Environment(\.island) private var theme
    private static let initials = ["L", "M", "M", "G", "V", "S", "D"]
    private let columns = Array(repeating: GridItem(.fixed(24), spacing: 3), count: 7)

    var body: some View {
        IslandSurface(padding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.monthTitle)
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                    .padding(.leading, 4)
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(Array(Self.initials.enumerated()), id: \.offset) { _, letter in
                        Text(letter)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(theme.muted)
                            .frame(height: 14)
                    }
                    ForEach(model.cells) { cell in
                        dayCell(cell)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ cell: MonthCell) -> some View {
        if let day = cell.day {
            Text("\(day)")
                .font(IslandFont.mono(11, weight: cell.isToday ? .bold : .regular))
                .foregroundStyle(cell.isToday ? Color.white : (cell.isWeekend ? theme.muted : theme.foreground))
                .frame(width: 22, height: 19)
                .background(Circle().fill(cell.isToday ? theme.accent : Color.clear).frame(width: 20, height: 20))
        } else {
            Color.clear.frame(width: 22, height: 19)
        }
    }
}

struct ClockFaceLeading: View {
    @ObservedObject var model: ClockModel
    @Environment(\.island) private var theme

    var body: some View {
        Text(model.time)
            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(theme.foreground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
    }
}

struct ClockFaceTrailing: View {
    @ObservedObject var model: ClockModel
    @Environment(\.island) private var theme

    var body: some View {
        Text(model.shortDate)
            .font(.system(size: 12))
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 8)
    }
}

struct ClockSettingsView: View {
    @State var showSeconds: Bool
    @State var showNextToNotch: Bool
    let hasNotch: Bool
    let onSeconds: (Bool) -> Void
    let onNotch: (Bool) -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Mostra i secondi nella scheda", isOn: $showSeconds)
                    .onChange(of: showSeconds) { _, v in onSeconds(v) }
            }
            Section {
                Toggle("Mostra l'ora accanto alla notch", isOn: $showNextToNotch)
                    .onChange(of: showNextToNotch) { _, v in onNotch(v) }
            } footer: {
                Text(hasNotch
                     ? "La barra dei menu mostra già l'ora: di solito non serve."
                     : "Questo schermo non ha la notch: l'ora resta comunque sulla pillola.")
            }
        }
    }
}
