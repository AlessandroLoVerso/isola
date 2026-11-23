import AppKit
import EventKit
import IsolaCore
import SwiftUI

/// "Calendario": gli eventi di oggi e domani, il conto alla rovescia accanto alla notch quando il
/// prossimo sta per cominciare e un avviso 5 minuti prima. Chiede l'accesso al Calendario solo
/// quando premi il pulsante. A riposo c'è un solo timer, puntato al prossimo momento utile.
public final class CalendarModule: IslandModule, RestingFaceProvider, PeekProvider {
    public init() {}
    public var id: String { "calendar" }
    public var title: String { "Calendario" }
    public var symbol: String { "calendar" }
    public var order: Int { 45 }
    public var enabledByDefault: Bool { true }

    private var host: IslandHost?
    private let model = CalendarModel()
    private var store: EKEventStore?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var reloadWork: DispatchWorkItem?
    private var events: [CalendarEvent] = []
    /// Il giorno per cui `events` copre oggi e domani.
    private var loadedDay: Date?
    /// Eventi già annunciati. Resta tra uno spegnimento e l'altro: un avviso per evento.
    private var peeked = Set<String>()
    private var lastPriority = 0

    static let peekLead: TimeInterval = 5 * 60
    static let nowWindow: TimeInterval = 5 * 60

