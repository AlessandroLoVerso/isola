import AppKit
import IsolaCore
import SwiftUI
import UserNotifications

/// "Promemoria": la lista di promemoria di Isola (non quelli di Apple), con le ripetizioni.
/// Un solo timer puntato al prossimo momento che cambia qualcosa (un promemoria che scade, o che
/// entra nei 15 minuti "a breve"); niente gira nel frattempo. Riprogrammato al risveglio e quando
/// cambiano l'ora o il fuso. Un promemoria scaduto allarga l'isola (anche sopra le app a schermo
/// intero) e resta sulla pillola finché nella scheda non si preme "Fatto" o "Rimanda 10 min".
public final class RemindersModule: IslandModule, RestingFaceProvider, PeekProvider {
    public init() {}
    public var id: String { "reminders" }
    public var title: String { "Promemoria" }
    public var symbol: String { "bell" }
    public var order: Int { 50 }
    public var enabledByDefault: Bool { true }

    private static let soonWindow: TimeInterval = 15 * 60
    private static let peekDuration: TimeInterval = 30

    let vm = RemindersViewModel()
    private weak var host: IslandHost?
    private var store: ReminderStore?
    private var settings = RemindersSettings()
    /// In ordine di scadenza.
    private var firing: [UUID] = []
    private var timer: Timer?
    private var priority = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    // MARK: ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        settings = host.loadSettings(RemindersSettings.self, fallback: RemindersSettings())
        store = ReminderStore(directory: host.dataDirectory)
        firing = []
        priority = 0
        vm.module = self
        host.onCardVisibilityChange { [weak self] visible in
            // "oggi" e "domani" possono essere vecchi dopo la mezzanotte.
            if visible { self?.refreshCard() }
        }
        let nc = NotificationCenter.default
        observe(nc, .NSSystemClockDidChange) { $0.evaluate() }
        observe(nc, .NSSystemTimeZoneDidChange) { $0.evaluate() }
        observe(nc, .NSCalendarDayChanged) { $0.refreshCard() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.evaluate() }
        // Scaduti mentre il Mac era spento o Isola chiusa: scattano adesso, una volta.
        evaluate()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        store = nil
        firing = []
        priority = 0
        vm.module = nil
        host = nil
    }

    public func makeCard() -> AnyView? {
        refreshCard()
        return AnyView(RemindersCard(vm: vm))
    }

    public func makeSettings() -> AnyView? {
        AnyView(RemindersSettingsView(
            notifications: settings.notifications,
            onChange: { [weak self] on, done in self?.setNotifications(on, done: done) }))
    }

    // MARK: faccia, peek

    public var restingPriority: Int { priority }

    public func makeRestingFace() -> RestingFace {
        RestingFace(sideWidth: 96, leading: ReminderFaceLeading(vm: vm), trailing: ReminderFaceTrailing(vm: vm))
    }

    public func makePeek() -> AnyView { AnyView(ReminderPeek(vm: vm)) }

    // MARK: programmazione

    /// Fa scattare ciò che è scaduto, aggiorna la pillola e punta il timer al prossimo momento
    /// che cambia qualcosa.
    func evaluate() {
        guard let store, let host else { return }
        timer?.invalidate()
        timer = nil
        let now = Date()

        let newlyDue = store.items
            .filter { $0.due.date <= now.addingTimeInterval(0.5) && !firing.contains($0.id) }
            .sorted { $0.due < $1.due }
        firing.append(contentsOf: newlyDue.map(\.id))
        firing.removeAll { id in !store.items.contains { $0.id == id } }

        let pending = store.items.filter { !firing.contains($0.id) }.sorted { $0.due < $1.due }
        let next = pending.first

        // Faccia: vince ciò che è scaduto; altrimenti il prossimo, se entro 15 minuti.
        let newPriority: Int
        if let first = firstFiring() {
            newPriority = 90
            vm.setFace(text: first.text,
                       time: firing.count > 1 ? "+\(firing.count - 1)" : RemText.time(first.due.date),
                       firing: true)
        } else if let next, next.due.date.timeIntervalSince(now) <= Self.soonWindow {
            newPriority = 15
            vm.setFace(text: next.text, time: RemText.time(next.due.date), firing: false)
        } else {
            newPriority = 0
        }
        let changed = newPriority != priority
        priority = newPriority
        if changed || !newlyDue.isEmpty { host.refreshRestingFace() }
        if !newlyDue.isEmpty {
            host.log(newlyDue.count == 1 ? "un promemoria è scaduto" : "\(newlyDue.count) promemoria scaduti")
            host.attention(duration: Self.peekDuration)
            if settings.notifications { newlyDue.forEach { RemNotifier.post(id: $0.id, text: $0.text) } }
        }

        // Prossimo risveglio: l'inizio dei 15 minuti "a breve" o la scadenza, quello che viene prima.
        if let next {
            let due = next.due.date
            let wake = due.addingTimeInterval(-Self.soonWindow) > now ? due.addingTimeInterval(-Self.soonWindow) : due
            // Al massimo 6 ore: il timer non conta il tempo in stop, ogni tanto si riallinea.
            let wait = min(max(wake.timeIntervalSince(now), 0.2), 6 * 3600)
            let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            t.tolerance = min(1, wait * 0.01)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        refreshCard()
    }

    private func firstFiring() -> Reminder? {
        guard let store else { return nil }
        for id in firing { if let r = store.items.first(where: { $0.id == id }) { return r } }
        return nil
    }

    func refreshCard() {
        guard let store else { return }
        let now = Date()
        let firingItems = firing.compactMap { id in store.items.first { $0.id == id } }
        let upcoming = store.items.filter { !firing.contains($0.id) }.sorted { $0.due < $1.due }
        vm.update(upcoming: upcoming, firing: firingItems, now: now)
    }

    // MARK: azioni dalla scheda

    func requestKeyboardFocus() { host?.requestKeyboardFocus() }

    func reminder(_ id: UUID) -> Reminder? { store?.items.first { $0.id == id } }

    /// Aggiunge (o, con `replacing`, sostituisce) un promemoria. `false` se la data è passata.
    @discardableResult
    func add(text: String, due chosen: Date, repeats: ReminderRepeat, replacing: UUID? = nil) -> Bool {
        guard let store else { return false }
        let now = Date()
        var due = chosen
        if repeats != .none {
            due = Recurrence.firstOnOrAfter(repeats, chosen: due)
            if due <= now {
                let probe = Reminder(text: "", due: WallTime(due), anchor: WallTime(due), repeats: repeats)
                due = Recurrence.nextAfter(probe, after: now).date
            }
        } else if due <= now {
            return false
        }
        if let old = replacing {
            store.items.removeAll { $0.id == old }
            firing.removeAll { $0 == old }
            RemNotifier.remove([old])
        }
        let wall = WallTime(due)
        store.items.append(Reminder(id: replacing ?? UUID(), text: text, due: wall, anchor: wall, repeats: repeats))
        store.save()
        evaluate()
        return true
    }

    func delete(_ id: UUID) {
        guard let store else { return }
        store.items.removeAll { $0.id == id }
        firing.removeAll { $0 == id }
        RemNotifier.remove([id])
        store.save()
        evaluate()
    }

    func snooze(_ id: UUID) {
        guard let store, let i = store.items.firstIndex(where: { $0.id == id }) else { return }
        store.items[i].due = WallTime(Date().addingTimeInterval(10 * 60))
        firing.removeAll { $0 == id }
        RemNotifier.remove([id])
        store.save()
        evaluate()
    }

    func done(_ id: UUID) {
        guard let store, let i = store.items.firstIndex(where: { $0.id == id }) else { return }
        let r = store.items[i]
        if r.repeats == .none { store.items.remove(at: i) }
        else { store.items[i].due = Recurrence.nextAfter(r, after: Date()) }
        firing.removeAll { $0 == id }
        RemNotifier.remove([id])
        store.save()
        evaluate()
    }

    // MARK: impostazioni

    private func setNotifications(_ on: Bool, done: @escaping (Bool, String?) -> Void) {
        guard on else {
            settings.notifications = false
            host?.saveSettings(settings)
            done(false, nil)
            return
        }
        RemNotifier.requestPermission { [weak self] granted in
            guard let self else { return }
            self.settings.notifications = granted
            self.host?.saveSettings(self.settings)
            done(granted, granted ? nil : "macOS non lo permette: accendile in Impostazioni di Sistema › Notifiche › Isola.")
        }
    }

    // MARK: utilità

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (RemindersModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}

struct RemindersSettings: Codable {
    /// Anche una notifica di macOS quando un promemoria scade. Spenta di default.
    var notifications = false
}

/// Notifiche di macOS (facoltative). Senza bundle (eseguibile nudo) UserNotifications si blocca:
/// in quel caso non fa niente.
enum RemNotifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    @MainActor
    static func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard available else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in done(granted) }
        }
    }

    static func post(id: UUID, text: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Promemoria"
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    static func remove(_ ids: [UUID]) {
        guard available, !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map(\.uuidString))
    }
}

