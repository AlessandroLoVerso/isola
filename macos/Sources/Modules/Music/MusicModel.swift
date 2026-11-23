import AppKit
import SwiftUI

/// Lo stato che le viste del modulo osservano. Lo aggiorna solo `MusicModule`.
@MainActor
final class MusicModel: ObservableObject {
    enum Source: Equatable { case none, adapter, fallback }

    // Brano
    @Published var hasSession = false
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var bundleId: String?
    @Published var sourceIcon: NSImage?
    @Published var artwork: NSImage?
    @Published var accent: Color?
    @Published var isPlaying = false
    /// Secondi; `nil` = diretta o sconosciuta (niente barra).
    @Published var duration: Double?
    /// Posizione nota (`basePos`) all'istante `baseAt`, avanza con `rate` mentre suona.
    @Published var basePos: Double = 0
    @Published var baseAt = Date()
    @Published var rate: Double = 1
    @Published var canSeek = true

    // Testi
    @Published var lyrics: [LrcLine]?

    // Stato e opzioni
    @Published var source = Source.none
    @Published var needsConsent = false
    @Published var cardVisible = false
    @Published var lyricsEnabled = false
    @Published var peekOnChange = true
    @Published var clientId = ""

    // Azioni (le collega il modulo)
    var onCommand: (MediaCommand) -> Void = { _ in }
    var onSeek: (Double) -> Void = { _ in }
    var onRequestConsent: () -> Void = {}
    var onLyricsToggle: (Bool) -> Void = { _ in }
    var onPeekToggle: (Bool) -> Void = { _ in }
    var onClientIdChange: (String) -> Void = { _ in }
    var onKeyboardFocus: () -> Void = {}
    var onLaunch: (MusicLauncher.Player) -> Void = { _ in }
    var onPlayShortcut: (SpotifyShortcut) -> Void = { _ in }

    // Avvio da Isola
    @Published var launching: String?
    @Published var launchMessage = ""

    var appName: String {
        guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func position(at date: Date) -> Double {
        var p = basePos
        if isPlaying { p += max(0, date.timeIntervalSince(baseAt)) * rate }
        if let duration { p = min(p, duration) }
        return max(0, p)
    }

    func clear() {
        hasSession = false
        title = ""
        artist = ""
        album = ""
        bundleId = nil
        sourceIcon = nil
        artwork = nil
        accent = nil
        isPlaying = false
        duration = nil
        basePos = 0
        baseAt = Date()
        rate = 1
        canSeek = true
        lyrics = nil
    }

    static func time(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
