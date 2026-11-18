import IsolaCore
import SwiftUI

// MARK: - Formati

enum PerfFormat {
    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(v.rounded()))%"
    }

    /// Velocità con due cifre significative: la terza fa solo ballare il numero.
    static func rate(_ bytes: Double?, compact: Bool = false) -> String {
        guard let bytes else { return "–" }
        let kb = bytes / 1024
        let k = compact ? "K" : " KB/s"
        let m = compact ? "M" : " MB/s"
        let g = compact ? "G" : " GB/s"
        if kb < 99.5 { return "\(Int(kb.rounded()))\(k)" }
        if kb < 995 { return "\(Int((kb / 10).rounded()) * 10)\(k)" }
        let mb = kb / 1024
        if mb < 9.95 { return decimal(mb) + m }
        if mb < 999.5 { return "\(Int(mb.rounded()))\(m)" }
        return decimal(mb / 1024) + g
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        decimal(Double(bytes) / 1_073_741_824)
    }

    private static func decimal(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// Barre a passi del 2%: ogni ridisegno costa più della lettura.
    static func fraction(_ percent: Double?) -> Double {
        guard let percent else { return 0 }
        return (min(1, max(0, percent / 100)) * 50).rounded() / 50
    }

    /// Scala logaritmica: 1 KB/s = 0, 100 MB/s = pieno.
    static func rateFraction(_ bytes: Double?) -> Double {
        guard let bytes, bytes >= 1024 else { return 0 }
        return (min(1, max(0, log10(bytes / 1024) / 5)) * 50).rounded() / 50
    }

    static func thermal(_ s: ProcessInfo.ThermalState) -> (String, Color?) {
        switch s {
        case .nominal: return ("Temperatura normale", nil)
        case .fair: return ("Un po' caldo", nil)
        case .serious: return ("Caldo: può rallentare", IslandTheme.orange)
        case .critical: return ("Troppo caldo", IslandTheme.red)
        @unknown default: return ("", nil)
        }
    }
}

// MARK: - Striscia

enum PerfStripMetrics {
    static let sideWidth: CGFloat = 118
}

/// Un lato della striscia: a sinistra CPU e GPU, a destra RAM e rete.
struct PerfStripSide: View {
    @ObservedObject var model: PerfModel
    let leading: Bool
    /// Solo un lato riferisce la visibilità, così la striscia conta una volta.
    let report: ((Bool) -> Void)?

    var body: some View {
        let s = model.snapshot
        let set = model.settings
        HStack(spacing: 10) {
            if leading {
                if set.stripCPU { cell("CPU", PerfFormat.percent(s.cpu), PerfFormat.fraction(s.cpu)) }
                if set.stripGPU { cell("GPU", PerfFormat.percent(s.gpu), PerfFormat.fraction(s.gpu)) }
            } else {
                if set.stripRAM {
                    cell("RAM", PerfFormat.percent(s.ramPercent), PerfFormat.fraction(s.ramPercent),
                         tint: s.pressure == .critical ? IslandTheme.red : (s.pressure == .warning ? IslandTheme.orange : nil))
                }
                if set.stripNet { cell("↓", PerfFormat.rate(s.down, compact: true), PerfFormat.rateFraction(s.down)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leading ? .trailing : .leading)
        .padding(.horizontal, 4)
        .onAppear { report?(true) }
        .onDisappear { report?(false) }
    }

    private func cell(_ label: String, _ value: String, _ fraction: Double, tint: Color? = nil) -> some View {
        StripCell(label: label, value: value, fraction: fraction, bars: model.settings.bars, tint: tint)
    }
}

private struct StripCell: View {
    let label: String
    let value: String
    let fraction: Double
    let bars: Bool
    let tint: Color?
    @Environment(\.island) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.muted)
                Text(value)
                    .font(IslandFont.mono(11, weight: .semibold))
                    .foregroundStyle(tint ?? theme.foreground)
                    .lineLimit(1)
                    .fixedSize()
            }
            if bars {
                MiniBar(fraction: fraction, tint: tint ?? theme.accent)
                    .frame(height: 2)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MiniBar: View {
    let fraction: Double
    let tint: Color
    @Environment(\.island) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surface)
                Capsule().fill(tint).frame(width: geo.size.width * fraction)
            }
        }
    }
}

// MARK: - Scheda

