import IsolaCore
import SwiftUI

// MARK: - Testi

enum BatteryText {
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func status(_ s: BatteryState) -> String {
        if s.charged { return "Carica completa" }
        if s.charging { return "In carica" }
        if s.optimizedPause { return "Carica ottimizzata: in pausa" }
        if s.pluggedIn { return "Collegato, non in carica" }
        return "A batteria"
    }

    static func time(_ s: BatteryState) -> String {
        if s.charging {
            if let m = s.minutesToFull { return "Piena tra \(duration(m))" }
            return "Calcolo del tempo…"
        }
        if !s.pluggedIn {
            if let m = s.minutesToEmpty { return "Ancora \(duration(m))" }
            return "Calcolo del tempo…"
        }
        return ""
    }

    /// `nil` = il colore del testo del tema.
    static func color(_ s: BatteryState, settings: BatterySettings) -> Color? {
        if s.pluggedIn { return IslandTheme.green }
        if s.percent <= settings.criticalLevel { return IslandTheme.red }
        if s.percent <= settings.lowLevel { return IslandTheme.orange }
        return nil
    }
}

// MARK: - Disegno della batteria

/// Una batteria disegnata: contorno, riempimento proporzionale, fulmine se in carica.
struct BatteryGlyph: View {
    var fraction: Double
    var fill: Color
    var bolt: Bool
    var width: CGFloat = 26
    @Environment(\.island) private var theme

    var body: some View {
        let height = width * 0.48
        let line = max(1, width / 22)
        HStack(spacing: line) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.28, style: .continuous)
                    .strokeBorder(theme.muted.opacity(0.8), lineWidth: line)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(fill)
                    .padding(line * 2)
                    .frame(width: max(line * 5, (width - width * 0.08) * min(1, max(0, fraction))))
                if bolt {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.72, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width - width * 0.08, height: height)
            RoundedRectangle(cornerRadius: line)
                .fill(theme.muted.opacity(0.8))
                .frame(width: width * 0.06, height: height * 0.36)
        }
        .frame(width: width + line, height: height)
    }
}

// MARK: - Faccia

/// A sinistra la batteria, a destra la percentuale. In verde nei secondi dopo che colleghi
/// l'alimentatore, in rosso sotto la soglia critica.
struct BatteryFaceSide: View {
    @ObservedObject var model: BatteryModel
    let leading: Bool

    var body: some View {
        let s = model.state
        let tint = model.flash ? IslandTheme.green : IslandTheme.red
        Group {
            if leading {
                BatteryGlyph(fraction: Double(s.percent) / 100, fill: tint, bolt: model.flash, width: 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            } else {
                Text("\(s.percent)%")
                    .font(IslandFont.mono(13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: model.flash)
    }
}

// MARK: - Peek

struct BatteryPeek: View {
    @ObservedObject var model: BatteryModel
    let kind: BatteryPeekKind
    @State private var progress: Double = 0
    @Environment(\.island) private var theme

    var body: some View {
        let s = model.state
        HStack(spacing: 12) {
            switch kind {
            case .charging:
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IslandTheme.green)
                    .symbolEffect(.pulse, options: .repeating)
                ChargeBar(fraction: progress)
                    .frame(width: 120, height: 8)
                Text("\(s.percent)%")
                    .font(IslandFont.mono(15, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(s.minutesToFull.map { "Piena tra \(BatteryText.duration($0))" }
                     ?? (s.charged ? "Carica completa" : "In carica"))
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            case .low(let level):
                BatteryGlyph(fraction: Double(s.percent) / 100,
                             fill: level <= model.settings.criticalLevel ? IslandTheme.red : IslandTheme.orange,
                             bolt: false, width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Batteria al \(s.percent)%")
                        .font(IslandFont.bodyBold)
                        .foregroundStyle(theme.foreground)
                    Text("Collega l'alimentatore")
                        .font(IslandFont.small)
                        .foregroundStyle(theme.muted)
                }
                Spacer(minLength: 8)
                if let m = s.minutesToEmpty {
                    Text("Ancora \(BatteryText.duration(m))")
                        .font(IslandFont.mono(11))
                        .foregroundStyle(theme.muted)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            progress = 0
            withAnimation(.easeOut(duration: 1.2).delay(0.15)) { progress = Double(s.percent) / 100 }
        }
    }
}

private struct ChargeBar: View {
    let fraction: Double
    @Environment(\.island) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surface)
                Capsule()
                    .fill(LinearGradient(colors: [IslandTheme.green.opacity(0.7), IslandTheme.green],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * fraction))
            }
        }
    }
}

// MARK: - Scheda

struct BatteryCard: View {
    @ObservedObject var model: BatteryModel
    @Environment(\.island) private var theme

    var body: some View {
        let s = model.state
        if !s.present {
            IslandEmptyState("powerplug", title: "Nessuna batteria", subtitle: "Questo Mac è sempre collegato alla corrente.")
        } else {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 12) {
                        BatteryGlyph(fraction: Double(s.percent) / 100,
                                     fill: BatteryText.color(s, settings: model.settings) ?? theme.foreground,
                                     bolt: s.charging, width: 46)
                        Text("\(s.percent)%")
                            .font(IslandFont.mono(40, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                    }
                    Text(BatteryText.status(s))
                        .font(IslandFont.title)
                        .foregroundStyle(theme.foreground)
                    let time = BatteryText.time(s)
                    if !time.isEmpty {
                        Text(time)
                            .font(IslandFont.body)
                            .foregroundStyle(theme.muted)
                    }
                    if s.lowPowerMode {
                        Label("Risparmio energetico attivo", systemImage: "leaf.fill")
                            .font(IslandFont.small)
                            .foregroundStyle(IslandTheme.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                IslandSurface(padding: 12) {
                    VStack(alignment: .leading, spacing: 9) {
                        row("powerplug.fill", "Alimentatore",
                            s.pluggedIn ? (s.adapterWatts.map { "\($0) W" } ?? "Collegato") : "Scollegato")
                        if let cycles = s.cycleCount {
                            row("arrow.triangle.2.circlepath", "Cicli",
                                s.designCycles.map { "\(cycles) di \($0)" } ?? "\(cycles)")
                        }
                        if let cap = s.maxCapacity {
                            row("heart.fill", "Capacità massima", "≈ \(cap)%")
                                .help("Stima dai dati della batteria: può differire di qualche punto da Impostazioni di Sistema.")
                        }
                    }
                }
                .frame(width: 230)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .frame(width: 16)
            Text(title)
                .font(IslandFont.body)
                .foregroundStyle(theme.muted)
            Spacer(minLength: 6)
            Text(value)
                .font(IslandFont.mono(13, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
        }
    }
}

// MARK: - Impostazioni

struct BatterySettingsView: View {
    @ObservedObject var model: BatteryModel
    let changed: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Mostra la carica quando colleghi l'alimentatore", isOn: binding(\.peekOnPlug))
            }
            Section {
                Toggle("Avvisa con la batteria scarica", isOn: binding(\.lowWarnings))
                Picker("Primo avviso", selection: binding(\.lowLevel)) {
                    ForEach(BatterySettings.lowChoices, id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!model.settings.lowWarnings)
                Picker("Avviso critico", selection: binding(\.criticalLevel)) {
                    ForEach(BatterySettings.criticalChoices, id: \.self) { Text("\($0)%").tag($0) }
                }
                Text("Sotto la soglia critica, a batteria, l'isola mostra la percentuale in rosso accanto alla notch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Batteria scarica")
            }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<BatterySettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: key] },
            set: { model.settings[keyPath: key] = $0; changed() })
    }
}
