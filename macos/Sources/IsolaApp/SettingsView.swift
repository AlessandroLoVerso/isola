import AppKit
import IsolaCore
import ServiceManagement
import SwiftUI

/// La finestra Impostazioni: Generale, Aspetto, Moduli e una pagina per ogni modulo che ne ha una.
struct SettingsView: View {
    @ObservedObject var manager: ModuleManager
    @ObservedObject var island: IslandController
    @State private var page: String = "generale"

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label("Generale", systemImage: "gearshape").tag("generale")
                    Label("Aspetto", systemImage: "paintpalette").tag("aspetto")
                    Label("Moduli", systemImage: "square.grid.2x2").tag("moduli")
                }
                Section("Moduli") {
                    ForEach(manager.records.filter { $0.running && $0.module.makeSettings() != nil }) { r in
                        Label(r.module.title, systemImage: r.module.symbol).tag("m:" + r.moduleId)
                    }
                }
                Section {
                    Label("Informazioni", systemImage: "info.circle").tag("info")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detail.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 20)
            }
            .id(page)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case "generale": GeneralPage(island: island)
        case "aspetto": AppearancePage(island: island)
        case "moduli": ModulesPage(manager: manager)
        case "info": InfoPage()
        default:
            if page.hasPrefix("m:"), let r = manager.record(String(page.dropFirst(2))), r.running,
               let v = r.module.makeSettings() {
                v.formStyle(.grouped)
            } else {
                Text("Modulo spento").foregroundStyle(.secondary).padding()
            }
        }
    }
}

private struct GeneralPage: View {
    @ObservedObject var island: IslandController
    @ObservedObject private var store = SettingsStore.shared
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Avvia con il Mac", isOn: Binding(get: { loginOn }, set: setLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Icona nella barra dei menu", isOn: store.binding(\.showStatusItem))
            }
            Section("Comportamento") {
                Picker("Schermo", selection: store.binding(\.screen)) {
                    Text("Quello con la notch").tag("auto")
                    Text("Principale").tag("main")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
                }
                Picker("Sopra le app a schermo intero", selection: store.binding(\.fullscreen)) {
                    Text("Striscia").tag(FullscreenBehavior.striscia)
                    Text("Nascondi").tag(FullscreenBehavior.nascondi)
                    Text("Normale").tag(FullscreenBehavior.normale)
                }
                .pickerStyle(.segmented)
                LabeledContent("Ritardo di apertura") {
                    HStack {
                        Slider(value: store.binding(\.openDelayMs), in: 0...800, step: 50)
                        Text("\(Int(store.current.openDelayMs)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                Toggle("Vibrazione del trackpad quando si apre", isOn: store.binding(\.haptics))
            }
            Section {
                Text("La striscia mostra, accanto alla notch, quello che un modulo vuole tenerti sotto gli occhi anche dentro un gioco o un video (per esempio CPU e GPU). Se nessun modulo la usa, l'isola si nasconde.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Non riuscito: \(error.localizedDescription). Isola deve stare in Applicazioni."
        }
        loginOn = SMAppService.mainApp.status == .enabled
    }
}

private struct AppearancePage: View {
    @ObservedObject var island: IslandController
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("Tema") {
                HStack(spacing: 14) {
                    ForEach(ThemeKind.allCases, id: \.self) { t in
                        ThemeTile(kind: t, selected: store.current.theme == t) {
                            store.update { $0.theme = t }
                        }
                    }
                }
                .padding(.vertical, 6)
                Text(themeNote).font(.caption).foregroundStyle(.secondary)
            }
            Section("Forma") {
                Picker("Forma", selection: store.binding(\.shape)) {
                    Text("Notch").tag(IslandShapeKind.notch)
                    Text("Isola").tag(IslandShapeKind.isola)
                }
                .pickerStyle(.segmented)
                .disabled(island.geometry.hasNotch)
                Text(island.geometry.hasNotch
                     ? "Su questo schermo c'è la notch vera: l'isola ci si attacca sempre."
                     : "Notch: attaccata al bordo in alto. Isola: una pillola staccata dal bordo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var themeNote: String {
        switch store.current.theme {
        case .nero: "Nero si fonde con la notch: da chiusa non si vede il confine."
        case .grafite: "Grigio scuro, come la versione per Windows."
        case .vetro: "Sfocatura di macOS dietro l'isola."
        case .liquido: "Vetro con riflessi di luce sui bordi. La rifrazione vera della versione Windows su Mac richiederebbe il permesso di registrare lo schermo, quindi qui non c'è."
        }
    }
}

private struct ThemeTile: View {
    let kind: ThemeKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: [.purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                    IslandBackground(kind: kind, shape: IslandShape(bodyWidth: 60, bottomRadius: 9, flare: 5, topRadius: 0))
                        .frame(width: 70, height: 22)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: 96, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1))
                Text(kind.label).font(.callout)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ModulesPage: View {
    @ObservedObject var manager: ModuleManager

    var body: some View {
        Form {
            Section {
                ForEach(manager.records) { r in
                    ModuleRow(record: r, manager: manager)
                }
            } footer: {
                Text("Ogni modulo è indipendente: se uno si spegne per un errore, gli altri continuano. L'interruttore lo riprova.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModuleRow: View {
    @ObservedObject var record: ModuleRecord
    let manager: ModuleManager

    var body: some View {
        Toggle(isOn: Binding(get: { record.running }, set: { manager.setEnabled(record, $0) })) {
            HStack(spacing: 10) {
                Image(systemName: record.module.symbol).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.module.title)
                    if let e = record.error {
                        Text("Spento per un errore: \(e)").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

private struct InfoPage: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Versione", value: AppDelegate.version)
                LabeledContent("Codice", value: "github.com/AlessandroLoVerso/isola")
                Button("Mostra i dati nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.root])
                }
            } footer: {
                Text("Niente account, niente telemetria. Vanno in rete solo i testi delle canzoni (se li accendi), il meteo e Spotify (se lo colleghi). Pubblico dominio (Unlicense).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
