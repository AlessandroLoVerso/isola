import IsolaCore
import SwiftUI

// MARK: - Scheda

struct AgentsCard: View {
    @ObservedObject var model: AgentsModel
    @Environment(\.island) private var theme

    var body: some View {
        if model.rows.isEmpty {
            IslandEmptyState("sparkles", title: "Nessuna sessione di Claude Code", subtitle: emptyHint)
                .padding(.horizontal, 40)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(model.rows) { s in
                        AgentRow(session: s, now: model.now)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
        }
    }

    private var emptyHint: String {
        switch model.serverState {
        case .listening?, .starting?:
            return "Quando un agente lavora o ti aspetta, compare qui. Per collegarlo: Impostazioni › Agenti."
        default:
            return "Server spento: " + model.serverText
        }
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let now: Date
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor(session.state, theme))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.folder)
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.detail)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(agentElapsed(now.timeIntervalSince(session.since)))
                .font(IslandFont.mono(11, weight: .regular))
                .foregroundStyle(theme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surface))
    }
}

private func stateColor(_ state: AgentState, _ theme: IslandTheme) -> Color {
    switch state {
    case .working: return IslandTheme.orange
    case .waiting: return theme.accent
    case .done: return IslandTheme.green
    }
}

// MARK: - Faccia sulla pillola

/// A sinistra: icona di stato + "Ti aspetta" / "Al lavoro" / "Finito".
struct AgentFaceLeading: View {
    @ObservedObject var model: AgentsModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 6) {
            switch model.face.state {
            case .waiting?:
                PulsingDot(color: theme.accent)
                label("Ti aspetta")
            case .working?:
                WorkingSpinner()
                label("Al lavoro")
            case .done?:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(IslandTheme.green)
                label("Finito")
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.foreground)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A destra: il progetto, o quante sessioni sono in quello stato.
struct AgentFaceTrailing: View {
    @ObservedObject var model: AgentsModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if model.face.state != nil {
                Text(model.face.count > 1 ? "\(model.face.count) agenti" : model.face.folder)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.trailing, 4)
    }
}

/// Pallino che pulsa piano, a 20 fotogrammi al secondo: ogni fotogramma ridisegna la finestra.
private struct PulsingDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * .pi / 0.7) + 1) / 2 // 0…1, 0,7 s per mezzo ciclo
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(0.25 + 0.75 * phase)
        }
        .frame(width: 8, height: 8)
    }
}

/// Cerchio tratteggiato che gira a scatti (8 al secondo): si vede che lavora, costa poco.
private struct WorkingSpinner: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 8)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate * 8) % 12
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(IslandTheme.orange, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(Double(step) * 30))
        }
        .frame(width: 11, height: 11)
    }
}

// MARK: - Riga sotto la notch

struct AgentPeekView: View {
    @ObservedObject var model: AgentsModel
    @Environment(\.island) private var theme

    var body: some View {
        if let p = model.peek {
            HStack(spacing: 10) {
                Circle()
                    .fill(stateColor(p.state, theme))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.folder)
                        .font(IslandFont.bodyBold)
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    if p.state == .waiting && p.detail != "Ti aspetta" {
                        Text(p.detail)
                            .font(IslandFont.small)
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                Text(p.state == .waiting ? "Ti aspetta" : "Finito")
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(p.state == .waiting ? theme.accent : IslandTheme.green)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(theme.muted)
                Text("Agenti").font(IslandFont.bodyBold).foregroundStyle(theme.foreground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Impostazioni

@MainActor
final class AgentsSettingsModel: ObservableObject {
    let url = HooksInstaller.defaultURL
    @Published var status: HooksInstaller.Status = .disconnected
    @Published var result: String?

    var path: String { HooksInstaller.displayPath(url) }

    init() { reload() }

    func reload() { status = HooksInstaller.status(at: url) }

    func apply(install: Bool, log: (String) -> Void) {
        do {
            let n = install ? try HooksInstaller.install(at: url) : try HooksInstaller.uninstall(at: url)
            log((install ? "Hook aggiunti: " : "Hook tolti: ") + "\(n)")
            if n == 0 {
                result = install ? "Era già tutto a posto." : "Non c'era niente da togliere."
            } else {
                result = install
                    ? "Fatto. Vale per le sessioni di Claude Code che apri da adesso."
                    : "Fatto: gli hook di Isola sono stati tolti."
            }
        } catch {
            log("Modifica di settings.json non riuscita")
            result = "Non riuscito: " + error.localizedDescription
        }
        reload()
    }
}

struct AgentsSettings: View {
    @ObservedObject var model: AgentsModel
    @StateObject private var hooks = AgentsSettingsModel()
    @State private var confirming = false
    @State private var installing = true

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Stato") {
                    Text(model.serverText)
                        .foregroundStyle(model.serverOK ? Color.secondary : Color.red)
                }
                if !model.serverOK && model.serverState != .starting && model.restartServer != nil {
                    Button("Riprova") { model.restartServer?() }
                }
            }

            Section {
                Text(statusText)
                    .foregroundStyle(statusIsError ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Collega Claude Code") { ask(install: true) }
                        .disabled(hooks.status == .connected)
                    Button("Scollega") { ask(install: false) }
                        .disabled(hooks.status == .disconnected)
                }
                if let r = hooks.result {
                    Text(r)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Gli hook di Claude Code mandano a Isola, con curl e solo dentro questo Mac, l'evento della sessione. Isola usa il nome della cartella, lo stato e lo strumento in uso, e non salva niente.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { hooks.reload() }
        .alert(installing ? "Collegare Claude Code?" : "Scollegare Claude Code?", isPresented: $confirming) {
            Button("Conferma") {
                let log = model.log
                hooks.apply(install: installing) { log?($0) }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(!installing
                 ? "Isola toglierà da \(hooks.path) solo i suoi hook \"curl\". Prima viene salvata una copia."
                 : "Isola aggiungerà a \(hooks.path) un hook \"curl\" per UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop e SessionEnd. Il resto del file non cambia e prima viene salvata una copia (settings.json.isola-backup-…).")
        }
    }

    private func ask(install: Bool) {
        installing = install
        hooks.result = nil
        confirming = true
    }

    private var statusText: String {
        switch hooks.status {
        case .connected:
            return "Collegato: gli hook di Isola sono in \(hooks.path)."
        case .partial:
            return "Collegato in parte: manca qualche hook. Premi Collega per completare."
        case .disconnected:
            return "Non collegato. Gli agenti compariranno dopo il collegamento (vale per le sessioni nuove)."
        case .unreadable(let why):
            return "Non riesco a leggere \(hooks.path): \(why)"
        }
    }

    private var statusIsError: Bool {
        if case .unreadable = hooks.status { return true }
        return false
    }
}