struct PerfCard: View {
    @ObservedObject var model: PerfModel

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PerfTile(title: "Processore", detail: cpuDetail(s), detailTint: nil,
                         value: PerfFormat.percent(s.cpu),
                         series: [model.cpuHistory], maxValue: 100)
                let thermal = PerfFormat.thermal(s.thermal)
                PerfTile(title: "GPU", detail: thermal.0, detailTint: thermal.1,
                         value: PerfFormat.percent(s.gpu),
                         series: [model.gpuHistory], maxValue: 100)
            }
            HStack(spacing: 8) {
                PerfTile(title: "Memoria", detail: ramDetail(s), detailTint: pressureTint(s.pressure),
                         value: PerfFormat.percent(s.ramPercent),
                         series: [model.ramHistory], maxValue: 100)
                PerfTile(title: "Rete", detail: "↑ " + PerfFormat.rate(s.up), detailTint: nil,
                         value: "↓ " + PerfFormat.rate(s.down),
                         series: [model.downHistory, model.upHistory], maxValue: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cpuDetail(_ s: PerfSnapshot) -> String {
        if let p = s.cpuPerformance, let e = s.cpuEfficiency {
            return "P \(PerfFormat.percent(p)) · E \(PerfFormat.percent(e))"
        }
        return model.logicalCores > 0 ? "\(model.logicalCores) core" : ""
    }

    private func ramDetail(_ s: PerfSnapshot) -> String {
        guard s.ramTotal > 0 else { return "" }
        let base = "\(PerfFormat.gigabytes(s.ramUsed)) di \(PerfFormat.gigabytes(s.ramTotal)) GB"
        return s.pressure == .warning || s.pressure == .critical ? s.pressure.label : base
    }

    private func pressureTint(_ p: MemoryPressure) -> Color? {
        switch p {
        case .warning: return IslandTheme.orange
        case .critical: return IslandTheme.red
        default: return nil
        }
    }
}

private struct PerfTile: View {
    let title: String
    let detail: String
    let detailTint: Color?
    let value: String
    /// La prima serie è quella principale; la seconda (upload) è più tenue.
    let series: [[Double]]
    /// `nil` = scala sul massimo visibile.
    let maxValue: Double?
    @Environment(\.island) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted)
                Spacer(minLength: 4)
                Text(detail)
                    .font(IslandFont.mono(11, weight: .regular))
                    .foregroundStyle(detailTint ?? theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(alignment: .bottom, spacing: 12) {
                Text(value)
                    .font(IslandFont.mono(value.count > 6 ? 19 : 24, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .fixedSize()
                Sparkline(series: series, maxValue: maxValue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface))
    }
}

/// L'ultimo minuto, un punto al secondo, da destra verso sinistra.
private struct Sparkline: View {
    let series: [[Double]]
    let maxValue: Double?
    @Environment(\.island) private var theme

    var body: some View {
        Canvas { context, size in
            let top: Double = maxValue ?? max(1024, series.flatMap { $0 }.max() ?? 0) * 1.15
            guard top > 0 else { return }
            let step = size.width / CGFloat(PerfModel.historyLength - 1)
            for (index, values) in series.enumerated().reversed() where values.count >= 2 {
                var line = Path()
                let startX = size.width - CGFloat(values.count - 1) * step
                for (i, v) in values.enumerated() {
                    let x = startX + CGFloat(i) * step
                    let y = size.height - CGFloat(min(1, max(0, v / top))) * size.height
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                let main = index == 0
                if main {
                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.addLine(to: CGPoint(x: startX, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [theme.accent.opacity(0.35), theme.accent.opacity(0.02)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                context.stroke(line, with: .color(main ? theme.accent : theme.muted.opacity(0.7)),
                               style: StrokeStyle(lineWidth: main ? 1.5 : 1, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Impostazioni

struct PerfSettingsView: View {
    @ObservedObject var model: PerfModel
    let changed: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Striscia sopra le app a schermo intero", isOn: binding(\.strip))
                Text("Sopra un gioco o un video a schermo intero l'isola mostra questi valori accanto alla notch "
                     + "(se in Generale hai scelto «Striscia»). "
                     + "Le letture avvengono solo mentre la striscia o la scheda sono visibili.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Valori nella striscia") {
                Toggle("CPU", isOn: binding(\.stripCPU))
                Toggle("GPU", isOn: binding(\.stripGPU))
                Toggle("Memoria", isOn: binding(\.stripRAM))
                Toggle("Rete (download)", isOn: binding(\.stripNet))
                Toggle("Barre sottili sotto i numeri", isOn: binding(\.bars))
            }
            .disabled(!model.settings.strip)
        }
    }

    private func binding(_ key: WritableKeyPath<PerfSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: key] },
            set: { model.settings[keyPath: key] = $0; changed() })
    }
}
