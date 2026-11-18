import AppKit
import SwiftUI

// MARK: - Il contratto dei moduli (vedi MODULES.md)

/// Una funzione dell'isola. Una classe `final`, con `init()` leggero: il lavoro vero comincia
/// in `start(host:)`. Tutto gira sul main thread.
@MainActor
public protocol IslandModule: AnyObject {
    init()
    /// Minuscolo e stabile ("music", "clipboard"...). È la chiave di impostazioni e dati.
    var id: String { get }
    /// Etichetta della scheda, in italiano.
    var title: String { get }
    /// Nome di un SF Symbol (es. "music.note").
    var symbol: String { get }
    /// Ordine delle schede, crescente.
    var order: Int { get }
    var enabledByDefault: Bool { get }

    /// Accende il modulo. Se lancia un errore il modulo viene spento per questa sessione e
    /// l'errore compare in Impostazioni › Moduli.
    func start(host: IslandHost) throws
    /// Libera tutto: timer, osservatori, server, handle. Può essere seguito da un altro `start`.
    func stop()
    /// Chiamata una volta dopo `start`: il contenuto della scheda (area `IslandMetrics.card`,
    /// sfondo già dipinto dall'isola), oppure `nil` se il modulo non ha una scheda.
    func makeCard() -> AnyView?
    /// Chiamata ogni volta che la pagina viene mostrata: la pagina impostazioni, o `nil`.
    func makeSettings() -> AnyView?
}

public extension IslandModule {
    func makeSettings() -> AnyView? { nil }
}

/// Contenuto della pillola chiusa: una parte a sinistra e una a destra della notch.
/// Sugli schermi senza notch le due parti stanno affiancate.
public struct RestingFace {
    public var leading: AnyView
    public var trailing: AnyView
    /// Larghezza di ciascun lato, in punti (la notch del MacBook Air è ~185 pt).
    public var sideWidth: CGFloat

    public init(sideWidth: CGFloat = 72, leading: some View, trailing: some View) {
        self.leading = AnyView(leading)
        self.trailing = AnyView(trailing)
        self.sideWidth = sideWidth
    }
}

/// Facoltativo: cosa mostrare sulla pillola chiusa.
@MainActor
public protocol RestingFaceProvider: IslandModule {
    /// Priorità attuale: vince il valore più alto, 0 = niente da mostrare. A parità vince
    /// l'`order` più basso. Riferimenti: Ora = 1, musica in riproduzione ≈ 50,
    /// batteria in carica ≈ 60, microfono muto o chiamata ≈ 80, agente che aspetta ≈ 90.
    /// Quando cambia chiama `host.refreshRestingFace()`.
    var restingPriority: Int { get }
    /// Un valore nuovo a ogni chiamata. Tieni le viste aggiornate con un modello osservabile.
    func makeRestingFace() -> RestingFace
}

/// Facoltativo: la riga che compare sotto la notch quando chiami `host.attention(...)`.
/// Senza, l'isola mostra icona e titolo del modulo.
@MainActor
public protocol PeekProvider: IslandModule {
    /// Area di circa `IslandMetrics.peek`. Un valore nuovo a ogni chiamata.
    func makePeek() -> AnyView
}

/// Facoltativo: la striscia accanto alla notch sopra le app a schermo intero
/// (se l'utente ha scelto "Striscia").
@MainActor
public protocol StripProvider: IslandModule {
    /// `true` quando hai qualcosa da mostrare. Quando cambia chiama `host.refreshRestingFace()`.
    var wantsStrip: Bool { get }
    func makeStrip() -> RestingFace
}

/// Facoltativo: riceve i file lasciati in qualsiasi punto dell'isola (titolo, schede, pillola),
/// non solo sulla propria scheda. Quando un file entra nell'isola si apre la sua scheda.
/// Vince il primo modulo acceso in ordine di scheda.
@MainActor
public protocol FileDropHandler: IslandModule {
    /// `false` se in questo momento non li vuoi (per esempio se il trascinamento parte da te).
    func acceptFiles(_ providers: [NSItemProvider]) -> Bool
}

// MARK: - Quello che il modulo riceve

/// Ogni modulo riceve la sua istanza. Si chiama dal main thread.
@MainActor
public protocol IslandHost: AnyObject {
    /// Rivaluta le facce della pillola e la striscia.
    func refreshRestingFace()
    /// Apre la scheda del modulo. Se il puntatore non è sopra, si richiude dopo 4 s.
    func openTab(_ moduleId: String)
    /// Allarga la pillola sotto la notch per `duration` secondi (max 300) con il tuo
    /// `PeekProvider`. Compare anche sopra le app a schermo intero. Ignorato a scheda aperta.
    func attention(duration: TimeInterval)
    /// Da chiamare quando l'utente tocca un campo di testo della tua scheda: l'isola prende la
    /// tastiera senza attivare l'app (il resto del Mac resta dov'era).
    func requestKeyboardFocus()
    /// `true` se la scheda dell'isola è aperta su questo modulo.
    var isCardVisible: Bool { get }
    /// Un'app copre lo schermo dell'isola (gioco, video).
    var isFullscreenAppActive: Bool { get }
    /// Notifiche di schermo intero e di scheda visibile. Rimosse da sole in `stop`.
    func onFullscreenChange(_ handler: @escaping (Bool) -> Void)
    func onCardVisibilityChange(_ handler: @escaping (Bool) -> Void)
    /// Lo schermo dell'isola ha la notch vera.
    var screenHasNotch: Bool { get }

    /// JSON in ~/Library/Application Support/Isola/settings/<id>.json. Mancante o rotto ⇒ `fallback`.
    func loadSettings<T: Codable>(_ type: T.Type, fallback: T) -> T
    func saveSettings<T: Codable>(_ value: T)
    /// ~/Library/Application Support/Isola/data/<id>/, creata se manca.
    var dataDirectory: URL { get }
    /// Una riga nel log. Niente nomi di file, app, persone o contenuti.
    func log(_ message: String)
}

// MARK: - Misure

public enum IslandMetrics {
    /// L'area della scheda aperta, sotto la riga delle schede.
    public static let card = CGSize(width: 536, height: 196)
    /// La riga sotto la notch durante `attention`.
    public static let peek = CGSize(width: 360, height: 40)
}
