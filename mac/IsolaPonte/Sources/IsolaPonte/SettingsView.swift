import PonteCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: PonteController
    @State private var keyDraft = ""
    @State private var keyMessage = ""
    @State private var showKey = false
    @State private var confirmNewKey = false

    var body: some View {
        Form {
            Section {
                TextField("Altro computer", text: $controller.peer, prompt: Text("es. pcale"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Text("Il nome dell'altro computer su Tailscale (MagicDNS) o il suo indirizzo 100.x.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Chiave di abbinamento").font(.headline)
                if let key = controller.formattedKey {
                    HStack {
                        Text(showKey ? key : String(repeating: "••••-", count: 7) + "••••")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button(showKey ? "Nascondi" : "Mostra") { showKey.toggle() }
                    }
                } else {
                    Text("Nessuna chiave: incolla quella generata da Isola su Windows, oppure generane una qui.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Incolla la chiave", text: $keyDraft, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit(commitKey)
                    .onChange(of: keyDraft) { _ in tryKey() }
                HStack {
                    Button("Genera chiave") {
                        if controller.hasKey { confirmNewKey = true } else { generate() }
                    }
                    Button("Copia") {
                        controller.copyKey()
                        keyMessage = "Copiata (non va nella cronologia né all'altro computer)"
                    }
                    .disabled(!controller.hasKey)
                    Spacer()
                }
                if !keyMessage.isEmpty {
                    Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("Prova") { controller.test() }
                    Circle().fill(toneColor).frame(width: 8, height: 8)
                    Text(controller.peerStatus.isEmpty ? " " : controller.peerStatus)
                        .foregroundStyle(controller.peerTone == .error ? .red : .primary)
                    Spacer()
                }
                Text(controller.listenStatus).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pausa condivisione", isOn: Binding(get: { controller.paused }, set: { controller.setPaused($0) }))
                Toggle("Apri all'avvio", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                Toggle("Avvisa quando arrivano appunti", isOn: Binding(get: { controller.notify }, set: { controller.setNotify($0) }))
                if !controller.notice.isEmpty {
                    Text(controller.notice).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Generare una chiave nuova?", isPresented: $confirmNewKey) {
            Button("Genera chiave nuova", role: .destructive) { generate() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Quella di adesso smette di funzionare: andrà scritta la nuova anche su Windows.")
        }
    }

    private var toneColor: Color {
        switch controller.peerTone {
        case .ok: return .green
        case .error: return .red
        case .neutral: return .secondary
        }
    }

    private func generate() {
        _ = controller.generateKey()
        showKey = true
        keyMessage = "Chiave nuova salvata nel Portachiavi. Scrivila uguale in Isola su Windows."
    }

    /// Saves as soon as the field holds a valid key.
    private func tryKey() {
        guard Ponte.parseKey(keyDraft) != nil else {
            keyMessage = ""
            return
        }
        commitKey()
    }

    private func commitKey() {
        if keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if controller.setKey(keyDraft) {
            keyDraft = ""
            showKey = false
            keyMessage = "Chiave salvata nel Portachiavi"
        } else {
            keyMessage = "Chiave non valida: servono 32 caratteri (A–Z, 2–7)"
        }
    }
}