    // MARK: ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        model.settings = host.loadSettings(CalendarSettings.self, fallback: CalendarSettings())
        model.requestAccess = { [weak self] in self?.requestAccess() }
        model.access = Self.currentAccess()
        lastPriority = 0
        host.onCardVisibilityChange { [weak self] visible in
            // L'accesso può essere cambiato in Impostazioni di Sistema mentre Isola era aperta.
            if visible { self?.recheckAccess() }
        }
        if model.access == .granted { connect() }
    }

    public func stop() {
        host = nil // Prima: spegnendo non si richiama l'isola.
        disconnect()
        model.requestAccess = nil
        lastPriority = 0
    }

    // MARK: accesso

    static func currentAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    private func recheckAccess() {
        let access = Self.currentAccess()
        guard access != model.access else { return }
        model.access = access
        if access == .granted { connect() } else { disconnect() }
    }

    /// Solo da un clic dell'utente.
    private func requestAccess() {
        guard host != nil else { return }
        let store = self.store ?? EKEventStore()
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.host != nil else { return }
                self.model.access = Self.currentAccess()
                self.host?.log("Accesso al Calendario: \(self.model.access == .granted ? "concesso" : "non concesso")")
                if self.model.access == .granted { self.connect(store: store) }
            }
        }
    }

    // MARK: collegamento a EventKit

    private func connect(store existing: EKEventStore? = nil) {
        guard host != nil, self.store == nil else { reload(); return }
        let store = existing ?? EKEventStore()
        self.store = store

        let center = NotificationCenter.default
        observe(center, .EKEventStoreChanged, object: store) { [weak self] in self?.scheduleReload() }
        observe(center, .NSCalendarDayChanged) { [weak self] in self?.reload() }
        observe(center, .NSSystemClockDidChange) { [weak self] in self?.reload() }
        observe(center, .NSSystemTimeZoneDidChange) { [weak self] in self?.reload() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.reload() }
        reload()
    }

    private func disconnect() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        reloadWork?.cancel()
        reloadWork = nil
        timer?.invalidate()
        timer = nil
        store = nil
        events = []
        loadedDay = nil
        model.today = []
        model.tomorrow = []
        model.calendars = []
        model.face = nil
        refreshPriority()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                         _ action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    /// Le modifiche arrivano a raffica durante una sincronizzazione: una lettura sola.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadWork = nil
                self?.reload()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: lettura

    private func reload() {
        guard let store, host != nil else { return }
        let now = Date()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 2, to: startOfToday) else { return }
        loadedDay = startOfToday

        let all = store.calendars(for: .event)
        model.calendars = all
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                source: $0.source?.title ?? "", color: Color(cgColor: $0.cgColor)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        let selected = all.filter { !model.settings.excludedCalendars.contains($0.calendarIdentifier) }

        if selected.isEmpty {
            events = []
        } else {
            let predicate = store.predicateForEvents(withStart: startOfToday, end: end, calendars: selected)
            events = store.events(matching: predicate)
                .filter { $0.status != .canceled && !Self.declined($0) }
                .map(CalendarEvent.init)
                .sorted { a, b in
                    if a.isAllDay != b.isAllDay { return a.isAllDay }
                    return a.start != b.start ? a.start < b.start : a.title < b.title
                }
        }
        update()
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    // MARK: tempo

    /// Ricalcola lista, faccia e avvisi, poi punta il timer al prossimo cambiamento.
    private func update() {
        timer?.invalidate()
        timer = nil
        guard host != nil, store != nil else { return }
        let now = Date()
        let cal = Calendar.current
        // Dopo mezzanotte "domani" diventa "oggi": si rilegge.
        if loadedDay != cal.startOfDay(for: now) { reload(); return }
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now

        let visible = events.filter { $0.end > now }
        model.now = now
        model.today = visible.filter { $0.start < startOfTomorrow }
        model.tomorrow = visible.filter { $0.start >= startOfTomorrow }

        // Faccia: il prossimo evento entro l'anticipo scelto, altrimenti quello appena cominciato.
        let lead = TimeInterval(model.settings.leadMinutes * 60)
        let timed = visible.filter { !$0.isAllDay }
        let upcoming = timed.first { $0.start > now && $0.start.timeIntervalSince(now) <= lead }
        let current = timed.last { $0.start <= now && now.timeIntervalSince($0.start) < Self.nowWindow }
        if let e = upcoming ?? current {
            let face = CalendarFace(event: e, label: Self.countdown(to: e.start, now: now))
            if model.face != face { model.face = face }
        } else if model.face != nil {
            model.face = nil
        }
        refreshPriority()

        // Avviso 5 minuti prima, una volta per evento.
        // Più eventi alla stessa ora: si annuncia il primo.
        let due = timed.filter { e in
            let left = e.start.timeIntervalSince(now)
            return left > 0 && left <= Self.peekLead && !peeked.contains(e.id)
        }
        due.forEach { peeked.insert($0.id) }
        if let first = due.first, model.settings.peek {
            model.peekEvent = first
            host?.attention(duration: 5)
        }
        if peeked.count > 200 { peeked = Set(peeked.filter { key in events.contains { $0.id == key } }) }

        scheduleTimer(after: now, visible: visible, lead: lead, startOfTomorrow: startOfTomorrow)
    }

    private func scheduleTimer(after now: Date, visible: [CalendarEvent], lead: TimeInterval, startOfTomorrow: Date) {
        var candidates: [Date] = [startOfTomorrow]
        for e in visible {
            candidates.append(e.end)
            guard !e.isAllDay else { continue }
            candidates.append(e.start.addingTimeInterval(-lead))
            candidates.append(e.start.addingTimeInterval(-Self.peekLead))
            candidates.append(e.start)
            candidates.append(e.start.addingTimeInterval(Self.nowWindow))
        }
        // Mentre c'è il conto alla rovescia: il prossimo cambio di minuto.
        if let face = model.face, face.event.start > now {
            let minutes = ceil(face.event.start.timeIntervalSince(now) / 60)
            candidates.append(face.event.start.addingTimeInterval(-(minutes - 1) * 60))
        }
        guard let next = candidates.filter({ $0.timeIntervalSince(now) > 0.5 }).min() else { return }
        let t = Timer(fire: next.addingTimeInterval(0.2), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.update()
            }
        }
        t.tolerance = model.face != nil ? 0.5 : 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func countdown(to start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 { return "ora" }
        return "tra \(Int(ceil(seconds / 60))) min"
    }

    private func refreshPriority() {
        let p = restingPriority
        guard p != lastPriority else { return }
        lastPriority = p
        host?.refreshRestingFace()
    }

    // MARK: faccia e peek

    public var restingPriority: Int {
        host != nil && model.face != nil ? 70 : 0
    }

    public func makeRestingFace() -> RestingFace {
        RestingFace(sideWidth: 84,
                    leading: CalendarFaceSide(model: model, leading: true),
                    trailing: CalendarFaceSide(model: model, leading: false))
    }

    public func makePeek() -> AnyView {
        AnyView(CalendarPeek(model: model, event: model.peekEvent ?? model.face?.event))
    }

    // MARK: scheda e impostazioni

    public func makeCard() -> AnyView? {
        AnyView(CalendarCard(model: model))
    }

    public func makeSettings() -> AnyView? {
        AnyView(CalendarSettingsView(model: model) { [weak self] in self?.settingsChanged() })
    }

    private func settingsChanged() {
        host?.saveSettings(model.settings)
        if store != nil { reload() }
    }
}

