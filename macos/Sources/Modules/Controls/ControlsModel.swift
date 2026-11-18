import CoreAudio
import Foundation

/// Impostazioni del modulo Controlli (`controls.json`). Le chiavi mancanti prendono il valore
/// predefinito, così i file vecchi restano validi.
struct ControlsSettings: Codable, Equatable {
    /// Scorciatoia globale per il muto.
    var hotkeyEnabled = true
    /// -1 = automatica (⌃⌥M, se occupata ⌃⇧⌥M), 0 = solo ⌃⌥M, 1 = solo ⌃⇧⌥M.
    var hotkeyVariant = -1
    /// Mostra "Microfono spento/acceso" sotto la notch quando cambia il muto.
    var peekOnMute = true
    /// Accanto alla notch: muto e timer della chiamata.
    var showMutedFace = true
    var showCallFace = true
    /// Righe della scheda.
    var showBrightness = true
    var showRadios = true
    /// Volumi d'ingresso salvati quando il microfono non ha un vero "muto" (UID → volume).
    var savedInputVolumes: [String: [Float]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControlsSettings()
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        hotkeyVariant = try c.decodeIfPresent(Int.self, forKey: .hotkeyVariant) ?? d.hotkeyVariant
        peekOnMute = try c.decodeIfPresent(Bool.self, forKey: .peekOnMute) ?? d.peekOnMute
        showMutedFace = try c.decodeIfPresent(Bool.self, forKey: .showMutedFace) ?? d.showMutedFace
        showCallFace = try c.decodeIfPresent(Bool.self, forKey: .showCallFace) ?? d.showCallFace
        showBrightness = try c.decodeIfPresent(Bool.self, forKey: .showBrightness) ?? d.showBrightness
        showRadios = try c.decodeIfPresent(Bool.self, forKey: .showRadios) ?? d.showRadios
        savedInputVolumes = try c.decodeIfPresent([String: [Float]].self, forKey: .savedInputVolumes) ?? [:]
    }
}

/// Stato condiviso da scheda, faccia e peek. Solo main thread.
enum LocationState { case notAsked, allowed, denied }

@MainActor
final class ControlsModel: ObservableObject {
    @Published var settings = ControlsSettings()
    @Published var hotkeyStatusText = ""
    @Published var hotkeyProblem = false
    @Published var locationState = LocationState.notAsked

    // Microfono
    @Published var muted = false
    @Published var inCall = false
    @Published var callTime = "00:00"
    @Published var hotkeyHint = "⌃⌥M"
    @Published var hasInput = false
    /// L'ultimo tentativo di muto non è riuscito (microfono senza muto né volume).
    @Published var muteUnsupported = false

    // Uscita
    @Published var hasOutput = false
    @Published var volume: Double = 0
    @Published var outputMuted = false
    @Published var outputs: [AudioDeviceItem] = []
    @Published var inputs: [AudioDeviceItem] = []
    @Published var outputID: AudioObjectID = 0
    @Published var inputID: AudioObjectID = 0

    // Luminosità
    @Published var brightnessAvailable = false
    @Published var brightness: Double = 0

    // Radio
    @Published var wifiAvailable = false
    @Published var wifiOn = false
    @Published var wifiName: String?
    @Published var bluetoothToggleAvailable = false
    @Published var bluetoothOn: Bool?

    // Righe visibili
    @Published var showBrightness = true
    @Published var showRadios = true

    var editingVolume = false
    var editingBrightness = false

    // Azioni (impostate dal modulo)
    var toggleMute: () -> Void = {}
    var setVolume: (Double) -> Void = { _ in }
    var toggleOutputMute: () -> Void = {}
    var selectOutput: (AudioObjectID) -> Void = { _ in }
    var selectInput: (AudioObjectID) -> Void = { _ in }
    var setBrightness: (Double) -> Void = { _ in }
    var toggleWiFi: () -> Void = {}
    var toggleBluetooth: () -> Void = {}

    var outputName: String { outputs.first { $0.id == outputID }?.name ?? "Nessuna uscita" }
    var inputName: String { inputs.first { $0.id == inputID }?.name ?? "Nessun microfono" }

    var volumeSymbol: String {
        if outputMuted || volume < 0.005 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var wifiSubtitle: String {
        guard wifiOn else { return "Spento" }
        return wifiName ?? "Acceso"
    }

    var bluetoothSubtitle: String {
        switch bluetoothOn {
        case .some(true): return "Acceso"
        case .some(false): return "Spento"
        case .none: return bluetoothToggleAvailable ? "…" : "Impostazioni"
        }
    }
}
