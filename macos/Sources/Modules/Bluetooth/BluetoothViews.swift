import IsolaCore
import SwiftUI

// MARK: - Batteria

private func batterySymbol(_ p: Int) -> String {
    switch p {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

/// "S 80%" con l'icona della batteria (rossa sotto il 20%).
private struct BatteryBadge: View {
    let label: String
    let percent: Int
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 3) {
            if !label.isEmpty {
                Text(label).font(IslandFont.small).foregroundStyle(theme.muted)
            }
            Image(systemName: batterySymbol(percent))
                .font(.system(size: 11))
                .foregroundStyle(percent <= 20 ? IslandTheme.red : theme.foreground)
            Text("\(percent)%").font(IslandFont.mono(11)).foregroundStyle(theme.foreground)
        }
        .fixedSize()
    }
}

private struct BatteryRow: View {
    let battery: BTBattery
    /// Etichette brevi (peek) o lunghe (scheda).
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            if let l = battery.left { BatteryBadge(label: compact ? "S" : "Sinistra", percent: l) }
            if let r = battery.right { BatteryBadge(label: compact ? "D" : "Destra", percent: r) }
            if let s = battery.single, battery.left == nil, battery.right == nil {
                BatteryBadge(label: "", percent: s)
            }
            if let c = battery.caseLevel { BatteryBadge(label: compact ? "Cust." : "Custodia", percent: c) }
        }
    }
}

// MARK: - Scheda

struct BluetoothCard: View {
    @ObservedObject var model: BluetoothModel
    @Environment(\.island) private var theme

    var body: some View {
        Group {
            if model.devices.isEmpty {
                if model.permission == .denied {
                    IslandEmptyState("exclamationmark.triangle", title: "Bluetooth non consentito",
                                     subtitle: "Consentilo in Impostazioni di Sistema › Privacy e sicurezza › Bluetooth.")
                } else {
                    IslandEmptyState("airpodspro", title: "Nessun dispositivo collegato",
                                     subtitle: "Cuffie, AirPods e casse compaiono qui quando si collegano.")
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(model.devices) { device in
                            DeviceRow(device: device, showBattery: model.settings.showBattery) {
                                model.disconnect(device.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(width: IslandMetrics.card.width, height: IslandMetrics.card.height)
    }
}

private struct DeviceRow: View {
    let device: BTDevice
    let showBattery: Bool
    let disconnect: () -> Void
    @Environment(\.island) private var theme

    var body: some View {
        IslandSurface(padding: 8) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(IslandFont.bodyBold).foregroundStyle(theme.foreground).lineLimit(1)
                    if showBattery && !device.battery.isEmpty {
                        BatteryRow(battery: device.battery, compact: false)
                    } else {
                        Text("Collegato")
                            .font(IslandFont.small).foregroundStyle(theme.muted)
                    }
                }
                Spacer(minLength: 0)
                IslandIconButton("xmark", size: 11, help: "Disconnetti", action: disconnect)
            }
        }
    }
}

// MARK: - Peek

struct BluetoothPeek: View {
    @ObservedObject var model: BluetoothModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if let d = model.peekDevice {
                Image(systemName: d.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.name).font(IslandFont.bodyBold).foregroundStyle(theme.foreground).lineLimit(1)
                    Text("Collegato").font(IslandFont.small).foregroundStyle(theme.muted)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                if model.settings.showBattery {
                    BatteryRow(battery: d.battery, compact: true)
                }
            } else {
                Image(systemName: "airpodspro").foregroundStyle(theme.foreground)
                Text("Bluetooth").font(IslandFont.bodyBold).foregroundStyle(theme.foreground)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: IslandMetrics.peek.width, height: IslandMetrics.peek.height)
        .animation(.easeOut(duration: 0.2), value: model.peekDevice?.battery)
    }
}

// MARK: - Faccia

struct BluetoothFaceLeading: View {
    @ObservedObject var model: BluetoothModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack {
            Image(systemName: model.faceDevice?.symbol ?? "airpodspro")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.foreground)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BluetoothFaceTrailing: View {
    @ObservedObject var model: BluetoothModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if model.settings.showBattery, let p = model.faceDevice?.battery.lowest {
                BatteryBadge(label: "", percent: p)
            }
        }
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Impostazioni

struct BluetoothSettingsView: View {
    @ObservedObject var model: BluetoothModel
    let module: BluetoothModule

    private func binding(_ key: WritableKeyPath<BluetoothSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] },
                set: { v in module.updateSettings { $0[keyPath: key] = v } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Avvisa quando si collegano cuffie o casse", isOn: binding(\.peekOnConnect))
                Toggle("Mostra la batteria", isOn: binding(\.showBattery))
                Toggle("Mostra le cuffie accanto alla notch", isOn: binding(\.showFace))
            } footer: {
                Text("La batteria delle AirPods non ha un'API pubblica: Isola la mostra quando macOS la rende disponibile, altrimenti non mostra niente.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Permesso Bluetooth")
                        Text(permissionText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.permission == .allowed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Apri Impostazioni") { BluetoothModule.openPrivacySettings() }
                    }
                }
            } footer: {
                Text("Serve per sapere quando un dispositivo si collega. macOS lo chiede la prima volta che il modulo si accende. Nomi e dati dei dispositivi restano sul Mac.")
            }
        }
    }

    private var permissionText: String {
        switch model.permission {
        case .allowed: return "Consentito."
        case .denied: return "Negato: Isola non vede i dispositivi."
        case .notAsked: return "Non ancora chiesto."
        }
    }
}
