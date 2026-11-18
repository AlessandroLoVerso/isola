import CoreAudio
import IsolaCore
import SwiftUI

// MARK: - Scheda

struct ControlsCard: View {
    @ObservedObject var model: ControlsModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            micColumn
                .frame(width: 112)
            VStack(alignment: .leading, spacing: 8) {
                if model.hasOutput {
                    SliderRow(symbol: model.volumeSymbol,
                              help: model.outputMuted ? "Togli il muto all'audio" : "Metti in muto l'audio",
                              value: Binding(get: { model.outputMuted ? 0 : model.volume },
                                             set: { model.volume = $0; model.setVolume($0) }),
                              onEditing: { model.editingVolume = $0 },
                              onIcon: model.toggleOutputMute)
                }
                if model.showBrightness && model.brightnessAvailable {
                    SliderRow(symbol: "sun.max.fill", help: "Luminosità",
                              value: Binding(get: { model.brightness },
                                             set: { model.brightness = $0; model.setBrightness($0) }),
                              onEditing: { model.editingBrightness = $0 },
                              onIcon: nil)
                }
                HStack(spacing: 8) {
                    DeviceMenu(symbol: "hifispeaker.fill", help: "Uscita audio", title: model.outputName,
                               items: model.outputs, selected: model.outputID, select: model.selectOutput)
                    DeviceMenu(symbol: "mic.fill", help: "Microfono", title: model.inputName,
                               items: model.inputs, selected: model.inputID, select: model.selectInput)
                }
                if model.showRadios {
                    HStack(spacing: 8) {
                        if model.wifiAvailable {
                            RadioChip(symbol: model.wifiOn ? "wifi" : "wifi.slash", title: "Wi-Fi",
                                      subtitle: model.wifiSubtitle, on: model.wifiOn, action: model.toggleWiFi)
                        }
                        RadioChip(symbol: "antenna.radiowaves.left.and.right", title: "Bluetooth",
                                  subtitle: model.bluetoothSubtitle, on: model.bluetoothOn == true,
                                  action: model.toggleBluetooth)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: IslandMetrics.card.width, height: IslandMetrics.card.height)
    }

    private var micColumn: some View {
        VStack(spacing: 6) {
            MicButton(muted: model.muted, action: model.toggleMute)
            Text(model.muted ? "Muto" : "Microfono attivo")
                .font(IslandFont.bodyBold)
                .foregroundStyle(model.muted ? IslandTheme.red : theme.foreground)
                .lineLimit(1)
            Text(model.inCall ? "In chiamata · \(model.callTime)" : model.hotkeyHint)
                .font(model.inCall ? IslandFont.mono(11) : IslandFont.small)
                .foregroundStyle(model.inCall ? IslandTheme.green : theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct MicButton: View {
    let muted: Bool
    let action: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(muted ? Color.white : theme.foreground)
                .frame(width: 64, height: 64)
                .background(Circle().fill(muted ? IslandTheme.red : (hover ? theme.surfaceHover : theme.surface)))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.2), value: muted)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Metti o togli il muto al microfono in tutte le app")
    }
}

private struct SliderRow: View {
    let symbol: String
    let help: String
    @Binding var value: Double
    let onEditing: (Bool) -> Void
    let onIcon: (() -> Void)?
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let onIcon {
                    Button(action: onIcon) { icon }.buttonStyle(.plain).help(help)
                } else {
                    icon.help(help)
                }
            }
            .frame(width: 22)
            Slider(value: $value, in: 0...1, onEditingChanged: onEditing)
                .controlSize(.small)
                .tint(theme.accent)
            Text("\(Int((value * 100).rounded()))")
                .font(IslandFont.mono(11))
                .foregroundStyle(theme.muted)
                .frame(width: 26, alignment: .trailing)
        }
        .frame(height: 24)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.muted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

private struct DeviceMenu: View {
    let symbol: String
    let help: String
    let title: String
    let items: [AudioDeviceItem]
    let selected: AudioObjectID
    let select: (AudioObjectID) -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    select(item.id)
                } label: {
                    if item.id == selected {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(IslandFont.small).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover ? theme.surfaceHover : theme.surface))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .onHover { hover = $0 }
        .help(help)
        .disabled(items.isEmpty)
    }
}

private struct RadioChip: View {
    let symbol: String
    let title: String
    let subtitle: String
    let on: Bool
    let action: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(IslandFont.small).opacity(0.75).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? Color.white : theme.foreground)
            .padding(.horizontal, 10)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? theme.accent : (hover ? theme.surfaceHover : theme.surface)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Faccia e peek