// MARK: - Modello delle viste

struct ReminderRow: Identifiable, Equatable {
    let id: UUID
    let text: String
    let when: String
    let repeats: ReminderRepeat
    let soon: Bool
}

@MainActor
final class RemindersViewModel: ObservableObject {
    weak var module: RemindersModule?

    // Lista e banner
    @Published var upcoming: [ReminderRow] = []
    @Published var bannerId: UUID?
    @Published var bannerText = ""
    @Published var bannerSub = ""
    @Published var showTonight = true

    // Pillola e peek
    @Published var faceText = ""
    @Published var faceTime = ""
    @Published var faceFiring = false

    // Composer (qui e non in @State: la vista può essere ricreata)
    @Published var text = "" { didSet { if text != oldValue { textError = false } } }
    @Published var repeats: ReminderRepeat = .none
    @Published var showCustom = false
    @Published var customTime = "" { didSet { timeError = false } }
    @Published var customDate = "" { didSet { dateError = false } }
    @Published var textError = false
    @Published var timeError = false
    @Published var dateError = false
    @Published var editingId: UUID?
    /// Cresce quando il campo del testo deve prendere il fuoco.
    @Published var focusText = 0

    func setFace(text: String, time: String, firing: Bool) {
        faceText = text
        faceTime = time
        faceFiring = firing
    }

