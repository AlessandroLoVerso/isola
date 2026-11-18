import AppKit
import IsolaCore
import SwiftUI

/// "Widget": fusi orari, meteo (Open-Meteo), timer di concentrazione 25/5, lista "Da fare" e
/// l'orologio Day sul desktop (facoltativo, spento di default).
/// Timer: gli orologi girano una volta al minuto solo con la scheda aperta; il Day si aggiorna a
/// mezzanotte (notifica di sistema); il meteo si chiede al massimo ogni 30 minuti, solo con la
/// scheda aperta o se la pillola lo mostra; il timer di concentrazione dorme fino alla fine della
/// fase (i secondi li conta SwiftUI, `Text(timerInterval:)`).
public final class WidgetsModule: IslandModule, RestingFaceProvider, PeekProvider {
    public init() {}
    public var id: String { "widgets" }
    public var title: String { "Widget" }
    public var symbol: String { "square.grid.2x2" }
    public var order: Int { 60 }
    public var enabledByDefault: Bool { true }

    static let focusLength: TimeInterval = 25 * 60
    static let breakLength: TimeInterval = 5 * 60
    private static let weatherEvery: TimeInterval = 30 * 60
    private static let weatherRetry: TimeInterval = 5 * 60
    private static let alertLength: TimeInterval = 8

    let vm = WidgetsViewModel()
    private weak var host: IslandHost?
    private var settings = WidgetsSettings()
    private var todo: TodoStore?
    private var cardVisible = false
    private var priority = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var minuteTimer: Timer?
    private var weatherTimer: Timer?
    private var focusTimer: Timer?
    private var alertTimer: Timer?
    private var weatherTask: Task<Void, Never>?
    private var weatherGeneration = 0
    private var weatherFetched: Date?
    private var weatherAttempt: Date?
    private var dayWindow: DayDesktopWindow?

    // Timer di concentrazione
    private var focusOnBreak = false
    private var focusRunning = false
    private var focusEndsAt = Date()
    private var focusRemaining = WidgetsModule.focusLength

    // MARK: ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        settings = host.loadSettings(WidgetsSettings.self, fallback: WidgetsSettings())
        var seen = Set<String>()
        settings.timeZones = settings.timeZones
            .filter { TimeZone(identifier: $0) != nil && seen.insert($0).inserted }
            .prefix(4).map { $0 }
        vm.module = self
        vm.settings = settings
        vm.weather = nil
        vm.weatherBusy = false
        vm.weatherCity = Self.shortCity(settings.cityLabel ?? settings.city)
        vm.weatherStatus = settings.city.isEmpty && !settings.hasPlace ? "Scegli una città" : ""
        todo = TodoStore(directory: host.dataDirectory)
        publishTodo()
        weatherFetched = nil
        weatherAttempt = nil
        focusOnBreak = false
        focusRunning = false
        focusRemaining = Self.focusLength
        priority = 0
        cardVisible = host.isCardVisible

        host.onCardVisibilityChange { [weak self] visible in self?.cardVisibilityChanged(visible) }
        let nc = NotificationCenter.default
        observe(nc, .NSSystemClockDidChange) { $0.timeChanged() }
        observe(nc, .NSSystemTimeZoneDidChange) { $0.timeChanged() }
        observe(nc, .NSCalendarDayChanged) { $0.updateClocks() }
        observe(nc, NSApplication.didChangeScreenParametersNotification) { $0.dayWindow?.reposition() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.didWake() }

