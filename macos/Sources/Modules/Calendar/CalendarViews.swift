import IsolaCore
import SwiftUI

// MARK: - Formati

@MainActor
enum CalendarFormat {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d"
        return f
    }()

    static func clock(_ d: Date) -> String { time.string(from: d) }
    static func dayName(_ d: Date) -> String { day.string(from: d) }

    static func range(_ e: CalendarEvent) -> String {
        "\(clock(e.start))–\(clock(e.end))"
    }
}

// MARK: - Faccia

/// A sinistra un pallino del colore del calendario e "tra 8 min" (o "ora"), a destra il titolo.
struct CalendarFaceSide: View {
    @ObservedObject var model: CalendarModel
    let leading: Bool
    @Environment(\.island) private var theme

    var body: some View {
        Group {
            if let face = model.face {
                if leading {
                    HStack(spacing: 6) {
                        Circle().fill(face.event.color).frame(width: 8, height: 8)
                        Text(face.label)
                            .font(IslandFont.mono(12, weight: .semibold))
                            .foregroundStyle(face.label == "ora" ? IslandTheme.green : theme.foreground)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                } else {
                    Text(face.event.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 10)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Peek

struct CalendarPeek: View {
    @ObservedObject var model: CalendarModel
    let event: CalendarEvent?
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if let e = event {
                Circle().fill(e.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title)
                        .font(IslandFont.bodyBold)
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    Text(subtitle(e))
                        .font(IslandFont.small)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if e.joinURL != nil {
                    Button("Partecipa") { CalendarActions.join(e) }
                        .buttonStyle(IslandButtonStyle(prominent: true))
                }
            } else {
                Image(systemName: "calendar").foregroundStyle(theme.muted)
                Text("Calendario").font(IslandFont.bodyBold).foregroundStyle(theme.foreground)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func subtitle(_ e: CalendarEvent) -> String {
        let when = "\(CalendarModule.countdown(to: e.start, now: Date())) · \(CalendarFormat.clock(e.start))"
        if let place = e.location { return "\(when) · \(place)" }
        return when
    }
}

// MARK: - Scheda

struct CalendarCard: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.island) private var theme

    var body: some View {
        switch model.access {
        case .notDetermined:
            permission(
                symbol: "calendar",
                title: "Il Calendario non è collegato",
                subtitle: "Isola legge i tuoi eventi solo su questo Mac, per mostrarti oggi e domani.",
                button: "Consenti l'accesso al Calendario") { model.requestAccess?() }
        case .denied, .writeOnly:
            permission(
                symbol: "calendar.badge.exclamationmark",
                title: model.access == .writeOnly ? "Serve l'accesso completo" : "Accesso al Calendario negato",
                subtitle: "Per vedere gli eventi, consenti l'accesso in Impostazioni di Sistema › Privacy e sicurezza › Calendari.",
                button: "Apri Impostazioni di Sistema") { CalendarActions.openPrivacySettings() }
        case .granted:
            if model.today.isEmpty && model.tomorrow.isEmpty {
                VStack(spacing: 10) {
                    IslandEmptyState("calendar", title: "Niente in programma",
                                     subtitle: model.calendars.isEmpty || !hasSelected
                                        ? "Nessun calendario scelto nelle impostazioni."
                                        : "Oggi e domani sei libero.")
                        .frame(maxHeight: 110)
                    Button("Apri Calendario") { CalendarActions.openCalendarApp() }
                        .buttonStyle(IslandButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var hasSelected: Bool {
        model.calendars.contains { !model.settings.excludedCalendars.contains($0.id) }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                if !model.today.isEmpty {
                    header("Oggi")
                    ForEach(model.today) { EventRow(event: $0, now: model.now) }
                }
                if !model.tomorrow.isEmpty {
                    header("Domani · \(CalendarFormat.dayName(model.tomorrow[0].start))")
                        .padding(.top, model.today.isEmpty ? 0 : 6)
                    ForEach(model.tomorrow) { EventRow(event: $0, now: model.now) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.muted)
            .padding(.leading, 8)
    }

    private func permission(symbol: String, title: String, subtitle: String, button: String,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(theme.muted)
            Text(title).font(IslandFont.bodyBold).foregroundStyle(theme.foreground)
            Text(subtitle)
                .font(IslandFont.small)
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(button, action: action)
                .buttonStyle(IslandButtonStyle(prominent: true))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let now: Date
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        let inProgress = !event.isAllDay && event.start <= now && event.end > now
        HStack(spacing: 10) {
            Group {
                if event.isAllDay {
                    Text("Tutto il giorno")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else if inProgress {
                    Text("Ora").font(IslandFont.mono(12, weight: .semibold)).foregroundStyle(IslandTheme.green)
                } else {
                    Text(CalendarFormat.clock(event.start)).font(IslandFont.mono(12, weight: .semibold))
                }
            }
            .foregroundStyle(theme.muted)
            .frame(width: 46, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(event.color)
                .frame(width: 4, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = detail {
                    Text(detail)
                        .font(IslandFont.small)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            if event.joinURL != nil, event.end > now {
                Button("Partecipa") { CalendarActions.join(event) }
                    .buttonStyle(IslandButtonStyle(prominent: inProgress || event.start.timeIntervalSince(now) < 15 * 60))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(hover ? theme.surfaceHover : theme.surface))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { CalendarActions.open(event) }
        .help("Apri in Calendario")
    }

    private var detail: String? {
        let time = event.isAllDay ? nil : CalendarFormat.range(event)
        switch (time, event.location) {
        case let (t?, p?): return "\(t) · \(p)"
        case let (t?, nil): return t
        case let (nil, p?): return p
        default: return nil
        }
    }
}

// MARK: - Impostazioni

struct CalendarSettingsView: View {
    @ObservedObject var model: CalendarModel
    let changed: () -> Void

    var body: some View {
        Form {
            Section {
                switch model.access {
                case .granted:
                    if model.calendars.isEmpty {
                        Text("Nessun calendario su questo Mac.").foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.0) { source, calendars in
                        if !source.isEmpty {
                            Text(source).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        ForEach(calendars) { c in
                            Toggle(isOn: included(c.id)) {
                                HStack(spacing: 8) {
                                    Circle().fill(c.color).frame(width: 10, height: 10)
                                    Text(c.title)
                                }
                            }
                        }
                    }
                case .notDetermined:
                    Text("Isola legge i tuoi eventi solo su questo Mac, per mostrarti oggi e domani.")
                        .foregroundStyle(.secondary)
                    Button("Consenti l'accesso al Calendario") { model.requestAccess?() }
                case .denied, .writeOnly:
                    Text("L'accesso al Calendario è negato. Puoi consentirlo in Privacy e sicurezza › Calendari.")
                        .foregroundStyle(.secondary)
                    Button("Apri Impostazioni di Sistema") { CalendarActions.openPrivacySettings() }
                }
            } header: {
                Text("Calendari da mostrare")
            }

            Section {
                Picker("Conto alla rovescia accanto alla notch", selection: binding(\.leadMinutes)) {
                    ForEach(CalendarSettings.leadChoices, id: \.self) { Text("\($0) min prima").tag($0) }
                }
                Toggle("Avvisa 5 minuti prima dell'inizio", isOn: binding(\.peek))
            } header: {
                Text("Avvisi")
            }
        }
    }

    private var groups: [(String, [CalendarInfo])] {
        var order: [String] = []
        var map: [String: [CalendarInfo]] = [:]
        for c in model.calendars {
            if map[c.source] == nil { order.append(c.source) }
            map[c.source, default: []].append(c)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func included(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !model.settings.excludedCalendars.contains(id) },
            set: { on in
                if on { model.settings.excludedCalendars.remove(id) } else { model.settings.excludedCalendars.insert(id) }
                changed()
            })
    }

    private func binding<T>(_ key: WritableKeyPath<CalendarSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: key] },
            set: { model.settings[keyPath: key] = $0; changed() })
    }
}