    func update(upcoming items: [Reminder], firing: [Reminder], now: Date) {
        upcoming = items.map { r in
            ReminderRow(id: r.id, text: r.text, when: RemText.when(r.due.date, now: now), repeats: r.repeats,
                        soon: r.due.date.timeIntervalSince(now) <= 15 * 60)
        }
        if let f = firing.first {
            bannerId = f.id
            bannerText = f.text
            let cal = RemCal.calendar
            var sub = cal.isDate(f.due.date, inSameDayAs: now)
                ? "Promemoria delle \(RemText.time(f.due.date))"
                : "Promemoria di \(RemText.when(f.due.date, now: now))"
            if firing.count > 1 { sub += " · altri \(firing.count - 1)" }
            bannerSub = sub
        } else {
            bannerId = nil
        }
        showTonight = RemCal.calendar.component(.hour, from: now) < 20
        if let e = editingId, !items.contains(where: { $0.id == e }) { cancelEdit() }
    }

    // MARK: composer

    func quick(_ kind: QuickTime) {
        let cal = RemCal.calendar
        let now = Date()
        let today = cal.startOfDay(for: now)
        let due: Date
        switch kind {
        case .tenMinutes: due = now.addingTimeInterval(10 * 60)
        case .oneHour: due = now.addingTimeInterval(3600)
        case .tonight: due = cal.date(bySettingHour: 20, minute: 0, second: 0, of: today) ?? now
        case .tomorrow:
            let t = cal.date(byAdding: .day, value: 1, to: today) ?? today
            due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: t) ?? now
        }
        addAt(due)
    }

    enum QuickTime { case tenMinutes, oneHour, tonight, tomorrow }

    func addAt(_ due: Date) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            textError = true
            module?.requestKeyboardFocus()
            focusText += 1
            return
        }
        guard let module, module.add(text: String(t.prefix(200)), due: due, repeats: repeats, replacing: editingId) else {
            if showCustom { timeError = true; dateError = true }
            return
        }
        text = ""
        repeats = .none
        showCustom = false
        editingId = nil
    }

    func addCustom() {
        let now = Date()
        let time = RemText.parseTime(customTime)
        let date = RemText.parseDate(customDate, now: now)
        var dateOk = true
        if case .invalid = date { dateOk = false }
        timeError = time == nil
        dateError = !dateOk
        guard let (h, m) = time, dateOk else { return }

        let cal = RemCal.calendar
        var due: Date
        if case .day(let d) = date {
            due = cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
        } else {
            due = cal.date(bySettingHour: h, minute: m, second: 0, of: cal.startOfDay(for: now)) ?? now
            if due <= now { due = cal.date(byAdding: .day, value: 1, to: due) ?? due }
        }
        if due <= now && repeats == .none {
            timeError = true
            dateError = true
            return
        }
        addAt(due)
    }

    func setCustom(_ show: Bool) {
        showCustom = show
        guard show, editingId == nil else { return }
        let cal = RemCal.calendar
        let now = Date()
        let inHour = now.addingTimeInterval(3600)
        let suggestion = cal.date(bySettingHour: cal.component(.hour, from: inHour), minute: 0, second: 0, of: inHour) ?? inHour
        fillCustom(suggestion, now: now)
    }

    private func fillCustom(_ d: Date, now: Date) {
        let cal = RemCal.calendar
        customTime = RemText.format("HH:mm", d)
        if cal.isDate(d, inSameDayAs: now) { customDate = "oggi" }
        else if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { customDate = "domani" }
        else { customDate = RemText.format("dd/MM/yyyy", d) }
        timeError = false
        dateError = false
    }

    func cycleRepeat() { repeats = repeats.next }

    /// Invio nel campo del testo: apre "Altro", o aggiunge se è già aperto.
    func submitText() {
        if showCustom { addCustom() } else { setCustom(true) }
    }

    func beginEdit(_ id: UUID) {
        guard let r = module?.reminder(id) else { return }
        editingId = id
        text = r.text
        repeats = r.repeats
        showCustom = true
        fillCustom(r.due.date, now: Date())
        module?.requestKeyboardFocus()
        focusText += 1
    }

    func cancelEdit() {
        editingId = nil
        text = ""
        repeats = .none
        showCustom = false
    }

    func delete(_ id: UUID) { module?.delete(id) }
    func done() { if let id = bannerId { module?.done(id) } }
    func snooze() { if let id = bannerId { module?.snooze(id) } }
    func requestKeyboardFocus() { module?.requestKeyboardFocus() }
}