        updateClocks()
        updateFocusView()
        scheduleMinute()
        if settings.restingFace == .weather { refreshWeather(force: true) }
        if settings.day.pinned { showDay(true) }
        updatePriority()
    }

    public func stop() {
        for t in [minuteTimer, weatherTimer, focusTimer, alertTimer] { t?.invalidate() }
        minuteTimer = nil; weatherTimer = nil; focusTimer = nil; alertTimer = nil
        weatherTask?.cancel()
        weatherTask = nil
        weatherGeneration += 1
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        showDay(false)
        focusRunning = false
        vm.alertActive = false
        vm.weatherBusy = false
        vm.module = nil
        todo = nil
        cardVisible = false
        priority = 0
        host = nil
    }

    public func makeCard() -> AnyView? { AnyView(WidgetsCard(vm: vm)) }

    public func makeSettings() -> AnyView? { AnyView(WidgetsSettingsView(vm: vm)) }

    // MARK: faccia e peek

    public var restingPriority: Int { priority }

    public func makeRestingFace() -> RestingFace {
        RestingFace(sideWidth: 72, leading: WidgetsFaceLeading(vm: vm), trailing: WidgetsFaceTrailing(vm: vm))
    }

    public func makePeek() -> AnyView { AnyView(WidgetsPeek(vm: vm)) }

    private func updatePriority() {
        let p: Int
        if focusRunning || vm.alertActive { p = 55 }
        else if settings.restingFace == .weather && vm.weather != nil { p = 2 }
        else { p = 0 }
        vm.faceMode = focusRunning || vm.alertActive ? .focus : .weather
        guard p != priority else { return }
        priority = p
        host?.refreshRestingFace()
    }

    // MARK: eventi di sistema

    private func cardVisibilityChanged(_ visible: Bool) {
        cardVisible = visible
        if visible {
            updateClocks()
            refreshWeather(force: false)
        }
        scheduleMinute()
    }

    private func timeChanged() {
        updateClocks()
        scheduleMinute()
        scheduleFocus()
    }

    private func didWake() {
        updateClocks()
        scheduleMinute()
        if focusRunning && Date() >= focusEndsAt { focusTick() } else { scheduleFocus() }
        // La rete ha bisogno di un momento dopo il risveglio.
        if settings.restingFace == .weather { scheduleWeather(after: 15) }
        dayWindow?.reposition()
    }

    // MARK: orologi

    private func scheduleMinute() {
        minuteTimer?.invalidate()
        minuteTimer = nil
        guard cardVisible else { return }
        let t = Date().timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 60 - t.truncatingRemainder(dividingBy: 60) + 0.04, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateClocks()
                self?.scheduleMinute()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func updateClocks() {
        let now = Date()
        let local = WText.calendar(.autoupdatingCurrent)
        func dayKey(_ cal: Calendar) -> Int {
            let c = cal.dateComponents([.year, .month, .day], from: now)
            return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
        }
        let today = dayKey(local)
        let rows: [ClockRow] = settings.timeZones.compactMap { id in
            guard let tz = TimeZone(identifier: id) else { return nil }
            let other = dayKey(WText.calendar(tz))
            let hint = other > today ? "+1g" : (other < today ? "−1g" : "")
            return ClockRow(id: id, city: Zones.name(id), time: WText.time(now, zone: tz), dayHint: hint)
        }
        if vm.clocks != rows { vm.clocks = rows }
        let weekday = WText.weekdayUpper(now), date = WText.longDate(now)
        if vm.weekday != weekday { vm.weekday = weekday }
        if vm.dateLine != date { vm.dateLine = date }
    }

    // MARK: meteo

    private func scheduleWeather(after delay: TimeInterval) {
        weatherTimer?.invalidate()
        weatherTimer = nil
        // Il timer serve solo se la pillola mostra il meteo; altrimenti si chiede all'apertura della scheda.
        guard host != nil, settings.restingFace == .weather, settings.hasPlace || !settings.city.isEmpty else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWeather(force: true) }
        }
        t.tolerance = min(60, delay * 0.1)
        RunLoop.main.add(t, forMode: .common)
        weatherTimer = t
    }

    /// Senza `force` non fa niente se i dati hanno meno di 30 minuti (o se l'ultimo tentativo
    /// fallito è di meno di un minuto fa).
    func refreshWeather(force: Bool) {
        guard host != nil, !vm.weatherBusy else { return }
        guard settings.hasPlace || !settings.city.isEmpty else {
            vm.weather = nil
            vm.weatherStatus = "Scegli una città"
            return
        }
        let now = Date()
        if !force {
            if vm.weather != nil, let f = weatherFetched, now.timeIntervalSince(f) < Self.weatherEvery { return }
            if vm.weather == nil, let a = weatherAttempt, now.timeIntervalSince(a) < 60 { return }
        }
        weatherAttempt = now
        weatherTimer?.invalidate()
        weatherTimer = nil
        vm.weatherBusy = true
        if vm.weather == nil { vm.weatherStatus = "Caricamento del meteo…" }
        weatherGeneration += 1
        let generation = weatherGeneration
        let snapshot = settings

        weatherTask = Task { [weak self] in
            var ok = false
            var place: GeoPlace?
            var weather: WeatherNow?
            var failure: Error?
            do {
                if snapshot.hasPlace, let lat = snapshot.latitude, let lon = snapshot.longitude {
                    weather = try await WeatherClient.forecast(latitude: lat, longitude: lon)
                } else if let found = try await WeatherClient.geocode(snapshot.city, count: 1).first {
                    place = found
                    weather = try await WeatherClient.forecast(latitude: found.latitude, longitude: found.longitude)
                }
                ok = true
            } catch {
                failure = error
            }
            guard let self, self.host != nil, generation == self.weatherGeneration, !Task.isCancelled else { return }
            self.vm.weatherBusy = false
            self.weatherTask = nil
            if let place {
                self.settings.city = place.name
                self.settings.cityLabel = place.label
                self.settings.latitude = place.latitude
                self.settings.longitude = place.longitude
                self.save()
            }
            if let weather {
                self.vm.weather = weather
                self.vm.weatherCity = Self.shortCity(self.settings.cityLabel ?? self.settings.city)
                self.vm.weatherStatus = ""
                self.weatherFetched = Date()
            } else if ok {
                // Nessun risultato per quel nome.
                self.vm.weather = nil
                self.vm.weatherStatus = "Città non trovata: \(snapshot.city)"
                self.settings.cityLabel = nil
                self.save()
            } else {
                self.host?.log("meteo non disponibile (\(Self.describe(failure)))")
                if self.vm.weather == nil { self.vm.weatherStatus = "Meteo non disponibile. Tocca per riprovare." }
            }
            self.updatePriority()
            if weather != nil || !ok { self.scheduleWeather(after: ok ? Self.weatherEvery : Self.weatherRetry) }
        }
    }

    /// Solo il tipo di errore: l'URL contiene la città e non va nel log.
    private static func describe(_ error: Error?) -> String {
        if let u = error as? URLError { return "rete \(u.code.rawValue)" }
        if let f = error as? WeatherClient.Failure, case .badResponse(let code) = f { return "HTTP \(code)" }
        if error is DecodingError { return "risposta illeggibile" }
        return "errore"
    }

    /// Tocco sulla casella del meteo: riprova se manca, altrimenti aggiorna solo se è vecchio.
    func weatherTapped() { refreshWeather(force: vm.weather == nil) }

    /// Città scritta nella scheda: si prende il primo risultato.
    func setCityName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        settings.city = name
        settings.cityLabel = nil
        settings.latitude = nil
        settings.longitude = nil
        placeChanged()
    }

    /// Luogo scelto tra i risultati nelle impostazioni.
    func setPlace(_ place: GeoPlace) {
        settings.city = place.name
        settings.cityLabel = place.label
        settings.latitude = place.latitude
        settings.longitude = place.longitude
        placeChanged()
    }

    func clearPlace() {
        settings.city = ""
        settings.cityLabel = nil
        settings.latitude = nil
        settings.longitude = nil
        placeChanged()
    }

    private func placeChanged() {
        weatherTask?.cancel()
        weatherTask = nil
        weatherGeneration += 1
        vm.weatherBusy = false
        vm.weather = nil
        weatherFetched = nil
        weatherAttempt = nil
        vm.weatherCity = Self.shortCity(settings.cityLabel ?? settings.city)
        vm.editingCity = false
        save()
        updatePriority()
        refreshWeather(force: true)
    }

    func searchPlaces(_ name: String) async -> Result<[GeoPlace], Error> {
        do { return .success(try await WeatherClient.geocode(name, count: 6)) }
        catch {
            host?.log("ricerca della città non riuscita (\(Self.describe(error)))")
            return .failure(error)
        }
    }

    private static func shortCity(_ label: String) -> String {
        label.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
    }

    // MARK: timer di concentrazione (25/5)

    func focusToggle() {
        let now = Date()
        if focusRunning {
            focusRemaining = max(0, focusEndsAt.timeIntervalSince(now))
            focusRunning = false
        } else {
            if focusRemaining <= 0 { focusRemaining = focusOnBreak ? Self.breakLength : Self.focusLength }
            focusEndsAt = now.addingTimeInterval(focusRemaining)
            focusRunning = true
        }
        updateFocusView()
        scheduleFocus()
        updatePriority()
    }

    func focusReset() {
        focusRunning = false
        focusOnBreak = false
        focusRemaining = Self.focusLength
        updateFocusView()
        scheduleFocus()
        updatePriority()
    }

    private func focusTick() {
        if focusRunning && Date() >= focusEndsAt.addingTimeInterval(-0.05) { focusPhaseEnded() }
        updateFocusView()
        scheduleFocus()
        updatePriority()
    }

    private func focusPhaseEnded() {
        if !focusOnBreak {
            // Concentrazione finita: la pausa parte da sola.
            focusOnBreak = true
            focusRemaining = Self.breakLength
            focusEndsAt = Date().addingTimeInterval(Self.breakLength)
            focusRunning = true
            alert(title: "Pausa", text: "25 minuti fatti · 5 di pausa")
        } else {
            focusOnBreak = false
            focusRemaining = Self.focusLength
            focusRunning = false
            alert(title: "Pausa finita", text: "Pronto per altri 25 minuti")
        }
    }

    /// Un solo timer, alla fine della fase: i secondi sullo schermo li conta SwiftUI.
    private func scheduleFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        guard focusRunning else { return }
        let wait = max(0.01, focusEndsAt.timeIntervalSinceNow)
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusTick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        focusTimer = t
    }

    private func updateFocusView() {
        let total = focusOnBreak ? Self.breakLength : Self.focusLength
        let left = focusRunning ? max(0, focusEndsAt.timeIntervalSinceNow) : focusRemaining
        vm.focusRunning = focusRunning
        vm.focusBreak = focusOnBreak
        vm.focusEndsAt = focusEndsAt
        vm.focusTotal = total
        vm.focusRemaining = left
        vm.focusPhase = focusOnBreak ? "Pausa" : (focusRunning || left < total ? "Concentrazione" : "Timer 25 / 5")
    }

    private func alert(title: String, text: String) {
        vm.alertTitle = title
        vm.alertText = text
        vm.alertActive = true
        alertTimer?.invalidate()
        let t = Timer(timeInterval: Self.alertLength, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.vm.alertActive = false
                self.alertTimer = nil
                self.updatePriority()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        alertTimer = t
        updatePriority()
        host?.attention(duration: Self.alertLength)
    }

    // MARK: da fare

    @discardableResult
    func todoAdd(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let todo, !text.isEmpty else { return false }
        todo.items.append(TodoItem(text: String(text.prefix(120))))
        todo.save()
        publishTodo()
        return true
    }

    func todoToggle(_ id: UUID) {
        guard let todo, let i = todo.items.firstIndex(where: { $0.id == id }) else { return }
        todo.items[i].done.toggle()
        todo.save()
        publishTodo()
    }

    func todoDelete(_ id: UUID) {
        guard let todo else { return }
        todo.items.removeAll { $0.id == id }
        todo.save()
        publishTodo()
    }

    private func publishTodo() {
        let items = todo?.items ?? []
        vm.todos = items.filter { !$0.done }.sorted { $0.created < $1.created }
            + items.filter(\.done).sorted { $0.created > $1.created }
    }

    // MARK: impostazioni

    func requestKeyboardFocus() { host?.requestKeyboardFocus() }

    /// Ogni modifica dalle impostazioni passa di qui: salva e applica solo ciò che è cambiato.
    func updateSettings(_ change: (inout WidgetsSettings) -> Void) {
        let old = settings
        change(&settings)
        guard settings != old else { return }
        save()
        if settings.timeZones != old.timeZones { updateClocks() }
        if settings.restingFace != old.restingFace {
            if settings.restingFace == .weather { refreshWeather(force: false) }
            if settings.restingFace == .weather, vm.weather != nil, weatherTimer == nil, !vm.weatherBusy {
                let age = weatherFetched.map { Date().timeIntervalSince($0) } ?? Self.weatherEvery
                scheduleWeather(after: max(1, Self.weatherEvery - age))
            }
            if settings.restingFace == .clock { weatherTimer?.invalidate(); weatherTimer = nil }
            updatePriority()
        }
        if settings.day != old.day {
            if settings.day.pinned != old.day.pinned { showDay(settings.day.pinned) }
            dayWindow?.apply(settings.day)
        }
    }

    private func save() {
        vm.settings = settings
        host?.saveSettings(settings)
    }

    // MARK: Day sul desktop

    private func showDay(_ show: Bool) {
        if !show {
            dayWindow?.close()
            dayWindow = nil
            return
        }
        guard dayWindow == nil, host != nil else { return }
        updateClocks()
        dayWindow = DayDesktopWindow(vm: vm, settings: settings.day)
    }

    // MARK: utilità

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (WidgetsModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}

// MARK: - Modello delle viste

@MainActor
final class WidgetsViewModel: ObservableObject {
    weak var module: WidgetsModule?
    @Published var settings = WidgetsSettings()

    // Orologi
    @Published var clocks: [ClockRow] = []
    @Published var weekday = ""
    @Published var dateLine = ""

    // Meteo
    @Published var weather: WeatherNow?
    @Published var weatherStatus = ""
    @Published var weatherCity = ""
    @Published var weatherBusy = false
    @Published var editingCity = false
    @Published var cityDraft = ""

    // Concentrazione
    @Published var focusRunning = false
    @Published var focusBreak = false
    @Published var focusEndsAt = Date()
    @Published var focusTotal = WidgetsModule.focusLength
    @Published var focusRemaining = WidgetsModule.focusLength
    @Published var focusPhase = "Timer 25 / 5"

    // Avviso di fine fase e faccia
    enum FaceMode { case weather, focus }
    @Published var faceMode: FaceMode = .weather
    @Published var alertActive = false
    @Published var alertTitle = ""
    @Published var alertText = ""

    // Da fare
    @Published var todos: [TodoItem] = []
    @Published var todoDraft = ""

    var hasCity: Bool { settings.hasPlace || !settings.city.isEmpty }

    /// L'intervallo della fase in corso (per `Text(timerInterval:)` e la barra).
    var focusInterval: ClosedRange<Date> {
        let start = focusEndsAt.addingTimeInterval(-focusTotal)
        return start...max(start, focusEndsAt)
    }

    static func clockText(_ seconds: TimeInterval) -> String {
        let s = Int((seconds - 0.001).rounded(.up))
        return String(format: "%02d:%02d", max(0, s) / 60, max(0, s) % 60)
    }
}