struct ControlsFaceLeading: View {
    @ObservedObject var model: ControlsModel

    var body: some View {
        HStack(spacing: 5) {
            if model.muted {
                Image(systemName: "mic.slash.fill").foregroundStyle(IslandTheme.red)
            } else {
                Image(systemName: "mic.fill").foregroundStyle(IslandTheme.green)
                Circle().fill(IslandTheme.green).frame(width: 6, height: 6)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ControlsFaceTrailing: View {
    @ObservedObject var model: ControlsModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(model.inCall ? IslandFont.mono(13, weight: .semibold) : IslandFont.bodyBold)
                .foregroundStyle(model.muted ? IslandTheme.red : IslandTheme.green)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var text: String {
        if model.muted { return model.inCall ? "Muto · \(model.callTime)" : "Muto" }
        return model.callTime
    }
}

struct ControlsPeek: View {
    @ObservedObject var model: ControlsModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.muted ? IslandTheme.red : theme.foreground)
                .frame(width: 24)
            Text(model.muteUnsupported ? "Questo microfono non si può spegnere"
                 : model.muted ? "Microfono spento" : "Microfono acceso")
                .font(IslandFont.bodyBold)
                .foregroundStyle(theme.foreground)
            Spacer(minLength: 0)
            if !model.hotkeyHint.isEmpty, model.hotkeyHint != "Tocca per il muto" {
                Text(model.hotkeyHint).font(IslandFont.small).foregroundStyle(theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: IslandMetrics.peek.width, height: IslandMetrics.peek.height)
    }
}

// MARK: - Impostazioni

struct ControlsSettingsView: View {
    @ObservedObject var model: ControlsModel
    let module: ControlsModule

    private func binding(_ key: WritableKeyPath<ControlsSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] },
                set: { v in module.updateSettings { $0[keyPath: key] = v } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Scorciatoia globale per il muto", isOn: binding(\.hotkeyEnabled))
                Picker("Combinazione", selection: Binding(
                    get: { model.settings.hotkeyVariant == 0 || model.settings.hotkeyVariant == 1 ? model.settings.hotkeyVariant : -1 },
                    set: { v in module.updateSettings { $0.hotkeyVariant = v } })) {
                    Text("Automatica").tag(-1)
                    Text("⌃⌥M").tag(0)
                    Text("⌃⇧⌥M").tag(1)
                }
                .disabled(!model.settings.hotkeyEnabled)
                Text(model.hotkeyStatusText)
                    .font(.callout)
                    .foregroundStyle(model.hotkeyProblem ? Color.red : Color.secondary)
                Toggle("Mostra «Microfono spento/acceso» sotto la notch", isOn: binding(\.peekOnMute))
            } header: {
                Text("Muto del microfono")
            } footer: {
                Text("«Automatica» usa ⌃⌥M e, se un'altra app l'ha già presa, ⌃⇧⌥M. Il muto agisce sul microfono, quindi vale per tutte le app insieme (FaceTime, Meet, Discord, giochi). Anche un microfono collegato dopo prende lo stato muto.")
            }

            Section("Accanto alla notch") {
                Toggle("Microfono muto", isOn: binding(\.showMutedFace))
                Toggle("Timer della chiamata", isOn: binding(\.showCallFace))
            }

            Section {
                Toggle("Luminosità", isOn: binding(\.showBrightness))
                Toggle("Wi-Fi e Bluetooth", isOn: binding(\.showRadios))
            } header: {
                Text("Nella scheda")
            } footer: {
                Text("Il timer parte quando un'altra app usa il microfono per più di 3 secondi.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nome della rete Wi-Fi")
                        Text(locationText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch model.locationState {
                    case .allowed:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Button("Apri Impostazioni") { LocationAccess.openPrivacySettings() }
                    case .notAsked:
                        Button("Consenti") { module.requestLocation() }
                    }
                }
            } footer: {
                Text("macOS mostra il nome della rete solo alle app con il permesso Posizione. Isola non usa la tua posizione per altro.")
            }
        }
    }

    private var locationText: String {
        switch model.locationState {
        case .allowed: return "Consentito: la scheda mostra il nome della rete."
        case .denied: return "Negato: la scheda mostra solo «Acceso»."
        case .notAsked: return "Senza permesso la scheda mostra solo «Acceso»."
        }
    }
}
