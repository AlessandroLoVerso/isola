import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Impostazioni › Appunti. Finestra normale: colori di sistema, non quelli dell'isola.
struct ClipboardSettingsView: View {
    @ObservedObject var model: ClipboardHistory
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.enabled)) {
                    Text("Ricorda quello che copi")
                    Text("Spenta, quello che copi non viene salvato.")
                }
                Picker("Quanti elementi", selection: binding(\.maxItems)) {
                    ForEach(ClipboardSettings.sizeChoices, id: \.self) { n in Text("\(n)").tag(n) }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cancella cronologia")
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancella…") { confirmClear = true }
                        .disabled(!model.items.contains { !$0.pinned })
                }
            } header: {
                Text("Cronologia")
            } footer: {
                Text("I fissati non scadono e restano anche dopo la cancellazione.")
            }

            Section("Scorciatoia") {
                Toggle("Apri gli Appunti con la tastiera", isOn: binding(\.hotKeyEnabled))
                Picker("Combinazione", selection: binding(\.hotKey)) {
                    ForEach(ClipHotKey.allCases) { k in Text(k.label).tag(k) }
                }
                .disabled(!model.settings.hotKeyEnabled)
                if model.settings.hotKeyEnabled {
                    if model.hotKeyRegistered {
                        Label("Attiva", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Non disponibile: la usa già un'altra app. Scegline un'altra.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if model.settings.hotKey == .optionCommandV {
                    Text("Nel Finder ⌥⌘V sposta i file copiati: se ti serve, scegli un'altra combinazione.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                if model.settings.ignoredApps.isEmpty {
                    Text("Nessuna app aggiunta.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.ignoredApps, id: \.bundleId) { app in
                    HStack {
                        AppIcon(bundleId: app.bundleId)
                        Text(app.name)
                        Spacer()
                        Button {
                            model.update { s in s.ignoredApps.removeAll { $0.bundleId == app.bundleId } }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Togli")
                    }
                }
                Button("Aggiungi app…") { pickApp() }
            } header: {
                Text("Ignora queste app")
            } footer: {
                Text("Quello che copi da queste app non viene ricordato. I gestori di password (1Password, Bitwarden, Password, Accesso Portachiavi, Dashlane, LastPass, KeePassXC…) e gli elementi che segnano come riservati sono sempre ignorati.")
            }

            Section {
                Text("Testo, link, immagini e file restano solo su questo Mac, in una cartella che puoi leggere solo tu. Un clic su un elemento lo rimette negli appunti: poi incolla con ⌘V.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Cancellare la cronologia?", isPresented: $confirmClear) {
            Button("Cancella", role: .destructive) { model.clearUnpinned() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Gli elementi fissati restano.")
        }
    }

    private var description: String {
        let n = model.items.count
        let p = model.items.filter(\.pinned).count
        var s = n == 0 ? "La cronologia è vuota." : (n == 1 ? "1 elemento" : "\(n) elementi")
        if p > 0 { s += p == 1 ? ", 1 fissato" : ", \(p) fissati" }
        return s
    }

    private func binding<T: Equatable>(_ key: WritableKeyPath<ClipboardSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] },
                set: { v in model.update { $0[keyPath: key] = v } })
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "Scegli un'app da ignorare"
        panel.prompt = "Ignora"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var apps: [ClipboardSettings.IgnoredApp] = []
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            apps.append(.init(bundleId: id, name: name))
        }
        guard !apps.isEmpty else { return }
        model.update { s in
            for a in apps where !s.ignoredApps.contains(where: { $0.bundleId == a.bundleId }) {
                s.ignoredApps.append(a)
            }
        }
    }
}

private struct AppIcon: View {
    let bundleId: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app").frame(width: 18, height: 18)
        }
    }
}