// MARK: - Impostazioni

struct CalendarSettings: Codable, Equatable {
    /// Calendari esclusi (così quelli nuovi si vedono subito).
    var excludedCalendars: Set<String> = []
    /// Da quanti minuti prima mostrare il conto alla rovescia accanto alla notch.
    var leadMinutes = 15
    /// Allarga l'isola 5 minuti prima dell'inizio.
    var peek = true

    static let leadChoices = [5, 10, 15]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CalendarSettings()
        excludedCalendars = try c.decodeIfPresent(Set<String>.self, forKey: .excludedCalendars) ?? d.excludedCalendars
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? d.leadMinutes
        peek = try c.decodeIfPresent(Bool.self, forKey: .peek) ?? d.peek
        if !Self.leadChoices.contains(leadMinutes) { leadMinutes = d.leadMinutes }
    }
}

// MARK: - Modello

enum CalendarAccess: Equatable {
    case notDetermined, granted, denied, writeOnly
}

struct CalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let source: String
    let color: Color
}

/// Un evento, copiato da EventKit (il titolo non finisce mai nel log).
struct CalendarEvent: Identifiable, Equatable {
    /// Identificatore + inizio: le ripetizioni hanno lo stesso `eventIdentifier`.
    let id: String
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let location: String?
    let joinURL: URL?

    init(_ e: EKEvent) {
        let identifier: String? = e.eventIdentifier
        eventIdentifier = identifier
        start = e.startDate
        end = e.endDate
        id = "\(identifier ?? e.calendarItemIdentifier)|\(Int(e.startDate.timeIntervalSince1970))"
        let t = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = t.isEmpty ? "Senza titolo" : t
        isAllDay = e.isAllDay
        color = Color(cgColor: e.calendar?.cgColor ?? CGColor(gray: 0.6, alpha: 1))
        joinURL = MeetingLink.find(url: e.url, location: e.location, notes: e.notes)
        let place = e.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        location = place.isEmpty || MeetingLink.containsLink(place) ? nil : place
    }
}

struct CalendarFace: Equatable {
    let event: CalendarEvent
    let label: String
}

@MainActor
final class CalendarModel: ObservableObject {
    @Published var access: CalendarAccess = .notDetermined
    @Published var settings = CalendarSettings()
    @Published var today: [CalendarEvent] = []
    @Published var tomorrow: [CalendarEvent] = []
    @Published var face: CalendarFace?
    @Published var calendars: [CalendarInfo] = []
    @Published var now = Date()
    var peekEvent: CalendarEvent?
    var requestAccess: (() -> Void)?
}

// MARK: - Link delle videochiamate

enum MeetingLink {
    private static let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "facetime.apple.com"]
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        for text in [location, notes].compactMap({ $0 }) where !text.isEmpty {
            if let found = links(in: text).first(where: isMeeting) { return found }
        }
        return nil
    }

    static func containsLink(_ text: String) -> Bool {
        links(in: text).contains(where: isMeeting)
    }

    private static func links(in text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }

    private static func isMeeting(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

// MARK: - Azioni

enum CalendarActions {
    /// Apre l'evento in Calendario; se non si può, apre l'app.
    @MainActor
    static func open(_ e: CalendarEvent) {
        if let id = e.eventIdentifier,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        openCalendarApp()
    }

    @MainActor
    static func openCalendarApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    static func join(_ e: CalendarEvent) {
        if let url = e.joinURL { NSWorkspace.shared.open(url) }
    }

    @MainActor
    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
